use std::{
    ffi::c_void,
    ptr::{self, NonNull},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
    },
};

use objc2::{AnyThread, ClassType, msg_send, rc::Retained, runtime::AnyObject, sel};
use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart,
    AudioDeviceStop, AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap,
    AudioObjectGetPropertyData, AudioObjectID, AudioObjectPropertyAddress, CATapDescription,
    CATapMuteBehavior,
};
use objc2_core_audio_types::{
    AudioBuffer, AudioBufferList, AudioStreamBasicDescription, AudioTimeStamp,
};
use objc2_core_foundation::{
    CFArray, CFBoolean, CFDictionary, CFNumber, CFRetained, CFString, CFType,
};
use objc2_foundation::{NSMutableArray, NSNumber, NSString, NSUUID, ns_string};

use super::{
    AudioCaptureBackend, AudioCaptureError, AudioFrameConsumer, AudioResponseController,
    AudioTapChannelMode, InterleavedStereoF32, MonoPcmF32,
};

pub type DefaultAudioResponseController =
    AudioResponseController<crate::WallpaperEngine, PlatformAudioCaptureBackend>;

const NO_ERR: i32 = 0;
const K_AUDIO_OBJECT_UNKNOWN: AudioObjectID = 0;
const K_AUDIO_OBJECT_SYSTEM_OBJECT: AudioObjectID = 1;
const K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN: u32 = 0;
const K_AUDIO_AGGREGATE_DRIFT_COMPENSATION_MEDIUM_QUALITY: u32 = 0x40;
const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = fourcc(*b"glob");
const K_AUDIO_HARDWARE_PROPERTY_TRANSLATE_PID_TO_PROCESS_OBJECT: u32 = fourcc(*b"id2p");
const K_AUDIO_TAP_PROPERTY_FORMAT: u32 = fourcc(*b"tfmt");

// === Three resource types, each with its own Drop ===

struct TapResources {
    id: AudioObjectID,
    uid: Retained<NSString>,
}

impl Drop for TapResources {
    fn drop(&mut self) {
        if self.id != K_AUDIO_OBJECT_UNKNOWN {
            unsafe { AudioHardwareDestroyProcessTap(self.id) };
        }
    }
}

impl TapResources {
    /// Creates a process tap and reads its initial stream format.
    /// Returns the tap, the sample rate, and the channel layout the tap
    /// actually delivers, all discovered at creation time.
    ///
    /// Retained as a named constructor (rather than inlined into
    /// `CaptureState::start`) because the Core Audio setup is ~100 lines and
    /// combines PID translation, tap description configuration, tap creation,
    /// and format probing; the dedicated name documents the acquisition step.
    #[allow(clippy::single_call_fn)]
    unsafe fn new(
        _consumer: &Arc<dyn AudioFrameConsumer>,
    ) -> Result<(Self, u32, AudioTapChannelMode), AudioCaptureError> {
        let excluded = {
            let excluded = NSMutableArray::array();
            let process_id = {
                let address = AudioObjectPropertyAddress {
                    mSelector: K_AUDIO_HARDWARE_PROPERTY_TRANSLATE_PID_TO_PROCESS_OBJECT,
                    mScope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
                    mElement: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
                };
                let pid = unsafe { libc::getpid() };
                let mut process_id = K_AUDIO_OBJECT_UNKNOWN;
                let mut size =
                    u32::try_from(std::mem::size_of::<AudioObjectID>()).unwrap_or(u32::MAX);
                let qualifier_size =
                    u32::try_from(std::mem::size_of::<libc::pid_t>()).unwrap_or(u32::MAX);
                let status = unsafe {
                    AudioObjectGetPropertyData(
                        K_AUDIO_OBJECT_SYSTEM_OBJECT,
                        NonNull::from_ref(&address),
                        qualifier_size,
                        (&raw const pid).cast::<c_void>(),
                        NonNull::from_mut(&mut size),
                        NonNull::from_mut(&mut process_id).cast::<c_void>(),
                    )
                };
                if status == NO_ERR {
                    process_id
                } else {
                    K_AUDIO_OBJECT_UNKNOWN
                }
            };
            if process_id != K_AUDIO_OBJECT_UNKNOWN {
                excluded.addObject(&*NSNumber::numberWithUnsignedInt(process_id));
            }
            excluded
        };
        let (description, requested_mode) = unsafe { global_tap_description(&excluded) };

        let name = ns_string!("Wallpaper Engine System Audio Tap");
        let uuid = NSUUID::UUID();
        let tap_uid = uuid.UUIDString();

        unsafe {
            description.setPrivate(true);
            description.setMuteBehavior(CATapMuteBehavior::Unmuted);
            description.setName(name);
            description.setUUID(&uuid);
        }

        let mut process_tap_id = K_AUDIO_OBJECT_UNKNOWN;
        let status =
            unsafe { AudioHardwareCreateProcessTap(Some(&description), &raw mut process_tap_id) };
        if status != NO_ERR {
            return Err(status_error(status, "AudioHardwareCreateProcessTap"));
        }

        // Read the tap's stream format to discover the sample rate.
        let address = AudioObjectPropertyAddress {
            mSelector: K_AUDIO_TAP_PROPERTY_FORMAT,
            mScope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            mElement: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        let mut format = unsafe { core::mem::zeroed::<AudioStreamBasicDescription>() };
        let mut size =
            u32::try_from(std::mem::size_of::<AudioStreamBasicDescription>()).unwrap_or(u32::MAX);
        let status = unsafe {
            AudioObjectGetPropertyData(
                process_tap_id,
                NonNull::from_ref(&address),
                0,
                ptr::null(),
                NonNull::from_mut(&mut size),
                NonNull::from_mut(&mut format).cast::<c_void>(),
            )
        };
        if status != NO_ERR || size as usize != std::mem::size_of::<AudioStreamBasicDescription>() {
            // Tap created but format query failed — destroy the tap before returning error.
            unsafe { AudioHardwareDestroyProcessTap(process_tap_id) };
            return Err(AudioCaptureError::Platform(
                "failed to query tap stream format".to_string(),
            ));
        }
        if format.mSampleRate <= 0.0 || format.mSampleRate > f64::from(u32::MAX) {
            unsafe { AudioHardwareDestroyProcessTap(process_tap_id) };
            return Err(AudioCaptureError::Platform(
                "tap reported an invalid sample rate".to_string(),
            ));
        }

        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let sample_rate = format.mSampleRate as u32;
        // The tap's own format is the authority on what it will deliver: a
        // stereo description that ended up single-channel is reported as mono.
        let channel_mode = if requested_mode == AudioTapChannelMode::Stereo
            && format.mChannelsPerFrame >= 2
        {
            AudioTapChannelMode::Stereo
        } else {
            AudioTapChannelMode::Mono
        };
        Ok((
            Self {
                id: process_tap_id,
                uid: tap_uid,
            },
            sample_rate,
            channel_mode,
        ))
    }
}

struct AggregateResources {
    device_id: AudioObjectID,
    #[allow(dead_code)] // Kept alive for potential future use; Drop uses device_id.
    uid: Retained<NSString>,
}

impl Drop for AggregateResources {
    fn drop(&mut self) {
        if self.device_id != K_AUDIO_OBJECT_UNKNOWN {
            unsafe { AudioHardwareDestroyAggregateDevice(self.device_id) };
        }
    }
}

impl AggregateResources {
    #[allow(clippy::single_call_fn)]
    unsafe fn new(tap: &TapResources) -> Result<Self, AudioCaptureError> {
        let uuid = NSUUID::UUID();
        let aggregate_uid = uuid.UUIDString();
        let tap_entry = CFDictionary::from_slices(
            &[
                &*CFString::from_static_str("uid"),
                &*CFString::from_static_str("drift"),
                &*CFString::from_static_str("drift quality"),
            ],
            &[
                AsRef::<CFType>::as_ref(AsRef::<CFString>::as_ref(&tap.uid)),
                AsRef::<CFType>::as_ref(&CFBoolean::new(true)),
                AsRef::<CFType>::as_ref(&CFNumber::new_i32(
                    i32::try_from(K_AUDIO_AGGREGATE_DRIFT_COMPENSATION_MEDIUM_QUALITY)
                        .expect("Core Audio drift-quality constant fits i32"),
                )),
            ],
        );
        let tap_list = CFArray::from_retained_objects(&[tap_entry]);
        let aggregate: CFRetained<CFDictionary> = unsafe {
            core::mem::transmute(CFDictionary::from_slices(
                &[
                    &*CFString::from_static_str("name"),
                    &*CFString::from_static_str("uid"),
                    &*CFString::from_static_str("private"),
                    &*CFString::from_static_str("taps"),
                    &*CFString::from_static_str("tapautostart"),
                ],
                &[
                    AsRef::<CFType>::as_ref(&CFString::from_static_str(
                        "Wallpaper Engine System Audio Capture",
                    )),
                    AsRef::<CFType>::as_ref(AsRef::<CFString>::as_ref(&aggregate_uid)),
                    AsRef::<CFType>::as_ref(&CFBoolean::new(true)),
                    AsRef::<CFType>::as_ref(&tap_list),
                    AsRef::<CFType>::as_ref(&CFBoolean::new(false)),
                ],
            ))
        };

        let mut device_id = K_AUDIO_OBJECT_UNKNOWN;
        let status = unsafe {
            AudioHardwareCreateAggregateDevice(&aggregate, NonNull::from_mut(&mut device_id))
        };
        if status != NO_ERR {
            return Err(status_error(status, "AudioHardwareCreateAggregateDevice"));
        }

        Ok(Self {
            device_id,
            uid: aggregate_uid,
        })
    }
}

struct IoProcResources {
    aggregate_device_id: AudioObjectID,
    id: AudioDeviceIOProcID,
    #[allow(dead_code)] // Prevents deallocation while I/O proc is active.
    callback_state: Box<CallbackState>,
}

impl Drop for IoProcResources {
    fn drop(&mut self) {
        if self.aggregate_device_id != K_AUDIO_OBJECT_UNKNOWN && self.id.is_some() {
            unsafe {
                let _ = AudioDeviceStop(self.aggregate_device_id, self.id);
                let _ = AudioDeviceDestroyIOProcID(self.aggregate_device_id, self.id);
            }
        }
    }
}

impl IoProcResources {
    #[allow(clippy::single_call_fn)]
    unsafe fn new(
        aggregate: &AggregateResources,
        consumer: Arc<dyn AudioFrameConsumer>,
        sample_rate: u32,
        channel_mode: AudioTapChannelMode,
    ) -> Result<Self, AudioCaptureError> {
        let callback_state = Box::new(CallbackState {
            consumer,
            scratch: Mutex::new([0.0; CallbackState::SCRATCH_SAMPLES]),
            sample_rate: AtomicU32::new(sample_rate),
            channel_mode,
        });
        let client_data = (&raw const *callback_state).cast_mut().cast::<c_void>();
        let mut io_proc_id = None;
        let status = unsafe {
            AudioDeviceCreateIOProcID(
                aggregate.device_id,
                Some(CallbackState::audio_device_io_proc),
                client_data,
                NonNull::from_mut(&mut io_proc_id),
            )
        };
        if status != NO_ERR {
            return Err(status_error(status, "AudioDeviceCreateIOProcID"));
        }
        Ok(Self {
            aggregate_device_id: aggregate.device_id,
            id: io_proc_id,
            callback_state,
        })
    }
}

// === Refactored CaptureState ===

struct CaptureState {
    consumer: Arc<dyn AudioFrameConsumer>,
    sample_rate: u32,
    channel_mode: AudioTapChannelMode,
    running: bool,
    // Drop order (reverse declaration): io_proc → aggregate → tap.
    tap: Option<TapResources>,
    aggregate: Option<AggregateResources>,
    io_proc: Option<IoProcResources>,
}

impl CaptureState {
    fn start(&mut self) -> Result<(), AudioCaptureError> {
        let result = objc2::rc::autoreleasepool(|_| unsafe {
            let (tap, sample_rate, channel_mode) = TapResources::new(&self.consumer)?;
            self.tap = Some(tap);
            self.sample_rate = sample_rate;
            self.channel_mode = channel_mode;

            let aggregate = AggregateResources::new(self.tap.as_ref().unwrap())?;
            self.aggregate = Some(aggregate);

            let io_proc = IoProcResources::new(
                self.aggregate.as_ref().unwrap(),
                self.consumer.clone(),
                self.sample_rate,
                self.channel_mode,
            )?;
            self.io_proc = Some(io_proc);

            // Start the aggregate device.
            let device_id = self.aggregate.as_ref().unwrap().device_id;
            let io_proc_id = self.io_proc.as_ref().unwrap().id;
            let status = AudioDeviceStart(device_id, io_proc_id);
            if status != NO_ERR {
                return Err(status_error(status, "AudioDeviceStart"));
            }

            // The fallback is silent otherwise, and a mono tap changes what the
            // spectrum can mean for every consumer downstream.
            log::info!(
                "[wallpaper-core audio] system audio tap started at {sample_rate} Hz, {}",
                match self.channel_mode {
                    AudioTapChannelMode::Stereo => "stereo",
                    AudioTapChannelMode::Mono => "mono (no usable stereo tap)",
                }
            );
            self.running = true;
            Ok(())
        });
        if result.is_err() {
            self.stop();
        }
        result
    }

    fn stop(&mut self) {
        self.io_proc = None;
        self.aggregate = None;
        self.tap = None;
        self.running = false;
    }
}

impl Drop for CaptureState {
    fn drop(&mut self) {
        self.stop();
    }
}

// === CallbackState with moved audio_device_io_proc ===

struct CallbackState {
    consumer: Arc<dyn AudioFrameConsumer>,
    /// Preallocated so the real-time I/O proc never allocates; sized for the
    /// widest layout (`CHUNK_FRAMES` interleaved stereo frames).
    scratch: Mutex<[f32; Self::SCRATCH_SAMPLES]>,
    sample_rate: AtomicU32,
    channel_mode: AudioTapChannelMode,
}

impl CallbackState {
    const CHUNK_FRAMES: usize = 1024;
    const SCRATCH_SAMPLES: usize = Self::CHUNK_FRAMES * 2;

    /// C ABI I/O proc passed to `AudioDeviceCreateIOProcID`. Kept as a named
    /// associated function because it must cross the FFI boundary as a stable
    /// function pointer — closures cannot be used here.
    #[allow(clippy::single_call_fn)]
    unsafe extern "C-unwind" fn audio_device_io_proc(
        _device: AudioObjectID,
        _now: NonNull<AudioTimeStamp>,
        input_data: NonNull<AudioBufferList>,
        _input_time: NonNull<AudioTimeStamp>,
        _output_data: NonNull<AudioBufferList>,
        _output_time: NonNull<AudioTimeStamp>,
        client_data: *mut c_void,
    ) -> i32 {
        if client_data.is_null() {
            return NO_ERR;
        }

        let state = unsafe { &*client_data.cast::<CallbackState>() };
        let input_data = unsafe { input_data.as_ref() };
        let Ok(frame_count) = input_data.frame_count() else {
            return NO_ERR;
        };
        let Ok(mut scratch) = state.scratch.lock() else {
            return NO_ERR;
        };
        let sample_rate = state.sample_rate.load(Ordering::Relaxed);
        let stereo = state.channel_mode == AudioTapChannelMode::Stereo;
        // Fixed scratch storage keeps even larger device buffers allocation-free.
        for frame_offset in (0..frame_count).step_by(Self::CHUNK_FRAMES) {
            let chunk_frames = (frame_count - frame_offset).min(Self::CHUNK_FRAMES);
            if stereo {
                let chunk = &mut scratch[..chunk_frames * 2];
                if input_data.copy_to_stereo_f32(frame_offset, chunk).is_err() {
                    return NO_ERR;
                }
                if let Ok(frames) = InterleavedStereoF32::new(sample_rate, chunk) {
                    let _ = state.consumer.submit_audio_frames(frames);
                }
            } else {
                let chunk = &mut scratch[..chunk_frames];
                if input_data.copy_to_mono_f32(frame_offset, chunk).is_err() {
                    return NO_ERR;
                }
                if let Ok(frames) = MonoPcmF32::borrowed(sample_rate, chunk) {
                    let _ = state.consumer.submit_mono_audio_frames(frames);
                }
            }
        }

        NO_ERR
    }
}

// === PlatformAudioCaptureBackend ===

pub struct PlatformAudioCaptureBackend {
    state: Option<CaptureState>,
    permission_granted_hint: bool,
}

impl PlatformAudioCaptureBackend {
    /// Creates a platform audio capture backend.
    ///
    /// # Errors
    ///
    /// Currently this constructor does not perform fallible platform setup on
    /// macOS, but the `Result` preserves the public backend API for unsupported
    /// or future platform initialization failures.
    pub fn new() -> Result<Self, AudioCaptureError> {
        Ok(Self {
            state: None,
            permission_granted_hint: false,
        })
    }

    /// Returns the channel layout of the running tap, or `None` when capture
    /// is not running. This is the measured mode, not the requested one: on a
    /// host without a usable stereo tap it reports
    /// [`AudioTapChannelMode::Mono`].
    #[must_use]
    pub fn tap_channel_mode(&self) -> Option<AudioTapChannelMode> {
        self.state
            .as_ref()
            .filter(|state| state.running)
            .map(|state| state.channel_mode)
    }
}

impl AudioCaptureBackend for PlatformAudioCaptureBackend {
    /// Reports a local capture-start hint, not the OS authorization status.
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(self.permission_granted_hint)
    }

    /// Enables a recording attempt. CoreAudio performs OS authorization when
    /// tap recording starts; no permission prompt or TCC preflight runs here.
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        self.permission_granted_hint = true;
        Ok(true)
    }

    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        if self.is_running() {
            return Ok(());
        }

        let mut state = CaptureState {
            consumer,
            sample_rate: 48_000,
            channel_mode: AudioTapChannelMode::Mono,
            running: false,
            tap: None,
            aggregate: None,
            io_proc: None,
        };
        state.start()?;
        self.permission_granted_hint = true;
        self.state = Some(state);
        Ok(())
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        let Some(mut state) = self.state.take() else {
            return Ok(());
        };

        state.stop();
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.state
            .as_ref()
            .is_some_and(|state| state.running && state.io_proc.is_some())
    }
}

impl Drop for PlatformAudioCaptureBackend {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

// === Helpers ===

fn status_error(status: i32, operation: &str) -> AudioCaptureError {
    AudioCaptureError::Platform(format!("{operation} failed (OSStatus={status})"))
}

/// Builds the global-tap description, preferring a stereo tap.
///
/// `initStereoGlobalTapButExcludeProcesses:` is not present on every supported
/// host, and Core Audio may still refuse to build the description, so both the
/// missing-selector and the nil-result cases fall back to the mono tap rather
/// than failing capture outright. The caller reconciles the returned mode
/// against the tap's actual stream format.
unsafe fn global_tap_description(
    excluded: &NSMutableArray<NSNumber>,
) -> (Retained<CATapDescription>, AudioTapChannelMode) {
    let selector = sel!(initStereoGlobalTapButExcludeProcesses:);
    if CATapDescription::class().responds_to(selector) {
        let allocated = CATapDescription::alloc();
        let description: Option<Retained<CATapDescription>> = unsafe {
            msg_send![allocated, initStereoGlobalTapButExcludeProcesses: &**excluded as &AnyObject]
        };
        if let Some(description) = description {
            return (description, AudioTapChannelMode::Stereo);
        }
    }

    let description = unsafe {
        CATapDescription::initMonoGlobalTapButExcludeProcesses(CATapDescription::alloc(), excluded)
    };
    (description, AudioTapChannelMode::Mono)
}

const fn fourcc(bytes: [u8; 4]) -> u32 {
    ((bytes[0] as u32) << 24)
        | ((bytes[1] as u32) << 16)
        | ((bytes[2] as u32) << 8)
        | bytes[3] as u32
}

trait AudioBufferListExt {
    fn buffer_at(&self, index: usize) -> Option<&AudioBuffer>;
    fn buffer_count(&self) -> usize;
    fn frame_count(&self) -> Result<usize, ()>;
    fn copy_to_mono_f32(&self, frame_offset: usize, mono: &mut [f32]) -> Result<(), ()>;
    fn copy_to_stereo_f32(&self, frame_offset: usize, stereo: &mut [f32]) -> Result<(), ()>;
}

trait AudioBufferExt {
    fn f32_frame_count(&self) -> Result<usize, ()>;
}

impl AudioBufferListExt for AudioBufferList {
    fn buffer_at(&self, index: usize) -> Option<&AudioBuffer> {
        if usize::try_from(self.mNumberBuffers).is_ok_and(|count| index < count) {
            Some(unsafe { &*self.mBuffers.as_ptr().add(index) })
        } else {
            None
        }
    }

    fn buffer_count(&self) -> usize {
        usize::try_from(self.mNumberBuffers).unwrap_or(usize::MAX)
    }

    fn frame_count(&self) -> Result<usize, ()> {
        let frame_count = self.buffer_at(0).ok_or(())?.f32_frame_count()?;
        for index in 1..self.buffer_count() {
            if self.buffer_at(index).ok_or(())?.f32_frame_count()? != frame_count {
                return Err(());
            }
        }
        Ok(frame_count)
    }

    fn copy_to_mono_f32(&self, frame_offset: usize, mono: &mut [f32]) -> Result<(), ()> {
        let frame_end = frame_offset.checked_add(mono.len()).ok_or(())?;
        if mono.is_empty() || frame_end > self.frame_count()? {
            return Err(());
        }

        let first = self.buffer_at(0).ok_or(())?;
        if self.buffer_count() == 1 && first.mNumberChannels == 1 {
            let source = unsafe {
                std::slice::from_raw_parts(first.mData.cast::<f32>().add(frame_offset), mono.len())
            };
            mono.copy_from_slice(source);
            return Ok(());
        }

        let mut total_channels = 0usize;
        mono.fill(0.0);
        for index in 0..self.buffer_count() {
            let buffer = self.buffer_at(index).ok_or(())?;
            let channels = usize::try_from(buffer.mNumberChannels).map_err(|_| ())?;
            total_channels = total_channels.checked_add(channels).ok_or(())?;
            let source = unsafe {
                std::slice::from_raw_parts(
                    buffer.mData.cast::<f32>().add(frame_offset * channels),
                    mono.len() * channels,
                )
            };
            for (sample, frame) in mono.iter_mut().zip(source.chunks_exact(channels)) {
                *sample += frame.iter().sum::<f32>();
            }
        }
        #[allow(clippy::cast_precision_loss)]
        let total_channels = total_channels as f32;
        for sample in mono {
            *sample /= total_channels;
        }
        Ok(())
    }

    /// Writes `stereo.len() / 2` interleaved LR frames starting at
    /// `frame_offset`. Channels are assigned by their global position across
    /// the buffer list: even channels feed left, odd channels feed right, and a
    /// single-channel source is duplicated into both sides.
    fn copy_to_stereo_f32(&self, frame_offset: usize, stereo: &mut [f32]) -> Result<(), ()> {
        if stereo.is_empty() || !stereo.len().is_multiple_of(2) {
            return Err(());
        }
        let frames = stereo.len() / 2;
        let frame_end = frame_offset.checked_add(frames).ok_or(())?;
        if frame_end > self.frame_count()? {
            return Err(());
        }

        let first = self.buffer_at(0).ok_or(())?;
        if self.buffer_count() == 1 && first.mNumberChannels == 2 {
            let source = unsafe {
                std::slice::from_raw_parts(
                    first.mData.cast::<f32>().add(frame_offset * 2),
                    stereo.len(),
                )
            };
            stereo.copy_from_slice(source);
            return Ok(());
        }

        let mut side_channels = [0usize; 2];
        let mut global_channel = 0usize;
        stereo.fill(0.0);
        for index in 0..self.buffer_count() {
            let buffer = self.buffer_at(index).ok_or(())?;
            let channels = usize::try_from(buffer.mNumberChannels).map_err(|_| ())?;
            let source = unsafe {
                std::slice::from_raw_parts(
                    buffer.mData.cast::<f32>().add(frame_offset * channels),
                    frames * channels,
                )
            };
            for channel in 0..channels {
                let side = (global_channel + channel) % 2;
                side_channels[side] = side_channels[side].checked_add(1).ok_or(())?;
                for (frame, samples) in source.chunks_exact(channels).enumerate() {
                    stereo[(frame * 2) + side] += samples[channel];
                }
            }
            global_channel = global_channel.checked_add(channels).ok_or(())?;
        }

        if side_channels[1] == 0 {
            // A mono source has no right channel of its own; both sides carry it.
            for frame in 0..frames {
                stereo[(frame * 2) + 1] = stereo[frame * 2];
            }
            side_channels[1] = side_channels[0];
        }
        if side_channels[0] == 0 {
            return Err(());
        }

        #[allow(clippy::cast_precision_loss)]
        let divisors = [side_channels[0] as f32, side_channels[1] as f32];
        for (index, sample) in stereo.iter_mut().enumerate() {
            *sample /= divisors[index % 2];
        }
        Ok(())
    }
}

impl AudioBufferExt for AudioBuffer {
    fn f32_frame_count(&self) -> Result<usize, ()> {
        let channels = usize::try_from(self.mNumberChannels).map_err(|_| ())?;
        let byte_count = usize::try_from(self.mDataByteSize).map_err(|_| ())?;
        let bytes_per_frame = channels.checked_mul(std::mem::size_of::<f32>()).ok_or(())?;
        if bytes_per_frame == 0
            || byte_count == 0
            || !byte_count.is_multiple_of(bytes_per_frame)
            || self.mData.is_null()
            || !self.mData.cast::<f32>().is_aligned()
        {
            return Err(());
        }
        Ok(byte_count / bytes_per_frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // CoreAudio's trailing AudioBuffer array is variable-length at the ABI.
    #[repr(C)]
    struct TestBufferList<const N: usize> {
        count: u32,
        buffers: [AudioBuffer; N],
    }

    impl<const N: usize> TestBufferList<N> {
        fn new(buffers: [AudioBuffer; N]) -> Self {
            Self {
                count: u32::try_from(N).unwrap(),
                buffers,
            }
        }

        fn as_list(&self) -> &AudioBufferList {
            assert!(N > 0);
            // repr(C) preserves AudioBufferList's header, alignment and first
            // buffer, with storage for every buffer advertised by the count.
            unsafe { &*std::ptr::from_ref(self).cast::<AudioBufferList>() }
        }
    }

    fn buffer(channels: u32, samples: &mut [f32]) -> AudioBuffer {
        AudioBuffer {
            mNumberChannels: channels,
            mDataByteSize: u32::try_from(std::mem::size_of_val(samples)).unwrap(),
            mData: samples.as_mut_ptr().cast(),
        }
    }

    #[test]
    fn mixed_interleaved_buffers_preserve_frames_and_all_channels() {
        let mut first = [1.0, 0.0, 0.25, 0.75];
        let mut second = [0.5, 0.5, 1.0, 1.0];
        let buffers = TestBufferList::new([buffer(2, &mut first), buffer(2, &mut second)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(0, &mut mono).unwrap();
        assert_eq!(mono, [0.5, 0.75]);
    }

    #[test]
    fn mixed_channel_counts_weight_channels_instead_of_buffers() {
        let mut stereo = [1.0, 1.0, 0.0, 0.0];
        let mut single = [0.0, 1.0];
        let buffers = TestBufferList::new([buffer(2, &mut stereo), buffer(1, &mut single)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(0, &mut mono).unwrap();
        assert_eq!(mono, [2.0 / 3.0, 1.0 / 3.0]);
        let mut chunk = [0.0];
        buffers.as_list().copy_to_mono_f32(1, &mut chunk).unwrap();
        assert_eq!(chunk, [1.0 / 3.0]);
    }

    #[test]
    fn mono_fast_path_copies_only_requested_frame_range() {
        let mut samples = [0.25, 0.5, 0.75];
        let buffers = TestBufferList::new([buffer(1, &mut samples)]);
        let mut mono = [0.0; 2];
        buffers.as_list().copy_to_mono_f32(1, &mut mono).unwrap();
        assert_eq!(mono, [0.5, 0.75]);
        assert!(buffers.as_list().copy_to_mono_f32(2, &mut mono).is_err());
    }

    #[test]
    fn short_interleaved_buffer_rejects_entire_conversion_before_output() {
        let mut first = [1.0, 0.0, 0.25, 0.75];
        let mut short = [0.5, 0.5];
        let buffers = TestBufferList::new([buffer(2, &mut first), buffer(2, &mut short)]);
        let mut mono = [-1.0; 2];
        assert!(buffers.as_list().copy_to_mono_f32(0, &mut mono).is_err());
        assert_eq!(mono, [-1.0; 2]);
    }

    #[test]
    fn malformed_buffers_are_rejected_before_reading_pcm() {
        let mut samples = [1.0; 4];
        let valid = buffer(2, &mut samples);
        let malformed = [
            AudioBuffer {
                mNumberChannels: 0,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 0,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 15,
                ..valid
            },
            AudioBuffer {
                mDataByteSize: 12,
                ..valid
            },
            AudioBuffer {
                mData: ptr::null_mut(),
                ..valid
            },
            AudioBuffer {
                mData: valid.mData.wrapping_byte_add(1),
                ..valid
            },
        ];
        for invalid in malformed {
            let buffers = TestBufferList::new([valid, invalid]);
            let mut mono = [-1.0; 2];
            assert!(buffers.as_list().copy_to_mono_f32(0, &mut mono).is_err());
            assert_eq!(mono, [-1.0; 2]);
        }
    }

    #[test]
    fn interleaved_stereo_buffer_is_copied_without_downmixing() {
        let mut samples = [1.0, -1.0, 0.25, -0.25, 0.5, -0.5];
        let buffers = TestBufferList::new([buffer(2, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(1, &mut stereo).unwrap();
        assert_eq!(stereo, [0.25, -0.25, 0.5, -0.5]);
    }

    #[test]
    fn separate_channel_buffers_keep_left_and_right_apart() {
        let mut left = [1.0, 0.5];
        let mut right = [-1.0, -0.5];
        let buffers = TestBufferList::new([buffer(1, &mut left), buffer(1, &mut right)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [1.0, -1.0, 0.5, -0.5]);
    }

    #[test]
    fn surround_channels_fold_onto_their_own_side() {
        // Four channels: L, R, Ls, Rs. Each side averages its own members and
        // never borrows from the other.
        let mut samples = [1.0, -1.0, 0.0, 0.0, 0.5, -0.5, 0.5, -0.5];
        let buffers = TestBufferList::new([buffer(4, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [0.5, -0.5, 0.5, -0.5]);
    }

    #[test]
    fn mono_source_is_duplicated_rather_than_left_silent_on_the_right() {
        let mut samples = [0.25, 0.75];
        let buffers = TestBufferList::new([buffer(1, &mut samples)]);
        let mut stereo = [0.0; 4];
        buffers.as_list().copy_to_stereo_f32(0, &mut stereo).unwrap();
        assert_eq!(stereo, [0.25, 0.25, 0.75, 0.75]);
    }

    #[test]
    fn stereo_copy_rejects_out_of_range_and_odd_requests() {
        let mut samples = [1.0, -1.0, 0.25, -0.25];
        let buffers = TestBufferList::new([buffer(2, &mut samples)]);
        let mut stereo = [-2.0; 4];
        assert!(buffers.as_list().copy_to_stereo_f32(1, &mut stereo).is_err());
        assert_eq!(stereo, [-2.0; 4]);
        let mut odd = [-2.0; 3];
        assert!(buffers.as_list().copy_to_stereo_f32(0, &mut odd).is_err());
        assert_eq!(odd, [-2.0; 3]);
    }
}

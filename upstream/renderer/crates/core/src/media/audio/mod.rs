mod capture;

use std::{
    borrow::Cow,
    collections::HashSet,
    error::Error,
    fmt::{Display, Formatter},
    sync::Arc,
};

pub use capture::{DefaultAudioResponseController, PlatformAudioCaptureBackend};

use crate::project::SceneHandle;

/// Safe audio volume wrapper
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioVolume(f32);

impl TryFrom<f32> for AudioVolume {
    type Error = AudioInputError;

    fn try_from(value: f32) -> Result<Self, Self::Error> {
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err(AudioInputError::InvalidAudioVolume(value));
        }
        Ok(Self(value))
    }
}

impl From<AudioVolume> for f32 {
    fn from(value: AudioVolume) -> Self {
        value.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InterleavedStereoF32<'a> {
    sample_rate: u32,
    samples: &'a [f32],
}

impl<'a> InterleavedStereoF32<'a> {
    /// Creates an interleaved stereo PCM view.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero, [`AudioInputError::EmptyInput`] when `samples` is empty, or
    /// [`AudioInputError::OddSampleCount`] when the buffer does not contain
    /// complete left/right sample pairs.
    pub fn new(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        if !samples.len().is_multiple_of(2) {
            return Err(AudioInputError::OddSampleCount(samples.len()));
        }

        Ok(Self {
            sample_rate,
            samples,
        })
    }

    #[must_use]
    pub fn sample_rate(self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(self) -> u32 {
        u32::try_from(self.samples.len() / 2).unwrap_or(u32::MAX)
    }

    #[must_use]
    pub fn samples(self) -> &'a [f32] {
        self.samples
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MonoPcmF32<'a> {
    sample_rate: u32,
    samples: Cow<'a, [f32]>,
}

impl<'a> MonoPcmF32<'a> {
    /// Creates a borrowed mono PCM view.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero or [`AudioInputError::EmptyInput`] when `samples` is empty.
    pub fn borrowed(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        Ok(Self {
            sample_rate,
            samples: Cow::Borrowed(samples),
        })
    }

    /// Creates an owned mono PCM buffer.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero or [`AudioInputError::EmptyInput`] when `samples` is empty.
    pub fn owned(sample_rate: u32, samples: Vec<f32>) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        Ok(Self {
            sample_rate,
            samples: Cow::Owned(samples),
        })
    }

    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(&self) -> u32 {
        u32::try_from(self.samples.len()).unwrap_or(u32::MAX)
    }

    #[must_use]
    pub fn samples(&self) -> &[f32] {
        &self.samples
    }
}

/// Channel layout of the platform system-audio tap actually in use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioTapChannelMode {
    Mono,
    Stereo,
}

/// One fixed-size analysis block ready for the renderer, borrowed from the
/// resampler's own storage so steady-state resampling never allocates.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioResponseBlock<'a> {
    Mono(MonoPcmF32<'a>),
    Stereo(InterleavedStereoF32<'a>),
}

/// Resamples captured PCM to the fixed analysis rate, preserving the channel
/// layout it was fed: a stereo submission stays two independent channels all
/// the way to the analyser.
#[derive(Debug)]
pub struct AudioResponseResampler {
    /// Interleaved when `channels == 2`, otherwise one sample per frame.
    pending: Vec<f32>,
    channels: usize,
    source_position: f64,
    previous: [f32; 2],
    has_previous: bool,
    source_sample_rate: Option<u32>,
}

impl Default for AudioResponseResampler {
    fn default() -> Self {
        Self {
            pending: Vec::new(),
            channels: 1,
            source_position: 0.0,
            previous: [0.0; 2],
            has_previous: false,
            source_sample_rate: None,
        }
    }
}

impl AudioResponseResampler {
    pub const TARGET_SAMPLE_RATE: u32 = 12_000;
    pub const BLOCK_FRAMES: usize = 200;

    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends mono PCM and emits every complete fixed-size mono block.
    ///
    /// # Panics
    ///
    /// Panics only if the fixed-size block emitted internally is rejected as an
    /// invalid mono PCM buffer, which would indicate a broken resampler
    /// invariant.
    pub fn push_mono(
        &mut self,
        frames: &MonoPcmF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 1);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Mono(
                MonoPcmF32::borrowed(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    /// Appends interleaved stereo PCM and emits every complete fixed-size
    /// stereo block, keeping the two channels independent.
    ///
    /// # Panics
    ///
    /// Panics only if the fixed-size block emitted internally is rejected as an
    /// invalid stereo PCM buffer, which would indicate a broken resampler
    /// invariant.
    pub fn push_stereo(
        &mut self,
        frames: &InterleavedStereoF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 2);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Stereo(
                InterleavedStereoF32::new(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    fn accept(&mut self, source_sample_rate: u32, samples: &[f32], channels: usize) {
        // Interpolation state and buffered frames belong to one rate and one
        // channel layout; either change restarts from an empty buffer.
        if self.source_sample_rate != Some(source_sample_rate) || self.channels != channels {
            if self.channels != channels {
                self.pending.clear();
                self.channels = channels;
            }
            self.source_sample_rate = Some(source_sample_rate);
            self.has_previous = false;
            self.source_position = 0.0;
        }

        if source_sample_rate == Self::TARGET_SAMPLE_RATE {
            self.pending.extend_from_slice(samples);
        } else {
            self.append_resampled(source_sample_rate, samples);
        }
    }

    fn drain_blocks(&mut self, mut emit: impl FnMut(&[f32])) {
        let block_len = Self::BLOCK_FRAMES * self.channels;
        let mut consumed = 0usize;
        while consumed + block_len <= self.pending.len() {
            emit(&self.pending[consumed..consumed + block_len]);
            consumed += block_len;
        }
        if consumed > 0 {
            // One compaction of the sub-block remainder per call, never a
            // prefix shuffle per emitted block.
            self.pending.copy_within(consumed.., 0);
            self.pending.truncate(self.pending.len() - consumed);
        }
    }

    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss
    )]
    fn append_resampled(&mut self, source_sample_rate: u32, samples: &[f32]) {
        let channels = self.channels;
        let step = f64::from(source_sample_rate) / f64::from(Self::TARGET_SAMPLE_RATE);
        let carried = usize::from(self.has_previous);
        let previous = self.previous;
        let total_frames = carried + (samples.len() / channels);
        // The carried tail frame is addressed in place instead of being
        // prepended into a scratch buffer.
        let sample_at = |frame: usize, channel: usize| {
            if frame < carried {
                previous[channel]
            } else {
                samples[((frame - carried) * channels) + channel]
            }
        };

        while self.source_position + 1.0 < total_frames as f64 {
            let index = self.source_position.floor() as usize;
            let fraction = (self.source_position - index as f64) as f32;
            for channel in 0..channels {
                let current = sample_at(index, channel);
                let next = sample_at(index + 1, channel);
                self.pending.push(current + ((next - current) * fraction));
            }
            self.source_position += step;
        }

        if total_frames > 0 {
            for channel in 0..channels {
                self.previous[channel] = sample_at(total_frames - 1, channel);
            }
            self.has_previous = true;
            self.source_position = (self.source_position - (total_frames - 1) as f64).max(0.0);
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn pending_for_testing(&self) -> &[f32] {
        &self.pending
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AudioInputError {
    InvalidSampleRate,
    EmptyInput,
    InvalidAudioVolume(f32),
    OddSampleCount(usize),
}

impl Display for AudioInputError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSampleRate => write!(f, "sample_rate must be greater than zero"),
            Self::EmptyInput => write!(f, "samples must not be empty"),
            Self::OddSampleCount(count) => {
                write!(f, "samples must contain stereo pairs, got {count} values")
            }
            Self::InvalidAudioVolume(volume) => {
                write!(f, "audio volume must be between 0.0 and 1.0, got {volume}")
            }
        }
    }
}

impl Error for AudioInputError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioCaptureError {
    UnsupportedPlatform,
    PermissionDenied(String),
    Platform(String),
    Engine(String),
}

impl Display for AudioCaptureError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedPlatform => {
                write!(f, "system audio capture is not supported on this platform")
            }
            Self::PermissionDenied(message) | Self::Platform(message) | Self::Engine(message) => {
                write!(f, "{message}")
            }
        }
    }
}

impl Error for AudioCaptureError {}

pub trait AudioFrameConsumer: Send + Sync {
    /// Accepts interleaved stereo `float32` PCM in LRLR order.
    /// The sample rate is supplied by the caller and is not resampled by this
    /// API.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError>;

    /// Accepts mono `float32` PCM.
    ///
    /// Consumers must not satisfy this by duplicating the mono samples into an
    /// interleaved pair and forwarding them to [`Self::submit_audio_frames`]:
    /// downstream analysis reports a two-channel submission as stereo, and a
    /// mono source is not stereo.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError>;
}

pub trait AudioResponseEngine: AudioFrameConsumer {
    /// Enables or disables audio response for one scene.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine cannot update the scene.
    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError>;
}

pub trait AudioCaptureBackend {
    /// Returns the backend's current permission status or capture-start hint.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission check fails.
    fn has_permission(&self) -> Result<bool, AudioCaptureError>;
    /// Requests permission or allows a subsequent capture startup to request it.
    ///
    /// The macOS CoreAudio backend only records a hint here; OS authorization
    /// happens when tap recording starts. A `true` result is not an OS grant.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission prompt or
    /// status check fails.
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError>;
    /// Starts audio capture and forwards captured frames to `consumer`.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform capture setup fails.
    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError>;
    /// Stops audio capture.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform teardown fails.
    fn stop(&mut self) -> Result<(), AudioCaptureError>;
    #[must_use]
    fn is_running(&self) -> bool;
}

pub struct AudioCaptureController<B: AudioCaptureBackend> {
    consumer: Arc<dyn AudioFrameConsumer>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
    suspended: bool,
}

impl<B: AudioCaptureBackend> AudioCaptureController<B> {
    #[must_use]
    pub fn new(consumer: Arc<dyn AudioFrameConsumer>, backend: B) -> Self {
        Self {
            consumer,
            backend,
            enabled_handles: HashSet::new(),
            suspended: false,
        }
    }

    /// Returns the backend's current permission status or capture-start hint.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// Requests permission (or enables the backend's startup authorization path)
    /// and starts capture if scenes are already enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture_state()?;
        }
        Ok(granted)
    }

    /// Enables or disables capture for one scene.
    /// Scenes remain pending when permission is unavailable. A failed new
    /// activation is rolled back; removals remain committed even if stopping
    /// fails, so departed scenes never retain capture ownership.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when synchronizing backend capture state
    /// fails.
    pub fn set_scene_capturing(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        let inserted = if enabled {
            self.enabled_handles.insert(handle)
        } else {
            self.enabled_handles.remove(&handle);
            false
        };
        if let Err(error) = self.sync_capture_state() {
            if inserted {
                self.enabled_handles.remove(&handle);
            }
            return Err(error);
        }
        Ok(())
    }

    /// Releases capture ownership for scenes absent from `handles`.
    ///
    /// Removals are committed even if backend synchronization fails. Calling
    /// this again retries synchronization without resurrecting departed scenes.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn retain_scenes(&mut self, handles: &[SceneHandle]) -> Result<(), AudioCaptureError> {
        self.enabled_handles
            .retain(|handle| handles.contains(handle));
        self.sync_capture_state()
    }

    /// Globally stops capture without forgetting which scenes requested it.
    /// Resuming restores capture for every scene still enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn set_suspended(&mut self, suspended: bool) -> Result<(), AudioCaptureError> {
        let previous = self.suspended;
        self.suspended = suspended;
        if let Err(error) = self.sync_capture_state() {
            self.suspended = previous;
            if let Err(rollback) = self.sync_capture_state() {
                return Err(AudioCaptureError::Platform(format!(
                    "{error}; audio capture rollback failed: {rollback}"
                )));
            }
            return Err(error);
        }
        Ok(())
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    fn sync_capture_state(&mut self) -> Result<(), AudioCaptureError> {
        let should_run = !self.suspended && !self.enabled_handles.is_empty();
        if should_run {
            if !self.backend.is_running() && self.backend.has_permission()? {
                self.backend.start(Arc::clone(&self.consumer))?;
            }
        } else if self.backend.is_running() {
            self.backend.stop()?;
        }
        Ok(())
    }
}

impl<B: AudioCaptureBackend> Drop for AudioCaptureController<B> {
    fn drop(&mut self) {
        if self.backend.is_running() {
            let _ = self.backend.stop();
        }
    }
}

/// macOS hosts using the built-in backend must provide
/// `NSAudioCaptureUsageDescription` in the embedding app bundle. The native
/// backend captures system output audio and forwards interleaved stereo
/// `float32` PCM while preserving the source sample rate.
pub struct AudioResponseController<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> {
    engine: Arc<E>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> AudioResponseController<E, B> {
    #[must_use]
    pub fn new(engine: Arc<E>, backend: B) -> Self {
        Self {
            engine,
            backend,
            enabled_handles: HashSet::new(),
        }
    }

    /// Returns whether the backend currently has capture permission.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// Requests capture permission and starts capture if scenes are already
    /// enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture_state()?;
        }
        Ok(granted)
    }

    /// Enables or disables audio response for one scene and syncs capture
    /// state.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine update or capture state
    /// sync fails.
    pub fn set_scene_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        self.engine.set_audio_response_enabled(handle, enabled)?;
        if enabled {
            self.enabled_handles.insert(handle);
        } else {
            self.enabled_handles.remove(&handle);
        }
        self.sync_capture_state()
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    fn sync_capture_state(&mut self) -> Result<(), AudioCaptureError> {
        let should_run = !self.enabled_handles.is_empty();
        if should_run {
            if !self.backend.is_running() && self.backend.has_permission()? {
                self.backend.start(self.engine.clone())?;
            }
        } else if self.backend.is_running() {
            self.backend.stop()?;
        }
        Ok(())
    }
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> Drop
    for AudioResponseController<E, B>
{
    fn drop(&mut self) {
        if self.backend.is_running() {
            let _ = self.backend.stop();
        }
    }
}

#[cfg(test)]
mod capture_controller_tests {
    use super::*;

    #[derive(Default)]
    struct TestConsumer;

    impl AudioFrameConsumer for TestConsumer {
        fn submit_audio_frames(
            &self,
            _frames: InterleavedStereoF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }

        fn submit_mono_audio_frames(
            &self,
            _frames: MonoPcmF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }
    }

    #[derive(Default)]
    struct TestBackend {
        running: bool,
        permission_pending: bool,
        fail_start: bool,
        fail_stop: bool,
    }

    impl AudioCaptureBackend for TestBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            Ok(!self.permission_pending)
        }

        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.permission_pending = false;
            Ok(true)
        }

        fn start(
            &mut self,
            _consumer: Arc<dyn AudioFrameConsumer>,
        ) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_start) {
                return Err(AudioCaptureError::Platform("start failed".into()));
            }
            self.running = true;
            Ok(())
        }

        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_stop) {
                return Err(AudioCaptureError::Platform("stop failed".into()));
            }
            self.running = false;
            Ok(())
        }

        fn is_running(&self) -> bool {
            self.running
        }
    }

    #[test]
    fn retaining_scenes_stops_capture_only_after_final_owner_departs() {
        let consumer = Arc::new(TestConsumer);
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(consumer, backend);
        let handle = SceneHandle::new(7);

        controller.set_scene_capturing(handle, true).unwrap();
        let other = SceneHandle::new(8);
        controller.set_scene_capturing(other, true).unwrap();
        controller.retain_scenes(&[other]).unwrap();

        assert!(controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);
        controller.retain_scenes(&[]).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 0);
    }

    #[test]
    fn failed_new_activation_does_not_leave_capture_ownership() {
        let backend = TestBackend {
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        assert!(
            controller
                .set_scene_capturing(SceneHandle::new(7), true)
                .is_err()
        );
        assert_eq!(controller.active_scene_count(), 0);
        controller.request_permission().unwrap();
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(8), true)
            .unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn pending_scene_survives_failed_permission_start_and_repeated_enable() {
        let backend = TestBackend {
            permission_pending: true,
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        let handle = SceneHandle::new(7);
        controller.set_scene_capturing(handle, true).unwrap();
        assert!(!controller.is_capturing());
        assert!(controller.request_permission().is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.backend.fail_start = true;
        assert!(controller.set_scene_capturing(handle, true).is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.request_permission().unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn removals_stay_committed_when_stop_fails_and_allow_teardown_retry() {
        for retain in [false, true] {
            let backend = TestBackend {
                fail_stop: true,
                ..TestBackend::default()
            };
            let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
            let handle = SceneHandle::new(7);
            controller.set_scene_capturing(handle, true).unwrap();
            let result = if retain {
                controller.retain_scenes(&[])
            } else {
                controller.set_scene_capturing(handle, false)
            };
            assert!(result.is_err());
            assert_eq!(controller.active_scene_count(), 0);
            assert!(controller.is_capturing());
            controller.retain_scenes(&[]).unwrap();
            assert!(!controller.is_capturing());
        }
    }

    #[test]
    fn suspending_stops_capture_and_resuming_restores_enabled_scenes() {
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        assert!(controller.is_capturing());

        controller.set_suspended(true).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);

        controller.set_suspended(false).unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn failed_resume_preserves_suspension_across_capture_updates() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.set_suspended(true).unwrap();
        controller.backend.fail_start = true;

        let error = controller.set_suspended(false).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("start failed".into()));
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(!controller.is_capturing());

        controller.set_suspended(true).unwrap();
        controller.set_suspended(false).unwrap();
        assert!(controller.is_capturing());
        controller.set_suspended(true).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 2);
    }

    #[test]
    fn failed_suspend_preserves_running_capture_intent() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_stop = true;

        let error = controller.set_suspended(true).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("stop failed".into()));
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(controller.is_capturing());
        controller.set_suspended(true).unwrap();
        assert!(!controller.is_capturing());
        controller.set_suspended(false).unwrap();
        assert!(controller.is_capturing());
    }
}

use std::sync::{Arc, Mutex};

use crate::{
    media::audio::{
        AudioCaptureBackend, AudioCaptureError, AudioFrameConsumer, AudioInputError,
        AudioResponseBlock, AudioResponseController, AudioResponseEngine, AudioResponseResampler,
        InterleavedStereoF32, MonoPcmF32, PlatformAudioCaptureBackend,
    },
    project::SceneHandle,
};

/// Collects emitted blocks as owned samples so assertions can outlive the
/// resampler's borrow.
#[derive(Default)]
struct CollectedBlocks {
    mono: Vec<Vec<f32>>,
    stereo: Vec<Vec<f32>>,
}

impl CollectedBlocks {
    fn collector(&mut self) -> impl FnMut(AudioResponseBlock<'_>) + '_ {
        |block| match block {
            AudioResponseBlock::Mono(frames) => {
                assert_eq!(frames.sample_rate(), AudioResponseResampler::TARGET_SAMPLE_RATE);
                self.mono.push(frames.samples().to_vec());
            }
            AudioResponseBlock::Stereo(frames) => {
                assert_eq!(frames.sample_rate(), AudioResponseResampler::TARGET_SAMPLE_RATE);
                self.stereo.push(frames.samples().to_vec());
            }
        }
    }
}

#[test]
pub fn case_audio_capture_controller_starts_and_stops_backend() {
    let engine = Arc::new(FakeEngine::default());
    let backend = FakeBackend::default();
    let mut controller = AudioResponseController::new(engine, backend);
    let handle = SceneHandle::new(42);

    controller
        .set_scene_enabled(handle, true)
        .expect("enabling audio response should start capture");
    assert!(controller.is_capturing());
    assert_eq!(controller.active_scene_count(), 1);

    controller
        .set_scene_enabled(handle, false)
        .expect("disabling final scene should stop capture");
    assert!(!controller.is_capturing());
    assert_eq!(controller.active_scene_count(), 0);
}

#[test]
pub fn case_interleaved_stereo_rejects_invalid_buffers() {
    assert!(matches!(
        InterleavedStereoF32::new(0, &[0.0, 0.0]),
        Err(AudioInputError::InvalidSampleRate)
    ));
    assert!(matches!(
        InterleavedStereoF32::new(48_000, &[]),
        Err(AudioInputError::EmptyInput)
    ));
    assert!(matches!(
        InterleavedStereoF32::new(48_000, &[0.0]),
        Err(AudioInputError::OddSampleCount(1))
    ));
}

#[test]
pub fn case_mono_pcm_rejects_invalid_buffers() {
    assert!(matches!(
        MonoPcmF32::borrowed(0, &[0.0]),
        Err(AudioInputError::InvalidSampleRate)
    ));
    assert!(matches!(
        MonoPcmF32::borrowed(12_000, &[]),
        Err(AudioInputError::EmptyInput)
    ));
}

#[test]
pub fn case_audio_response_resampler_preserves_12khz_mono() {
    let mut resampler = AudioResponseResampler::new();
    let input = vec![0.5f32; 200];
    let input = MonoPcmF32::borrowed(12_000, &input).expect("valid mono input");

    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&input, collected.collector());

    assert!(collected.stereo.is_empty());
    assert_eq!(collected.mono.len(), 1);
    assert_eq!(collected.mono[0], vec![0.5f32; 200]);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_audio_response_resampler_converts_48khz_mono_to_12khz() {
    let mut resampler = AudioResponseResampler::new();
    #[allow(clippy::cast_precision_loss)]
    let input = (0..800).map(|frame| frame as f32).collect::<Vec<_>>();
    let input = MonoPcmF32::borrowed(48_000, &input).expect("valid mono input");

    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&input, collected.collector());

    assert_eq!(collected.mono.len(), 1);
    #[allow(clippy::cast_precision_loss)]
    let expected = (0..200).map(|frame| (frame * 4) as f32).collect::<Vec<_>>();
    assert_eq!(collected.mono[0], expected);
}

#[test]
pub fn case_audio_response_resampler_buffers_partial_blocks() {
    let mut resampler = AudioResponseResampler::new();
    let first = vec![1.0f32; 100];
    let second = vec![1.0f32; 100];

    let first = MonoPcmF32::borrowed(12_000, &first).expect("valid first chunk");
    let mut collected = CollectedBlocks::default();
    resampler.push_mono(&first, collected.collector());
    assert!(collected.mono.is_empty());

    let second = MonoPcmF32::borrowed(12_000, &second).expect("valid second chunk");
    resampler.push_mono(&second, collected.collector());
    assert_eq!(collected.mono.len(), 1);
    assert_eq!(collected.mono[0].len(), 200);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_audio_response_resampler_resets_interpolation_across_rate_changes() {
    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();
    let first = MonoPcmF32::borrowed(24_000, &[1.0, 2.0, 99.0]).unwrap();
    resampler.push_mono(&first, collected.collector());
    assert!(collected.mono.is_empty());
    let bypass_samples = [3.0; 198];
    let bypass = MonoPcmF32::borrowed(12_000, &bypass_samples).unwrap();
    resampler.push_mono(&bypass, collected.collector());
    assert!(collected.mono.is_empty());
    let last = MonoPcmF32::borrowed(24_000, &[4.0, 5.0]).unwrap();
    resampler.push_mono(&last, collected.collector());

    assert_eq!(collected.mono.len(), 1);
    let block = &collected.mono[0];
    assert_eq!(block[0], 1.0);
    assert_eq!(&block[1..199], &bypass_samples);
    assert_eq!(block[199], 4.0);
}

#[test]
pub fn case_audio_response_resampler_keeps_stereo_channels_independent() {
    // 48 kHz stereo where the two channels never share a value: a downmix
    // would show up immediately as averaged samples.
    let mut source = Vec::with_capacity(1600);
    for frame in 0..800u32 {
        source.push(f32::from(u16::try_from(frame).unwrap()));
        source.push(-f32::from(u16::try_from(frame).unwrap()));
    }
    let input = InterleavedStereoF32::new(48_000, &source).expect("valid stereo input");

    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();
    resampler.push_stereo(&input, collected.collector());

    assert!(collected.mono.is_empty());
    assert_eq!(collected.stereo.len(), 1);
    let block = &collected.stereo[0];
    assert_eq!(block.len(), 400);
    for frame in 0..200usize {
        let expected = f32::from(u16::try_from(frame * 4).unwrap());
        assert_eq!(block[frame * 2], expected);
        assert_eq!(block[(frame * 2) + 1], -expected);
    }
}

#[test]
pub fn case_audio_response_resampler_discards_buffered_frames_on_layout_change() {
    let mut resampler = AudioResponseResampler::new();
    let mut collected = CollectedBlocks::default();

    let partial = vec![1.0f32; 100];
    let partial = MonoPcmF32::borrowed(12_000, &partial).expect("valid mono chunk");
    resampler.push_mono(&partial, collected.collector());
    assert!(!resampler.pending_for_testing().is_empty());

    // 200 stereo frames are a whole block only if the buffered mono frames were
    // dropped rather than reinterpreted as interleaved samples.
    let stereo = vec![0.25f32; 400];
    let stereo = InterleavedStereoF32::new(12_000, &stereo).expect("valid stereo chunk");
    resampler.push_stereo(&stereo, collected.collector());

    assert!(collected.mono.is_empty());
    assert_eq!(collected.stereo.len(), 1);
    assert_eq!(collected.stereo[0], vec![0.25f32; 400]);
    assert!(resampler.pending_for_testing().is_empty());
}

#[test]
pub fn case_platform_audio_backend_constructs_or_reports_unsupported() {
    match PlatformAudioCaptureBackend::new() {
        Ok(backend) => assert!(!backend.is_running()),
        Err(AudioCaptureError::UnsupportedPlatform) => {}
        Err(error) => panic!("unexpected platform backend error: {error}"),
    }
}

#[derive(Default)]
struct FakeEngine {
    stereo_frames: Mutex<usize>,
    mono_frames: Mutex<usize>,
}

impl AudioFrameConsumer for FakeEngine {
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError> {
        *self
            .stereo_frames
            .lock()
            .expect("frames lock should be valid") += frames.frame_count() as usize;
        Ok(())
    }

    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
        *self.mono_frames.lock().expect("frames lock should be valid") +=
            frames.frame_count() as usize;
        Ok(())
    }
}

impl AudioResponseEngine for FakeEngine {
    fn set_audio_response_enabled(
        &self,
        _handle: SceneHandle,
        _enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        Ok(())
    }
}

#[derive(Default)]
struct FakeBackend {
    running: bool,
}

impl AudioCaptureBackend for FakeBackend {
    fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        Ok(true)
    }

    fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        Ok(true)
    }

    fn start(&mut self, _consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
        self.running = true;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), AudioCaptureError> {
        self.running = false;
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.running
    }
}

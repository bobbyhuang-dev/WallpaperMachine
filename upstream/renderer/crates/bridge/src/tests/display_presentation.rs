//! Per-display presentation suspension and the audio consumer gate it feeds.
//!
//! One screen being covered must stop that screen's work and nothing else, and
//! system audio capture must follow the wallpapers that are actually presenting
//! rather than a single global pause flag.

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{
    BridgePlaybackState, api::BridgeBuilder, engine::FakeEngineFacade,
};

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: None,
        accepts_pointer_input: false,
        window_active: false,
        assignment: None,
    }
}

/// Sets audio response for one committed wallpaper and commits the change.
/// Audio response defaults to enabled, so every test that reasons about audio
/// consumers states the value it means explicitly.
async fn set_audio_response(bridge: &crate::api::WallpaperBridge, wallpaper: &str, enabled: bool) {
    bridge
        .set_audio_response_enabled(wallpaper.into(), enabled)
        .await
        .unwrap();
    bridge.apply_wallpaper_options(wallpaper.into()).await.unwrap();
}

/// Two displays, each with its own scene wallpaper committed to it.
async fn two_display_bridge(engine: &FakeEngineFacade) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    for (wallpaper, display) in [("100", "7"), ("200", "9")] {
        bridge
            .inject_scene_wallpaper_config_for_test(wallpaper, "Scene")
            .await;
        bridge
            .set_display_config_enabled(wallpaper.into(), display.into(), true)
            .await
            .unwrap();
        bridge
            .apply_wallpaper_options(wallpaper.into())
            .await
            .unwrap();
    }
    bridge
}

fn paused_by_display(engine: &FakeEngineFacade) -> Vec<(u32, bool)> {
    let mut scenes: Vec<(u32, bool)> = engine
        .rendered_scenes()
        .iter()
        .map(|scene| (scene.display.display_id, scene.paused))
        .collect();
    scenes.sort_unstable();
    scenes
}

#[tokio::test]
async fn suspending_one_display_leaves_the_other_rendering() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, false)]);

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();

    assert_eq!(
        engine.display_paused_calls(),
        vec![(9, true)],
        "only the covered display is told to stop"
    );
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing,
        "occluding one screen is not the user's Play/Pause choice"
    );

    // The next reconcile has to rebuild the same split, not one global state.
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

#[tokio::test]
async fn resuming_one_display_does_not_resume_a_display_that_is_still_hidden() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    for display in ["7", "9"] {
        bridge
            .set_display_presentation_suspended(display.into(), true)
            .await
            .unwrap();
    }
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();

    assert_eq!(
        engine.display_paused_calls(),
        vec![(7, true), (9, true), (7, false)]
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

#[tokio::test]
async fn a_global_resume_keeps_a_display_that_is_still_covered_paused() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    // Display sleep, then wake: the global transition must not restart the
    // display that is still covered by a window.
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    assert_eq!(
        engine.display_paused_calls().last().copied(),
        Some((9, true)),
        "waking the screens re-applies the per-display suspension"
    );
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

#[tokio::test]
async fn a_user_pause_survives_per_display_resume() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge.pause_all().await.unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    assert_eq!(paused_by_display(&engine), vec![(7, true), (9, true)]);
}

#[tokio::test]
async fn repeated_and_unknown_requests_are_rejected_or_ignored() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    assert_eq!(
        engine.display_paused_calls(),
        vec![(9, true)],
        "an unchanged decision must not be sent again"
    );

    let error = bridge
        .set_display_presentation_suspended("not-a-display".into(), true)
        .await
        .unwrap_err();
    assert!(error.message().contains("not-a-display"), "{error}");
}

#[tokio::test]
async fn a_failed_display_transition_rolls_back_and_can_be_retried() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    engine.fail_next_display_pause();
    assert!(
        bridge
            .set_display_presentation_suspended("9".into(), true)
            .await
            .is_err()
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        paused_by_display(&engine),
        vec![(7, false), (9, false)],
        "a rejected transition must not leave the display recorded as suspended"
    );

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

// MARK: - A01: audio capture follows visible consumers

#[tokio::test]
async fn audio_capture_stops_when_the_only_audio_consumer_is_hidden() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "100", false).await;
    set_audio_response(&bridge, "200", true).await;

    // The only audio-response wallpaper lives on display 9. While it presents,
    // the tap has to run.
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    assert!(
        !engine.audio_capture_suspended(),
        "hiding a display with no audio consumer must not stop the analysis"
    );

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    assert!(
        engine.audio_capture_suspended(),
        "with every audio consumer hidden there is nothing left to analyse"
    );

    bridge
        .set_display_presentation_suspended("9".into(), false)
        .await
        .unwrap();
    assert!(
        !engine.audio_capture_suspended(),
        "the consumer became visible again"
    );
}

#[tokio::test]
async fn a_presentation_transition_never_opens_the_tap_without_a_consumer() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "100", false).await;
    set_audio_response(&bridge, "200", false).await;

    // Neither wallpaper asked for audio response, so no presentation
    // transition is a reason to open the system audio tap.
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(
        engine
            .audio_capture_suspend_calls()
            .iter()
            .all(|suspended| *suspended),
        "resuming presentation with nothing to analyse must not start capture: {:?}",
        engine.audio_capture_suspend_calls()
    );

    // With a consumer on a presenting display, the same transition does open it.
    set_audio_response(&bridge, "100", true).await;
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(!engine.audio_capture_suspended());
}

#[tokio::test]
async fn muting_a_wallpaper_does_not_stop_its_audio_response() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "200", false).await;
    bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    bridge.set_muted("100".into(), true).await.unwrap();
    bridge.set_volume("100".into(), 0.0).await.unwrap();
    bridge.apply_wallpaper_options("100".into()).await.unwrap();
    // A pause transition is what recomputes the gate.
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    assert!(
        !engine.audio_capture_suspended(),
        "silencing wallpaper playback is a different control from system audio response"
    );
}

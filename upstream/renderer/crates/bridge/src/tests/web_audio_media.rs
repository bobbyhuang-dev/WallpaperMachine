//! Web audio consumers, system media replay, and scene optimisation.
//!
//! Three things matter here. A web page consumes system audio without ever
//! owning a renderer scene, so the capture tap has to open and close on
//! something other than scene handles — and mute, which is a different control
//! entirely, must not close it. System media state is remembered so a page that
//! loads late can be caught up, which is worthless if a slow artwork fetch can
//! overwrite the track that replaced it. And the scene optimisation the user
//! can switch off has to survive a restart and reach the renderer.

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{
    api::{BridgeBuilder, WallpaperBridge},
    engine::FakeEngineFacade,
};

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        // A web wallpaper is rendered by the host, so its display has no scene
        // handle. That absence is the whole point of these tests.
        handle: None,
        accepts_pointer_input: false,
        window_active: true,
        assignment: None,
    }
}

/// One web wallpaper committed to display 7, with audio response left at its
/// default of on.
async fn web_bridge(engine: &FakeEngineFacade) -> WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test(
            "300",
            "Web",
            r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        )
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into()).await.unwrap();
    bridge
}

fn tap_open(engine: &FakeEngineFacade) -> bool {
    !engine
        .audio_capture_suspend_calls()
        .last()
        .copied()
        .expect("a subscription change must reach the capture tap")
}

async fn audio_consumers(bridge: &WallpaperBridge) -> u32 {
    bridge
        .renderer_counters()
        .await
        .unwrap()
        .audio_active_consumers
}

#[tokio::test]
async fn capture_tap_follows_web_subscribers_with_no_scene_handle() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert_eq!(
        audio_consumers(&bridge).await,
        0,
        "a web wallpaper that has not registered an audio listener consumes nothing"
    );

    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert!(
        tap_open(&engine),
        "a subscribed web page is a consumer even though it has no scene"
    );
    assert_eq!(audio_consumers(&bridge).await, 1);

    bridge
        .set_web_audio_subscribed("300".into(), 7, false)
        .await
        .unwrap();
    assert!(
        !tap_open(&engine),
        "losing the last consumer must close the tap"
    );
    assert_eq!(audio_consumers(&bridge).await, 0);
}

#[tokio::test]
async fn muting_a_web_wallpaper_does_not_stop_its_audio_response() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();

    bridge.set_muted("300".into(), true).await.unwrap();

    assert_eq!(
        audio_consumers(&bridge).await,
        1,
        "mute silences output; it is not a switch for analysing what the system plays"
    );
    // Re-asserting the same subscription is what makes the tap state the
    // bridge computes after the mute observable.
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert!(tap_open(&engine));
}

#[tokio::test]
async fn turning_audio_response_off_removes_a_subscribed_web_page_as_a_consumer() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert_eq!(audio_consumers(&bridge).await, 1);

    bridge
        .set_audio_response_enabled("300".into(), false)
        .await
        .unwrap();

    assert_eq!(
        audio_consumers(&bridge).await,
        0,
        "a page still holding a listener consumes nothing once its wallpaper has audio response off"
    );
}

#[tokio::test]
async fn pausing_stops_a_web_page_from_consuming_audio() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();

    bridge.pause_all().await.unwrap();
    assert_eq!(audio_consumers(&bridge).await, 0);

    bridge.play_all().await.unwrap();
    assert_eq!(audio_consumers(&bridge).await, 1);
}

#[tokio::test]
async fn the_spectrum_a_page_reads_is_the_one_the_renderer_produced() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert!(
        bridge.web_audio_spectrum().unwrap().is_none(),
        "no analysis yet is not an all-zero spectrum"
    );

    let mut bins = [0.0_f32; 128];
    bins[3] = 0.75;
    bins[67] = 0.25;
    engine.set_audio_spectrum(Some(wallpaper_core::AudioSpectrum128 {
        generation: 42,
        stereo: true,
        bins,
    }));

    let spectrum = bridge.web_audio_spectrum().unwrap().unwrap();
    assert_eq!(spectrum.generation, 42);
    assert!(spectrum.stereo);
    assert_eq!(spectrum.bins.len(), 128);
    // Index 3 is the left channel, 67 the right: the halves must stay
    // independent rather than being averaged or mirrored on the way through.
    assert_eq!(spectrum.bins[3], 0.75);
    assert_eq!(spectrum.bins[67], 0.25);

    // A mono capture is the one case where the two halves are guaranteed
    // equal, so the fixture is built that way rather than as a state the
    // analyser cannot produce.
    let mut mono_bins = [0.0_f32; 128];
    mono_bins[3] = 0.5;
    mono_bins[67] = 0.5;
    engine.set_audio_spectrum(Some(wallpaper_core::AudioSpectrum128 {
        generation: 43,
        stereo: false,
        bins: mono_bins,
    }));
    assert!(
        !bridge.web_audio_spectrum().unwrap().unwrap().stereo,
        "a mono capture must never be reported as stereo"
    );
}

#[tokio::test]
async fn web_wallpapers_report_their_media_integration_consent() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert!(
        !bridge.web_wallpapers().await.unwrap()[0].media_integration_enabled,
        "media integration needs an API this application cannot rely on, so it is opt-in"
    );

    bridge
        .set_media_integration_enabled("300".into(), true)
        .await
        .unwrap();

    assert!(bridge.web_wallpapers().await.unwrap()[0].media_integration_enabled);
    assert!(
        bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .media_integration_enabled
    );
}

#[tokio::test]
async fn a_late_media_event_never_overwrites_newer_state() {
    let bridge = WallpaperBridge::new_for_test();

    assert!(
        bridge.current_system_media_state().is_none(),
        "nothing known yet is not the same as known to be empty"
    );

    bridge
        .submit_system_media_event(
            r#"{"type":"mediaPropertiesChanged","generation":7,"title":"Second"}"#.into(),
        )
        .unwrap();
    // The artwork fetch for the previous track finishing after the track has
    // already changed is the case this ordering exists for.
    bridge
        .submit_system_media_event(
            r#"{"type":"mediaPropertiesChanged","generation":6,"title":"First"}"#.into(),
        )
        .unwrap();

    let state: serde_json::Value =
        serde_json::from_str(&bridge.current_system_media_state().unwrap()).unwrap();
    let events = state.as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["title"], "Second");
}

#[tokio::test]
async fn media_state_keeps_one_event_of_each_kind_verbatim() {
    let bridge = WallpaperBridge::new_for_test();

    for event in [
        r#"{"type":"mediaStatusChanged","enabled":true}"#,
        r#"{"type":"mediaPlaybackChanged","state":0}"#,
        r#"{"type":"mediaTimelineChanged","position":12.5,"duration":200.0}"#,
        r#"{"type":"mediaPlaybackChanged","state":1}"#,
    ] {
        bridge.submit_system_media_event(event.into()).unwrap();
    }

    let state: serde_json::Value =
        serde_json::from_str(&bridge.current_system_media_state().unwrap()).unwrap();
    let events = state.as_array().unwrap();
    assert_eq!(events.len(), 3, "one retained event per listener, not a log");
    let playback = events
        .iter()
        .find(|event| event["type"] == "mediaPlaybackChanged")
        .unwrap();
    assert_eq!(playback["state"], 1, "the newer playback state wins");
    let timeline = events
        .iter()
        .find(|event| event["type"] == "mediaTimelineChanged")
        .unwrap();
    // The payload contract belongs to the host; the bridge must hand back what
    // it was given rather than a reshaped version of it.
    assert_eq!(timeline["position"], 12.5);
    assert_eq!(timeline["duration"], 200.0);
}

#[tokio::test]
async fn an_unrecognised_media_event_is_refused_and_stores_nothing() {
    let bridge = WallpaperBridge::new_for_test();

    let error = bridge
        .submit_system_media_event(r#"{"type":"mediaLyricsChanged","lyrics":"…"}"#.into())
        .unwrap_err();

    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);
    assert!(bridge.current_system_media_state().is_none());
}

#[tokio::test]
async fn scene_optimization_defaults_on_and_survives_a_restart() {
    let temp = tempfile::tempdir().unwrap();
    let store = crate::config::ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert!(
        bridge
            .settings_snapshot()
            .await
            .unwrap()
            .scene_optimization_enabled,
        "a rendering optimisation with no intended visual difference is on unless taken away"
    );

    let snapshot = bridge
        .set_scene_optimization_enabled(false)
        .await
        .unwrap()
        .settings;
    assert!(!snapshot.scene_optimization_enabled);
    assert_eq!(
        engine.scene_optimization_calls(),
        vec![false],
        "the renderer is told directly; a rebuild is not how a frame-building switch is applied"
    );
    assert!(
        engine.rendered_scenes().is_empty(),
        "changing it must not reopen or reparse anything"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert!(
        !restarted
            .settings_snapshot()
            .await
            .unwrap()
            .scene_optimization_enabled
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine.scene_optimization_calls().last().copied(),
        Some(false),
        "a process-wide renderer switch lives in C, so a saved opt-out has to be pushed back in"
    );
}

#[tokio::test]
async fn video_plane_sampling_defaults_off_and_survives_a_restart() {
    // The switch selects between two programs a running scene already holds, so
    // the properties that matter are: off unless asked for, pushed straight at
    // the renderer rather than through a rebuild, and pushed back in on the
    // next launch -- the value lives in C, not in the config the bridge reads.
    let temp = tempfile::tempdir().unwrap();
    let store = crate::config::ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert!(
        !bridge
            .settings_snapshot()
            .await
            .unwrap()
            .scene_video_plane_sampling_enabled,
        "a sampling path whose equivalence is bounded rather than total is opted into"
    );

    let snapshot = bridge
        .set_scene_video_plane_sampling_enabled(true)
        .await
        .unwrap()
        .settings;
    assert!(snapshot.scene_video_plane_sampling_enabled);
    assert_eq!(
        engine.scene_video_plane_sampling_calls(),
        vec![true],
        "the renderer is told directly; both programs were compiled with the graph"
    );
    assert!(
        engine.rendered_scenes().is_empty(),
        "changing it must not reopen, reparse or restart anything"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert!(
        restarted
            .settings_snapshot()
            .await
            .unwrap()
            .scene_video_plane_sampling_enabled
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine
            .scene_video_plane_sampling_calls()
            .last()
            .copied(),
        Some(true),
        "a process-wide renderer switch lives in C, so a saved opt-in has to be pushed back in"
    );
}

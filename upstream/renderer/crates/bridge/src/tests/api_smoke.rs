use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment,
};

use crate::{
    BridgeDisplayMode, BridgeErrorKind, BridgePlaybackState, BridgeScalingMode,
    BridgeWallpaperKind, WallpaperBridge,
    actor::state::BridgeActorState,
    api::BridgeBuilder,
    config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::FakeEngineFacade,
};

#[tokio::test]
async fn bridge_starts_with_playing_state_and_empty_snapshots() {
    let bridge = WallpaperBridge::new_for_test();

    let app = bridge
        .app_snapshot()
        .await
        .expect("app snapshot should be available");
    let library = bridge
        .library_snapshot()
        .await
        .expect("library snapshot should be available");

    assert_eq!(app.playback_state, BridgePlaybackState::Playing);
    assert!(app.active_wallpaper_ids.is_empty());
    assert!(library.wallpapers.is_empty());
    assert_eq!(library.scan_status.total, 0);
}

#[tokio::test]
async fn actor_bridge_starts_with_playing_state_and_empty_snapshots() {
    let bridge = WallpaperBridge::new_for_test();

    let app = bridge
        .app_snapshot()
        .await
        .expect("app snapshot should be available");
    let library = bridge
        .library_snapshot()
        .await
        .expect("library snapshot should be available");

    assert_eq!(app.playback_state, BridgePlaybackState::Playing);
    assert!(app.active_wallpaper_ids.is_empty());
    assert!(library.wallpapers.is_empty());
    assert_eq!(library.scan_status.total, 0);
}

#[tokio::test]
async fn actor_snapshots_reflect_actor_state_mutations() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_wallpaper_for_test("wallpaper-1", "Wallpaper 1", BridgeWallpaperKind::Video)
        .await;
    bridge
        .select_wallpaper("wallpaper-1".to_string())
        .await
        .expect("actor select should work");

    let app = bridge
        .app_snapshot()
        .await
        .expect("app snapshot should be available");
    let library = bridge
        .library_snapshot()
        .await
        .expect("library snapshot should be available");

    assert_eq!(app.selected_wallpaper_id.as_deref(), Some("wallpaper-1"));
    assert_eq!(library.wallpapers.len(), 1);
    assert!(library.wallpapers[0].selected);
}

#[tokio::test]
async fn wallpaper_options_preserves_invalid_input_errors() {
    let bridge = WallpaperBridge::new_for_test();

    let error = bridge
        .wallpaper_options_snapshot("missing".to_string())
        .await
        .expect_err("actor domain error should be returned");

    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
}

pub(super) fn mouse_scenario<F: Future<Output = ()>>(run: impl FnOnce() -> F + Send + 'static) {
    let (done, result) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(run());
        }));
        let _ = done.send(outcome);
    });
    let outcome = result
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("mouse scenario, including bridge drop, must finish within two seconds");
    worker.join().unwrap();
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
}

pub(super) fn active_mouse_display() -> DisplaySnapshotEntry {
    let mut display = identified_display("mouse-display", 7);
    display.handle = Some(wallpaper_core::project::SceneHandle::new(42));
    display
}

pub(super) fn await_mouse_sample(engine: &FakeEngineFacade) {
    let poll = engine.block_next_mouse_poll();
    let reached = poll.wait_until_blocked(std::time::Duration::from_secs(1));
    poll.release();
    assert!(reached, "enabled poller must reach the engine");
}

pub(super) fn assert_mouse_idle(engine: &FakeEngineFacade) {
    let count = engine.mouse_poll_calls().len();
    std::thread::sleep(std::time::Duration::from_millis(80));
    assert_eq!(
        engine.mouse_poll_calls().len(),
        count,
        "quiescent poller must perform no periodic engine work"
    );
}

#[test]
fn mouse_polling_follows_scene_lifetime_and_samples_latest_input_on_resume() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        bridge.app_snapshot().await.unwrap();
        bridge.poll_mouse_position().await.unwrap();
        assert_mouse_idle(&engine);
        assert!(engine.mouse_poll_calls().is_empty());

        engine.set_snapshot(vec![active_mouse_display()]);
        bridge.refresh_displays().await.unwrap();
        await_mouse_sample(&engine);

        bridge.set_presentation_suspended(true).await.unwrap();
        let suspended_count = engine.mouse_poll_calls().len();
        bridge.poll_mouse_position().await.unwrap();
        assert_eq!(engine.mouse_poll_calls().len(), suspended_count);
        assert_mouse_idle(&engine);
        engine.set_mouse_input(123.0, 456.0);
        let resumed = engine.block_next_mouse_poll();
        bridge.set_presentation_suspended(false).await.unwrap();
        let reached = resumed.wait_until_blocked(std::time::Duration::from_secs(1));
        resumed.release();
        assert!(reached, "resume must sample without any new input event");
        assert_eq!(engine.mouse_samples().last(), Some(&(123.0, 456.0)));

        engine.set_snapshot(Vec::new());
        bridge.refresh_displays().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
    });
}

#[test]
fn mouse_polling_disabled_drop_exits_without_an_input_event() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        let bridge = BridgeBuilder::new(engine.clone()).build().unwrap();
        bridge.app_snapshot().await.unwrap();
        assert_mouse_idle(&engine);
        drop(bridge);
        assert!(engine.mouse_poll_calls().is_empty());
    });
}

#[test]
fn bridge_mouse_polling_waits_for_stalled_engine_poll() {
    mouse_scenario(|| async {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![active_mouse_display()]);
        let blocked_poll = engine.block_next_mouse_poll();
        let bridge = BridgeBuilder::new(engine.clone())
            .with_state(BridgeActorState::default())
            .build()
            .expect("bridge should build");

        let reached = blocked_poll.wait_until_blocked(std::time::Duration::from_secs(1));
        if !reached {
            blocked_poll.release();
        }
        assert!(reached, "first mouse poll should reach the engine");
        std::thread::sleep(std::time::Duration::from_millis(80));
        let calls = engine.mouse_poll_calls().len();
        let next_poll = engine.block_next_mouse_poll();
        blocked_poll.release();
        assert_eq!(calls, 1, "only one poll may be in flight");
        let queued = next_poll.wait_until_blocked(std::time::Duration::from_millis(8));
        next_poll.release();
        assert!(!queued, "stalled poll must not accumulate a backlog");
        drop(bridge);
    });
}

#[tokio::test]
async fn settings_snapshot_uses_stable_identity_mirror_target() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![
        identified_display("primary", 1),
        DisplaySnapshotEntry {
            assignment: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
            ..identified_display("secondary", 7)
        },
    ]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    let snapshot = bridge
        .settings_snapshot()
        .await
        .expect("settings snapshot should be available");

    assert_eq!(snapshot.displays.len(), 2);
    let secondary = snapshot
        .displays
        .iter()
        .find(|display| display.title.contains("secondary"))
        .expect("secondary display row should exist");
    assert_eq!(secondary.mode, BridgeDisplayMode::Mirror);
    assert_eq!(secondary.selected_mirror_target.as_deref(), Some("primary"));
}

#[tokio::test]
async fn monitor_information_snapshot_includes_configured_metadata() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![identified_display_with_refresh("primary", 1, 90)]);
    let bridge = BridgeBuilder::new(engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Configured Scene")
        .await;
    bridge
        .set_audio_response_enabled("100".to_string(), true)
        .await
        .unwrap();
    bridge
        .set_scaling_mode(
            "100".to_string(),
            "primary".to_string(),
            BridgeScalingMode::Fill,
        )
        .await
        .unwrap();
    bridge
        .set_target_fps("100".to_string(), "primary".to_string(), 144)
        .await
        .unwrap();

    let snapshot = bridge
        .monitor_information_snapshot()
        .await
        .expect("monitor snapshot should be available");

    assert_eq!(snapshot.rows.len(), 1);
    assert_eq!(snapshot.rows[0].display_id, "primary");
    assert_eq!(snapshot.rows[0].wallpaper_id, "100");
    assert_eq!(snapshot.rows[0].wallpaper_title, "Configured Scene");
    assert_eq!(snapshot.rows[0].scaling_mode, "Fill");
    assert_eq!(snapshot.rows[0].target_fps, "90");
    assert!(snapshot.rows[0].audio_response);
}

#[tokio::test]
async fn wallpaper_options_snapshot_includes_display_config_rows() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![
        identified_display_with_refresh("primary", 1, 60),
        identified_display_with_refresh("secondary", 7, 75),
    ]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".to_string(), "primary".to_string(), true)
        .await
        .unwrap();
    bridge
        .set_display_config_enabled(
            "100".to_string(),
            bridge
                .settings_snapshot()
                .await
                .unwrap()
                .displays
                .into_iter()
                .find(|display| display.title.contains("secondary"))
                .unwrap_or_else(|| panic!("missing display row containing title secondary"))
                .display_id,
            false,
        )
        .await
        .unwrap();
    bridge
        .set_scaling_mode(
            "100".to_string(),
            "primary".to_string(),
            BridgeScalingMode::Fill,
        )
        .await
        .unwrap();
    bridge
        .set_target_fps("100".to_string(), "primary".to_string(), 144)
        .await
        .unwrap();

    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .expect("wallpaper options should be available");

    assert_eq!(snapshot.display_configurations.len(), 2);
    let primary = snapshot
        .display_configurations
        .iter()
        .find(|row| row.display_id == "primary")
        .expect("primary display config row should exist");
    assert!(primary.enabled);
    assert_eq!(primary.scaling_mode, BridgeScalingMode::Fill);
    assert_eq!(primary.target_fps, 60);
    let secondary = snapshot
        .display_configurations
        .iter()
        .find(|row| row.title.contains("secondary"))
        .expect("secondary display config row should exist");
    assert!(!secondary.enabled);
}

#[tokio::test]
async fn snapshot_bundle_records_are_constructible() {
    let bridge = WallpaperBridge::new_for_test();
    let app = bridge.app_snapshot().await.unwrap();
    let library = bridge.library_snapshot().await.unwrap();
    let monitor_information = bridge.monitor_information_snapshot().await.unwrap();
    let settings = bridge.settings_snapshot().await.unwrap();
    let bundle = crate::BridgeSnapshotBundle {
        app,
        library,
        wallpaper_options: None,
        monitor_information,
        settings,
    };

    assert!(bundle.wallpaper_options.is_none());
}

fn identified_display(uuid: &str, display_id: u32) -> DisplaySnapshotEntry {
    identified_display_with_refresh(uuid, display_id, 60)
}

fn identified_display_with_refresh(
    uuid: &str,
    display_id: u32,
    refresh_rate_hz: u32,
) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_string()),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {uuid}")),
    };
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0)
            .with_refresh_rate(refresh_rate_hz),
        handle: None,
        window_active: true,
        assignment: None,
    }
}

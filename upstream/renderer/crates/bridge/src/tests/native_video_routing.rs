//! Routing of plain local videos to the native player.
//!
//! The property that matters is exclusivity. A wallpaper belongs to exactly one
//! renderer at a time: if the native backend takes it, the scene engine must
//! not also be given a scene for it, or the display decodes and presents the
//! same content twice. The second property is that the fallback terminates —
//! a wallpaper the host refuses goes back to the engine and stays there.

use std::fs;

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{api::BridgeBuilder, engine::FakeEngineFacade, paths::BridgePaths};

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

/// A workshop tree with one video project whose media file exists, and one
/// whose declared media file does not.
fn workshop_with_videos(paths: &BridgePaths) {
    for (id, write_media) in [("300", true), ("400", false)] {
        let dir = paths.steam_workshop_root().join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("project.json"),
            format!(
                r#"{{"type":"video","title":"Clip {id}","file":"clip.mp4","description":""}}"#
            ),
        )
        .unwrap();
        if write_media {
            fs::write(dir.join("clip.mp4"), b"not really a video, only its presence matters")
                .unwrap();
        }
    }
}

async fn video_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    bridge
}

async fn commit(bridge: &crate::api::WallpaperBridge, wallpaper: &str, display: &str) {
    // The project model is what the routing reads: the wallpaper config alone
    // says nothing about the project's type or its media file.
    bridge
        .inject_scene_project_for_test(
            wallpaper,
            "Clip",
            &format!(
                r#"{{"type":"video","title":"Clip {wallpaper}","file":"clip.mp4","description":""}}"#
            ),
        )
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, "Video")
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

fn scene_ids(engine: &FakeEngineFacade) -> Vec<String> {
    engine
        .rendered_scenes()
        .iter()
        .map(|scene| scene.scene_path.clone())
        .collect()
}

#[tokio::test]
async fn the_backend_is_off_until_it_is_turned_on() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "nothing may be routed natively before the user opts in"
    );
    assert!(
        scene_ids(&engine).iter().any(|path| path.contains("300")),
        "the scene engine keeps the wallpaper while the backend is off"
    );
}

#[tokio::test]
async fn a_natively_routed_wallpaper_is_not_also_given_to_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    bridge.set_native_video_backend_enabled(true).await.unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert_eq!(native[0].wallpaper_id, "300");
    assert_eq!(native[0].display_id, 7);
    assert!(native[0].media_path.ends_with("clip.mp4"));
    assert!(
        !scene_ids(&engine).iter().any(|path| path.contains("300")),
        "two renderers for one display would decode and present the same clip twice"
    );
}

#[tokio::test]
async fn a_video_whose_media_is_missing_stays_on_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "400", "7").await;

    bridge.set_native_video_backend_enabled(true).await.unwrap();

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "a window that can never play is worse than the engine's own error path"
    );
    assert!(scene_ids(&engine).iter().any(|path| path.contains("400")));
}

#[tokio::test]
async fn a_refused_wallpaper_goes_back_to_the_engine_and_stays_there() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);

    bridge
        .reject_native_video("300".into(), "target frame rate below the clip's rate".into())
        .await
        .unwrap();

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "a refusal must take effect immediately, not on the next unrelated reconcile"
    );
    assert!(
        scene_ids(&engine).iter().any(|path| path.contains("300")),
        "the engine has to take it back or the display shows nothing"
    );

    // Repeating the refusal is not a second fallback: without this the host and
    // the bridge could hand the wallpaper back and forth indefinitely.
    let reconciles_before = engine.calls().len();
    bridge
        .reject_native_video("300".into(), "target frame rate below the clip's rate".into())
        .await
        .unwrap();
    assert_eq!(engine.calls().len(), reconciles_before);
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
}

#[tokio::test]
async fn turning_the_backend_off_returns_every_wallpaper_and_clears_refusals() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    bridge
        .reject_native_video("300".into(), "unsupported".into())
        .await
        .unwrap();

    bridge.set_native_video_backend_enabled(false).await.unwrap();
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
    assert!(scene_ids(&engine).iter().any(|path| path.contains("300")));

    // A refusal describes a configuration the user has since changed, so it
    // must not permanently exclude the wallpaper from a later opt-in.
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);
}

#[tokio::test]
async fn the_native_descriptor_carries_the_users_own_settings() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    bridge.set_volume("300".into(), 0.25).await.unwrap();
    bridge.set_muted("300".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("300".into()).await.unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert!((native[0].volume - 0.25).abs() < f32::EPSILON);
    assert!(native[0].muted);
    // The target rate is the user's requirement, so it has to reach the host
    // rather than being left for the player to choose.
    assert!(native[0].fps > 0);
    assert!(native[0].fps <= 60);
}

#[tokio::test]
async fn hiding_a_display_pauses_only_its_native_wallpaper() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    commit(&bridge, "300", "9").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    let hidden = native.iter().find(|row| row.display_id == 9).unwrap();
    let visible = native.iter().find(|row| row.display_id == 7).unwrap();
    assert!(hidden.paused);
    assert!(
        !visible.paused,
        "one screen being covered must not stop a screen that is still visible"
    );
}

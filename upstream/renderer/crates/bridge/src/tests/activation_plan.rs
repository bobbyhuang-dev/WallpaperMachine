use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, project::ScalingMode,
};

use crate::{
    config::{
        AppConfig, MonitorCfg, MonitorRender, MonitorSettingsCfg, SerializedSelector,
        WallpaperConfig,
    },
    engine::{ActivationInputs, NativeVideoRejection},
    paths::BridgePaths,
};

fn assert_f32_close(actual: f32, expected: f32) {
    assert!(
        (actual - expected).abs() <= f32::EPSILON,
        "expected {actual} to be within f32::EPSILON of {expected}"
    );
}

#[test]
fn activation_plan_marks_scenes_paused_when_global_playback_is_paused() {
    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("100".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    wallpapers.insert("100".to_string(), WallpaperConfig::new_for("100", "scene"));
    let display = DisplayDesc::with_identity(1, DisplayIdentity::default(), 0, 0, 1920, 1080, 2.0);
    let displays = vec![DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: display,
        handle: None,
        accepts_pointer_input: false,
        window_active: true,
        assignment: None,
    }];
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        paused: true,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert!(scenes[0].paused);
}

#[test]
fn activation_plan_gives_primary_wallpaper_to_current_primary_display() {
    let display_a = identified_display("a", 1);
    let display_b = identified_display("b", 3);
    let selector_a =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display_a.identity.clone()));
    let selector_b =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display_b.identity.clone()));
    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: selector_a,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("100".to_string()),
        mirror_target: None,
    });
    config.monitors.push(MonitorCfg {
        selector: selector_b,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("200".to_string()),
        mirror_target: None,
    });
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("300".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    for id in ["100", "200", "300"] {
        wallpapers.insert(id.to_string(), WallpaperConfig::new_for(id, "scene"));
    }

    let displays = vec![display_a.clone(), display_b.clone()];
    let paths = BridgePaths::for_home("/Users/example");
    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();
    assert_eq!(scenes.len(), 2);
    assert_scene(&scenes, 1, "300");
    assert_scene(&scenes, 3, "200");

    let displays = vec![display_b, display_a];
    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();
    assert_eq!(scenes.len(), 2);
    assert_scene(&scenes, 3, "300");
    assert_scene(&scenes, 1, "100");
}

#[test]
fn activation_plan_uses_primary_render_override_for_identity_primary_monitor() {
    let display = identified_display("primary", 1);
    let identity_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()));
    let app_config = AppConfig {
        monitors: vec![MonitorCfg {
            selector: identity_selector,
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some("3539559752".to_string()),
            mirror_target: None,
        }],
        ..AppConfig::default()
    };
    let mut wallpaper = WallpaperConfig::new_for("3539559752", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: SerializedSelector::Primary,
        scaling_mode: "fill".to_string(),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("3539559752".to_string(), wallpaper)]);
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        displays: &[display],
        suspended_displays: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_eq!(
        scenes[0].scaling_mode,
        ScalingMode::Fill,
        "a single-monitor identity assignment must still inherit the saved Primary render override"
    );
}

#[test]
fn activation_plan_uses_identity_render_override_for_primary_monitor() {
    let display = identified_display("primary", 1);
    let identity_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()));
    let app_config = AppConfig {
        monitors: vec![MonitorCfg {
            selector: SerializedSelector::Primary,
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some("3539559752".to_string()),
            mirror_target: None,
        }],
        ..AppConfig::default()
    };
    let mut wallpaper = WallpaperConfig::new_for("3539559752", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: identity_selector,
        scaling_mode: "fill".to_string(),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("3539559752".to_string(), wallpaper)]);
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        displays: &[display],
        suspended_displays: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_eq!(
        scenes[0].scaling_mode,
        ScalingMode::Fill,
        "a Primary assignment must inherit the saved identity render override for the same \
         primary display"
    );
}

fn assert_scene(scenes: &[wallpaper_core::project::SceneDesc], display_id: u32, workshop_id: &str) {
    let scene = scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene for display {display_id}"));
    assert!(
        scene.scene_path.contains(&format!("/{workshop_id}/")),
        "display {display_id} should use wallpaper {workshop_id}, got {}",
        scene.scene_path
    );
}

#[test]
fn mirror_scene_follows_source_wallpaper_with_monitor_overrides() {
    let mut wallpapers = BTreeMap::new();
    let mut wallpaper = WallpaperConfig::new_for("100", "scene");
    wallpaper.audio.response_enabled = true;
    wallpaper.audio.volume = 0.4;
    wallpaper.audio.muted = false;
    wallpapers.insert("100".to_string(), wallpaper);
    let app_config = AppConfig {
        monitors: vec![
            MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                wallpaper: Some("100".to_string()),
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: SerializedSelector::LiveDisplayId { display_id: 2 },
                enabled: true,
                mode: "mirror".to_string(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        monitor_settings: vec![MonitorSettingsCfg {
            selector: SerializedSelector::LiveDisplayId { display_id: 2 },
            scaling_mode: "fill".to_string(),
            scaling_factor: 1.25,
            target_fps: 30,
            volume: 0.2,
            muted: true,
        }],
        ..AppConfig::default()
    };
    let displays = vec![display_snapshot(1), display_snapshot(2)];
    let paths = BridgePaths::for_home("/tmp/test-home");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
    }
    .build()
    .unwrap();

    let primary = scenes
        .iter()
        .find(|scene| scene.display.display_id == 1)
        .expect("primary scene should be active");
    let mirror = scenes
        .iter()
        .find(|scene| scene.display.display_id == 2)
        .expect("mirror scene should be active");
    assert_eq!(scenes.len(), 2);
    assert!(primary.audio_response_enabled);
    assert!(mirror.audio_response_enabled);
    assert_f32_close(f32::from(primary.audio_volume), 0.4);
    assert_f32_close(f32::from(mirror.audio_volume), 0.2);
    assert!(!primary.audio_muted);
    assert!(mirror.audio_muted);
    assert_eq!(
        mirror.scaling_mode,
        wallpaper_core::project::ScalingMode::Fill
    );
    assert!(
        (mirror.scaling_factor - 1.25).abs() <= f64::EPSILON,
        "expected {} to be within f64::EPSILON of 1.25",
        mirror.scaling_factor
    );
    assert_eq!(mirror.fps, 30);
    assert_scene(&scenes, 2, "100");
}

fn identified_display(uuid: &str, display_id: u32) -> DisplaySnapshotEntry {
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
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0),
        handle: None,
        accepts_pointer_input: false,
        window_active: true,
        assignment: None,
    }
}

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            2.0,
        ),
        handle: None,
        accepts_pointer_input: false,
        window_active: true,
        assignment: None,
    }
}

/// The routing rules themselves, with no actor and no host query in the way.
///
/// Every reconcile runs through `build()`/`build_native_video()`, including the
/// ones the bridge spawns for unrelated reasons, so a recorded refusal has to
/// be re-evaluated here rather than only in the bookkeeping that runs when the
/// host asks what to play. Otherwise a wallpaper whose configuration changed
/// would be rendered by both backends until the host happened to ask again.
#[test]
fn a_rejection_recorded_for_another_admission_key_does_not_route_a_video_to_the_engine() {
    let temp = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let project_dir = paths.steam_workshop_root().join("500");
    std::fs::create_dir_all(&project_dir).unwrap();
    std::fs::write(project_dir.join("clip.mp4"), b"clip bytes").unwrap();

    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("500".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    wallpapers.insert("500".to_string(), WallpaperConfig::new_for("500", "video"));
    let mut project_models = BTreeMap::new();
    project_models.insert(
        "500".to_string(),
        crate::project::ProjectModel::parse(
            "500",
            r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#,
        )
        .unwrap(),
    );
    let displays = vec![display_snapshot(1)];
    let suspended = BTreeSet::new();

    fn plan<'a>(
        app_config: &'a AppConfig,
        wallpapers: &'a BTreeMap<String, WallpaperConfig>,
        displays: &'a [DisplaySnapshotEntry],
        suspended_displays: &'a BTreeSet<u32>,
        paths: &'a BridgePaths,
        project_models: &'a BTreeMap<String, crate::project::ProjectModel>,
        native_video_rejected: &'a crate::engine::NativeVideoRejections,
    ) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config,
            wallpapers,
            displays,
            suspended_displays,
            paused: false,
            paths,
            force_shader_refresh: false,
            project_models,
            native_video_enabled: true,
            native_video_rejected,
        }
    }
    macro_rules! inputs {
        ($rejected:expr) => {
            plan(
                &config,
                &wallpapers,
                &displays,
                &suspended,
                &paths,
                &project_models,
                $rejected,
            )
        };
    }

    let empty = BTreeMap::new();
    let live_key = inputs!(&empty).build_native_video().unwrap()[0].admission_key;

    let matching: crate::engine::NativeVideoRejections = [(
        "500".to_string(),
        [(
            live_key,
            NativeVideoRejection {
                reason: "unsupported".to_string(),
            },
        )]
        .into(),
    )]
    .into();
    assert!(inputs!(&matching).build_native_video().unwrap().is_empty());
    assert_eq!(
        inputs!(&matching).build().unwrap().len(),
        1,
        "a refusal that describes the live configuration puts the wallpaper on the engine"
    );

    let stale: crate::engine::NativeVideoRejections = [(
        "500".to_string(),
        [(
            live_key ^ 1,
            NativeVideoRejection {
                reason: "unsupported".to_string(),
            },
        )]
        .into(),
    )]
    .into();
    assert_eq!(
        inputs!(&stale).build_native_video().unwrap().len(),
        1,
        "a refusal for a configuration that no longer exists must not exclude this one"
    );
    assert!(
        inputs!(&stale).build().unwrap().is_empty(),
        "and the engine must not also be handed a scene for it"
    );
}
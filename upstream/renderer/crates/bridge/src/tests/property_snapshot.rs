use crate::{BridgeErrorKind, BridgePropertyKind, BridgePropertyValue, BridgeWallpaperOptionsSnapshot, WallpaperBridge};

fn assert_f64_close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() <= f64::EPSILON,
        "expected {actual} to be within f64::EPSILON of {expected}"
    );
}

#[tokio::test]
async fn property_snapshot_exposes_raw_html_and_edit_dirty_state() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "enabled":{"type":"bool","text":"<b>Bold</b>","value":false}
            }}
        }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();

    assert_eq!(snapshot.properties.len(), 1);
    assert_eq!(snapshot.properties[0].kind, BridgePropertyKind::Bool);
    assert_eq!(snapshot.properties[0].label_html, "<b>Bold</b>");

    bridge
        .edit_property(
            "100".to_string(),
            "enabled".to_string(),
            BridgePropertyValue::Bool { value: true },
        )
        .await
        .unwrap();
    let edited = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(edited.properties[0].dirty);

    bridge
        .restore_property_default("100".to_string(), "enabled".to_string())
        .await
        .unwrap();
    let restored = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!restored.properties[0].dirty);
}

#[tokio::test]
async fn property_snapshot_exposes_slider_metadata_and_accepts_in_range_edit() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test(
        "100",
        "Scene",
        r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "size":{"type":"slider","text":"Size","value":10,"min":10,"max":20,"step":2,"precision":0}
            }}
        }"#,
    ).await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();

    assert_eq!(snapshot.properties[0].kind, BridgePropertyKind::Slider);
    let metadata = snapshot.properties[0]
        .slider
        .as_ref()
        .expect("slider metadata should be exposed");
    assert_f64_close(metadata.min, 10.0);
    assert_f64_close(metadata.max, 20.0);
    assert_f64_close(metadata.step, 2.0);
    assert_eq!(metadata.precision, 0);

    bridge
        .edit_property(
            "100".to_string(),
            "size".to_string(),
            BridgePropertyValue::Number { value: 16.0 },
        )
        .await
        .unwrap();

    let edited = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(edited.properties[0].dirty);
}

#[tokio::test]
async fn invalid_property_edits_return_invalid_input_without_dirtying_draft() {
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test(
        "100",
        "Scene",
        r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "enabled":{"type":"bool","text":"Enabled","value":false},
                "amount":{"type":"slider","text":"Amount","value":10,"min":10,"max":20,"step":2,"precision":0},
                "tint":{"type":"color","text":"Tint","value":"0.1 0.2 0.3"},
                "choice":{"type":"combo","text":"Choice","value":"a","options":[{"label":"A","value":"a"},{"label":"B","value":"b"}]}
            }}
        }"#,
    ).await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let invalid_edits = [
        ("missing", BridgePropertyValue::Bool { value: true }),
        (
            "enabled",
            BridgePropertyValue::String {
                value: "true".into(),
            },
        ),
        ("amount", BridgePropertyValue::Number { value: f64::NAN }),
        (
            "amount",
            BridgePropertyValue::Number {
                value: f64::INFINITY,
            },
        ),
        ("amount", BridgePropertyValue::Number { value: 22.0 }),
        (
            "tint",
            BridgePropertyValue::ColorRgb {
                red: 1.2,
                green: 0.0,
                blue: 0.0,
            },
        ),
        (
            "tint",
            BridgePropertyValue::ColorRgb {
                red: f64::NAN,
                green: 0.0,
                blue: 0.0,
            },
        ),
        (
            "choice",
            BridgePropertyValue::String {
                value: "missing".into(),
            },
        ),
    ];

    for (property_id, value) in invalid_edits {
        let error = bridge
            .edit_property("100".to_string(), property_id.to_string(), value)
            .await
            .expect_err("invalid property edit should be rejected");
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        let snapshot = bridge
            .wallpaper_options_snapshot("100".to_string())
            .await
            .unwrap();
        assert!(
            !snapshot.dirty,
            "invalid edit for {property_id} must not dirty the draft"
        );
        assert!(
            snapshot.properties.iter().all(|property| !property.dirty),
            "invalid edit for {property_id} must not dirty any property"
        );
    }
}

#[tokio::test]
async fn restore_unknown_property_returns_invalid_input_without_dirtying_draft() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "enabled":{"type":"bool","text":"Enabled","value":false}
            }}
        }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let error = bridge
        .restore_property_default("100".to_string(), "missing".to_string())
        .await
        .expect_err("unknown property restore should be rejected");

    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert!(!snapshot.dirty);
    assert!(snapshot.properties.iter().all(|property| !property.dirty));
}

#[tokio::test]
async fn combo_snapshot_options_preserve_labels_and_use_editable_value_types() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "choice":{"type":"combo","value":1,"options":[
                        {"label":"English","value":1},
                        {"label":"日本語","value":"2"},
                        {"label":"Enabled","value":true},
                        {"label":"Color-like identifier","value":"0.1 0.2 0.3"}
                    ]}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let snapshot = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    let choice = &snapshot.properties[0];
    assert_eq!(choice.kind, BridgePropertyKind::Combo);
    assert_eq!(choice.value, BridgePropertyValue::String { value: "1".into() });
    assert_eq!(choice.default_value, choice.value);
    assert_eq!(
        choice.combo_options.iter().map(|option| (option.label.as_str(), &option.value)).collect::<Vec<_>>(),
        vec![
            ("English", &BridgePropertyValue::String { value: "1".into() }),
            ("日本語", &BridgePropertyValue::String { value: "2".into() }),
            ("Enabled", &BridgePropertyValue::String { value: "true".into() }),
            ("Color-like identifier", &BridgePropertyValue::String { value: "0.1 0.2 0.3".into() }),
        ]
    );

    for option in &choice.combo_options {
        let edited = bridge
            .edit_property("100".to_string(), "choice".to_string(), option.value.clone())
            .await
            .unwrap()
            .wallpaper_options;
        assert_eq!(edited.properties[0].value, option.value);
    }
    let restored = bridge
        .restore_property_default("100".to_string(), "choice".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_eq!(restored.properties[0].value, choice.default_value);
    assert!(!restored.dirty);
}

fn assert_property_ids(snapshot: &BridgeWallpaperOptionsSnapshot, expected: &[&str]) {
    assert_eq!(
        snapshot.properties.iter().map(|property| property.id.as_str()).collect::<Vec<_>>(),
        expected
    );
}

#[tokio::test]
async fn conditional_snapshot_tracks_language_defaults_discard_and_hidden_overrides() {
    let bridge = WallpaperBridge::new_for_test();
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
                "type":"scene",
                "general":{"properties":{
                    "language":{"type":"combo","value":"1","index":0,"options":[
                        {"label":"English","value":"1"},
                        {"label":"日本語","value":"2"}
                    ]},
                    "english":{"type":"bool","value":true,"index":1,"condition":"language.value == 1"},
                    "japanese":{"type":"text","text":"日本語","index":2,"condition":"language.value == 2"},
                    "dependent":{"type":"text","text":"Disabled","index":3,"condition":"!english.value"},
                    "malformed":{"type":"text","text":"Still visible","index":4,"condition":"language.value = 1"}
                }}
            }"#,
        )
        .await;
    bridge.select_wallpaper("100".to_string()).await.unwrap();

    let initial = bridge
        .wallpaper_options_snapshot("100".to_string())
        .await
        .unwrap();
    assert_property_ids(&initial, &["language", "english", "malformed"]);

    let edited = bridge
        .edit_property("100".to_string(), "english".to_string(), BridgePropertyValue::Bool { value: false })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&edited, &["language", "english", "dependent", "malformed"]);

    let japanese = bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&japanese, &["language", "japanese", "dependent", "malformed"]);
    assert!(japanese.dirty);

    let restored = bridge
        .restore_property_default("100".to_string(), "language".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&restored, &["language", "english", "dependent", "malformed"]);
    let english = restored.properties.iter().find(|property| property.id == "english").unwrap();
    assert_eq!(english.value, BridgePropertyValue::Bool { value: false });
    assert!(english.dirty);

    bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap();
    let discarded = bridge
        .cancel_wallpaper_options("100".to_string())
        .await
        .unwrap()
        .wallpaper_options;
    assert_eq!(discarded.properties, initial.properties);
    assert!(!discarded.dirty);

    // A hidden property's authored default must still participate in conditions.
    let japanese_default = bridge
        .edit_property("100".to_string(), "language".to_string(), BridgePropertyValue::String { value: "2".into() })
        .await
        .unwrap()
        .wallpaper_options;
    assert_property_ids(&japanese_default, &["language", "japanese", "malformed"]);
}

#[tokio::test]
async fn user_shortcut_offers_the_actions_this_host_can_carry_out() {
    // The author declares that a shortcut exists and leaves its value empty;
    // what it does is the user's choice, so it has to reach them as a choice.
    let bridge = WallpaperBridge::new_for_test();
    bridge.inject_scene_project_for_test(
        "100",
        "Scene",
        r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "playpausebutton":{"type":"usershortcut","text":"Play/Pause","value":""}
            }}
        }"#,
    ).await;

    let snapshot = bridge.wallpaper_options_snapshot("100".to_string()).await.unwrap();
    let property = snapshot
        .properties
        .iter()
        .find(|entry| entry.id == "playpausebutton")
        .expect("the shortcut property is described");

    assert_eq!(property.kind, BridgePropertyKind::Combo,
        "a shortcut the user cannot bind is a button that does nothing");
    let values: Vec<BridgePropertyValue> =
        property.combo_options.iter().map(|option| option.value.clone()).collect();
    assert_eq!(
        values,
        ["", "media:playpause", "media:next", "media:previous"]
            .map(|value| BridgePropertyValue::String { value: value.to_owned() })
            .to_vec()
    );
}

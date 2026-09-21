//! Extended project.json parser for GUI consumption.
//!
//! `wallpaper_core::ProjectManifest` stays authoritative for type / file /
//! workshop id / dependencies. This GUI-facing parser additionally extracts
//! `title`, raw HTML description, `preview` filename, and every
//! `general.properties` entry as a `ProjectProperty` for the editor panel.

use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

use serde_json::Value;
use wallpaper_core::project::WallpaperProjectType;

use super::property::{
    ComboOption, DirectoryMode, FileFilter, FileMedia, PropertyKind, PropertyMetadata,
    PropertyValue,
};
use crate::{BridgeError, BridgeErrorKind};

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectModel {
    pub workshop_id: String,
    pub title: String,
    pub description_html: String,
    pub project_type: WallpaperProjectType,
    pub preview_file: Option<PathBuf>,
    /// The manifest's `file` entry (video file or web page), relative to the
    /// project directory.
    pub entry_file: Option<String>,
    pub properties: Vec<ProjectProperty>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectProperty {
    pub id: String,
    pub kind: PropertyKind,
    pub default_value: PropertyValue,
    /// True when `default_value` is this host's own suggestion rather than
    /// what the author wrote. The scene engine parses the project file itself,
    /// so it only learns such a value if it is sent along with the user's own
    /// overrides.
    pub default_is_host_supplied: bool,
    pub label_html: String,
    pub order: i64,
    pub index: i64,
    pub condition: Option<String>, // Parsed lazily when building property snapshots.
    pub metadata: PropertyMetadata,
}

impl ProjectModel {
    /// # Errors
    ///
    /// Returns an error if `json` is not a valid Wallpaper Engine project
    /// object.
    #[allow(clippy::too_many_lines)]
    pub fn parse(workshop_id: &str, json: &str) -> Result<Self, BridgeError> {
        let root: Value = serde_json::from_str(json).map_err(|e| project_error(e.to_string()))?;
        let obj = root
            .as_object()
            .ok_or_else(|| project_error("root must be object"))?;

        let project_type = match obj.get("type").and_then(Value::as_str) {
            Some(raw_type) => match raw_type.to_ascii_lowercase().as_str() {
                "scene" => WallpaperProjectType::Scene,
                "video" => WallpaperProjectType::Video,
                "web" => WallpaperProjectType::Web,
                _ => WallpaperProjectType::Unknown,
            },
            None => WallpaperProjectType::Unknown,
        };

        let title = obj
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let description_html = obj
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let preview_file = obj
            .get("preview")
            .and_then(Value::as_str)
            .map(PathBuf::from);
        let entry_file = obj
            .get("file")
            .and_then(Value::as_str)
            .filter(|file| !file.is_empty())
            .map(str::to_string);

        let properties = obj
            .get("general")
            .and_then(Value::as_object)
            .and_then(|g| g.get("properties"))
            .and_then(Value::as_object)
            .map(|properties| {
                let mut seen_positions = BTreeSet::new();
                let mut parsed = Vec::new();
                for (id, value) in properties {
                    let Some(object) = value.as_object() else {
                        continue;
                    };

                    let kind = match object.get("type").and_then(Value::as_str).unwrap_or("") {
                        raw if raw.eq_ignore_ascii_case("slider") => PropertyKind::Slider,
                        raw if raw.eq_ignore_ascii_case("combo") => PropertyKind::Combo,
                        // The author declares that a shortcut exists; the user
                        // decides what it does. Wallpaper Engine has the user
                        // bind one in its own editor, and this is the same
                        // choice offered through the control the panel already
                        // has, so nothing downstream needs a new widget.
                        raw if raw.eq_ignore_ascii_case("usershortcut") => PropertyKind::Combo,
                        raw if raw.eq_ignore_ascii_case("bool") => PropertyKind::Bool,
                        raw if raw.eq_ignore_ascii_case("color") => PropertyKind::Color,
                        raw if raw.eq_ignore_ascii_case("textinput") => PropertyKind::TextInput,
                        raw if raw.eq_ignore_ascii_case("text") => PropertyKind::Text,
                        raw if raw.eq_ignore_ascii_case("group") => PropertyKind::Group,
                        raw if raw.eq_ignore_ascii_case("file") => PropertyKind::File,
                        raw if raw.eq_ignore_ascii_case("directory") => PropertyKind::Directory,
                        raw if raw.eq_ignore_ascii_case("scenetexture")
                            || raw.eq_ignore_ascii_case("texture") =>
                        {
                            PropertyKind::Texture
                        }
                        raw => PropertyKind::Unknown(raw.to_string()),
                    };
                    let metadata = match &kind {
                        PropertyKind::Slider => {
                            let min = object.get("min").and_then(Value::as_f64).unwrap_or(0.0);
                            let max = object.get("max").and_then(Value::as_f64).unwrap_or(1.0);
                            let step = object.get("step").and_then(Value::as_f64).unwrap_or(0.01);
                            let precision = object
                                .get("precision")
                                .and_then(Value::as_u64)
                                .and_then(|value| u32::try_from(value).ok())
                                .unwrap_or(2);
                            let fraction = object
                                .get("fraction")
                                .and_then(Value::as_bool)
                                .unwrap_or(false);
                            PropertyMetadata::Slider {
                                min,
                                max,
                                step,
                                precision,
                                fraction,
                            }
                        }
                        PropertyKind::Combo
                            if object
                                .get("type")
                                .and_then(Value::as_str)
                                .is_some_and(|raw| raw.eq_ignore_ascii_case("usershortcut")) =>
                        {
                            PropertyMetadata::Combo {
                                options: user_shortcut_options(),
                            }
                        }
                        PropertyKind::Combo => {
                            let options = object
                                .get("options")
                                .and_then(Value::as_array)
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|value| {
                                            let option = value.as_object()?;
                                            Some(ComboOption {
                                                label: option
                                                    .get("label")
                                                    .and_then(Value::as_str)
                                                    .unwrap_or("")
                                                    .to_string(),
                                                value: option.get("value").map_or_else(
                                                    String::new,
                                                    PropertyValue::json_scalar_to_string,
                                                ),
                                            })
                                        })
                                        .collect()
                                })
                                .unwrap_or_default();
                            PropertyMetadata::Combo { options }
                        }
                        PropertyKind::Bool => PropertyMetadata::Bool,
                        PropertyKind::Color => PropertyMetadata::Color,
                        PropertyKind::TextInput => PropertyMetadata::TextInput,
                        PropertyKind::Text => PropertyMetadata::Text,
                        PropertyKind::Group => PropertyMetadata::Group,
                        PropertyKind::File => PropertyMetadata::File {
                            filter: parse_file_filter(object),
                        },
                        PropertyKind::Directory => PropertyMetadata::Directory {
                            filter: parse_file_filter(object),
                            mode: parse_directory_mode(object),
                        },
                        PropertyKind::Texture => PropertyMetadata::Texture,
                        PropertyKind::Unknown(_) => PropertyMetadata::Unknown,
                    };
                    let label_html = object
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let condition = object
                        .get("condition")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let order = object.get("order").and_then(Value::as_i64).unwrap_or(0);
                    let index = object.get("index").and_then(Value::as_i64).unwrap_or(0);
                    let mut host_supplied = false;
                    let default_value = match (&kind, object.get("value")) {
                        (PropertyKind::Combo, value)
                            if object
                                .get("type")
                                .and_then(Value::as_str)
                                .is_some_and(|raw| raw.eq_ignore_ascii_case("usershortcut")) =>
                        {
                            let authored =
                                value.map_or_else(String::new, PropertyValue::json_scalar_to_string);
                            PropertyValue::String(if authored.is_empty() {
                                let suggested =
                                    suggested_user_shortcut(id).unwrap_or_default().to_owned();
                                host_supplied = !suggested.is_empty();
                                suggested
                            } else {
                                authored
                            })
                        }
                        (
                            PropertyKind::File | PropertyKind::Directory | PropertyKind::Texture,
                            Some(Value::Null) | None,
                        ) => PropertyValue::String(String::new()),
                        (
                            PropertyKind::File | PropertyKind::Directory | PropertyKind::Texture,
                            Some(value),
                        ) => PropertyValue::String(PropertyValue::json_scalar_to_string(value)),
                        (_, Some(value)) => PropertyValue::from_json(value),
                        _ => PropertyValue::Null,
                    };

                    let property = ProjectProperty {
                        id: id.clone(),
                        kind,
                        default_value,
                        default_is_host_supplied: host_supplied,
                        label_html,
                        order,
                        index,
                        condition,
                        metadata,
                    };

                    if seen_positions.insert((property.order, property.index)) {
                        parsed.push(property);
                    }
                }

                parsed.sort_by_key(|property| (property.order, property.index));
                parsed
            })
            .unwrap_or_default();

        Ok(Self {
            workshop_id: workshop_id.to_string(),
            title,
            description_html,
            project_type,
            preview_file,
            entry_file,
            properties,
        })
    }

    /// Loads and parses a project, resolving `preview_file` against the
    /// directory holding `project.json`.
    ///
    /// # Errors
    ///
    /// Returns an error if the file cannot be read or parsed.
    pub fn load<P: AsRef<Path>>(workshop_id: &str, project_json: P) -> Result<Self, BridgeError> {
        let path = project_json.as_ref();
        let bytes = std::fs::read_to_string(path)
            .map_err(|e| project_error(format!("read {}: {e}", path.display())))?;
        let mut m = Self::parse(workshop_id, &bytes)?;
        if let Some(ref pv) = m.preview_file {
            m.preview_file = Some(
                path.parent()
                    .filter(|parent| !parent.as_os_str().is_empty())
                    .unwrap_or_else(|| Path::new("."))
                    .join(pv),
            );
        }
        Ok(m)
    }
}

fn project_error(message: impl Into<String>) -> BridgeError {
    BridgeError::Error {
        kind: BridgeErrorKind::Project,
        message: message.into(),
    }
}

/// Reads a `file`/`directory` property's file-type option.
///
/// Wallpaper Engine has shipped this option under more than one spelling, so
/// every accepted key is matched case-insensitively instead of looked up. An
/// absent or unrecognised value behaves as an image filter, which is the
/// editor's own fallback, and the raw text is retained rather than dropped.
fn parse_file_filter(object: &serde_json::Map<String, Value>) -> FileFilter {
    let raw = object
        .iter()
        .find(|(key, _)| {
            matches!(
                key.to_ascii_lowercase().as_str(),
                "filetype" | "file_type"
            )
        })
        .and_then(|(_, value)| value.as_str())
        .map(str::to_owned);
    let media = match raw.as_deref().map(str::trim) {
        Some(value) if value.eq_ignore_ascii_case("video") => FileMedia::Video,
        _ => FileMedia::Image,
    };

    FileFilter { media, raw }
}

/// Reads a `directory` property's `mode`. Anything other than `fetchall`,
/// including an absent key, is the on-demand mode the page pulls from.
fn parse_directory_mode(object: &serde_json::Map<String, Value>) -> DirectoryMode {
    match object.get("mode").and_then(Value::as_str).map(str::trim) {
        Some(mode) if mode.eq_ignore_ascii_case("fetchall") => DirectoryMode::FetchAll,
        _ => DirectoryMode::OnDemand,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN_JSON: &str = r#"{
        "type": "scene",
        "title": "Hello",
        "description": "desc",
        "preview": "preview.gif",
        "general": { "properties": {
            "slide1": { "type": "slider", "min": 0, "max": 10, "step": 0.5, "value": 3, "order": 2, "text": "s" },
            "combo1": { "type": "combo", "value": "a", "options": [{"label":"A","value":"a"}], "order": 1, "text": "c" },
            "bool1":  { "type": "bool", "value": true, "order": 3, "text": "b" }
        }}
    }"#;

    #[test]
    fn parse_basic_scene_model() {
        let m = ProjectModel::parse("1", MIN_JSON).unwrap();
        assert_eq!(m.workshop_id, "1");
        assert_eq!(m.title, "Hello");
        assert_eq!(m.project_type, WallpaperProjectType::Scene);
        assert_eq!(m.preview_file, Some(PathBuf::from("preview.gif")));
        assert_eq!(m.properties.len(), 3);
        assert_eq!(m.properties[0].id, "combo1");
        assert_eq!(m.properties[1].id, "slide1");
        assert_eq!(m.properties[2].id, "bool1");
    }

    #[test]
    fn parse_unknown_type_falls_to_unknown_variant() {
        let m =
            ProjectModel::parse("1", r#"{"type":"pixelart","general":{"properties":{}}}"#).unwrap();
        assert_eq!(m.project_type, WallpaperProjectType::Unknown);
    }

    #[test]
    fn parse_malformed_fails_cleanly() {
        let err = ProjectModel::parse("1", "not-json").unwrap_err();
        assert_eq!(err.kind(), BridgeErrorKind::Project);
    }

    #[test]
    fn slider_metadata_has_defaults_when_missing() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{
                "s":{"type":"slider","value":0,"text":"x"}
            }}
        }"#,
        )
        .unwrap();
        match &m.properties[0].metadata {
            PropertyMetadata::Slider {
                min,
                max,
                step,
                precision,
                fraction,
            } => {
                assert!(
                    (*min - 0.0).abs() <= f64::EPSILON,
                    "expected min {min} to be within f64::EPSILON of 0.0"
                );
                assert!(
                    (*max - 1.0).abs() <= f64::EPSILON,
                    "expected max {max} to be within f64::EPSILON of 1.0"
                );
                assert!(
                    (*step - 0.01).abs() <= f64::EPSILON,
                    "expected step {step} to be within f64::EPSILON of 0.01"
                );
                assert_eq!(*precision, 2);
                assert!(!fraction);
            }
            _ => panic!("expected slider"),
        }
    }

    #[test]
    fn unknown_kind_preserves_raw_type() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{"x":{"type":"weird","value":0}}}
        }"#,
        )
        .unwrap();
        assert_eq!(m.properties[0].kind, PropertyKind::Unknown("weird".into()));
    }

    #[test]
    fn load_anchors_preview_relative_to_manifest_directory_when_no_parent() {
        let resolved = Path::new("project.json")
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .join(Path::new("preview.gif"));
        assert_eq!(resolved, PathBuf::from(".").join("preview.gif"));
    }

    #[test]
    fn load_resolves_preview_relative_to_manifest_directory() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = dir.path().join("project.json");
        std::fs::write(&manifest, MIN_JSON).unwrap();

        let m = ProjectModel::load("1", &manifest).unwrap();
        assert_eq!(m.preview_file, Some(dir.path().join("preview.gif")));
    }

    #[test]
    fn oversized_slider_precision_uses_default() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{
                "s":{"type":"slider","precision":99999999999999999999,"value":0,"text":"x"}
            }}
        }"#,
        )
        .unwrap();

        match &m.properties[0].metadata {
            PropertyMetadata::Slider { precision, .. } => assert_eq!(*precision, 2),
            _ => panic!("expected slider"),
        }
    }

    #[test]
    fn duplicate_order_index_keeps_first_declared_property() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{
                "hero":{"type":"bool","value":true,"order":100,"index":0,"text":"<img src='hero.png'>"},
                "schemecolor":{"type":"color","value":"0.1 0.2 0.3","order":100,"index":0,"text":"ui_browse_properties_scheme_color"},
                "next":{"type":"bool","value":true,"order":101,"index":1,"text":"Next"}
            }}
        }"#,
        )
        .unwrap();

        assert_eq!(
            m.properties
                .iter()
                .map(|property| property.id.as_str())
                .collect::<Vec<_>>(),
            vec!["hero", "next"]
        );
    }

    #[test]
    fn scenetexture_properties_are_texture_selectors_not_directories() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{
                "custom_background":{"type":"scenetexture","value":"","order":1,"text":"Background"},
                "overlay":{"type":"texture","value":"materials/x.tex","order":2,"text":"Overlay"}
            }}
        }"#,
        )
        .unwrap();

        assert_eq!(m.properties[0].kind, PropertyKind::Texture);
        assert_eq!(m.properties[0].metadata, PropertyMetadata::Texture);
        assert_eq!(
            m.properties[0].default_value,
            PropertyValue::String(String::new())
        );
        assert_eq!(m.properties[1].kind, PropertyKind::Texture);
        assert_eq!(
            m.properties[1].default_value,
            PropertyValue::String("materials/x.tex".into())
        );
    }

    #[test]
    fn file_and_directory_properties_carry_their_filters_and_modes() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"web","general":{"properties":{
                "clip":{"type":"file","fileType":"video","order":1,"text":"Clip"},
                "photos":{"type":"directory","mode":"fetchall","file_type":"image","order":2,"text":"Photos"},
                "shuffle":{"type":"directory","mode":"ondemand","filetype":"VIDEO","order":3,"text":"Shuffle"},
                "plain":{"type":"directory","order":4,"text":"Plain"},
                "odd":{"type":"file","fileType":"model","order":5,"text":"Odd"},
                "mystery":{"type":"hologram","order":6,"text":"Mystery"}
            }}
        }"#,
        )
        .unwrap();

        let by_id = |id: &str| {
            m.properties
                .iter()
                .find(|property| property.id == id)
                .unwrap_or_else(|| panic!("{id} must parse"))
        };

        assert_eq!(by_id("clip").kind, PropertyKind::File);
        assert_eq!(
            by_id("clip").metadata,
            PropertyMetadata::File {
                filter: FileFilter {
                    media: FileMedia::Video,
                    raw: Some("video".into()),
                },
            }
        );
        // A file property with no value starts empty rather than null, so the
        // page sees "nothing chosen" instead of a missing key.
        assert_eq!(
            by_id("clip").default_value,
            PropertyValue::String(String::new())
        );

        assert_eq!(by_id("photos").kind, PropertyKind::Directory);
        assert_eq!(
            by_id("photos").metadata,
            PropertyMetadata::Directory {
                filter: FileFilter {
                    media: FileMedia::Image,
                    raw: Some("image".into()),
                },
                mode: DirectoryMode::FetchAll,
            }
        );

        assert_eq!(
            by_id("shuffle").metadata,
            PropertyMetadata::Directory {
                filter: FileFilter {
                    media: FileMedia::Video,
                    raw: Some("VIDEO".into()),
                },
                mode: DirectoryMode::OnDemand,
            }
        );

        // Absent options are the on-demand image defaults, and record that the
        // manifest said nothing rather than inventing a value it never wrote.
        assert_eq!(
            by_id("plain").metadata,
            PropertyMetadata::Directory {
                filter: FileFilter {
                    media: FileMedia::Image,
                    raw: None,
                },
                mode: DirectoryMode::OnDemand,
            }
        );

        // An unrecognised filter behaves as an image filter but is not erased.
        assert_eq!(
            by_id("odd").metadata,
            PropertyMetadata::File {
                filter: FileFilter {
                    media: FileMedia::Image,
                    raw: Some("model".into()),
                },
            }
        );

        assert_eq!(
            by_id("mystery").kind,
            PropertyKind::Unknown("hologram".into())
        );
        assert_eq!(by_id("mystery").metadata, PropertyMetadata::Unknown);
    }

    #[test]
    fn unbound_transport_shortcuts_start_on_the_action_they_are_named_for() {
        let m = ProjectModel::parse(
            "1",
            r#"{
            "type":"scene","general":{"properties":{
                "playpausebutton":{"type":"usershortcut","value":"","order":1},
                "nextsongbutton":{"type":"usershortcut","value":"","order":2},
                "previoussongbutton":{"type":"usershortcut","value":"","order":3},
                "secretbutton":{"type":"usershortcut","value":"","order":4},
                "nextsongbutton2":{"type":"usershortcut","value":"media:playpause","order":5}
            }}}"#,
        )
        .expect("manifest");
        let value = |id: &str| {
            m.properties
                .iter()
                .find(|property| property.id == id)
                .map(|property| property.default_value.clone())
                .expect(id)
        };

        // An author ships these empty because Wallpaper Engine binds them in
        // its own editor. Honouring that literally leaves the buttons dead.
        assert_eq!(value("playpausebutton"), PropertyValue::String("media:playpause".into()));
        assert_eq!(value("nextsongbutton"), PropertyValue::String("media:next".into()));
        assert_eq!(
            value("previoussongbutton"),
            PropertyValue::String("media:previous".into())
        );
        // A name that says nothing gets nothing: silence beats a wrong guess.
        assert_eq!(value("secretbutton"), PropertyValue::String(String::new()));
        // An author who did write a value keeps it, even one its name contradicts.
        assert_eq!(value("nextsongbutton2"), PropertyValue::String("media:playpause".into()));
    }
}

/// The media action a `usershortcut` most likely stands for, read from its name.
///
/// Wallpaper Engine has the user bind these in its own editor, so authors ship
/// them empty. A host that honours that literally leaves every transport button
/// dead until the user finds the dropdown, which is how a wallpaper whose
/// buttons are named play, next and previous ends up doing nothing at all.
///
/// This is a starting value only. The user's own choice is stored as an
/// override and always wins, including choosing no action, and dispatch never
/// consults the name -- it carries the value -- so rebinding a button really
/// rebinds it rather than running whatever its name suggests.
fn suggested_user_shortcut(id: &str) -> Option<&'static str> {
    let id = id.to_ascii_lowercase();
    // Longest first: "playpause" also contains "play", and "previous" is only
    // distinguishable from a bare "prev" by trying it first.
    [
        ("playpause", "media:playpause"),
        ("previous", "media:previous"),
        ("prev", "media:previous"),
        ("next", "media:next"),
        ("pause", "media:playpause"),
        ("play", "media:playpause"),
    ]
    .into_iter()
    .find_map(|(needle, action)| id.contains(needle).then_some(action))
}

/// What a `usershortcut` property may be bound to.
///
/// Wallpaper Engine lets the user pick the action in its own editor; these are
/// the ones this host can carry out. The empty value means the wallpaper's
/// button does nothing, which is what an unbound shortcut already did.
fn user_shortcut_options() -> Vec<ComboOption> {
    vec![
        // Not "None": the panel already uses that for deselecting, and this
        // is a button that does nothing rather than an empty selection.
        ComboOption { label: "No action".to_owned(), value: String::new() },
        ComboOption { label: "Play / Pause".to_owned(), value: "media:playpause".to_owned() },
        ComboOption { label: "Next Track".to_owned(), value: "media:next".to_owned() },
        ComboOption { label: "Previous Track".to_owned(), value: "media:previous".to_owned() },
    ]
}

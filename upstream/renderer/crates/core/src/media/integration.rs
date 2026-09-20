use serde::{Serialize, Serializer};

/// Playback state value expected by Wallpaper Engine media scripts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum MediaPlaybackState {
    /// Audio is currently progressing.
    Playing = 0,
    /// A player is active but playback is paused.
    Paused = 1,
    /// No active player is available.
    Stopped = 2,
}

impl Serialize for MediaPlaybackState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u8(*self as u8)
    }
}

/// Song metadata exposed to Wallpaper Engine media integration callbacks.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct MediaProperties {
    #[serde(rename = "albumTitle")]
    pub album_title: Option<String>,
    pub artist: Option<String>,
    pub title: Option<String>,
}

/// RGBA artwork texture payload for the renderer-owned `$mediaThumbnail`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaThumbnailRgba {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Incremental media-provider output from one system polling pass.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaPollResult {
    pub events: Vec<MediaIntegrationEvent>,
    pub artwork: Option<MediaThumbnailRgba>,
}

impl MediaPollResult {
    pub fn changed_events<'a>(&'a self, previous: Option<&'a Self>) -> impl Iterator<Item = &'a MediaIntegrationEvent> {
        let artwork_changed = self.artwork.is_some()
            && previous.and_then(|state| state.artwork.as_ref()) != self.artwork.as_ref();
        self.events.iter().filter(move |event| {
            (artwork_changed && matches!(event, MediaIntegrationEvent::ThumbnailChanged { .. }))
                || !previous.is_some_and(|state| state.events.contains(event))
        })
    }
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;

    #[test]
    fn changed_cover_replays_thumbnail_event_even_when_colors_match() {
        let first = MediaPollResult {
            events: vec![MediaIntegrationEvent::ThumbnailChanged {
                has_thumbnail: true, primary_color: [0.0; 3], text_color: [1.0; 3],
            }],
            artwork: Some(MediaThumbnailRgba::new(1, 1, vec![255, 0, 0, 255]).unwrap()),
        };
        let mut second = first.clone();
        second.artwork.as_mut().unwrap().rgba = vec![0, 255, 0, 255];
        assert_eq!(first.changed_events(None).count(), 1);
        assert_eq!(first.changed_events(Some(&first)).count(), 0);
        assert_eq!(second.changed_events(Some(&first)).count(), 1);
        assert_eq!(second.changed_events(Some(&second)).count(), 0);
    }
}

impl MediaThumbnailRgba {
    /// # Errors
    ///
    /// Returns an error if dimensions are zero or the RGBA payload length does
    /// not equal `width * height * 4`.
    pub fn new(width: u32, height: u32, rgba: Vec<u8>) -> Result<Self, &'static str> {
        if width == 0 || height == 0 {
            return Err("media thumbnail dimensions must be non-zero");
        }
        let expected = width as usize * height as usize * 4;
        if rgba.len() != expected {
            return Err("media thumbnail RGBA payload length must equal width * height * 4");
        }
        Ok(Self {
            width,
            height,
            rgba,
        })
    }
}

/// Media integration event serialized into Wallpaper Engine's JavaScript API.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type")]
pub enum MediaIntegrationEvent {
    #[serde(rename = "mediaStatusChanged")]
    StatusChanged { enabled: bool },
    #[serde(rename = "mediaPlaybackChanged")]
    PlaybackChanged { state: MediaPlaybackState },
    #[serde(rename = "mediaPropertiesChanged")]
    PropertiesChanged(MediaProperties),
    #[serde(rename = "mediaTimelineChanged")]
    TimelineChanged { duration: f64, position: f64 },
    #[serde(rename = "mediaThumbnailChanged")]
    ThumbnailChanged {
        #[serde(rename = "hasThumbnail")]
        has_thumbnail: bool,
        #[serde(rename = "primaryColor")]
        primary_color: [f32; 3],
        #[serde(rename = "textColor")]
        text_color: [f32; 3],
    },
}

impl MediaIntegrationEvent {
    /// # Errors
    ///
    /// Returns an error if serialization fails.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}

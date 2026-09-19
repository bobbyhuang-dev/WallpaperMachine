use std::fmt;

use crate::{ShaderError, ShaderResult};

/// Texture slot index.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(transparent)]
#[cfg_attr(feature = "serde", derive(serde::Serialize))]
pub struct TextureSlot(u8);

impl TextureSlot {
    /// Maximum texture slot accepted by the renderer-neutral model.
    pub const MAX: u8 = 31;

    /// Creates a validated texture slot.
    ///
    /// # Errors
    ///
    /// Returns an error when the slot is greater than 31.
    pub fn new(slot: u8) -> ShaderResult<Self> {
        if slot > Self::MAX {
            return Err(ShaderError::invalid_request("texture slot is out of range"));
        }

        Ok(Self(slot))
    }

    /// Returns the numeric slot index.
    #[must_use]
    pub const fn index(self) -> u8 {
        self.0
    }
}

impl fmt::Display for TextureSlot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.0)
    }
}

#[cfg(feature = "serde")]
impl<'de> serde::Deserialize<'de> for TextureSlot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = u8::deserialize(deserializer)?;
        Self::new(value).map_err(serde::de::Error::custom)
    }
}

/// Texture format hint.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum TextureFormatHint {
    /// Unknown or backend-inferred format.
    #[default]
    Unknown,
    /// Single-channel normalized 8-bit format.
    R8,
    /// Two-channel normalized 8-bit format.
    Rg8,
    /// Four-channel normalized 8-bit format.
    Rgba8,
}

/// Plane layout a video texture slot is sampled through.
///
/// `None` is what every ordinary texture carries, and it is what keeps the
/// generated program identical to the one this compiler produced before this
/// option existed: nothing is declared, nothing is rewritten and the cache key
/// gains no term. A slot marked `Nv12Biplanar` is instead compiled as a second
/// variant of the same author shader, sampling the decoder's luma and chroma
/// planes directly, so the renderer needs no full-frame colour conversion to
/// feed it.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum VideoPlaneLayout {
    /// One sampled image, exactly as the slot has always been compiled.
    #[default]
    None,
    /// Two planes: full-resolution 8-bit luma and half-resolution `RG8` chroma,
    /// converted to RGB inside the shader.
    Nv12Biplanar,
}

impl VideoPlaneLayout {
    /// Returns the stable cache-key and diagnostics spelling.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Nv12Biplanar => "nv12_biplanar",
        }
    }

    /// Returns whether this slot is sampled as separate planes.
    #[must_use]
    pub const fn is_planar(self) -> bool {
        matches!(self, Self::Nv12Biplanar)
    }
}

/// Texture information used by shader request planning.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ShaderTextureInfo {
    /// Texture slot referenced by the shader.
    slot: TextureSlot,
    /// Whether the material contains a texture resource for this slot.
    #[cfg_attr(feature = "serde", serde(default = "default_texture_present"))]
    is_present: bool,
    /// Whether the material enables this texture slot.
    is_enabled: bool,
    /// Backend format hint inferred from the material texture.
    format: TextureFormatHint,
    /// Enabled state for RGB components used by material combo planning.
    #[cfg_attr(feature = "serde", serde(default))]
    components: [TextureComponentState; 3],
    /// Plane layout this slot is sampled through.
    #[cfg_attr(feature = "serde", serde(default))]
    video_planes: VideoPlaneLayout,
}

impl ShaderTextureInfo {
    /// Creates texture information.
    #[must_use]
    pub const fn new(slot: TextureSlot, is_enabled: bool, format: TextureFormatHint) -> Self {
        Self {
            slot,
            is_present: true,
            is_enabled,
            format,
            components: [TextureComponentState::disabled(); 3],
            video_planes: VideoPlaneLayout::None,
        }
    }

    /// Creates texture information with per-component enabled state.
    #[must_use]
    pub const fn with_components(
        slot: TextureSlot,
        is_enabled: bool,
        format: TextureFormatHint,
        components: [TextureComponentState; 3],
    ) -> Self {
        Self {
            slot,
            is_present: true,
            is_enabled,
            format,
            components,
            video_planes: VideoPlaneLayout::None,
        }
    }

    /// Creates texture information with explicit material presence.
    #[must_use]
    pub const fn with_presence(
        slot: TextureSlot,
        is_present: bool,
        is_enabled: bool,
        format: TextureFormatHint,
        components: [TextureComponentState; 3],
    ) -> Self {
        Self {
            slot,
            is_present,
            is_enabled,
            format,
            components,
            video_planes: VideoPlaneLayout::None,
        }
    }

    /// Returns this texture information with an explicit plane layout.
    #[must_use]
    pub const fn with_video_planes(mut self, video_planes: VideoPlaneLayout) -> Self {
        self.video_planes = video_planes;
        self
    }

    /// Returns the texture slot.
    #[must_use]
    pub const fn slot(&self) -> TextureSlot {
        self.slot
    }

    /// Returns whether this slot has a material texture resource.
    #[must_use]
    pub const fn is_present(&self) -> bool {
        self.is_present
    }

    /// Returns whether the texture is enabled.
    #[must_use]
    pub const fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    /// Returns the format hint.
    #[must_use]
    pub const fn format(&self) -> TextureFormatHint {
        self.format
    }

    /// Returns per-component enabled state.
    #[must_use]
    pub const fn components(&self) -> &[TextureComponentState; 3] {
        &self.components
    }

    /// Returns the plane layout this slot is sampled through.
    #[must_use]
    pub const fn video_planes(&self) -> VideoPlaneLayout {
        self.video_planes
    }
}

/// Default material texture presence for serde backward compatibility.
#[cfg(feature = "serde")]
const fn default_texture_present() -> bool {
    true
}

/// Enabled state for one texture color component used by material combo
/// planning.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TextureComponentState {
    /// Whether this texture component participates in material rendering.
    is_enabled: bool,
}

impl TextureComponentState {
    /// Creates a texture component state.
    #[must_use]
    pub const fn new(is_enabled: bool) -> Self {
        Self { is_enabled }
    }

    /// Creates a disabled texture component state.
    #[must_use]
    pub const fn disabled() -> Self {
        Self { is_enabled: false }
    }

    /// Returns whether the component is enabled.
    #[must_use]
    pub const fn is_enabled(self) -> bool {
        self.is_enabled
    }
}

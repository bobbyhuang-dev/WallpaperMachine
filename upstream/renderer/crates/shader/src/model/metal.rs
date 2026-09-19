//! Metal Shading Language stage output model.

use super::{ShaderStageKind, ShaderSymbolName};

/// Metal argument-table namespace a shader resource is bound into.
///
/// Metal keeps buffers, textures and samplers in three independent index
/// spaces, so a slot number is only meaningful together with its namespace.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum MetalSlotKind {
    /// `[[buffer(n)]]` argument-table entry.
    Buffer,
    /// `[[texture(n)]]` argument-table entry.
    Texture,
    /// `[[sampler(n)]]` argument-table entry.
    Sampler,
}

impl MetalSlotKind {
    /// Returns the largest slot index Metal accepts for this namespace.
    ///
    /// The limits are the Metal argument-table sizes shared by every macOS GPU
    /// family this renderer targets: 31 buffers, 128 textures, 16 samplers.
    #[must_use]
    pub const fn max_slot(self) -> u32 {
        match self {
            Self::Buffer => 30,
            Self::Texture => 127,
            Self::Sampler => 15,
        }
    }

    /// Returns the stable bridge identifier for this namespace.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Buffer => "buffer",
            Self::Texture => "texture",
            Self::Sampler => "sampler",
        }
    }
}

/// One shader resource and the Metal argument-table slot it was bound to.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MetalResourceBinding {
    /// Shader-visible name of the global this binding belongs to.
    name: ShaderSymbolName,
    /// SPIR-V descriptor set the global was declared in.
    set: u32,
    /// SPIR-V binding index the global was declared with.
    binding: u32,
    /// Metal argument-table namespace the slot belongs to.
    slot_kind: MetalSlotKind,
    /// Metal argument-table index within `slot_kind`.
    slot: u32,
}

impl MetalResourceBinding {
    /// Creates a resource binding record.
    #[must_use]
    pub const fn new(
        name: ShaderSymbolName,
        set: u32,
        binding: u32,
        slot_kind: MetalSlotKind,
        slot: u32,
    ) -> Self {
        Self {
            name,
            set,
            binding,
            slot_kind,
            slot,
        }
    }

    /// Returns the shader-visible global name.
    #[must_use]
    pub const fn name(&self) -> &ShaderSymbolName {
        &self.name
    }

    /// Returns the SPIR-V descriptor set.
    #[must_use]
    pub const fn set(&self) -> u32 {
        self.set
    }

    /// Returns the SPIR-V binding index.
    #[must_use]
    pub const fn binding(&self) -> u32 {
        self.binding
    }

    /// Returns the Metal argument-table namespace.
    #[must_use]
    pub const fn slot_kind(&self) -> MetalSlotKind {
        self.slot_kind
    }

    /// Returns the Metal argument-table index.
    #[must_use]
    pub const fn slot(&self) -> u32 {
        self.slot
    }
}

/// Coordinate conventions the emitted Metal source follows.
///
/// Every field records a transform the shader compiler could have injected.
/// The Metal renderer has to agree with these, so they are reported instead of
/// assumed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MetalCoordinateConventions {
    /// Whether the backend negated clip-space `Y` in the vertex position.
    clip_space_y_flipped: bool,
    /// Whether the backend remapped clip-space `Z` from `0..1` to `-1..1`.
    clip_space_depth_remapped: bool,
    /// Whether the backend flipped the texture-sample coordinate origin.
    texture_origin_flipped: bool,
}

impl MetalCoordinateConventions {
    /// Returns the conventions used when no transform is injected at all.
    ///
    /// Clip-space position and texture coordinates are then emitted exactly as
    /// the shader IR expresses them, which is what the SPIR-V target already
    /// does after `ADJUST_COORDINATE_SPACE` is removed.
    #[must_use]
    pub const fn unmodified() -> Self {
        Self {
            clip_space_y_flipped: false,
            clip_space_depth_remapped: false,
            texture_origin_flipped: false,
        }
    }

    /// Returns whether clip-space `Y` was negated by the backend.
    #[must_use]
    pub const fn clip_space_y_flipped(self) -> bool {
        self.clip_space_y_flipped
    }

    /// Returns whether clip-space depth was remapped by the backend.
    #[must_use]
    pub const fn clip_space_depth_remapped(self) -> bool {
        self.clip_space_depth_remapped
    }

    /// Returns whether the texture-sample origin was flipped by the backend.
    #[must_use]
    pub const fn texture_origin_flipped(self) -> bool {
        self.texture_origin_flipped
    }
}

/// Compiled Metal Shading Language output for one shader stage.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MetalStageCode {
    /// Stage this Metal source was generated for.
    stage: ShaderStageKind,
    /// Generated Metal Shading Language source text.
    source: String,
    /// Generated Metal entry-point function name.
    ///
    /// The backend renames entry points, so callers must not assume `main`.
    entry_point: String,
    /// Metal Shading Language version the source targets.
    language_version: (u8, u8),
    /// Resource-to-slot mapping the source was generated against.
    bindings: Box<[MetalResourceBinding]>,
    /// Coordinate conventions the generated source follows.
    conventions: MetalCoordinateConventions,
}

impl MetalStageCode {
    /// Creates Metal stage output.
    #[must_use]
    pub const fn new(
        stage: ShaderStageKind,
        source: String,
        entry_point: String,
        language_version: (u8, u8),
        bindings: Box<[MetalResourceBinding]>,
        conventions: MetalCoordinateConventions,
    ) -> Self {
        Self {
            stage,
            source,
            entry_point,
            language_version,
            bindings,
            conventions,
        }
    }

    /// Returns the stage this Metal source was generated for.
    #[must_use]
    pub const fn stage(&self) -> ShaderStageKind {
        self.stage
    }

    /// Returns the generated Metal source text.
    #[must_use]
    pub fn source(&self) -> &str {
        &self.source
    }

    /// Returns the generated Metal entry-point function name.
    #[must_use]
    pub fn entry_point(&self) -> &str {
        &self.entry_point
    }

    /// Returns the targeted Metal Shading Language version.
    #[must_use]
    pub const fn language_version(&self) -> (u8, u8) {
        self.language_version
    }

    /// Returns the resource-to-slot mapping.
    #[must_use]
    pub fn bindings(&self) -> &[MetalResourceBinding] {
        &self.bindings
    }

    /// Returns the coordinate conventions the source follows.
    #[must_use]
    pub const fn conventions(&self) -> MetalCoordinateConventions {
        self.conventions
    }
}

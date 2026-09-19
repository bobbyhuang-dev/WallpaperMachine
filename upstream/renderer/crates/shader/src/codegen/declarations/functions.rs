//! Compatibility helper requests and function declaration facts.

use std::fmt::Write as _;

use super::{super::emission::SourceEmitter, layout::VideoPlaneResource,
            resources::TextureDeclaration};
use crate::{ShaderResult, SourceSpan};

/// Compatibility helper functions requested during codegen.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct CompatibilityFunctionRequests {
    /// Whether generated `clip` overloads are needed.
    clip: bool,
    /// Whether generated `PerformLighting_V1` overloads are needed.
    perform_lighting: bool,
}

impl CompatibilityFunctionRequests {
    /// Requests generated `clip` overloads.
    pub(crate) fn require_clip(&mut self) {
        self.clip = true;
    }

    /// Requests generated `PerformLighting_V1` overloads.
    pub(crate) fn require_perform_lighting(&mut self) {
        self.perform_lighting = true;
    }

    /// Emits requested compatibility helper functions.
    pub(crate) fn emit(self, output: &mut String) -> ShaderResult<()> {
        if self.perform_lighting {
            writeln!(
                output,
                "vec3 PerformLighting_V1(vec3 world_pos, vec3 albedo, vec3 normal, vec3 \
                 view_vector,\nvec3 specular_tint, vec3 f0, float roughness, float metallic) \
                 {{\nreturn albedo * max(dot(normalize(normal), normalize(view_vector)), \
                 0.0);\n}}\nvec3 PerformLighting_V1(vec3 world_pos, vec3 albedo, vec3 normal, \
                 vec3 view_vector,\nvec3 specular_tint, vec3 f0, float roughness, float metallic, \
                 float ao) {{\nreturn albedo * ao * max(dot(normalize(normal), \
                 normalize(view_vector)), 0.0);\n}}"
            )
            .map_err(SourceEmitter::write_error)?;
        }

        if self.clip {
            writeln!(
                output,
                "void clip(float value) {{ if (value < 0.0) discard; }}\nvoid clip(vec2 value) {{ \
                 if (any(lessThan(value, vec2(0.0)))) discard; }}\nvoid clip(vec3 value) {{ if \
                 (any(lessThan(value, vec3(0.0)))) discard; }}\nvoid clip(vec4 value) {{ if \
                 (any(lessThan(value, vec4(0.0)))) discard; }}"
            )
            .map_err(SourceEmitter::write_error)?;
        }

        if self.perform_lighting || self.clip {
            writeln!(output).map_err(SourceEmitter::write_error)?;
        }
        Ok(())
    }
}

/// Parsed function declaration information needed by collision rewrites.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct FunctionEntry<'src> {
    /// Function name from the parsed declaration.
    pub name: &'src str,
    /// Span covering only the function name token.
    pub name_span: SourceSpan,
}

/// Video plane sampling helpers requested during codegen.
///
/// A helper is emitted only for a slot whose sampling calls were actually
/// rewritten in this stage, so a vertex stage that never touches the video
/// texture declares no chroma plane and carries no dead function.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct VideoSamplingFunctionRequests {
    /// Material texture slots whose sampling calls were rewritten.
    slots: Vec<u8>,
}

impl VideoSamplingFunctionRequests {
    /// Requests the sampling helper for one material texture slot.
    pub(crate) fn require(&mut self, slot: u8) {
        if !self.slots.contains(&slot) {
            self.slots.push(slot);
        }
    }

    /// Returns whether a slot's helper was requested.
    #[must_use]
    pub(crate) fn contains(&self, slot: u8) -> bool {
        self.slots.contains(&slot)
    }

    /// Emits the requested helpers for the program's plane resources.
    ///
    /// The arithmetic is the same affine transform the renderer's own NV12
    /// conversion kernel applies, expressed against the same eight constants,
    /// so the direct path and the pre-converted path cannot disagree about
    /// range, matrix or alpha for one frame. Chroma is read from a plane at
    /// half resolution and is filtered by its own sampler, which is what
    /// reproduces the kernel's chroma upsample rather than approximating it.
    pub(crate) fn emit<'plane>(
        &self,
        output: &mut String,
        planes: impl Iterator<Item = &'plane VideoPlaneResource>,
    ) -> ShaderResult<()> {
        let mut emitted = false;
        for plane in planes.filter(|plane| self.contains(plane.slot)) {
            let helper = VideoPlaneResource::helper_name(plane.slot);
            let range = VideoPlaneResource::range_uniform_name(plane.slot);
            let matrix = VideoPlaneResource::matrix_uniform_name(plane.slot);
            let luma = plane.base_name.as_str();
            let luma_sampler = format!("{}{luma}", TextureDeclaration::SAMPLER_PREFIX);
            let chroma = plane.chroma_name.as_str();
            let chroma_sampler = format!("{}{chroma}", TextureDeclaration::SAMPLER_PREFIX);
            writeln!(
                output,
                "vec4 {helper}(vec2 _we_video_coord) {{\n    float _we_video_y = \
                 texture(sampler2D({luma}, {luma_sampler}), _we_video_coord).r;\n    vec2 \
                 _we_video_cbcr = texture(sampler2D({chroma}, {chroma_sampler}), \
                 _we_video_coord).rg;\n    float _we_video_luma = clamp((_we_video_y - \
                 {range}.x) * {range}.y, 0.0, 1.0);\n    vec2 _we_video_chroma = \
                 (_we_video_cbcr - {range}.z) * {range}.w;\n    return vec4(\n        \
                 clamp(_we_video_luma + {matrix}.x * _we_video_chroma.y, 0.0, 1.0),\n        \
                 clamp(_we_video_luma + {matrix}.y * _we_video_chroma.x + {matrix}.z * \
                 _we_video_chroma.y, 0.0, 1.0),\n        clamp(_we_video_luma + {matrix}.w * \
                 _we_video_chroma.x, 0.0, 1.0),\n        1.0);\n}}"
            )
            .map_err(SourceEmitter::write_error)?;
            emitted = true;
        }
        if emitted {
            writeln!(output).map_err(SourceEmitter::write_error)?;
        }
        Ok(())
    }
}

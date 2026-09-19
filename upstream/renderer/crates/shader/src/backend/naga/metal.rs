//! Metal Shading Language emission from a validated Naga module.
//!
//! Metal argument tables are flat: buffers, textures and samplers each have
//! their own index space and there is no descriptor-set concept. The renderer
//! and the shader compiler therefore have to agree on an explicit mapping.
//!
//! The mapping used here is deliberately trivial so the Metal backend can
//! reproduce it without consulting the reported map: every resource stays in
//! descriptor set `0`, and its Metal slot index within its own argument-table
//! namespace is exactly its SPIR-V binding index. Because the shader pipeline
//! allocates one unique binding index per resource inside set `0`, the slots
//! are unique across the whole stage as well.

use naga::back::msl;

use super::diagnostic::DiagnosticBuilder;
use crate::{
    MetalCoordinateConventions, MetalResourceBinding, MetalSlotKind, MetalStageCode, ShaderError,
    ShaderResult, ShaderStageKind, ShaderSymbolName,
};

/// Metal Shading Language version the generated source targets.
///
/// MSL 2.0 is available on every Metal-capable macOS release this renderer
/// supports.
const MSL_LANGUAGE_VERSION: (u8, u8) = (2, 0);

/// Emits Metal Shading Language for one validated Naga module.
#[derive(Clone, Copy, Debug)]
pub(super) struct MetalEmitter<'module> {
    /// Stage being emitted.
    pub stage: ShaderStageKind,
    /// Validated Naga module to translate.
    pub module: &'module naga::Module,
    /// Naga validation metadata for `module`.
    pub module_info: &'module naga::valid::ModuleInfo,
    /// Generated source text the module was compiled from.
    pub source_text: &'module str,
    /// Generated source path used in diagnostics.
    pub source_path: &'static str,
}

impl<'module> MetalEmitter<'module> {
    /// Translates the module into Metal source plus its binding map.
    pub(super) fn emit(&self) -> ShaderResult<MetalStageCode> {
        let ir_entry_point = self.ir_entry_point_name()?;
        let bindings = self.resource_bindings()?;
        let resources = Self::entry_point_resources(&bindings)?;

        let mut per_entry_point_map = msl::EntryPointResourceMap::default();
        let _previous = per_entry_point_map.insert(ir_entry_point.to_owned(), resources);

        let options = msl::Options {
            lang_version: MSL_LANGUAGE_VERSION,
            per_entry_point_map,
            // Naga's default invents slots for unmapped resources and emits a
            // shader that reads the wrong argument-table entry. Every binding
            // is explicit above, so a missing one must fail the compile.
            fake_missing_bindings: false,
            ..msl::Options::default()
        };
        let pipeline_options = msl::PipelineOptions {
            entry_point: Some((self.stage.into_naga(), ir_entry_point.to_owned())),
            ..msl::PipelineOptions::default()
        };

        let (source, info) =
            msl::write_string(self.module, self.module_info, &options, &pipeline_options)
                .map_err(|err| self.compile_error(format!("naga msl write failed: {err}")))?;

        Ok(MetalStageCode::new(
            self.stage,
            source,
            self.metal_entry_point_name(&info)?,
            MSL_LANGUAGE_VERSION,
            bindings.into_boxed_slice(),
            // Neither the SPIR-V nor the Metal path injects a clip-space or
            // texture-origin transform, so both targets carry the shader
            // author's conventions through unchanged.
            MetalCoordinateConventions::unmodified(),
        ))
    }

    /// Converts the reported binding map into Naga's entry-point resource map.
    fn entry_point_resources(
        bindings: &[MetalResourceBinding],
    ) -> ShaderResult<msl::EntryPointResources> {
        let mut resources = msl::EntryPointResources::default();

        for binding in bindings {
            let key = naga::ResourceBinding {
                group: binding.set(),
                binding: binding.binding(),
            };
            let slot = slot_index(binding)?;
            let target = match binding.slot_kind() {
                MetalSlotKind::Buffer => msl::BindTarget {
                    buffer: Some(slot),
                    ..msl::BindTarget::default()
                },
                MetalSlotKind::Texture => msl::BindTarget {
                    texture: Some(slot),
                    ..msl::BindTarget::default()
                },
                MetalSlotKind::Sampler => msl::BindTarget {
                    sampler: Some(msl::BindSamplerTarget::Resource(slot)),
                    ..msl::BindTarget::default()
                },
            };
            let _previous = resources.resources.insert(key, target);
        }

        Ok(resources)
    }

    /// Returns the Naga IR entry-point name for the requested stage.
    fn ir_entry_point_name(&self) -> ShaderResult<&'module str> {
        let stage = self.stage.into_naga();
        self.module
            .entry_points
            .iter()
            .find(|entry_point| entry_point.stage == stage)
            .map(|entry_point| entry_point.name.as_str())
            .ok_or_else(|| {
                self.compile_error(format!(
                    "shader module declares no {:?} entry point to translate to metal",
                    self.stage
                ))
            })
    }

    /// Returns the generated Metal entry-point name for the requested stage.
    fn metal_entry_point_name(&self, info: &msl::TranslationInfo) -> ShaderResult<String> {
        let Some(name) = info.entry_point_names.first() else {
            return Err(self.compile_error(format!(
                "naga msl write produced no {:?} entry point",
                self.stage
            )));
        };

        name.clone().map_err(|err| {
            self.compile_error(format!(
                "metal binding map does not cover every resource used by the {:?} entry point: \
                 {err}",
                self.stage
            ))
        })
    }

    /// Builds the resource-to-slot map for every global the module declares.
    fn resource_bindings(&self) -> ShaderResult<Vec<MetalResourceBinding>> {
        let mut bindings = Vec::new();

        for (_, global) in self.module.global_variables.iter() {
            let Some(slot_kind) = self.slot_kind(global)? else {
                continue;
            };
            let Some(resource_binding) = global.binding else {
                return Err(self.uncovered_global_error(
                    global,
                    "it has no layout(set, binding) qualifier, so it has no deterministic metal \
                     slot",
                ));
            };
            if resource_binding.group != 0 {
                return Err(self.uncovered_global_error(
                    global,
                    &format!(
                        "it uses descriptor set {}, but the metal slot mapping is only defined \
                         for descriptor set 0",
                        resource_binding.group
                    ),
                ));
            }

            let name = ShaderSymbolName::new(self.global_name(global)).map_err(|error| {
                self.compile_error(format!(
                    "metal binding map cannot name a global resource: {error}"
                ))
            })?;
            bindings.push(MetalResourceBinding::new(
                name,
                resource_binding.group,
                resource_binding.binding,
                slot_kind,
                resource_binding.binding,
            ));
        }

        Ok(bindings)
    }

    /// Returns the Metal namespace a global belongs to, or `None` when the
    /// global needs no argument-table entry at all.
    fn slot_kind(&self, global: &naga::GlobalVariable) -> ShaderResult<Option<MetalSlotKind>> {
        match global.space {
            naga::AddressSpace::Function
            | naga::AddressSpace::Private
            | naga::AddressSpace::WorkGroup => Ok(None),
            naga::AddressSpace::Uniform | naga::AddressSpace::Storage { .. } => {
                Ok(Some(MetalSlotKind::Buffer))
            }
            naga::AddressSpace::Handle => match self.resource_inner(global) {
                naga::TypeInner::Image { .. } => Ok(Some(MetalSlotKind::Texture)),
                naga::TypeInner::Sampler { .. } => Ok(Some(MetalSlotKind::Sampler)),
                _ => Err(self.uncovered_global_error(
                    global,
                    "it is an opaque handle that is neither an image nor a sampler",
                )),
            },
            naga::AddressSpace::Immediate => Err(self.uncovered_global_error(
                global,
                "push-constant/immediate data has no metal argument-table slot in this mapping",
            )),
            naga::AddressSpace::TaskPayload
            | naga::AddressSpace::RayPayload
            | naga::AddressSpace::IncomingRayPayload => Err(self.uncovered_global_error(
                global,
                "its address space is not supported by the metal target",
            )),
        }
    }

    /// Returns the global's resource type, unwrapping descriptor arrays.
    fn resource_inner(&self, global: &naga::GlobalVariable) -> &'module naga::TypeInner {
        match &self.module.types[global.ty].inner {
            naga::TypeInner::BindingArray { base, .. } => &self.module.types[*base].inner,
            inner => inner,
        }
    }

    /// Returns the shader-visible name of a global.
    fn global_name(&self, global: &'module naga::GlobalVariable) -> &'module str {
        global
            .name
            .as_deref()
            .or(self.module.types[global.ty].name.as_deref())
            .unwrap_or_default()
    }

    /// Builds the error used when a global cannot be given a Metal slot.
    fn uncovered_global_error(&self, global: &naga::GlobalVariable, reason: &str) -> ShaderError {
        self.compile_error(format!(
            "metal binding map cannot cover global `{}`: {reason}",
            self.global_name(global)
        ))
    }

    /// Builds a stage-scoped compile diagnostic error.
    fn compile_error(&self, message: String) -> ShaderError {
        let diagnostic = DiagnosticBuilder::new(self.stage, "naga msl write", self.source_path)
            .with_message(message)
            .with_source(self.source_text)
            .build();

        ShaderError::Compile {
            diagnostics: Box::from([diagnostic]),
        }
    }
}

/// Narrows a binding index into a Metal argument-table slot.
fn slot_index(binding: &MetalResourceBinding) -> ShaderResult<msl::Slot> {
    let kind = binding.slot_kind();
    let slot = binding.slot();
    if slot > kind.max_slot() {
        return Err(ShaderError::Reflection {
            message: format!(
                "metal {} slot {slot} for `{}` exceeds the argument-table limit of {}",
                kind.as_str(),
                binding.name(),
                kind.max_slot()
            ),
        });
    }

    msl::Slot::try_from(slot).map_err(|error| ShaderError::Reflection {
        message: format!(
            "metal {} slot {slot} for `{}` is not representable: {error}",
            kind.as_str(),
            binding.name()
        ),
    })
}

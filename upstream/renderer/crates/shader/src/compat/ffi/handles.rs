//! Owned FFI handles.

use std::{cell::RefCell, ffi::CString};

use super::{
    diagnostics_json::DiagnosticsJson,
    response_json::{MetadataJson, MetalStageJson, ReflectionJson},
};
use crate::{CompiledShaderProgram, ShaderError, ShaderTarget};

thread_local! {
    /// Thread-local error text exposed by `rs_shader_last_error`.
    pub(super) static LAST_ERROR: RefCell<CString> = RefCell::new(cstring_lossy("no shader error"));
}

/// Opaque compiled shader program handle returned to C++.
#[derive(Debug)]
pub struct RsShaderProgram {
    /// Compiled shader program retained by this handle.
    pub(super) program: CompiledShaderProgram,
    /// Prepared metadata JSON borrowed by accessors.
    pub(super) metadata_json: CString,
    /// Prepared reflection JSON borrowed by accessors.
    pub(super) reflection_json: CString,
    /// Prepared diagnostics JSON borrowed by accessors.
    pub(super) diagnostics_json: CString,
    /// Prepared cache key borrowed by accessors.
    pub(super) cache_key: CString,
    /// Prepared per-stage Metal payloads borrowed by accessors.
    ///
    /// Empty for non-Metal targets; one entry per compiled stage otherwise.
    pub(super) metal_stages: Box<[MetalStageStrings]>,
}

impl RsShaderProgram {
    /// Builds an owned FFI program handle and pre-serializes borrowed JSON
    /// views.
    #[allow(clippy::single_call_fn)]
    pub(super) fn from_compiled_program(
        program: CompiledShaderProgram,
    ) -> Result<Self, ShaderError> {
        let metadata_json = cstring_lossy(
            serde_json::to_string(&MetadataJson::from(program.metadata()))
                .map_err(|error| ShaderError::bridge(error.to_string()))?,
        );
        let reflection_json = cstring_lossy(
            serde_json::to_string(&ReflectionJson::from(program.reflection()))
                .map_err(|error| ShaderError::bridge(error.to_string()))?,
        );
        let diagnostics_json = cstring_lossy(
            serde_json::to_string(&DiagnosticsJson::from(program.diagnostics()))
                .map_err(|error| ShaderError::bridge(error.to_string()))?,
        );
        let cache_key = cstring_lossy(program.cache_key().as_str());
        let metal_stages = metal_stage_strings(&program)?;

        Ok(Self {
            program,
            metadata_json,
            reflection_json,
            diagnostics_json,
            cache_key,
            metal_stages,
        })
    }
}

/// Prepared borrowed strings describing one compiled Metal stage.
#[derive(Debug)]
pub(super) struct MetalStageStrings {
    /// Generated Metal Shading Language source text.
    pub(super) source: CString,
    /// Structured Metal stage payload as JSON.
    pub(super) json: CString,
}

/// Pre-serializes the Metal payload of every compiled stage.
///
/// The result is either empty (no stage targets Metal) or index-aligned with
/// `program.stages()`, so the FFI accessors can use the same stage index for
/// SPIR-V and Metal payloads.
#[allow(clippy::single_call_fn)]
fn metal_stage_strings(
    program: &CompiledShaderProgram,
) -> Result<Box<[MetalStageStrings]>, ShaderError> {
    if !program
        .stages()
        .iter()
        .any(|stage| stage.target() == ShaderTarget::MetalMsl)
    {
        return Ok(Box::from([]));
    }

    let mut stages = Vec::with_capacity(program.stages().len());

    for stage in program.stages() {
        let Some(metal) = stage.metal() else {
            return Err(ShaderError::bridge(format!(
                "compiled program mixes metal_msl and {:?} stages",
                stage.target()
            )));
        };
        stages.push(MetalStageStrings {
            source: cstring_lossy(metal.source()),
            json: cstring_lossy(
                serde_json::to_string(&MetalStageJson::from(metal))
                    .map_err(|error| ShaderError::bridge(error.to_string()))?,
            ),
        });
    }

    Ok(stages.into_boxed_slice())
}

/// Records a thread-local FFI error string.
pub(super) fn set_last_error(message: impl Into<String>) {
    let message = cstring_lossy(message.into());
    LAST_ERROR.with(|last_error| {
        *last_error.borrow_mut() = message;
    });
}

/// Returns a borrowed program handle when `program` is non-null.
pub(super) fn program_ref<'program>(
    program: *const RsShaderProgram,
) -> Option<&'program RsShaderProgram> {
    if program.is_null() {
        None
    } else {
        // SAFETY: The non-null pointer is treated as borrowed. Invalid external
        // pointers remain caller UB per the FFI contract.
        Some(unsafe { &*program })
    }
}

/// Creates a C string, replacing interior NUL bytes to preserve FFI validity.
pub(super) fn cstring_lossy(message: impl Into<Vec<u8>>) -> CString {
    let bytes = message
        .into()
        .into_iter()
        .map(|byte| if byte == 0 { b' ' } else { byte })
        .collect::<Vec<_>>();
    CString::new(bytes).unwrap_or_else(|_| c"invalid shader string".to_owned())
}

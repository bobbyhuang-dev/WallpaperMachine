use super::{CompiledStageArtifact, ShaderReflection, ShaderStageKind, ShaderTarget};
use crate::{ShaderResult, legalize::CodegenStageSource};

/// Trait for shader compiler backends.
pub trait ShaderCompiler {
    /// Backend module type retained internally for reflection.
    type Module;

    /// Compiles one shader stage for one output target.
    ///
    /// # Errors
    ///
    /// Returns an error when the backend cannot compile the provided source
    /// for the requested target.
    fn compile_stage(
        &self,
        target: ShaderTarget,
        stage: ShaderStageKind,
        source: &CodegenStageSource,
    ) -> ShaderResult<CompiledStageArtifact<Self::Module>>;
}

/// Trait for shader reflection backends.
pub trait ShaderReflector<M> {
    /// Reflects a compiled module.
    ///
    /// # Errors
    ///
    /// Returns an error when reflected bindings cannot be represented by the
    /// core model.
    fn reflect_stage(&self, stage: ShaderStageKind, module: &M) -> ShaderResult<ShaderReflection>;
}

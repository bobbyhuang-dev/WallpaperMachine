use crate::{
    ShaderError, ShaderResult,
    preprocess::PreprocessedStage,
    syntax::{ParsingContext, ShaderModule, ShaderSourceText},
};

/// Stage-local pipeline inputs.
#[derive(Debug)]
pub struct ProgramStageInputs<'src> {
    /// Parsed stages in request order.
    stages: Vec<ProgramStageInput<'src>>,
}

impl<'src> ProgramStageInputs<'src> {
    /// Constructs paired preprocessed and metadata-preserving stage inputs.
    ///
    /// # Errors
    ///
    /// Returns an error when the stage and metadata-source lists differ in
    /// length, when paired stages have different kinds, or when either source
    /// cannot be parsed.
    #[inline]
    #[allow(clippy::single_call_fn)]
    pub fn new(
        stages: &'src [PreprocessedStage],
        metadata_sources: &'src [PreprocessedStage],
    ) -> ShaderResult<Self> {
        if stages.len() != metadata_sources.len() {
            return Err(ShaderError::invalid_request(
                "preprocessed stage count does not match metadata stage count",
            ));
        }
        let stages = stages
            .iter()
            .zip(metadata_sources)
            .map(|(stage, metadata_stage)| {
                if stage.kind() != metadata_stage.kind() {
                    return Err(ShaderError::invalid_request(
                        "preprocessed stage kind does not match metadata stage kind",
                    ));
                }
                Ok(ProgramStageInput {
                    stage,
                    module: ProgramStageInput::parse(stage)?,
                    metadata_module: ParsingContext::new(
                        metadata_stage.kind(),
                        ShaderSourceText::new(metadata_stage.source()),
                    )?
                    .parse_metadata()?,
                })
            })
            .collect::<ShaderResult<Vec<_>>>()?;
        Ok(Self { stages })
    }

    /// Parses all preprocessed stages.
    ///
    /// # Errors
    ///
    /// Returns an error when any preprocessed stage cannot be parsed into a
    /// typed syntax module.
    pub fn parse(stages: &'src [PreprocessedStage]) -> ShaderResult<Self> {
        Self::new(stages, stages)
    }

    /// Returns parsed stages.
    #[must_use]
    pub fn stages(&self) -> &[ProgramStageInput<'src>] {
        &self.stages
    }
}

/// One preprocessed stage and its parsed syntax module.
#[derive(Debug)]
pub struct ProgramStageInput<'src> {
    /// Preprocessed stage source.
    pub stage: &'src PreprocessedStage,
    /// Parsed syntax module.
    pub module: ShaderModule<'src>,
    /// Parsed metadata syntax module with includes expanded before condition
    /// stripping.
    pub metadata_module: ShaderModule<'src>,
}

impl ProgramStageInput<'_> {
    /// Parses preprocessed stage source into a typed syntax module.
    fn parse(stage: &PreprocessedStage) -> ShaderResult<ShaderModule<'_>> {
        let context = ParsingContext::new(stage.kind(), ShaderSourceText::new(stage.source()))?;
        context.parse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ShaderStageKind;

    #[test]
    fn parse_paired_rejects_stage_count_mismatch() {
        let stages = [stage(ShaderStageKind::Vertex)];
        let metadata_sources = [];

        let Err(err) = ProgramStageInputs::new(&stages, &metadata_sources) else {
            panic!("mismatched stage counts are rejected");
        };

        assert!(
            err.to_string()
                .contains("preprocessed stage count does not match metadata stage count")
        );
    }

    #[test]
    fn parse_paired_rejects_stage_kind_mismatch() {
        let stages = [stage(ShaderStageKind::Vertex)];
        let metadata_sources = [stage(ShaderStageKind::Fragment)];

        let Err(err) = ProgramStageInputs::new(&stages, &metadata_sources) else {
            panic!("mismatched stage kinds are rejected");
        };

        assert!(
            err.to_string()
                .contains("preprocessed stage kind does not match metadata stage kind")
        );
    }

    #[test]
    fn metadata_preserves_uniforms_around_conditional_function_headers() {
        let source = concat!(
            "// [COMBO] {\"combo\":\"ROTATION\",\"default\":0}\n",
            "#if ROTATION\n",
            "uniform float g_Rotated; // {\"default\":2}\n",
            "#else\n",
            "uniform float g_Plain; // {\"default\":1}\n",
            "#endif\n",
            "#if ROTATION\n",
            "vec2 direction(vec4 value) {\n",
            "    vec2 result = value.xy;\n",
            "#else\n",
            "vec2 direction(vec2 value) {\n",
            "    vec2 result = value;\n",
            "#endif\n",
            "#if ROTATION\n",
            "    if (result.x > 0.0) {\n",
            "#else\n",
            "    if (result.y > 0.0) {\n",
            "#endif\n",
            "        result *= 2.0;\n",
            "    }\n",
            "    return result;\n",
            "}\n",
            "uniform float g_After; // {\"default\":3}\n",
            "void main() { gl_FragColor = vec4(1.0); }\n",
            "uniform float g_Ignored; // {\"default\":4}\n",
        );
        let metadata_sources = [PreprocessedStage::new(
            ShaderStageKind::Fragment,
            source.to_owned(),
        )];
        let stages = [stage(ShaderStageKind::Fragment)];
        let inputs = ProgramStageInputs::new(&stages, &metadata_sources)
            .expect("alternative function headers share their body in metadata sources");
        let metadata = inputs.stages()[0]
            .metadata_module
            .extract_metadata(&[])
            .expect("metadata extracts from every conditional branch");

        assert_eq!(
            metadata
                .default_uniforms()
                .iter()
                .map(|uniform| uniform.uniform())
                .collect::<Vec<_>>(),
            ["g_Rotated", "g_Plain", "g_After"]
        );
        assert_eq!(metadata.combos()[0].name().as_str(), "ROTATION");
        assert_eq!(metadata.combos()[0].value(), "0");

        // Compiled sources still require ordinary balanced syntax.
        assert!(ProgramStageInputs::new(&metadata_sources, &metadata_sources).is_err());
    }

    fn stage(kind: ShaderStageKind) -> PreprocessedStage {
        PreprocessedStage::new(kind, "void main() {}\n".to_owned())
    }
}

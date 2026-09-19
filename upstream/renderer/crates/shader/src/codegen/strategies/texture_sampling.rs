//! Texture sampling call codegen.

use linkme::distributed_slice;

use super::{
    CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES, StrategyContext, TEXTURE_SAMPLING,
};
use crate::{
    ShaderError, ShaderResult, SourceSpan,
    codegen::{DeclarationPlan, Fixup, VideoPlaneResource},
    syntax::{FunctionCall, FunctionCalls, SyntaxItem},
    tokenizer::{TokenCursor, TypedToken},
};

/// Rewrites source `sampler2D` calls to Naga-compatible separated handles.
struct TextureSamplingStrategy;

#[distributed_slice(GENERAL_POLICIES)]
static TEXTURE_SAMPLING_POLICY: CodegenStrategy = CodegenStrategy {
    name: TEXTURE_SAMPLING,
    stage: CodegenStage::CompatibilityExpansion,
    after: &[],
    emitter: &TextureSamplingStrategy,
};

impl Emitable for TextureSamplingStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        // Before any rewrite: a slot compiled as planes may only be read
        // through the sampling calls this strategy can translate, and finding
        // that out after half the calls were rewritten would leave a program
        // that is neither variant.
        Self::reject_unsupported_video_plane_uses(context)?;
        let tokens = context.context().module.token_stream().cursor();
        for call in context.context().module.function_calls() {
            Self::emit_call(context, tokens, &call)?;
        }

        for directive in context.context().module.items().iter().filter_map(|item| {
            let SyntaxItem::Directive(directive) = item else {
                return None;
            };
            Some(directive)
        }) {
            let Some(tokens) = directive.define_body_tokens_in(context.context().module)? else {
                continue;
            };
            let cursor = tokens.cursor();
            let facts = tokens.facts();
            for call in FunctionCalls::new(cursor, facts.calls()) {
                Self::emit_call(context, cursor, &call)?;
            }
        }
        Ok(())
    }
}

impl TextureSamplingStrategy {
    /// Emits texture-sampling fixups for one syntactic call.
    fn emit_call(
        context: &mut StrategyContext<'_, '_, '_>,
        tokens: TokenCursor<'_>,
        call: &FunctionCall,
    ) -> ShaderResult<()> {
        let Some(texture_call) =
            TextureSamplingCall::classify_call(tokens, call, &context.context().declarations)
        else {
            return Ok(());
        };

        if let Some(slot) = context
            .context()
            .declarations
            .video_plane_for_texture(texture_call.texture_name.as_str())
            .map(|plane| plane.slot)
        {
            return Self::emit_video_plane_call(context, slot, call, &texture_call);
        }

        context.context().fixups.push(Fixup::replace(
            texture_call.name_span(),
            texture_call.glsl_name(),
        ));
        context.context().fixups.push(Fixup::insert(
            texture_call.texture_start()?,
            "sampler2D(".to_owned(),
        ));
        context.context().fixups.push(Fixup::insert(
            texture_call.texture_end()?,
            format!(", {})", texture_call.sampler_name),
        ));
        Ok(())
    }

    /// Rewrites one sampling call on a slot compiled as separate planes into a
    /// call of that slot's generated helper.
    ///
    /// The texture argument is removed rather than translated: the helper reads
    /// both planes through the globals the resource layout allocated, and the
    /// coordinate stays exactly the expression the author wrote so every later
    /// coercion still applies to it.
    fn emit_video_plane_call(
        context: &mut StrategyContext<'_, '_, '_>,
        slot: u8,
        call: &FunctionCall,
        texture_call: &TextureSamplingCall,
    ) -> ShaderResult<()> {
        if texture_call.function != TextureSamplingFunction::ImplicitLod {
            return Err(Self::video_plane_error(
                &texture_call.texture_name,
                "an explicit level-of-detail sample",
            ));
        }
        let Some(first) = call.first_argument() else {
            return Err(Self::video_plane_error(
                &texture_call.texture_name,
                "a sampling call with no coordinate",
            ));
        };
        let Some(remaining) = first.remaining_argument_span() else {
            return Err(Self::video_plane_error(
                &texture_call.texture_name,
                "a sampling call with no coordinate",
            ));
        };
        if call.argument_count() != 2 {
            return Err(Self::video_plane_error(
                &texture_call.texture_name,
                "a sampling call with extra arguments",
            ));
        }

        context.context().fixups.push(Fixup::replace(
            texture_call.name_span(),
            VideoPlaneResource::helper_name(slot),
        ));
        context.context().fixups.push(Fixup::replace(
            SourceSpan::new(first.argument_span().start(), remaining.start())?,
            String::new(),
        ));
        context.context().declarations.require_video_plane(slot);
        Ok(())
    }

    /// Fails the plane variant, naming what the author's shader does that this
    /// translation cannot reproduce.
    fn video_plane_error(texture_name: &str, what: &str) -> ShaderError {
        ShaderError::invalid_request(format!(
            "video texture `{texture_name}` cannot be sampled as planes: the shader uses {what}"
        ))
    }

    /// Fails the plane variant when a slot compiled as planes is referenced
    /// anywhere other than a sampling call this strategy rewrites.
    ///
    /// Everything else -- a size query, a texel fetch, passing the sampler to a
    /// function -- would be left naming a luma plane while the author expects a
    /// colour image, so the variant is refused and the pre-converted program
    /// keeps the material. Macro bodies are scanned on the same terms as
    /// ordinary source, because that is where they are rewritten.
    fn reject_unsupported_video_plane_uses(
        context: &mut StrategyContext<'_, '_, '_>,
    ) -> ShaderResult<()> {
        let state = context.context();
        let planes: Vec<String> = state
            .declarations
            .textures()
            .filter(|texture| {
                state
                    .declarations
                    .video_plane_for_texture(texture.name)
                    .is_some()
            })
            .map(|texture| texture.name.to_owned())
            .collect();
        if planes.is_empty() {
            return Ok(());
        }

        let declaration_spans: Vec<SourceSpan> = state
            .module
            .items()
            .iter()
            .filter_map(|item| {
                let SyntaxItem::Declaration(declaration) = item else {
                    return None;
                };
                let name = declaration.name()?;
                planes
                    .iter()
                    .any(|plane| plane == name)
                    .then(|| declaration.span())
            })
            .collect();

        let tokens = state.module.token_stream().cursor();
        Self::reject_unsupported_uses_in(
            tokens,
            state.module.function_calls(),
            &planes,
            &declaration_spans,
            &state.declarations,
        )?;

        for item in state.module.items() {
            let SyntaxItem::Directive(directive) = item else {
                continue;
            };
            let Some(body) = directive.define_body_tokens_in(state.module)? else {
                continue;
            };
            let cursor = body.cursor();
            let facts = body.facts();
            Self::reject_unsupported_uses_in(
                cursor,
                FunctionCalls::new(cursor, facts.calls()),
                &planes,
                &declaration_spans,
                &state.declarations,
            )?;
        }
        Ok(())
    }

    /// Rejects unsupported references to a plane slot inside one token stream.
    fn reject_unsupported_uses_in(
        tokens: TokenCursor<'_>,
        calls: impl Iterator<Item = FunctionCall>,
        planes: &[String],
        declaration_spans: &[SourceSpan],
        declarations: &DeclarationPlan<'_>,
    ) -> ShaderResult<()> {
        let mut allowed = Vec::new();
        for call in calls {
            let Some(texture_call) = TextureSamplingCall::classify_call(tokens, &call, declarations)
            else {
                continue;
            };
            if !planes
                .iter()
                .any(|plane| plane.as_str() == texture_call.texture_name.as_str())
            {
                continue;
            }
            if let Some(first) = call.first_argument() {
                allowed.push(first.start());
            }
        }

        for index in 0..tokens.len() {
            let TypedToken::Identifier(name) = tokens[index].kind() else {
                continue;
            };
            if !planes.iter().any(|plane| plane.as_str() == name.as_str()) {
                continue;
            }
            if allowed.contains(&index) {
                continue;
            }
            let span = tokens[index].span();
            if declaration_spans
                .iter()
                .any(|declaration| declaration.contains(span))
            {
                continue;
            }
            return Err(Self::video_plane_error(
                name.as_str(),
                "the texture somewhere other than a plain sample of it",
            ));
        }
        Ok(())
    }
}

/// Texture sampling call that requires a separated Naga sampler wrapper.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct TextureSamplingCall {
    /// Original syntactic function call.
    call: FunctionCall,
    /// Sampling function family used by this call.
    pub(super) function: TextureSamplingFunction,
    /// Source texture declaration name sampled by this call.
    pub(super) texture_name: smol_str::SmolStr,
    /// Source span for the first texture argument.
    texture: SourceSpan,
    /// Generated sampler paired to the source texture declaration.
    sampler_name: String,
}

impl TextureSamplingCall {
    /// Classifies a call as a sampling call against a source `sampler2D`
    /// declaration.
    pub(super) fn classify_call(
        tokens: TokenCursor<'_>,
        call: &FunctionCall,
        declarations: &DeclarationPlan<'_>,
    ) -> Option<Self> {
        let function = TextureSamplingFunction::classify_name(call.name())?;

        let first_argument = call.first_argument()?;
        let TypedToken::Identifier(name) = tokens[first_argument.start()].kind() else {
            return None;
        };
        let sampler_name = declarations.texture_sampler_name(name)?;

        Some(Self {
            call: call.clone(),
            function,
            texture_name: name.clone(),
            texture: first_argument.argument_span(),
            sampler_name,
        })
    }

    /// Returns the source span for the call name.
    pub(super) const fn name_span(&self) -> SourceSpan {
        self.call.name_span()
    }

    /// Returns the GLSL sampling function emitted for this call.
    pub(super) const fn glsl_name(&self) -> &'static str {
        match self.function {
            TextureSamplingFunction::ImplicitLod => "texture",
            TextureSamplingFunction::ExplicitLod => "textureLod",
        }
    }

    /// Returns the insertion point before the texture argument.
    pub(super) fn texture_start(&self) -> ShaderResult<SourceSpan> {
        SourceSpan::new(self.texture.start(), self.texture.start())
    }

    /// Returns the insertion point after the texture argument.
    pub(super) fn texture_end(&self) -> ShaderResult<SourceSpan> {
        SourceSpan::new(self.texture.end(), self.texture.end())
    }
}

/// Texture sampling function family used by WE shaders.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum TextureSamplingFunction {
    /// `texture(...)` style implicit LOD sampling.
    ImplicitLod,
    /// `textureLod(...)` style explicit LOD sampling.
    ExplicitLod,
}

impl TextureSamplingFunction {
    /// Classifies a function name as a supported texture sampling function.
    pub(super) const fn classify_name(name: &str) -> Option<Self> {
        match name.as_bytes() {
            b"texture" | b"texture2D" | b"tex2D" | b"texSample2D" => Some(Self::ImplicitLod),
            b"textureLod" | b"texSample2DLod" => Some(Self::ExplicitLod),
            _ => None,
        }
    }
}

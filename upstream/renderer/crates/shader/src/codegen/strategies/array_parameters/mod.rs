//! Rewrites legacy array-parameter helpers into Naga-compatible GLSL.

/// Local array alias lowering.
mod aliases;
/// Call-site argument parsing for array parameter specialization.
mod calls;
/// Scope-aware scans for specialized array parameter uses.
mod scopes;
/// Function signature parsing for array parameter specialization.
mod signatures;
/// Specialization planning for array parameter functions.
mod specialization;

use linkme::distributed_slice;

use self::{
    aliases::ArrayAliases,
    calls::CallArguments,
    scopes::ArrayParameterUseScanner,
    signatures::{FunctionOverloads, FunctionParameterList, FunctionSpecializationSignature},
    specialization::FunctionSpecialization,
};
use super::{
    ARRAY_PARAMETERS, CodegenStage, CodegenStrategy, Emitable, GENERAL_POLICIES,
    RESERVED_IDENTIFIERS, StrategyContext,
};
use crate::{
    ShaderResult, SourceSpan,
    codegen::{
        Fixup, ScopedDeclarationFacts, ScopedDeclarationFactsConfig, ScopedDeclarationTypeMode,
        declarations::WidenedArrayMember,
    },
    syntax::{ShaderModule, SyntaxItem},
    tokenizer::TypedToken,
};

/// Returns how a generated block member was widened, when it was.
fn widened_member(
    context: &mut StrategyContext<'_, '_, '_>,
    name: &str,
) -> Option<WidenedArrayMember> {
    context
        .context()
        .declarations
        .uniform_block()?
        .members
        .iter()
        .find(|member| member.name.as_str() == name)
        .and_then(|member| {
            WidenedArrayMember::classify(member.ty.as_str(), member.array_suffix.as_deref())
        })
}

/// Specializes fixed-array function parameters to the global arrays passed by
/// every call. Naga's GLSL frontend accepts uniform array indexing, but does
/// not register user functions that take legacy array parameters.
struct ArrayParametersStrategy;
#[distributed_slice(GENERAL_POLICIES)]
static ARRAY_PARAMETERS_POLICY: CodegenStrategy = CodegenStrategy {
    name: ARRAY_PARAMETERS,
    stage: CodegenStage::SemanticRewrite,
    after: &[RESERVED_IDENTIFIERS],
    emitter: &ArrayParametersStrategy,
};

impl Emitable for ArrayParametersStrategy {
    fn emit(&self, context: &mut StrategyContext<'_, '_, '_>) -> ShaderResult<()> {
        let module = context.context().module;
        let mut aliases = ArrayAliases::default();
        aliases.collect(module);
        let mut alias_fixups = Vec::new();
        for alias in aliases.items {
            let widened = widened_member(context, alias.target());
            alias.emit(context.context().module, widened, &mut alias_fixups);
        }
        for fixup in alias_fixups {
            context.context().fixups.push(fixup);
        }

        for function in module.items().iter().filter_map(|item| match item {
            SyntaxItem::Function(function) => Some(function),
            _ => None,
        }) {
            let mut signatures = Vec::new();
            for overload in module.items().iter().filter_map(|item| match item {
                SyntaxItem::Function(overload) if overload.name() == function.name() => {
                    Some(overload)
                }
                _ => None,
            }) {
                let parameters = FunctionParameterList::parse(overload);
                signatures.push(FunctionSpecializationSignature {
                    has_array_parameters: parameters.has_array_parameters(),
                    retained_parameter_types: parameters.retained_parameter_types(),
                    call_shape: parameters.call_shape(),
                });
            }
            let overloads = FunctionOverloads { signatures };
            let parameters = FunctionParameterList::parse(function);
            if !parameters.has_array_parameters() {
                continue;
            }
            let arguments = CallArguments::new(module, function.name(), &parameters)?;
            if arguments.calls.is_empty() {
                continue;
            }
            let specialization = FunctionSpecialization::new(module, &parameters, &arguments)?;
            overloads.ensure_unambiguous(&parameters, &specialization)?;

            context
                .context()
                .fixups
                .push(Fixup::replace(parameters.span, specialization.parameters));
            for (parameter, argument) in specialization.array_parameters {
                let Some(body) = module
                    .token_stream()
                    .cursor()
                    .contained_byte_range(function.body_span().start(), function.body_span().end())
                else {
                    continue;
                };
                // Specializing a parameter away turns every use of it into a
                // use of the global it was called with. If that global is a
                // widened block member, these reads need the same swizzle a
                // read written against the global directly gets -- the
                // `widened_arrays` strategy cannot see them, because they do
                // not name the member until this rewrite lands.
                let widened = widened_member(context, argument.as_str());
                let tokens = module.token_stream().cursor();
                for index in (ArrayParameterUseScanner { body }).use_indices(
                    module,
                    tokens,
                    parameter.name.as_str(),
                ) {
                    context
                        .context()
                        .fixups
                        .push(Fixup::replace(tokens[index].span(), argument.to_string()));
                    if let Some(widened) = widened
                        && let Some(span) =
                            WidenedArrayMember::subscript_swizzle_span(tokens, index)
                    {
                        context
                            .context()
                            .fixups
                            .push(Fixup::insert(span, widened.swizzle().to_owned()));
                    }
                }
            }
            for call in specialization.calls {
                context
                    .context()
                    .fixups
                    .push(Fixup::replace(call.span, call.arguments));
            }
        }

        Ok(())
    }
}

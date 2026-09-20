use super::{Fixup, SourceSpan, StrategyContext, TypedToken};
use crate::tokenizer::{
    OperatorType::{Arithmetic, Conditional, Equality, Relational},
    TokenCursor,
};

/// Parenthesized comparisons used as arithmetic operands.
///
/// The permissive path these shaders were authored against converts a
/// comparison to `1.0`/`0.0` wherever arithmetic asks for a number, which is
/// how `depth *= (depth < limit) * 6.0;` selects a branch without one. A
/// strict frontend rejects the multiply instead, taking the whole effect with
/// it, so the comparison is given the conversion the author relied on.
#[derive(Default)]
pub(super) struct BooleanArithmeticOperands {
    /// Conversion insertions in source order.
    pub items: Vec<BooleanArithmeticOperand>,
}

impl BooleanArithmeticOperands {
    /// Scans tokens for comparison groups next to an arithmetic operator.
    pub(super) fn collect(&mut self, tokens: TokenCursor<'_>) {
        for open in 0..tokens.len() {
            if !tokens[open].kind().is_left_paren() {
                continue;
            }
            // An identifier or a type name before the parenthesis makes this a
            // call's argument list, not a group that can take a conversion.
            if tokens
                .previous_non_comment(open)
                .is_some_and(|previous| Self::opens_call(tokens, previous))
            {
                continue;
            }
            let Some(close) = tokens.matching_right_paren(open) else {
                continue;
            };
            if !Self::has_arithmetic_neighbour(tokens, open, close)
                || !Self::yields_comparison(tokens, open, close)
            {
                continue;
            }
            let start = tokens[open].span().start();
            let Ok(insertion) = SourceSpan::new(start, start) else {
                continue;
            };
            self.items.push(BooleanArithmeticOperand { insertion });
        }
    }

    /// Returns whether a token before a parenthesis makes it a call.
    fn opens_call(tokens: TokenCursor<'_>, previous: usize) -> bool {
        matches!(
            tokens[previous].kind(),
            TypedToken::Identifier(_) | TypedToken::TypeMark(_) | TypedToken::Keyword(_)
        )
    }

    /// Returns whether the group is an operand of an arithmetic operator.
    fn has_arithmetic_neighbour(tokens: TokenCursor<'_>, open: usize, close: usize) -> bool {
        let is_arithmetic = |index: usize| {
            matches!(tokens[index].kind(), TypedToken::Operator(Arithmetic(_)))
        };
        tokens
            .previous_non_comment(open)
            .is_some_and(&is_arithmetic)
            || tokens
                .next_non_comment(close + 1)
                .is_some_and(&is_arithmetic)
    }

    /// Returns whether the group's own top level is a comparison.
    ///
    /// A conditional selects a value rather than producing one, so `(a < b ? x
    /// : y)` is already the number it looks like and is left alone.
    fn yields_comparison(tokens: TokenCursor<'_>, open: usize, close: usize) -> bool {
        let mut depth = 0usize;
        let mut comparison = false;
        for index in open + 1..close {
            let kind = tokens[index].kind();
            if kind.is_left_paren() {
                depth += 1;
                continue;
            }
            if kind.is_right_paren() {
                depth = depth.saturating_sub(1);
                continue;
            }
            if depth != 0 {
                continue;
            }
            match kind {
                TypedToken::Operator(Relational(_) | Equality(_)) => comparison = true,
                TypedToken::Operator(Conditional(_)) => return false,
                _ => {}
            }
        }
        comparison
    }
}

/// One comparison group that needs a float conversion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct BooleanArithmeticOperand {
    /// Insertion point immediately before the group.
    pub insertion: SourceSpan,
}

impl BooleanArithmeticOperand {
    /// Emits the conversion in front of the group.
    pub(super) fn emit(self, context: &mut StrategyContext<'_, '_, '_>) {
        context
            .context()
            .fixups
            .push(Fixup::insert(self.insertion, "float".to_owned()));
    }
}

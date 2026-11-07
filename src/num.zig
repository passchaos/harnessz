//! Small numeric helpers shared by statistics, benchmark, and baseline code.
//!
//! These functions centralize two policies that otherwise drifted between
//! modules: division that has a defined result for a zero denominator, and the
//! JSON rule that non-finite floats are omitted instead of being rendered as
//! the invalid bare tokens `inf`/`nan`.

const std = @import("std");

/// Divide `numerator` by `denominator`, treating a zero denominator as a
/// limiting value instead of a floating-point exception.
///
/// `0 / 0` is `0`; a positive numerator yields `+inf` and a negative numerator
/// yields `-inf`. Callers that serialize the result to JSON should pass it
/// through `finiteOptional`.
pub fn safeDiv(numerator: f64, denominator: f64) f64 {
    if (denominator == 0) {
        if (numerator == 0) return 0;
        return if (numerator > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    return numerator / denominator;
}

/// Map a non-finite value to `null`. JSON has no representation for infinity
/// or NaN, and omitting the field is preferable to emitting an invalid token.
pub fn finiteOptional(value: ?f64) ?f64 {
    const number = value orelse return null;
    return if (std.math.isFinite(number)) number else null;
}

test "num: safeDiv handles zero denominators" {
    try std.testing.expectEqual(@as(f64, 0), safeDiv(0, 0));
    try std.testing.expectEqual(@as(f64, 2.5), safeDiv(5, 2));
    try std.testing.expect(std.math.isInf(safeDiv(1, 0)));
    try std.testing.expect(safeDiv(1, 0) > 0);
    try std.testing.expect(safeDiv(-1, 0) < 0);
}

test "num: finiteOptional drops non-finite values" {
    try std.testing.expectEqual(@as(?f64, null), finiteOptional(null));
    try std.testing.expectEqual(@as(?f64, 1.5), finiteOptional(1.5));
    try std.testing.expectEqual(@as(?f64, null), finiteOptional(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?f64, null), finiteOptional(std.math.nan(f64)));
}

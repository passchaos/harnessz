//! Welch's unequal-variance t-test with an exact Student-t tail probability.
//!
//! The test statistic and degrees of freedom follow Welch's original
//! formulation. The two-sided p-value is computed from the Student-t
//! distribution via the regularized incomplete beta function, so small samples
//! are not treated as if they were normal. `twoSidedNormalPValue` remains
//! available for callers that explicitly want the normal approximation.

const std = @import("std");

pub const WelchResult = struct {
    /// `(mean_a - mean_b) / sqrt(var_a / n_a + var_b / n_b)`.
    t: f64,
    /// Welch-Satterthwaite degrees of freedom.
    degrees_of_freedom: f64,
    /// Two-sided Student-t tail probability.
    p_value: f64,
};

/// Two-sided Welch t-test for the difference in means.
///
/// Both inputs must contain at least two samples; otherwise
/// `error.InvalidOptions` is returned. Zero variance on both sides yields
/// `t = 0, p = 1` when the means agree and an infinite `t` with `p = 0`
/// otherwise.
pub fn welchTTest(
    comptime T: type,
    a: []const T,
    b: []const T,
) !WelchResult {
    if (a.len < 2 or b.len < 2) return error.InvalidOptions;

    const n_a: f64 = @floatFromInt(a.len);
    const n_b: f64 = @floatFromInt(b.len);
    const mean_a = meanOf(T, a);
    const mean_b = meanOf(T, b);
    const var_a = sampleVariance(T, a, mean_a);
    const var_b = sampleVariance(T, b, mean_b);

    const term_a = var_a / n_a;
    const term_b = var_b / n_b;
    const standard_error_sq = term_a + term_b;

    if (standard_error_sq <= 0) {
        const degrees_of_freedom = n_a + n_b - 2.0;
        if (mean_a == mean_b) {
            return .{
                .t = 0,
                .degrees_of_freedom = degrees_of_freedom,
                .p_value = 1,
            };
        }
        return .{
            .t = if (mean_a > mean_b) std.math.inf(f64) else -std.math.inf(f64),
            .degrees_of_freedom = degrees_of_freedom,
            .p_value = 0,
        };
    }

    const t = (mean_a - mean_b) / @sqrt(standard_error_sq);
    const denominator = (term_a * term_a) / (n_a - 1.0) +
        (term_b * term_b) / (n_b - 1.0);
    const degrees_of_freedom = if (denominator > 0)
        (standard_error_sq * standard_error_sq) / denominator
    else
        n_a + n_b - 2.0;

    return .{
        .t = t,
        .degrees_of_freedom = degrees_of_freedom,
        .p_value = studentTTwoSidedPValue(t, degrees_of_freedom),
    };
}

/// Two-sided Student-t tail probability `P(|T| >= |t|)`.
///
/// Uses the identity `P = I_{df/(df+t^2)}(df/2, 1/2)` with the regularized
/// incomplete beta function. Invalid degrees of freedom and NaN inputs yield
/// 1; infinite `t` yields 0.
pub fn studentTTwoSidedPValue(t: f64, degrees_of_freedom: f64) f64 {
    if (std.math.isNan(t) or std.math.isNan(degrees_of_freedom)) return 1;
    if (!(degrees_of_freedom > 0) or !std.math.isFinite(degrees_of_freedom)) {
        return 1;
    }
    if (!std.math.isFinite(t)) return 0;
    if (t == 0) return 1;

    const df = degrees_of_freedom;
    const x = df / (df + t * t);
    return std.math.clamp(regularizedIncompleteBeta(x, df / 2.0, 0.5), 0, 1);
}

/// Two-sided Student-t critical value for a confidence level.
///
/// Solves `studentTTwoSidedPValue(t, df) = 1 - confidence` by bisection.
/// Returns `error.InvalidOptions` for non-positive/non-finite degrees of
/// freedom or a confidence outside `(0, 1)`.
pub fn studentTCritical(degrees_of_freedom: f64, confidence: f64) !f64 {
    if (!(degrees_of_freedom > 0) or !std.math.isFinite(degrees_of_freedom)) {
        return error.InvalidOptions;
    }
    if (!(confidence > 0) or !(confidence < 1)) return error.InvalidOptions;

    const alpha = 1.0 - confidence;
    var low: f64 = 0;
    var high: f64 = 1;
    while (studentTTwoSidedPValue(high, degrees_of_freedom) > alpha) {
        high *= 2;
        if (high > 1e15) return error.InvalidOptions;
    }

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        const mid = (low + high) / 2;
        if (studentTTwoSidedPValue(mid, degrees_of_freedom) > alpha) {
            low = mid;
        } else {
            high = mid;
        }
        if (high - low <= 1e-12 * @max(1.0, high)) break;
    }
    return (low + high) / 2;
}

/// Regularized incomplete beta function `I_x(a, b)`.
fn regularizedIncompleteBeta(x: f64, a: f64, b: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;

    const log_front = std.math.lgamma(f64, a + b) -
        std.math.lgamma(f64, a) -
        std.math.lgamma(f64, b) +
        a * @log(x) +
        b * @log(1.0 - x);
    const front = @exp(log_front);

    if (x < (a + 1.0) / (a + b + 2.0)) {
        return front * betaContinuedFraction(x, a, b) / a;
    }
    return 1.0 - front * betaContinuedFraction(1.0 - x, b, a) / b;
}

/// Continued fraction for the incomplete beta function (modified Lentz).
fn betaContinuedFraction(x: f64, a: f64, b: f64) f64 {
    const max_iterations = 300;
    const epsilon = 3e-14;
    const tiny = 1e-300;

    var c: f64 = 1;
    var d: f64 = 1 - (a + b) * x / (a + 1);
    if (@abs(d) < tiny) d = tiny;
    d = 1 / d;
    var h = d;

    var m: usize = 1;
    while (m <= max_iterations) : (m += 1) {
        const m_f: f64 = @floatFromInt(m);
        const m2: f64 = 2.0 * m_f;

        var aa = m_f * (b - m_f) * x / ((a + m2 - 1) * (a + m2));
        d = 1 + aa * d;
        if (@abs(d) < tiny) d = tiny;
        c = 1 + aa / c;
        if (@abs(c) < tiny) c = tiny;
        d = 1 / d;
        h *= d * c;

        aa = -(a + m_f) * (a + b + m_f) * x / ((a + m2) * (a + m2 + 1));
        d = 1 + aa * d;
        if (@abs(d) < tiny) d = tiny;
        c = 1 + aa / c;
        if (@abs(c) < tiny) c = tiny;
        d = 1 / d;
        const delta = d * c;
        h *= delta;

        if (@abs(delta - 1) < epsilon) break;
    }
    return h;
}

/// Two-sided p-value `P(|Z| >= |t|)` for a standard normal `Z`.
pub fn twoSidedNormalPValue(t: f64) f64 {
    if (std.math.isNan(t)) return 1;
    if (!std.math.isFinite(t)) return 0;
    const p = erfc(@abs(t) / @sqrt(2.0));
    return std.math.clamp(p, 0.0, 1.0);
}

/// Standard normal cumulative distribution function.
pub fn normalCdf(z: f64) f64 {
    if (std.math.isNan(z)) return std.math.nan(f64);
    return 0.5 * erfc(-z / @sqrt(2.0));
}

/// Complementary error function using the Numerical Recipes `erfcc`
/// rational approximation. Relative error is below 1.2e-7 everywhere, which
/// is ample for a documented normal approximation.
pub fn erfc(x: f64) f64 {
    if (std.math.isNan(x)) return std.math.nan(f64);
    const z = @abs(x);
    const t = 1.0 / (1.0 + 0.5 * z);
    const poly = 1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))));
    const value = t * @exp(-z * z - 1.26551223 + t * poly);
    return if (x >= 0) value else 2.0 - value;
}

fn meanOf(comptime T: type, values: []const T) f64 {
    var sum: f64 = 0;
    for (values) |value| sum += toF64(T, value);
    return sum / @as(f64, @floatFromInt(values.len));
}

/// Unbiased sample variance (denominator `n - 1`).
fn sampleVariance(comptime T: type, values: []const T, mean_value: f64) f64 {
    var sum: f64 = 0;
    for (values) |value| {
        const delta = toF64(T, value) - mean_value;
        sum += delta * delta;
    }
    return sum / @as(f64, @floatFromInt(values.len - 1));
}

fn toF64(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("welch supports integer and floating-point slices"),
    };
}

test "welch: known statistic and degrees of freedom" {
    const a = [_]f64{ 1, 2, 3 };
    const b = [_]f64{ 4, 5, 6 };
    const result = try welchTTest(f64, &a, &b);

    const expected_t = -3.0 / @sqrt(2.0 / 3.0);
    try std.testing.expectApproxEqAbs(expected_t, result.t, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), result.degrees_of_freedom, 1e-12);
    // Exact two-sided Student-t tail (the normal approximation would report
    // roughly 0.00024 for the same statistic).
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.021311641128756727),
        result.p_value,
        1e-9,
    );
}

test "welch: Student-t tail matches reference values" {
    const Case = struct { t: f64, df: f64, p: f64 };
    const cases = [_]Case{
        .{ .t = 2.0, .df = 10, .p = 0.07338803477074039 },
        .{ .t = 2.228138852, .df = 10, .p = 0.05 },
        .{ .t = 1.0, .df = 1, .p = 0.5 },
        .{ .t = 2.0, .df = 1, .p = 0.2951672353008664 },
        .{ .t = 3.0, .df = 2, .p = 0.09546596626670911 },
    };
    for (cases) |case| {
        try std.testing.expectApproxEqAbs(
            case.p,
            studentTTwoSidedPValue(case.t, case.df),
            1e-10,
        );
        try std.testing.expectApproxEqAbs(
            case.p,
            studentTTwoSidedPValue(-case.t, case.df),
            1e-10,
        );
    }

    try std.testing.expectEqual(@as(f64, 1), studentTTwoSidedPValue(0, 10));
    try std.testing.expectEqual(
        @as(f64, 0),
        studentTTwoSidedPValue(std.math.inf(f64), 10),
    );
    try std.testing.expectEqual(
        @as(f64, 1),
        studentTTwoSidedPValue(1, 0),
    );
    try std.testing.expectEqual(
        @as(f64, 1),
        studentTTwoSidedPValue(std.math.nan(f64), 10),
    );
}

test "welch: Student-t critical values" {
    const Case = struct { df: f64, confidence: f64, t: f64 };
    const cases = [_]Case{
        .{ .df = 1, .confidence = 0.95, .t = 12.706204736432095 },
        .{ .df = 4, .confidence = 0.95, .t = 2.7764451051977987 },
        .{ .df = 10, .confidence = 0.95, .t = 2.2281388519649385 },
        .{ .df = 30, .confidence = 0.95, .t = 2.0422724563012373 },
    };
    for (cases) |case| {
        try std.testing.expectApproxEqAbs(
            case.t,
            try studentTCritical(case.df, case.confidence),
            1e-8,
        );
    }

    try std.testing.expectError(
        error.InvalidOptions,
        studentTCritical(0, 0.95),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        studentTCritical(10, 1.0),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        studentTCritical(10, 0),
    );
}

test "welch: symmetric p-value" {
    const a = [_]u64{ 10, 12, 11, 9, 13 };
    const b = [_]u64{ 20, 22, 21, 19, 23 };
    const forward = try welchTTest(u64, &a, &b);
    const reverse = try welchTTest(u64, &b, &a);
    try std.testing.expectApproxEqAbs(forward.p_value, reverse.p_value, 1e-15);
    try std.testing.expectApproxEqAbs(forward.t, -reverse.t, 1e-12);
    try std.testing.expectApproxEqAbs(
        forward.degrees_of_freedom,
        reverse.degrees_of_freedom,
        1e-12,
    );
}

test "welch: identical distributions are not significant" {
    const values = [_]u64{ 100, 101, 99, 100, 102 };
    const result = try welchTTest(u64, &values, &values);
    try std.testing.expectEqual(@as(f64, 0), result.t);
    try std.testing.expectEqual(@as(f64, 1), result.p_value);
    try std.testing.expectEqual(@as(f64, 8), result.degrees_of_freedom);
}

test "welch: zero variance with different means" {
    const a = [_]u64{ 100, 100, 100 };
    const b = [_]u64{ 50, 50, 50 };
    const result = try welchTTest(u64, &a, &b);
    try std.testing.expect(result.t > 0);
    try std.testing.expect(std.math.isInf(result.t));
    try std.testing.expectEqual(@as(f64, 0), result.p_value);
}

test "welch: requires at least two samples" {
    try std.testing.expectError(
        error.InvalidOptions,
        welchTTest(u64, &[_]u64{1}, &[_]u64{ 1, 2 }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        welchTTest(u64, &[_]u64{ 1, 2 }, &[_]u64{}),
    );
}

test "normal approximation: cdf and p-value" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), normalCdf(0), 2e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.975), normalCdf(1.96), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), normalCdf(-1.96), 1e-5);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.05),
        twoSidedNormalPValue(1.959963984540054),
        1e-5,
    );
    try std.testing.expectEqual(@as(f64, 0), twoSidedNormalPValue(std.math.inf(f64)));
}

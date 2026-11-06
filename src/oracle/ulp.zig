//! ULP-based comparison for f32 and f64.

const std = @import("std");

pub const UlpReason = enum {
    finite,
    signed_zero,
    both_nan,
    nan_mismatch,
    both_infinite,
    infinite_mismatch,
};

pub const UlpReport = struct {
    equal: bool = false,
    /// Distance in representable floating-point values. It is 0 for equal
    /// values, both-NaN inputs, and signed zero. It is `maxInt(u64)` when the
    /// values are not comparable (one NaN, or infinities with different
    /// signs).
    ulp_distance: u64 = 0,
    expected: f64 = 0,
    actual: f64 = 0,
    reason: UlpReason = .finite,
};

/// Compare two floats by ULP distance.
///
/// Semantics:
/// - `+0.0` and `-0.0` are equal (reason `.signed_zero`, distance 0).
/// - NaN never compares equal, even to another NaN (reason `.both_nan` or
///   `.nan_mismatch`).
/// - Same-sign infinities are equal; opposite-sign infinities are not.
/// - Finite values pass when `ulp_distance <= max_ulp`.
pub fn compareUlp(
    comptime T: type,
    expected: T,
    actual: T,
    max_ulp: u64,
) UlpReport {
    comptime std.debug.assert(T == f32 or T == f64);

    var report: UlpReport = .{
        .expected = @floatCast(expected),
        .actual = @floatCast(actual),
    };

    const a: f64 = @floatCast(expected);
    const b: f64 = @floatCast(actual);
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan or b_nan) {
        report.reason = if (a_nan and b_nan) .both_nan else .nan_mismatch;
        report.equal = false;
        report.ulp_distance = if (a_nan and b_nan) 0 else std.math.maxInt(u64);
        return report;
    }

    const a_inf = std.math.isInf(a);
    const b_inf = std.math.isInf(b);
    if (a_inf or b_inf) {
        if (a_inf and b_inf and std.math.signbit(a) == std.math.signbit(b)) {
            report.reason = .both_infinite;
            report.equal = true;
            report.ulp_distance = 0;
        } else {
            report.reason = .infinite_mismatch;
            report.equal = false;
            report.ulp_distance = std.math.maxInt(u64);
        }
        return report;
    }

    if (a == 0 and b == 0) {
        const same_sign = std.math.signbit(a) == std.math.signbit(b);
        report.reason = if (same_sign) .finite else .signed_zero;
        report.equal = true;
        report.ulp_distance = 0;
        return report;
    }

    const distance = ulpDistance(T, expected, actual);
    report.ulp_distance = distance;
    report.equal = distance <= max_ulp;
    return report;
}

fn ulpDistance(comptime T: type, a: T, b: T) u64 {
    const Bits = std.meta.Int(.signed, @bitSizeOf(T));
    const a_ordered = orderedBits(Bits, @bitCast(a));
    const b_ordered = orderedBits(Bits, @bitCast(b));
    return @intCast(@abs(a_ordered - b_ordered));
}

/// Map raw float bits to a monotonically ordered integer. Negative values
/// (including -0.0) map below positive values; -0.0 and +0.0 both map to 0.
fn orderedBits(comptime I: type, value: I) i128 {
    if (value < 0) {
        return @as(i128, std.math.minInt(I)) - @as(i128, value);
    }
    return @as(i128, value);
}

test "ulp: exact and adjacent values" {
    const exact = compareUlp(f64, 1.0, 1.0, 0);
    try std.testing.expect(exact.equal);
    try std.testing.expectEqual(@as(u64, 0), exact.ulp_distance);
    try std.testing.expectEqual(UlpReason.finite, exact.reason);

    const one: f64 = 1.0;
    const next: f64 = @bitCast(@as(u64, @bitCast(one)) + 1);
    const adjacent = compareUlp(f64, one, next, 1);
    try std.testing.expect(adjacent.equal);
    try std.testing.expectEqual(@as(u64, 1), adjacent.ulp_distance);

    try std.testing.expect(!compareUlp(f64, one, next, 0).equal);

    const two_away: f64 = @bitCast(@as(u64, @bitCast(one)) + 2);
    try std.testing.expect(!compareUlp(f64, one, two_away, 1).equal);
    try std.testing.expect(compareUlp(f64, one, two_away, 2).equal);
}

test "ulp: f32 support" {
    const one: f32 = 1.0;
    const next: f32 = @bitCast(@as(u32, @bitCast(one)) + 1);
    const report = compareUlp(f32, one, next, 1);
    try std.testing.expect(report.equal);
    try std.testing.expectEqual(@as(u64, 1), report.ulp_distance);
    try std.testing.expect(!compareUlp(f32, one, next, 0).equal);
}

test "ulp: NaN and infinity handling" {
    const nan = std.math.nan(f64);
    const both_nan = compareUlp(f64, nan, nan, std.math.maxInt(u64));
    try std.testing.expect(!both_nan.equal);
    try std.testing.expectEqual(UlpReason.both_nan, both_nan.reason);
    try std.testing.expectEqual(@as(u64, 0), both_nan.ulp_distance);

    const one_nan = compareUlp(f64, 1.0, nan, std.math.maxInt(u64));
    try std.testing.expect(!one_nan.equal);
    try std.testing.expectEqual(UlpReason.nan_mismatch, one_nan.reason);

    const inf = std.math.inf(f64);
    const both_inf = compareUlp(f64, inf, inf, 0);
    try std.testing.expect(both_inf.equal);
    try std.testing.expectEqual(UlpReason.both_infinite, both_inf.reason);

    const opposite = compareUlp(f64, inf, -inf, std.math.maxInt(u64));
    try std.testing.expect(!opposite.equal);
    try std.testing.expectEqual(UlpReason.infinite_mismatch, opposite.reason);

    const finite_vs_inf = compareUlp(f64, 1.0, inf, std.math.maxInt(u64));
    try std.testing.expect(!finite_vs_inf.equal);
    try std.testing.expectEqual(UlpReason.infinite_mismatch, finite_vs_inf.reason);
}

test "ulp: signed zero is explicit" {
    const signed = compareUlp(f64, 0.0, -0.0, 0);
    try std.testing.expect(signed.equal);
    try std.testing.expectEqual(UlpReason.signed_zero, signed.reason);
    try std.testing.expectEqual(@as(u64, 0), signed.ulp_distance);

    const same = compareUlp(f64, -0.0, -0.0, 0);
    try std.testing.expect(same.equal);
    try std.testing.expectEqual(UlpReason.finite, same.reason);
}

test "ulp: negative values order correctly" {
    const minus_one: f64 = -1.0;
    const next_negative: f64 = @bitCast(@as(u64, @bitCast(minus_one)) - 1);
    const report = compareUlp(f64, minus_one, next_negative, 1);
    try std.testing.expect(report.equal);
    try std.testing.expectEqual(@as(u64, 1), report.ulp_distance);
}

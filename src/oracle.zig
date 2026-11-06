//! Byte, integer, and floating-point oracle comparisons.

const std = @import("std");

pub const Report = struct {
    equal: bool,
    first_mismatch: ?usize,
    expected_len: usize,
    actual_len: usize,

    pub fn ok(self: Report) bool {
        return self.equal;
    }
};

pub const FloatOptions = struct {
    /// Absolute tolerance. A pair passes when
    /// `|a-b| <= abs_tolerance + rel_tolerance * max(|a|,|b|)`.
    abs_tolerance: f64 = 0,
    rel_tolerance: f64 = 0,
    /// Treat two NaNs as equal. By default NaN differs from everything,
    /// including another NaN.
    nan_equal: bool = false,
    /// Treat +0.0 and -0.0 as equal (IEEE comparison default). Set false to
    /// require identical signs.
    signed_zero_equal: bool = true,
    /// Stop after this many mismatches. Zero means unlimited.
    max_mismatches: usize = 0,
};

pub const FloatReport = struct {
    equal: bool = true,
    first_mismatch: ?usize = null,
    mismatch_count: usize = 0,
    expected_len: usize = 0,
    actual_len: usize = 0,
    max_abs_error: f64 = 0,
    max_rel_error: f64 = 0,
    truncated: bool = false,

    pub fn ok(self: FloatReport) bool {
        return self.equal;
    }
};

pub fn compareBytes(expected: []const u8, actual: []const u8) Report {
    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common and expected[i] == actual[i]) : (i += 1) {}
    if (i == common and expected.len == actual.len) {
        return .{
            .equal = true,
            .first_mismatch = null,
            .expected_len = expected.len,
            .actual_len = actual.len,
        };
    }
    return .{
        .equal = false,
        .first_mismatch = i,
        .expected_len = expected.len,
        .actual_len = actual.len,
    };
}

pub fn compareIntSlices(
    comptime T: type,
    expected: []const T,
    actual: []const T,
) Report {
    comptime std.debug.assert(@typeInfo(T) == .int);
    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common and expected[i] == actual[i]) : (i += 1) {}
    if (i == common and expected.len == actual.len) {
        return .{
            .equal = true,
            .first_mismatch = null,
            .expected_len = expected.len,
            .actual_len = actual.len,
        };
    }
    return .{
        .equal = false,
        .first_mismatch = i,
        .expected_len = expected.len,
        .actual_len = actual.len,
    };
}

pub fn compareFloatSlices(
    comptime T: type,
    expected: []const T,
    actual: []const T,
    options: FloatOptions,
) FloatReport {
    comptime std.debug.assert(@typeInfo(T) == .float);
    std.debug.assert(std.math.isFinite(options.abs_tolerance));
    std.debug.assert(std.math.isFinite(options.rel_tolerance));
    std.debug.assert(options.abs_tolerance >= 0);
    std.debug.assert(options.rel_tolerance >= 0);

    var report: FloatReport = .{
        .expected_len = expected.len,
        .actual_len = actual.len,
    };

    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        const a: f64 = @floatCast(expected[i]);
        const b: f64 = @floatCast(actual[i]);

        const abs_error = absDifference(a, b);
        if (std.math.isFinite(abs_error)) {
            report.max_abs_error = @max(report.max_abs_error, abs_error);
            const scale = @max(@abs(a), @abs(b));
            const rel_error = if (scale == 0) 0 else abs_error / scale;
            if (std.math.isFinite(rel_error)) {
                report.max_rel_error = @max(report.max_rel_error, rel_error);
            }
        }

        if (!floatEqual(a, b, options)) {
            if (report.first_mismatch == null) report.first_mismatch = i;
            report.mismatch_count += 1;
            if (options.max_mismatches != 0 and
                report.mismatch_count >= options.max_mismatches)
            {
                report.truncated = true;
                break;
            }
        }
    }

    if (!report.truncated and expected.len != actual.len) {
        if (report.first_mismatch == null) report.first_mismatch = common;
        report.mismatch_count += if (expected.len > actual.len)
            expected.len - actual.len
        else
            actual.len - expected.len;
        if (options.max_mismatches != 0 and
            report.mismatch_count > options.max_mismatches)
        {
            report.mismatch_count = options.max_mismatches;
            report.truncated = true;
        }
    }

    report.equal = report.mismatch_count == 0;
    return report;
}

/// Stable 64-bit checksum for determinism reports.
pub fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn absDifference(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    if (std.math.isInf(a) or std.math.isInf(b)) {
        if (std.math.isInf(a) and std.math.isInf(b) and
            (std.math.signbit(a) == std.math.signbit(b)))
        {
            return 0;
        }
        return std.math.inf(f64);
    }
    return @abs(a - b);
}

fn floatEqual(a: f64, b: f64, options: FloatOptions) bool {
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan or b_nan) {
        return options.nan_equal and a_nan and b_nan;
    }

    if (std.math.isInf(a) or std.math.isInf(b)) {
        return std.math.isInf(a) and std.math.isInf(b) and
            std.math.signbit(a) == std.math.signbit(b);
    }

    if (a == 0 and b == 0) {
        if (options.signed_zero_equal) return true;
        return std.math.signbit(a) == std.math.signbit(b);
    }

    if (a == b) return true;

    const abs_error = @abs(a - b);
    const scale = @max(@abs(a), @abs(b));
    const allowed = options.abs_tolerance + options.rel_tolerance * scale;
    return abs_error <= allowed;
}

test "bytes: exact match" {
    const report = compareBytes("hello", "hello");
    try std.testing.expect(report.equal);
    try std.testing.expect(report.first_mismatch == null);
}

test "bytes: first mismatch offset and lengths" {
    const report = compareBytes("abcdef", "abXdef");
    try std.testing.expect(!report.equal);
    try std.testing.expectEqual(@as(?usize, 2), report.first_mismatch);
    try std.testing.expectEqual(@as(usize, 6), report.expected_len);
    try std.testing.expectEqual(@as(usize, 6), report.actual_len);

    const short = compareBytes("abc", "ab");
    try std.testing.expect(!short.equal);
    try std.testing.expectEqual(@as(?usize, 2), short.first_mismatch);
}

test "ints: first mismatch offset" {
    const expected = [_]i32{ 1, 2, 3, 4 };
    const actual = [_]i32{ 1, 2, 9, 4 };
    const report = compareIntSlices(i32, &expected, &actual);
    try std.testing.expect(!report.equal);
    try std.testing.expectEqual(@as(?usize, 2), report.first_mismatch);

    const same = compareIntSlices(i32, &expected, &expected);
    try std.testing.expect(same.equal);
}

test "checksum is stable and content-sensitive" {
    try std.testing.expectEqual(checksum("abc"), checksum("abc"));
    try std.testing.expect(checksum("abc") != checksum("abd"));
}

test "floats: exact and signed zero" {
    const expected = [_]f64{ 1.0, 0.0, -2.5 };
    const actual = [_]f64{ 1.0, -0.0, -2.5 };
    try std.testing.expect(compareFloatSlices(f64, &expected, &actual, .{}).equal);
    try std.testing.expect(!compareFloatSlices(f64, &expected, &actual, .{
        .signed_zero_equal = false,
    }).equal);
}

test "floats: NaN and infinity" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const expected = [_]f64{ nan, inf, -inf };
    const actual = [_]f64{ nan, inf, -inf };

    const default_report = compareFloatSlices(f64, &expected, &actual, .{});
    try std.testing.expect(!default_report.equal);
    try std.testing.expectEqual(@as(?usize, 0), default_report.first_mismatch);

    const nan_equal = compareFloatSlices(f64, &expected, &actual, .{ .nan_equal = true });
    try std.testing.expect(nan_equal.equal);

    const opposite_inf = [_]f64{ nan, inf, inf };
    try std.testing.expect(!compareFloatSlices(f64, &expected, &opposite_inf, .{
        .nan_equal = true,
    }).equal);

    const finite_vs_inf = [_]f64{ nan, 1.0, -inf };
    try std.testing.expect(!compareFloatSlices(f64, &expected, &finite_vs_inf, .{
        .nan_equal = true,
    }).equal);
}

test "floats: absolute tolerance boundary" {
    const expected = [_]f64{1.0};
    const at_boundary = [_]f64{1.5};
    const beyond = [_]f64{1.5000001};

    try std.testing.expect(compareFloatSlices(f64, &expected, &at_boundary, .{
        .abs_tolerance = 0.5,
    }).equal);
    try std.testing.expect(!compareFloatSlices(f64, &expected, &beyond, .{
        .abs_tolerance = 0.5,
    }).equal);
}

test "floats: relative tolerance boundary" {
    const expected = [_]f64{100.0};
    const actual = [_]f64{101.0};

    try std.testing.expect(compareFloatSlices(f64, &expected, &actual, .{
        .rel_tolerance = 0.01,
    }).equal);
    try std.testing.expect(!compareFloatSlices(f64, &expected, &actual, .{
        .rel_tolerance = 0.009,
    }).equal);
}

test "floats: max mismatch count and length mismatch" {
    const expected = [_]f64{ 1, 2, 3, 4 };
    const actual = [_]f64{ 9, 8, 7, 6 };
    const report = compareFloatSlices(f64, &expected, &actual, .{
        .max_mismatches = 2,
    });
    try std.testing.expect(!report.equal);
    try std.testing.expectEqual(@as(usize, 2), report.mismatch_count);
    try std.testing.expect(report.truncated);
    try std.testing.expectEqual(@as(?usize, 0), report.first_mismatch);

    const short = [_]f64{ 1, 2 };
    const length_report = compareFloatSlices(f64, &expected, &short, .{});
    try std.testing.expect(!length_report.equal);
    try std.testing.expectEqual(@as(usize, 2), length_report.mismatch_count);
    try std.testing.expectEqual(@as(?usize, 2), length_report.first_mismatch);
}

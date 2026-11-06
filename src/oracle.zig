//! Byte, integer, and floating-point oracle comparisons.

const std = @import("std");
const float = @import("oracle/float.zig");
const ulp = @import("oracle/ulp.zig");
const complex = @import("oracle/complex.zig");

pub const FloatOptions = float.FloatOptions;
pub const FloatReport = float.FloatReport;
pub const UlpReport = ulp.UlpReport;
pub const UlpReason = ulp.UlpReason;
pub const compareUlp = ulp.compareUlp;
pub const compareComplexSlices = complex.compareComplexSlices;

pub const Report = struct {
    equal: bool,
    first_mismatch: ?usize,
    expected_len: usize,
    actual_len: usize,

    pub fn ok(self: Report) bool {
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
    float.validateOptions(options);

    var report: FloatReport = .{
        .expected_len = expected.len,
        .actual_len = actual.len,
    };

    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        const a: f64 = @floatCast(expected[i]);
        const b: f64 = @floatCast(actual[i]);

        float.updateErrors(&report, a, b);

        if (!float.floatEqual(a, b, options)) {
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

test {
    // Force analysis of the oracle submodules so their tests are included in
    // the package test run.
    std.testing.refAllDecls(ulp);
    std.testing.refAllDecls(complex);
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

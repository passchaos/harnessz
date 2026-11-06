//! Complex-slice comparison built on the shared float tolerance policy.

const std = @import("std");
const float = @import("float.zig");

/// Compare complex slices element by element. A complex element counts as one
/// mismatch when either its real or imaginary part fails. `first_mismatch` is
/// the complex element index.
pub fn compareComplexSlices(
    comptime T: type,
    expected: []const std.math.Complex(T),
    actual: []const std.math.Complex(T),
    options: float.FloatOptions,
) float.FloatReport {
    comptime std.debug.assert(T == f32 or T == f64);
    float.validateOptions(options);

    var report: float.FloatReport = .{
        .expected_len = expected.len,
        .actual_len = actual.len,
    };

    const common = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        const expected_re: f64 = @floatCast(expected[i].re);
        const expected_im: f64 = @floatCast(expected[i].im);
        const actual_re: f64 = @floatCast(actual[i].re);
        const actual_im: f64 = @floatCast(actual[i].im);

        float.updateErrors(&report, expected_re, actual_re);
        float.updateErrors(&report, expected_im, actual_im);

        const equal = float.floatEqual(expected_re, actual_re, options) and
            float.floatEqual(expected_im, actual_im, options);
        if (!equal) {
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

test "complex: exact match and tolerance" {
    const Complex = std.math.Complex(f64);
    const expected = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
        .{ .re = -3.0, .im = 4.0 },
    };
    const actual = [_]Complex{
        .{ .re = 1.0 + 1e-10, .im = 2.0 },
        .{ .re = -3.0, .im = 4.0 - 1e-10 },
    };

    try std.testing.expect(compareComplexSlices(f64, &expected, &expected, .{}).equal);
    try std.testing.expect(compareComplexSlices(f64, &expected, &actual, .{
        .abs_tolerance = 1e-9,
    }).equal);
    try std.testing.expect(!compareComplexSlices(f64, &expected, &actual, .{}).equal);
}

test "complex: real and imaginary mismatches" {
    const Complex = std.math.Complex(f64);
    const expected = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
        .{ .re = 3.0, .im = 4.0 },
    };

    const real_bad = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
        .{ .re = 9.0, .im = 4.0 },
    };
    const real_report = compareComplexSlices(f64, &expected, &real_bad, .{});
    try std.testing.expect(!real_report.equal);
    try std.testing.expectEqual(@as(?usize, 1), real_report.first_mismatch);
    try std.testing.expectEqual(@as(usize, 1), real_report.mismatch_count);

    const imaginary_bad = [_]Complex{
        .{ .re = 1.0, .im = 9.0 },
        .{ .re = 3.0, .im = 4.0 },
    };
    const imaginary_report = compareComplexSlices(f64, &expected, &imaginary_bad, .{});
    try std.testing.expect(!imaginary_report.equal);
    try std.testing.expectEqual(@as(?usize, 0), imaginary_report.first_mismatch);
}

test "complex: NaN, infinity, and signed zero" {
    const Complex = std.math.Complex(f64);
    const expected = [_]Complex{
        .{ .re = std.math.nan(f64), .im = std.math.inf(f64) },
        .{ .re = 0.0, .im = -0.0 },
    };
    const same = [_]Complex{
        .{ .re = std.math.nan(f64), .im = std.math.inf(f64) },
        .{ .re = -0.0, .im = 0.0 },
    };

    try std.testing.expect(!compareComplexSlices(f64, &expected, &same, .{}).equal);
    try std.testing.expect(compareComplexSlices(f64, &expected, &same, .{
        .nan_equal = true,
    }).equal);

    const positive_zero = [_]Complex{
        .{ .re = 0.0, .im = 0.0 },
    };
    const negative_zero = [_]Complex{
        .{ .re = -0.0, .im = -0.0 },
    };
    try std.testing.expect(compareComplexSlices(f64, &positive_zero, &negative_zero, .{}).equal);

    const signed_report = compareComplexSlices(f64, &positive_zero, &negative_zero, .{
        .signed_zero_equal = false,
    });
    try std.testing.expect(!signed_report.equal);
    try std.testing.expectEqual(@as(?usize, 0), signed_report.first_mismatch);
}

test "complex: length mismatch and truncation" {
    const Complex = std.math.Complex(f64);
    const expected = [_]Complex{
        .{ .re = 1.0, .im = 1.0 },
        .{ .re = 2.0, .im = 2.0 },
        .{ .re = 3.0, .im = 3.0 },
    };
    const short = [_]Complex{
        .{ .re = 1.0, .im = 1.0 },
    };
    const length_report = compareComplexSlices(f64, &expected, &short, .{});
    try std.testing.expect(!length_report.equal);
    try std.testing.expectEqual(@as(?usize, 1), length_report.first_mismatch);
    try std.testing.expectEqual(@as(usize, 2), length_report.mismatch_count);

    const all_bad = [_]Complex{
        .{ .re = 9.0, .im = 9.0 },
        .{ .re = 9.0, .im = 9.0 },
        .{ .re = 9.0, .im = 9.0 },
    };
    const truncated = compareComplexSlices(f64, &expected, &all_bad, .{
        .max_mismatches = 2,
    });
    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(@as(usize, 2), truncated.mismatch_count);
}

test "complex: f32 components" {
    const Complex = std.math.Complex(f32);
    const expected = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
    };
    const actual = [_]Complex{
        .{ .re = 1.0 + 1e-5, .im = 2.0 },
    };

    try std.testing.expect(compareComplexSlices(f32, &expected, &actual, .{
        .abs_tolerance = 1e-4,
    }).equal);
    try std.testing.expect(!compareComplexSlices(f32, &expected, &actual, .{}).equal);
}

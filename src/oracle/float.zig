//! Shared floating-point comparison policy used by float and complex oracles.

const std = @import("std");

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

pub fn validateOptions(options: FloatOptions) void {
    std.debug.assert(std.math.isFinite(options.abs_tolerance));
    std.debug.assert(std.math.isFinite(options.rel_tolerance));
    std.debug.assert(options.abs_tolerance >= 0);
    std.debug.assert(options.rel_tolerance >= 0);
}

/// Track the largest absolute and relative errors for one pair.
pub fn updateErrors(report: *FloatReport, a: f64, b: f64) void {
    const abs_error = absDifference(a, b);
    if (!std.math.isFinite(abs_error)) return;

    report.max_abs_error = @max(report.max_abs_error, abs_error);
    const scale = @max(@abs(a), @abs(b));
    const rel_error = if (scale == 0) 0 else abs_error / scale;
    if (std.math.isFinite(rel_error)) {
        report.max_rel_error = @max(report.max_rel_error, rel_error);
    }
}

pub fn absDifference(a: f64, b: f64) f64 {
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

pub fn floatEqual(a: f64, b: f64, options: FloatOptions) bool {
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

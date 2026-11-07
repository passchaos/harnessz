//! Summary statistics and robust comparisons for benchmark samples.

const std = @import("std");
const streaming = @import("stats/streaming.zig");
const welch = @import("stats/welch.zig");
const rank = @import("stats/rank.zig");

pub const Summary = @import("stats/summary.zig").Summary;

/// Streaming (single-pass) mean/variance accumulator using Welford's method.
pub const Accumulator = streaming.Accumulator;
/// Linear histogram with JSON rendering.
pub const Histogram = streaming.Histogram;
/// Normal-approximation confidence interval for a sample mean.
pub const ConfidenceInterval = streaming.ConfidenceInterval;
pub const confidenceIntervalMean = streaming.confidenceIntervalMean;
/// Mean after symmetric trimming of the sorted samples.
pub const trimmedMean = streaming.trimmedMean;

/// Welch's unequal-variance t-test with a normal-approximation p-value.
pub const WelchResult = welch.WelchResult;
pub const welchTTest = welch.welchTTest;
pub const twoSidedNormalPValue = welch.twoSidedNormalPValue;
pub const normalCdf = welch.normalCdf;
pub const erfc = welch.erfc;

/// Two-sample Mann-Whitney U (rank-sum) test with a tie-corrected normal
/// approximation. Robust to timing outliers.
pub const RankResult = rank.RankResult;
pub const mannWhitneyU = rank.mannWhitneyU;

/// Population standard deviation.
pub fn stddev(comptime T: type, values: []const T) f64 {
    assertNonEmpty(values);
    var count: usize = 0;
    var running_mean: f64 = 0;
    var m2: f64 = 0;
    for (values) |value| {
        count += 1;
        const x = toF64(T, value);
        const delta = x - running_mean;
        running_mean += delta / @as(f64, @floatFromInt(count));
        const delta2 = x - running_mean;
        m2 += delta * delta2;
    }
    return @sqrt(m2 / @as(f64, @floatFromInt(count)));
}

pub fn mean(comptime T: type, values: []const T) f64 {
    assertNonEmpty(values);
    var sum: f64 = 0;
    for (values) |value| sum += toF64(T, value);
    return sum / @as(f64, @floatFromInt(values.len));
}

pub fn min(comptime T: type, values: []const T) T {
    assertNonEmpty(values);
    var result = values[0];
    for (values[1..]) |value| {
        if (value < result) result = value;
    }
    return result;
}

pub fn max(comptime T: type, values: []const T) T {
    assertNonEmpty(values);
    var result = values[0];
    for (values[1..]) |value| {
        if (value > result) result = value;
    }
    return result;
}

pub fn median(comptime T: type, values: []const T) f64 {
    assertNonEmpty(values);
    const sorted = sortedCopy(T, values);
    defer std.heap.page_allocator.free(sorted);
    return medianSorted(T, sorted);
}

/// Linear-interpolated percentile (the R-7 / NumPy default definition).
/// `percentile_value` must be in `[0, 100]`.
pub fn percentile(comptime T: type, values: []const T, percentile_value: f64) f64 {
    assertNonEmpty(values);
    std.debug.assert(percentile_value >= 0 and percentile_value <= 100);
    const sorted = sortedCopy(T, values);
    defer std.heap.page_allocator.free(sorted);
    return percentileSorted(T, sorted, percentile_value);
}

pub fn summarize(comptime T: type, values: []const T) Summary {
    if (values.len == 0) return .{};
    const sorted = sortedCopy(T, values);
    defer std.heap.page_allocator.free(sorted);

    var summary: Summary = .{
        .count = sorted.len,
        .min = toF64(T, sorted[0]),
        .max = toF64(T, sorted[sorted.len - 1]),
        .median = medianSorted(T, sorted),
        .p90 = percentileSorted(T, sorted, 90),
        .p99 = percentileSorted(T, sorted, 99),
    };

    var count: usize = 0;
    var running_mean: f64 = 0;
    var m2: f64 = 0;
    for (sorted) |value| {
        count += 1;
        const x = toF64(T, value);
        const delta = x - running_mean;
        running_mean += delta / @as(f64, @floatFromInt(count));
        const delta2 = x - running_mean;
        m2 += delta * delta2;
    }
    summary.mean = running_mean;
    summary.stddev = @sqrt(m2 / @as(f64, @floatFromInt(count)));
    return summary;
}

pub const RobustComparison = struct {
    a: Summary,
    b: Summary,

    /// Ratio of `b` to `a` (for example, candidate/baseline latency).
    pub fn ratio(self: RobustComparison) f64 {
        return safeDiv(self.b.median, self.a.median);
    }

    /// `a / b`, so values greater than 1 mean `b` is faster than `a`.
    pub fn speedup(self: RobustComparison) f64 {
        return safeDiv(self.a.median, self.b.median);
    }

    pub fn isImprovement(self: RobustComparison, min_ratio: f64) bool {
        return self.speedup() >= min_ratio;
    }
};

pub fn compare(comptime T: type, a: []const T, b: []const T) RobustComparison {
    return .{
        .a = summarize(T, a),
        .b = summarize(T, b),
    };
}

fn sortedCopy(comptime T: type, values: []const T) []T {
    const copy = std.heap.page_allocator.dupe(T, values) catch
        @panic("harnessz.stats: out of memory");
    std.mem.sort(T, copy, {}, std.sort.asc(T));
    return copy;
}

fn medianSorted(comptime T: type, sorted: []const T) f64 {
    const n = sorted.len;
    const mid = n / 2;
    if (n % 2 == 1) return toF64(T, sorted[mid]);
    return (toF64(T, sorted[mid - 1]) + toF64(T, sorted[mid])) / 2.0;
}

fn percentileSorted(comptime T: type, sorted: []const T, percentile_value: f64) f64 {
    if (sorted.len == 1) return toF64(T, sorted[0]);
    const position = (percentile_value / 100.0) *
        @as(f64, @floatFromInt(sorted.len - 1));
    const lower_float = @floor(position);
    const upper_float = @ceil(position);
    const lower: usize = @intFromFloat(lower_float);
    const upper: usize = @intFromFloat(upper_float);
    const fraction = position - lower_float;
    const lo = toF64(T, sorted[lower]);
    const hi = toF64(T, sorted[upper]);
    return lo + (hi - lo) * fraction;
}

fn toF64(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("stats supports integer and floating-point slices"),
    };
}

fn assertNonEmpty(values: anytype) void {
    std.debug.assert(values.len > 0);
}

fn safeDiv(numerator: f64, denominator: f64) f64 {
    if (denominator == 0) {
        if (numerator == 0) return 0;
        return if (numerator > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    return numerator / denominator;
}

test "median odd and even" {
    const odd = [_]f64{ 3, 1, 2 };
    const even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2), median(f64, &odd));
    try std.testing.expectEqual(@as(f64, 2.5), median(f64, &even));
}

test "percentile interpolation" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(f64, 1), percentile(f64, &values, 0));
    try std.testing.expectEqual(@as(f64, 5), percentile(f64, &values, 100));
    try std.testing.expectEqual(@as(f64, 3), percentile(f64, &values, 50));
    try std.testing.expectEqual(@as(f64, 4.8), percentile(f64, &values, 95));
}

test "mean, stddev, min, max" {
    const values = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    try std.testing.expectEqual(@as(f64, 5), mean(f64, &values));
    try std.testing.expectEqual(@as(f64, 2), stddev(f64, &values));
    try std.testing.expectEqual(@as(f64, 2), min(f64, &values));
    try std.testing.expectEqual(@as(f64, 9), max(f64, &values));
}

test "u64 samples" {
    const values = [_]u64{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(f64, 25), median(u64, &values));
    try std.testing.expectEqual(@as(f64, 25), mean(u64, &values));
    try std.testing.expectEqual(@as(u64, 10), min(u64, &values));
    try std.testing.expectEqual(@as(u64, 40), max(u64, &values));
}

test "summarize reports a consistent summary" {
    const values = [_]u64{ 5, 1, 3, 2, 4 };
    const summary = summarize(u64, &values);
    try std.testing.expectEqual(@as(usize, 5), summary.count);
    try std.testing.expectEqual(@as(f64, 1), summary.min);
    try std.testing.expectEqual(@as(f64, 5), summary.max);
    try std.testing.expectEqual(@as(f64, 3), summary.median);
    try std.testing.expectEqual(@as(f64, 3), summary.mean);
    try std.testing.expectEqual(@as(f64, 4.6), summary.p90);
    try std.testing.expectEqual(@as(f64, 4.96), summary.p99);
}

test "empty summary is zeroed" {
    const values = [_]f64{};
    const summary = summarize(f64, &values);
    try std.testing.expectEqual(@as(usize, 0), summary.count);
    try std.testing.expectEqual(@as(f64, 0), summary.median);
}

test "robust comparison speedup and improvement" {
    const baseline = [_]u64{ 100, 100, 100 };
    const faster = [_]u64{ 50, 50, 50 };
    const comparison = compare(u64, &baseline, &faster);
    try std.testing.expectEqual(@as(f64, 2), comparison.speedup());
    try std.testing.expect(comparison.isImprovement(1.5));
    try std.testing.expect(!comparison.isImprovement(2.5));
    try std.testing.expectEqual(@as(f64, 0.5), comparison.ratio());
}

test {
    // Force analysis of the submodules so their tests are included in the
    // package test run.
    std.testing.refAllDecls(streaming);
    std.testing.refAllDecls(welch);
    std.testing.refAllDecls(rank);
}

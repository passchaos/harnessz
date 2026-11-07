//! Streaming and distribution statistics that complement the batch helpers in
//! `stats.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Summary = @import("summary.zig").Summary;
const welch = @import("welch.zig");

/// Online mean/variance accumulator using Welford's algorithm. `variance`
/// is the population variance. Median and percentile fields in `summary` are
/// zero because a streaming accumulator does not retain the samples.
pub const Accumulator = struct {
    samples: usize = 0,
    running_mean: f64 = 0,
    m2: f64 = 0,
    min_value: f64 = std.math.inf(f64),
    max_value: f64 = -std.math.inf(f64),

    pub fn init() Accumulator {
        return .{};
    }

    pub fn add(self: *Accumulator, value: anytype) void {
        const x = numberToF64(value);
        self.samples += 1;

        const delta = x - self.running_mean;
        self.running_mean += delta / @as(f64, @floatFromInt(self.samples));
        const delta2 = x - self.running_mean;
        self.m2 += delta * delta2;

        if (x < self.min_value) self.min_value = x;
        if (x > self.max_value) self.max_value = x;
    }

    pub fn count(self: Accumulator) usize {
        return self.samples;
    }

    pub fn mean(self: Accumulator) f64 {
        return if (self.samples == 0) 0 else self.running_mean;
    }

    /// Population variance (divide by `count`, not `count - 1`).
    pub fn variance(self: Accumulator) f64 {
        if (self.samples == 0) return 0;
        return self.m2 / @as(f64, @floatFromInt(self.samples));
    }

    pub fn min(self: Accumulator) f64 {
        return if (self.samples == 0) 0 else self.min_value;
    }

    pub fn max(self: Accumulator) f64 {
        return if (self.samples == 0) 0 else self.max_value;
    }

    pub fn summary(self: Accumulator) Summary {
        return .{
            .count = self.samples,
            .min = self.min(),
            .max = self.max(),
            .mean = self.mean(),
            .stddev = @sqrt(self.variance()),
        };
    }
};

pub const Bucket = struct {
    lower: f64,
    upper: f64,
    count: u64,
};

/// Linear histogram over `[min, max]`. The last bucket includes the maximum.
/// Values must be finite. Equal values collapse to a zero-width first bucket.
pub const Histogram = struct {
    allocator: Allocator,
    min: f64,
    max: f64,
    width: f64,
    counts: []u64,

    pub fn build(
        alloc: Allocator,
        values: []const f64,
        bucket_count: usize,
    ) !Histogram {
        if (bucket_count == 0 or values.len == 0) return error.InvalidOptions;

        var min_value = values[0];
        var max_value = values[0];
        for (values) |value| {
            if (!std.math.isFinite(value)) return error.InvalidValue;
            if (value < min_value) min_value = value;
            if (value > max_value) max_value = value;
        }

        const counts = try alloc.alloc(u64, bucket_count);
        errdefer alloc.free(counts);
        @memset(counts, 0);

        const width = if (max_value == min_value)
            0
        else
            (max_value - min_value) / @as(f64, @floatFromInt(bucket_count));
        // Finite endpoints can still produce an infinite width when the
        // subtraction overflows. Reject that instead of emitting invalid JSON.
        if (!std.math.isFinite(width)) return error.InvalidValue;

        for (values) |value| {
            const index = bucketIndex(min_value, width, bucket_count, value);
            counts[index] += 1;
        }

        return .{
            .allocator = alloc,
            .min = min_value,
            .max = max_value,
            .width = width,
            .counts = counts,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
        self.* = undefined;
    }

    pub fn bucketCount(self: Histogram) usize {
        return self.counts.len;
    }

    pub fn total(self: Histogram) u64 {
        var result: u64 = 0;
        for (self.counts) |count| result += count;
        return result;
    }

    pub fn bucket(self: Histogram, index: usize) Bucket {
        std.debug.assert(index < self.counts.len);
        const lower = self.min + self.width * @as(f64, @floatFromInt(index));
        const upper = if (index + 1 == self.counts.len)
            self.max
        else
            self.min + self.width * @as(f64, @floatFromInt(index + 1));
        return .{
            .lower = lower,
            .upper = upper,
            .count = self.counts[index],
        };
    }

    pub fn writeJson(self: Histogram, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"min\":");
        try std.json.Stringify.value(self.min, .{}, writer);
        try writer.writeAll(",\"max\":");
        try std.json.Stringify.value(self.max, .{}, writer);
        try writer.print(",\"bucket_count\":{d},\"width\":", .{self.counts.len});
        try std.json.Stringify.value(self.width, .{}, writer);
        try writer.writeAll(",\"buckets\":[");
        for (self.counts, 0..) |_, index| {
            if (index != 0) try writer.writeByte(',');
            const entry = self.bucket(index);
            try writer.writeAll("{\"lower\":");
            try std.json.Stringify.value(entry.lower, .{}, writer);
            try writer.writeAll(",\"upper\":");
            try std.json.Stringify.value(entry.upper, .{}, writer);
            try writer.print(",\"count\":{d}}}", .{entry.count});
        }
        try writer.writeAll("]}");
    }

    pub fn toJson(self: Histogram, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};

fn bucketIndex(min: f64, width: f64, bucket_count: usize, value: f64) usize {
    if (width == 0) return 0;
    const position = (value - min) / width;
    const last = @as(f64, @floatFromInt(bucket_count - 1));
    const clamped = @min(@max(position, 0), last);
    return @intFromFloat(@floor(clamped));
}

pub const ConfidenceInterval = struct {
    lower: f64,
    upper: f64,
    margin: f64,
};

/// Normal-approximation confidence interval for the mean:
/// `mean +/- z * stddev / sqrt(n)`.
///
/// Assumption: samples are independent and identically distributed enough for
/// the central limit theorem to apply. This is an approximation, especially
/// for small samples or heavy-tailed benchmark data; it is not an exact
/// Student-t interval.
pub fn confidenceIntervalMean(values: []const f64, z: f64) ConfidenceInterval {
    std.debug.assert(values.len > 0);
    std.debug.assert(std.math.isFinite(z) and z >= 0);

    const n = @as(f64, @floatFromInt(values.len));
    const sample_mean = meanOf(values);
    const sd = stddevOf(values);
    const margin = z * sd / @sqrt(n);
    return .{
        .lower = sample_mean - margin,
        .upper = sample_mean + margin,
        .margin = margin,
    };
}

/// Student-t confidence interval for the mean using `n - 1` degrees of
/// freedom. Requires at least two values and a confidence in `(0, 1)`.
pub fn confidenceIntervalMeanT(
    values: []const f64,
    confidence: f64,
) !ConfidenceInterval {
    if (values.len < 2) return error.InvalidOptions;
    const degrees_of_freedom: f64 = @floatFromInt(values.len - 1);
    const critical = try welch.studentTCritical(degrees_of_freedom, confidence);
    return confidenceIntervalMean(values, critical);
}

/// Mean after discarding `floor(len * trim_fraction)` values from each end.
/// `trim_fraction` must be in `[0, 0.5)`.
pub fn trimmedMean(values: []const f64, trim_fraction: f64) f64 {
    std.debug.assert(values.len > 0);
    std.debug.assert(trim_fraction >= 0 and trim_fraction < 0.5);

    const sorted = sortedCopy(values);
    defer std.heap.page_allocator.free(sorted);

    const trim_count: usize = @intFromFloat(@floor(
        @as(f64, @floatFromInt(values.len)) * trim_fraction,
    ));
    const start = trim_count;
    const end = values.len - trim_count;
    if (start >= end) return sorted[values.len / 2];

    var sum: f64 = 0;
    for (sorted[start..end]) |value| sum += value;
    return sum / @as(f64, @floatFromInt(end - start));
}

fn numberToF64(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("expected an integer or float"),
    };
}

fn meanOf(values: []const f64) f64 {
    var sum: f64 = 0;
    for (values) |value| sum += value;
    return sum / @as(f64, @floatFromInt(values.len));
}

fn stddevOf(values: []const f64) f64 {
    var count: usize = 0;
    var running_mean: f64 = 0;
    var m2: f64 = 0;
    for (values) |value| {
        count += 1;
        const delta = value - running_mean;
        running_mean += delta / @as(f64, @floatFromInt(count));
        const delta2 = value - running_mean;
        m2 += delta * delta2;
    }
    return @sqrt(m2 / @as(f64, @floatFromInt(count)));
}

fn sortedCopy(values: []const f64) []f64 {
    const copy = std.heap.page_allocator.dupe(f64, values) catch
        @panic("harnessz.stats: out of memory");
    std.mem.sort(f64, copy, {}, std.sort.asc(f64));
    return copy;
}

test "accumulator: Welford mean and variance" {
    var accumulator: Accumulator = .init();
    const values = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    for (values) |value| accumulator.add(value);

    try std.testing.expectEqual(@as(usize, 8), accumulator.count());
    try std.testing.expectEqual(@as(f64, 5), accumulator.mean());
    try std.testing.expectEqual(@as(f64, 4), accumulator.variance());
    try std.testing.expectEqual(@as(f64, 2), accumulator.min());
    try std.testing.expectEqual(@as(f64, 9), accumulator.max());

    const summary = accumulator.summary();
    try std.testing.expectEqual(@as(usize, 8), summary.count);
    try std.testing.expectEqual(@as(f64, 5), summary.mean);
    try std.testing.expectEqual(@as(f64, 2), summary.stddev);
    try std.testing.expectEqual(@as(f64, 2), summary.min);
    try std.testing.expectEqual(@as(f64, 9), summary.max);
    try std.testing.expectEqual(@as(f64, 0), summary.median);
}

test "accumulator: integers and empty state" {
    var accumulator: Accumulator = .init();
    accumulator.add(@as(u64, 10));
    accumulator.add(@as(i32, -2));
    accumulator.add(@as(f32, 4.0));

    try std.testing.expectEqual(@as(usize, 3), accumulator.count());
    try std.testing.expectEqual(@as(f64, 4), accumulator.mean());
    try std.testing.expectEqual(@as(f64, -2), accumulator.min());
    try std.testing.expectEqual(@as(f64, 10), accumulator.max());

    const empty: Accumulator = .init();
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    try std.testing.expectEqual(@as(f64, 0), empty.mean());
    try std.testing.expectEqual(@as(f64, 0), empty.variance());
    try std.testing.expectEqual(@as(f64, 0), empty.min());
    try std.testing.expectEqual(@as(f64, 0), empty.max());
    try std.testing.expectEqual(@as(usize, 0), empty.summary().count);
}

test "histogram: linear buckets and totals" {
    const alloc = std.testing.allocator;
    const values = [_]f64{ 0, 1, 2, 3 };
    var histogram = try Histogram.build(alloc, &values, 2);
    defer histogram.deinit();

    try std.testing.expectEqual(@as(usize, 2), histogram.bucketCount());
    try std.testing.expectEqual(@as(u64, 4), histogram.total());
    try std.testing.expectEqual(@as(f64, 0), histogram.min);
    try std.testing.expectEqual(@as(f64, 3), histogram.max);
    try std.testing.expectEqual(@as(f64, 1.5), histogram.width);
    try std.testing.expectEqualSlices(u64, &.{ 2, 2 }, histogram.counts);

    const first = histogram.bucket(0);
    try std.testing.expectEqual(@as(f64, 0), first.lower);
    try std.testing.expectEqual(@as(f64, 1.5), first.upper);
    try std.testing.expectEqual(@as(u64, 2), first.count);

    const last = histogram.bucket(1);
    try std.testing.expectEqual(@as(f64, 3), last.upper);
    try std.testing.expectEqual(@as(u64, 2), last.count);
}

test "histogram: equal values and maximum inclusion" {
    const alloc = std.testing.allocator;

    const equal = [_]f64{ 5, 5, 5 };
    var flat = try Histogram.build(alloc, &equal, 3);
    defer flat.deinit();
    try std.testing.expectEqual(@as(f64, 0), flat.width);
    try std.testing.expectEqualSlices(u64, &.{ 3, 0, 0 }, flat.counts);

    const boundary = [_]f64{ 0, 5, 10 };
    var histogram = try Histogram.build(alloc, &boundary, 2);
    defer histogram.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, histogram.counts);
}

test "histogram: JSON and invalid inputs" {
    const alloc = std.testing.allocator;
    const values = [_]f64{ 0, 1, 2, 3 };
    var histogram = try Histogram.build(alloc, &values, 2);
    defer histogram.deinit();

    const json = try histogram.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"bucket_count\":2") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"count\":2") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"width\":1.5") != null);

    try std.testing.expectError(error.InvalidOptions, Histogram.build(alloc, &values, 0));
    const empty = [_]f64{};
    try std.testing.expectError(error.InvalidOptions, Histogram.build(alloc, &empty, 2));
    const non_finite = [_]f64{ 0, std.math.inf(f64) };
    try std.testing.expectError(error.InvalidValue, Histogram.build(alloc, &non_finite, 2));

    // Finite endpoints whose difference overflows must not produce an
    // infinite bucket width (and therefore invalid JSON).
    const extreme = [_]f64{ -1.7e308, 1.7e308 };
    try std.testing.expectError(error.InvalidValue, Histogram.build(alloc, &extreme, 2));
}

test "confidence interval: normal approximation" {
    const identical = [_]f64{ 10, 10, 10, 10 };
    const zero_margin = confidenceIntervalMean(&identical, 1.96);
    try std.testing.expectEqual(@as(f64, 10), zero_margin.lower);
    try std.testing.expectEqual(@as(f64, 10), zero_margin.upper);
    try std.testing.expectEqual(@as(f64, 0), zero_margin.margin);

    const values = [_]f64{ 1, 2, 3, 4, 5 };
    const interval = confidenceIntervalMean(&values, 1.96);
    const expected_margin = 1.96 * @sqrt(@as(f64, 2)) / @sqrt(@as(f64, 5));
    try std.testing.expectApproxEqAbs(expected_margin, interval.margin, 1e-12);
    try std.testing.expectApproxEqAbs(3 - expected_margin, interval.lower, 1e-12);
    try std.testing.expectApproxEqAbs(3 + expected_margin, interval.upper, 1e-12);

    const single = [_]f64{42};
    const single_interval = confidenceIntervalMean(&single, 1.96);
    try std.testing.expectEqual(@as(f64, 0), single_interval.margin);
    try std.testing.expectEqual(@as(f64, 42), single_interval.lower);
}

test "confidence interval: Student-t" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    const interval = try confidenceIntervalMeanT(&values, 0.95);
    const expected_margin =
        2.7764451051977987 * @sqrt(@as(f64, 2)) / @sqrt(@as(f64, 5));
    try std.testing.expectApproxEqAbs(expected_margin, interval.margin, 1e-9);
    try std.testing.expectApproxEqAbs(3 - expected_margin, interval.lower, 1e-9);
    try std.testing.expectApproxEqAbs(3 + expected_margin, interval.upper, 1e-9);

    const single = [_]f64{42};
    try std.testing.expectError(
        error.InvalidOptions,
        confidenceIntervalMeanT(&single, 0.95),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        confidenceIntervalMeanT(&values, 1.0),
    );
}

test "trimmed mean: symmetric trimming" {
    const values = [_]f64{ 10, 1, 9, 2, 8, 3, 7, 4, 6, 5 };
    try std.testing.expectEqual(@as(f64, 5.5), trimmedMean(&values, 0));
    try std.testing.expectEqual(@as(f64, 5.5), trimmedMean(&values, 0.2));

    const skewed = [_]f64{ 1, 2, 100, 101 };
    try std.testing.expectEqual(@as(f64, 51), trimmedMean(&skewed, 0.25));
    try std.testing.expectEqual(@as(f64, 51), trimmedMean(&skewed, 0.1));
}

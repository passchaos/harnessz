//! Two-sample Mann-Whitney U test (Wilcoxon rank-sum) with a tie-corrected
//! normal approximation.
//!
//! Unlike Welch's t-test, ranks are insensitive to timing outliers such as a
//! scheduler hiccup inflating one sample. Benchmarks should still prefer
//! Welch when samples are clean, but the rank test is a useful robustness
//! check on noisy hosts.

const std = @import("std");
const welch = @import("welch.zig");

pub const RankResult = struct {
    /// U statistic for sample `a`. Values near zero mean `a` is mostly below
    /// `b`; the maximum is `a.len * b.len`.
    u: f64,
    /// Continuity-corrected normal-approximation z score. Negative values
    /// mean `a` tends to be smaller than `b`.
    z: f64,
    /// Two-sided p-value from the normal approximation.
    p_approx: f64,
    /// Number of tied value groups (diagnostic).
    tie_groups: usize,
};

/// Two-sided Mann-Whitney U test. Requires at least two samples per side;
/// shorter inputs return `error.InvalidOptions`.
pub fn mannWhitneyU(comptime T: type, a: []const T, b: []const T) !RankResult {
    if (a.len < 2 or b.len < 2) return error.InvalidOptions;

    const total = a.len + b.len;
    const entries = try std.heap.page_allocator.alloc(Entry, total);
    defer std.heap.page_allocator.free(entries);

    for (a, 0..) |value, index| {
        entries[index] = .{ .value = toF64(T, value), .in_a = true };
    }
    for (b, 0..) |value, index| {
        entries[a.len + index] = .{ .value = toF64(T, value), .in_a = false };
    }
    std.mem.sort(Entry, entries, {}, entryLessThan);

    const n: f64 = @floatFromInt(a.len);
    const m: f64 = @floatFromInt(b.len);
    const total_f: f64 = @floatFromInt(total);

    var rank_sum_a: f64 = 0;
    var tie_sum: f64 = 0;
    var tie_groups: usize = 0;

    var index: usize = 0;
    while (index < total) {
        var end = index + 1;
        while (end < total and entries[end].value == entries[index].value) {
            end += 1;
        }
        // Ranks are one-based; tied values share the average rank.
        const average_rank =
            (@as(f64, @floatFromInt(index + 1)) +
                @as(f64, @floatFromInt(end))) / 2.0;
        for (entries[index..end]) |entry| {
            if (entry.in_a) rank_sum_a += average_rank;
        }
        const count = end - index;
        if (count > 1) {
            const count_f: f64 = @floatFromInt(count);
            tie_sum += count_f * count_f * count_f - count_f;
            tie_groups += 1;
        }
        index = end;
    }

    const u = rank_sum_a - n * (n + 1.0) / 2.0;
    const mean_u = n * m / 2.0;

    const tie_denominator = total_f * (total_f - 1.0);
    const tie_correction = if (tie_denominator > 0)
        tie_sum / tie_denominator
    else
        0;
    const variance = n * m / 12.0 * (total_f + 1.0 - tie_correction);
    if (variance <= 0) {
        // Every value is tied, so the two distributions are identical.
        return .{ .u = u, .z = 0, .p_approx = 1, .tie_groups = tie_groups };
    }

    const difference = u - mean_u;
    const corrected = if (difference > 0)
        difference - 0.5
    else if (difference < 0)
        difference + 0.5
    else
        0;
    const z = corrected / @sqrt(variance);

    return .{
        .u = u,
        .z = z,
        .p_approx = welch.twoSidedNormalPValue(z),
        .tie_groups = tie_groups,
    };
}

const Entry = struct {
    value: f64,
    in_a: bool,
};

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    return left.value < right.value;
}

fn toF64(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("rank statistics support integer and floating-point slices"),
    };
}

test "rank: complete separation has U zero" {
    const a = [_]u64{ 1, 2, 3 };
    const b = [_]u64{ 4, 5, 6 };
    const result = try mannWhitneyU(u64, &a, &b);
    try std.testing.expectEqual(@as(f64, 0), result.u);
    try std.testing.expect(result.z < 0);
    try std.testing.expect(result.p_approx < 0.1);
}

test "rank: swapping samples mirrors U and z" {
    const a = [_]u64{ 1, 4, 6, 9 };
    const b = [_]u64{ 2, 3, 7, 8 };
    const forward = try mannWhitneyU(u64, &a, &b);
    const reverse = try mannWhitneyU(u64, &b, &a);
    try std.testing.expectEqual(@as(f64, 16), forward.u + reverse.u);
    try std.testing.expectApproxEqAbs(forward.z, -reverse.z, 1e-12);
    try std.testing.expectApproxEqAbs(forward.p_approx, reverse.p_approx, 1e-12);
}

test "rank: identical distributions are not significant" {
    const a = [_]u64{ 1, 2, 3, 4 };
    const b = [_]u64{ 1, 2, 3, 4 };
    const result = try mannWhitneyU(u64, &a, &b);
    try std.testing.expectEqual(@as(f64, 1), result.p_approx);
    try std.testing.expectEqual(@as(f64, 0), result.z);
}

test "rank: ties are corrected and reported" {
    const a = [_]u64{ 1, 1, 2, 2 };
    const b = [_]u64{ 2, 2, 3, 3 };
    const result = try mannWhitneyU(u64, &a, &b);
    try std.testing.expect(result.tie_groups >= 1);
    try std.testing.expect(result.p_approx > 0.05);
}

test "rank: rejects fewer than two samples per side" {
    const one = [_]u64{1};
    const two = [_]u64{ 1, 2 };
    try std.testing.expectError(error.InvalidOptions, mannWhitneyU(u64, &one, &two));
    try std.testing.expectError(error.InvalidOptions, mannWhitneyU(u64, &two, &one));
    const empty = [_]u64{};
    try std.testing.expectError(error.InvalidOptions, mannWhitneyU(u64, &empty, &two));
}

test "rank: outlier does not hide a real separation" {
    const a = [_]u64{ 100, 101, 99, 100, 100 };
    const b = [_]u64{ 110, 111, 109, 110, 1000 };
    const rank_result = try mannWhitneyU(u64, &a, &b);
    try std.testing.expect(rank_result.p_approx < 0.05);

    // Welch's variance is dominated by the outlier, so it fails to separate
    // the same samples. This is the robustness the rank test adds.
    const welch_result = try welch.welchTTest(u64, &a, &b);
    try std.testing.expect(welch_result.p_approx > 0.05);
}

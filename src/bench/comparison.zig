//! Benchmark comparison values and gate logic.
//!
//! `Comparison` is built from already-collected samples so gate behaviour is
//! testable without a timer. It carries both a Welch t-test p-value and a
//! tie-corrected Mann-Whitney U p-value: the former is sensitive to outliers,
//! the latter trades some power for robustness on noisy hosts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stats = @import("../stats.zig");
const num = @import("../num.zig");

pub const GateResult = struct {
    passed: bool,
    speedup: f64,
    min_ratio: f64,
};

pub const Comparison = struct {
    a: stats.Summary,
    b: stats.Summary,
    rounds: usize,
    /// Two-sided Welch t-test p-value using the exact Student-t tail. Values
    /// at or below `significance_alpha` set `significant`.
    p_value: f64 = 1,
    /// `p_value <= significance_alpha`.
    significant: bool = false,
    /// Two-sided Mann-Whitney U p-value (tie-corrected normal approximation).
    /// Unlike `p_value`, ranks are not dominated by timing outliers.
    robust_p_value: f64 = 1,
    /// `robust_p_value <= significance_alpha`.
    robust_significant: bool = false,

    /// Conventional alpha used for the `significant` convenience flag.
    pub const significance_alpha: f64 = 0.05;

    /// Build a comparison from already-collected samples. This makes gate
    /// logic testable without running a timer.
    ///
    /// Welch's test and the rank test need at least two samples per side.
    /// When either side is shorter, both p-values are 1 and neither
    /// significance flag is set.
    pub fn fromSamples(a_samples: []const u64, b_samples: []const u64) Comparison {
        const welch_result = stats.welchTTest(u64, a_samples, b_samples) catch
            stats.WelchResult{ .t = 0, .degrees_of_freedom = 0, .p_value = 1 };
        const rank_result = stats.mannWhitneyU(u64, a_samples, b_samples) catch
            stats.RankResult{ .u = 0, .z = 0, .p_approx = 1, .tie_groups = 0 };
        return .{
            .a = stats.summarize(u64, a_samples),
            .b = stats.summarize(u64, b_samples),
            .rounds = @min(a_samples.len, b_samples.len),
            .p_value = welch_result.p_value,
            .significant = welch_result.p_value <= significance_alpha,
            .robust_p_value = rank_result.p_approx,
            .robust_significant = rank_result.p_approx <= significance_alpha,
        };
    }

    /// `a.median / b.median`; values above 1 mean `b` is faster.
    pub fn speedup(self: Comparison) f64 {
        return num.safeDiv(self.a.median, self.b.median);
    }

    pub fn gate(self: Comparison, min_ratio: f64) bool {
        return self.speedup() >= min_ratio;
    }

    pub fn gateResult(self: Comparison, min_ratio: f64) GateResult {
        return .{
            .passed = self.gate(min_ratio),
            .speedup = self.speedup(),
            .min_ratio = min_ratio,
        };
    }

    /// Pass when the speedup ratio reaches `min_ratio`, the Welch p-value is
    /// at most `max_p_value`, and the comparison is significant at the
    /// conventional 0.05 level. `max_p_value` must be finite and in `[0, 1]`;
    /// invalid thresholds fail the gate.
    pub fn gateSignificant(self: Comparison, min_ratio: f64, max_p_value: f64) bool {
        if (!std.math.isFinite(max_p_value) or max_p_value < 0 or max_p_value > 1) {
            return false;
        }
        return self.gate(min_ratio) and
            self.significant and
            self.p_value <= max_p_value;
    }

    /// Like `gateSignificant`, but uses the outlier-robust Mann-Whitney
    /// p-value instead of Welch's. `max_p_value` must be finite and in
    /// `[0, 1]`; invalid thresholds fail the gate.
    pub fn gateRobust(self: Comparison, min_ratio: f64, max_p_value: f64) bool {
        if (!std.math.isFinite(max_p_value) or max_p_value < 0 or max_p_value > 1) {
            return false;
        }
        return self.gate(min_ratio) and
            self.robust_significant and
            self.robust_p_value <= max_p_value;
    }

    pub fn writeJson(self: Comparison, writer: *std.Io.Writer) !void {
        const Wire = struct {
            rounds: usize,
            /// `null` when the speedup is not finite (for example, a zero
            /// candidate median). JSON has no representation for infinity.
            speedup: ?f64,
            p_value: f64,
            significant: bool,
            robust_p_value: f64,
            robust_significant: bool,
            a: stats.Summary,
            b: stats.Summary,
        };
        try std.json.Stringify.value(Wire{
            .rounds = self.rounds,
            .speedup = num.finiteOptional(self.speedup()),
            .p_value = self.p_value,
            .significant = self.significant,
            .robust_p_value = self.robust_p_value,
            .robust_significant = self.robust_significant,
            .a = self.a,
            .b = self.b,
        }, .{
            .whitespace = .indent_2,
            // `speedup` is the only optional field, so emitting nulls keeps
            // the key present and the document valid JSON.
            .emit_null_optional_fields = true,
        }, writer);
    }

    pub fn toJson(self: Comparison, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeCsv(self: Comparison, writer: *std.Io.Writer) !void {
        try writer.writeAll("metric,a,b\n");
        try writer.print("rounds,{d},{d}\n", .{ self.rounds, self.rounds });
        try writeSummaryPairCsv(writer, self.a, self.b);
        try writer.print("speedup,{d},{d}\n", .{ self.speedup(), self.speedup() });
        try writer.print("p_value,{d},{d}\n", .{ self.p_value, self.p_value });
        try writer.print("significant,{d},{d}\n", .{
            @intFromBool(self.significant),
            @intFromBool(self.significant),
        });
        try writer.print("robust_p_value,{d},{d}\n", .{
            self.robust_p_value,
            self.robust_p_value,
        });
        try writer.print("robust_significant,{d},{d}\n", .{
            @intFromBool(self.robust_significant),
            @intFromBool(self.robust_significant),
        });
    }

    pub fn toCsv(self: Comparison, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeCsv(&out.writer);
        return out.toOwnedSlice();
    }
};

fn writeSummaryPairCsv(writer: *std.Io.Writer, a: stats.Summary, b: stats.Summary) !void {
    try writer.print("min_ns,{d},{d}\n", .{ a.min, b.min });
    try writer.print("max_ns,{d},{d}\n", .{ a.max, b.max });
    try writer.print("mean_ns,{d},{d}\n", .{ a.mean, b.mean });
    try writer.print("stddev_ns,{d},{d}\n", .{ a.stddev, b.stddev });
    try writer.print("median_ns,{d},{d}\n", .{ a.median, b.median });
    try writer.print("p90_ns,{d},{d}\n", .{ a.p90, b.p90 });
    try writer.print("p99_ns,{d},{d}\n", .{ a.p99, b.p99 });
}

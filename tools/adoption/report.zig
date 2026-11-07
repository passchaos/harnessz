//! Text and JSON rendering for the adoption evidence tool.

const std = @import("std");
const Config = @import("config.zig").Config;
const scenario_mod = @import("scenario.zig");

const Allocator = std.mem.Allocator;
const ScenarioResult = scenario_mod.ScenarioResult;
const OrderingResult = scenario_mod.OrderingResult;
const OverheadResult = scenario_mod.OverheadResult;

pub fn writeTextReport(
    writer: *std.Io.Writer,
    config: Config,
    false_positive: ScenarioResult,
    detect_10pct: ScenarioResult,
    detect_20pct: ScenarioResult,
    ordering: OrderingResult,
    overhead: OverheadResult,
) !void {
    try writer.writeAll("harnessz adoption comparison\n");
    try writer.print(
        "trials={d} samples={d} iterations={d} warmup={d} jitter={d}%\n\n",
        .{
            config.trials,
            config.samples,
            config.iterations,
            config.warmup,
            config.jitter_percent,
        },
    );

    try writer.writeAll(
        "scenario\tmethod\ttrials\tflagged\trate\tratio_pass\trobust_sig\tmedian_ratio\tp10\tp90\trobust_median_p\n",
    );
    try writeScenarioRow(writer, false_positive, "internal", false_positive.internal_flagged, false_positive.internal_flagged, 0, false_positive.internal_ratio_median, 0, 0, 0);
    try writeScenarioRow(writer, false_positive, "harnessz", false_positive.harness_flagged, false_positive.harness_ratio_passes, false_positive.harness_robust_significant, false_positive.harness_ratio_median, false_positive.harness_ratio_p10, false_positive.harness_ratio_p90, false_positive.harness_robust_p_median);
    try writeScenarioRow(writer, detect_10pct, "internal", detect_10pct.internal_flagged, detect_10pct.internal_flagged, 0, detect_10pct.internal_ratio_median, 0, 0, 0);
    try writeScenarioRow(writer, detect_10pct, "harnessz", detect_10pct.harness_flagged, detect_10pct.harness_ratio_passes, detect_10pct.harness_robust_significant, detect_10pct.harness_ratio_median, detect_10pct.harness_ratio_p10, detect_10pct.harness_ratio_p90, detect_10pct.harness_robust_p_median);
    try writeScenarioRow(writer, detect_20pct, "internal", detect_20pct.internal_flagged, detect_20pct.internal_flagged, 0, detect_20pct.internal_ratio_median, 0, 0, 0);
    try writeScenarioRow(writer, detect_20pct, "harnessz", detect_20pct.harness_flagged, detect_20pct.harness_ratio_passes, detect_20pct.harness_robust_significant, detect_20pct.harness_ratio_median, detect_20pct.harness_ratio_p10, detect_20pct.harness_ratio_p90, detect_20pct.harness_robust_p_median);

    try writer.writeAll("\nordering bias (true slow/fast ratio = 2.000)\n");
    try writer.print(
        "sequential: ratio={d:.3} error={d:.1}%\nrotating:   ratio={d:.3} error={d:.1}%\n",
        .{
            ordering.sequential_ratio,
            ordering.sequential_error * 100,
            ordering.rotating_ratio,
            ordering.rotating_error * 100,
        },
    );

    try writer.writeAll("\nper-call overhead\n");
    try writer.print(
        "empty: internal={d:.2} ns harnessz={d:.2} ns\nsmall: internal={d:.2} ns harnessz={d:.2} ns\n",
        .{
            overhead.empty_internal_ns,
            overhead.empty_harness_ns,
            overhead.small_internal_ns,
            overhead.small_harness_ns,
        },
    );
}

fn writeScenarioRow(
    writer: *std.Io.Writer,
    scenario: ScenarioResult,
    method: []const u8,
    flagged: usize,
    ratio_passes: usize,
    significant: usize,
    median_ratio: f64,
    ratio_p10: f64,
    ratio_p90: f64,
    median_p: f64,
) !void {
    const rate = if (scenario.trials == 0)
        0.0
    else
        @as(f64, @floatFromInt(flagged)) / @as(f64, @floatFromInt(scenario.trials));
    try writer.print("{s}\t{s}\t{d}\t{d}\t{d:.1}%\t{d}\t{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.4}\n", .{
        scenario.name,
        method,
        scenario.trials,
        flagged,
        rate * 100,
        ratio_passes,
        significant,
        median_ratio,
        ratio_p10,
        ratio_p90,
        median_p,
    });
}

const ScenarioWire = struct {
    name: []const u8,
    trials: usize,
    internal_flagged: usize,
    harness_flagged: usize,
    harness_ratio_passes: usize,
    harness_robust_significant: usize,
    internal_ratio_median: f64,
    harness_ratio_median: f64,
    harness_ratio_p10: f64,
    harness_ratio_p90: f64,
    harness_robust_p_median: f64,
};

pub fn writeJsonReport(
    alloc: Allocator,
    config: Config,
    false_positive: ScenarioResult,
    detect_10pct: ScenarioResult,
    detect_20pct: ScenarioResult,
    ordering: OrderingResult,
    overhead: OverheadResult,
) ![]u8 {
    const Wire = struct {
        config: Config,
        false_positive: ScenarioWire,
        detect_10pct: ScenarioWire,
        detect_20pct: ScenarioWire,
        ordering: OrderingResult,
        overhead: OverheadResult,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Wire{
        .config = config,
        .false_positive = scenarioWire(false_positive),
        .detect_10pct = scenarioWire(detect_10pct),
        .detect_20pct = scenarioWire(detect_20pct),
        .ordering = ordering,
        .overhead = overhead,
    }, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

fn scenarioWire(scenario: ScenarioResult) ScenarioWire {
    return .{
        .name = scenario.name,
        .trials = scenario.trials,
        .internal_flagged = scenario.internal_flagged,
        .harness_flagged = scenario.harness_flagged,
        .harness_ratio_passes = scenario.harness_ratio_passes,
        .harness_robust_significant = scenario.harness_robust_significant,
        .internal_ratio_median = scenario.internal_ratio_median,
        .harness_ratio_median = scenario.harness_ratio_median,
        .harness_ratio_p10 = scenario.harness_ratio_p10,
        .harness_ratio_p90 = scenario.harness_ratio_p90,
        .harness_robust_p_median = scenario.harness_robust_p_median,
    };
}

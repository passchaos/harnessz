//! Adoption scenarios: false positives, detection sensitivity, ordering bias,
//! and per-call overhead.

const std = @import("std");
const harnessz = @import("harnessz");
const Config = @import("config.zig").Config;
const workload_mod = @import("workload.zig");

const Allocator = std.mem.Allocator;
const bench = harnessz.bench;
const Workload = workload_mod.Workload;
const DriftState = workload_mod.DriftState;
const NoopWorkload = workload_mod.NoopWorkload;
const RunnerContext = workload_mod.RunnerContext;
const runnerCallback = workload_mod.runnerCallback;
const noopRuntime = workload_mod.noopRuntime;
const internalBlock = workload_mod.internalBlock;
const harnessBlock = workload_mod.harnessBlock;

pub const ScenarioResult = struct {
    name: []const u8,
    trials: usize,
    internal_flagged: usize,
    harness_flagged: usize,
    /// Trials where the candidate/baseline median ratio reached the 5% gate.
    harness_ratio_passes: usize,
    /// Trials where the robust (Mann-Whitney) p-value was at most 0.05.
    harness_robust_significant: usize,
    internal_ratio_median: f64,
    harness_ratio_median: f64,
    harness_ratio_p10: f64,
    harness_ratio_p90: f64,
    harness_robust_p_median: f64,
};

pub fn runScenario(
    alloc: Allocator,
    io: std.Io,
    config: Config,
    name: []const u8,
    candidate_multiplier: u64,
) !ScenarioResult {
    var internal_flags: usize = 0;
    var harness_flags: usize = 0;
    var harness_ratio_passes: usize = 0;
    var harness_robust_significant: usize = 0;
    var internal_ratios = try alloc.alloc(f64, config.trials);
    defer alloc.free(internal_ratios);
    var harness_ratios = try alloc.alloc(f64, config.trials);
    defer alloc.free(harness_ratios);
    var harness_p_values = try alloc.alloc(f64, config.trials);
    defer alloc.free(harness_p_values);

    var trial_index: usize = 0;
    while (trial_index < config.trials) : (trial_index += 1) {
        const seed = config.seed +% trial_index *% 0x9e3779b97f4a7c15;
        const base_loops: u64 = 4000;

        var baseline = Workload.init(base_loops, config.jitter_percent, null, seed);
        var candidate = Workload.init(
            base_loops * candidate_multiplier / 100,
            config.jitter_percent,
            null,
            seed +% 0x517cc1b727220a95,
        );

        baseline.reset();
        candidate.reset();
        const baseline_ns = try internalBlock(io, &baseline, config.warmup, config.iterations);
        const candidate_ns = try internalBlock(io, &candidate, config.warmup, config.iterations);
        const internal_ratio = @as(f64, @floatFromInt(candidate_ns)) /
            @as(f64, @floatFromInt(baseline_ns));

        baseline.reset();
        candidate.reset();
        var baseline_context = RunnerContext{ .workload = baseline };
        var candidate_context = RunnerContext{ .workload = candidate };
        const runners = [_]bench.NamedRunner{
            .{ .name = "baseline", .runner = .{ .context = &baseline_context, .run = runnerCallback } },
            .{ .name = "candidate", .runner = .{ .context = &candidate_context, .run = runnerCallback } },
        };
        // Interleaved A/B: drift and jitter affect both candidates equally.
        var multi = try bench.compareMany(alloc, io, .{
            .warmup_iterations = config.warmup,
            .iterations = config.samples,
            .batch_size = config.iterations,
        }, &runners);
        defer multi.deinit();

        // `a = candidate`, `b = baseline`: speedup > 1 means the candidate is
        // slower, i.e. a regression.
        const comparison = multi.comparisonOf("candidate", "baseline").?;
        const harness_flagged = comparison.gateRobust(1.05, 0.05);

        internal_ratios[trial_index] = internal_ratio;
        harness_ratios[trial_index] = comparison.speedup();
        harness_p_values[trial_index] = comparison.robust_p_value;
        if (internal_ratio > 1.05) internal_flags += 1;
        if (comparison.speedup() >= 1.05) harness_ratio_passes += 1;
        if (comparison.robust_significant and comparison.robust_p_value <= 0.05) {
            harness_robust_significant += 1;
        }
        if (harness_flagged) harness_flags += 1;
    }

    return .{
        .name = name,
        .trials = config.trials,
        .internal_flagged = internal_flags,
        .harness_flagged = harness_flags,
        .harness_ratio_passes = harness_ratio_passes,
        .harness_robust_significant = harness_robust_significant,
        .internal_ratio_median = medianOf(internal_ratios),
        .harness_ratio_median = medianOf(harness_ratios),
        .harness_ratio_p10 = percentileOf(harness_ratios, 10),
        .harness_ratio_p90 = percentileOf(harness_ratios, 90),
        .harness_robust_p_median = medianOf(harness_p_values),
    };
}

pub const OrderingResult = struct {
    true_ratio: f64,
    sequential_ratio: f64,
    rotating_ratio: f64,
    sequential_error: f64,
    rotating_error: f64,
};

pub fn runOrdering(alloc: Allocator, io: std.Io, config: Config) !OrderingResult {
    const fast_loops: u64 = 200;
    const slow_loops: u64 = 400;
    const true_ratio = 2.0;

    // Sequential: measure each candidate completely before moving on. This is
    // the style used by per-file benchmark executables and shell matrices.
    var drift: DriftState = .{};
    var fast_a = RunnerContext{ .workload = Workload.init(fast_loops, 0, &drift, 11) };
    var fast_b = RunnerContext{ .workload = Workload.init(fast_loops, 0, &drift, 23) };
    var slow = RunnerContext{ .workload = Workload.init(slow_loops, 0, &drift, 37) };

    var fast_a_stats = try bench.runRuntime(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, &fast_a, runnerCallback);
    defer fast_a_stats.deinit(alloc);
    var fast_b_stats = try bench.runRuntime(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, &fast_b, runnerCallback);
    defer fast_b_stats.deinit(alloc);
    var slow_stats = try bench.runRuntime(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, &slow, runnerCallback);
    defer slow_stats.deinit(alloc);

    const sequential = bench.Comparison.fromSamples(
        slow_stats.samples_ns,
        fast_a_stats.samples_ns,
    );

    // Rotating: harnessz visits all three candidates every round, so the
    // shared drift affects each candidate's samples equally.
    var rotating_drift: DriftState = .{};
    var rotating_fast_a = RunnerContext{
        .workload = Workload.init(fast_loops, 0, &rotating_drift, 11),
    };
    var rotating_fast_b = RunnerContext{
        .workload = Workload.init(fast_loops, 0, &rotating_drift, 23),
    };
    var rotating_slow = RunnerContext{
        .workload = Workload.init(slow_loops, 0, &rotating_drift, 37),
    };

    const runners = [_]bench.NamedRunner{
        .{ .name = "fast-a", .runner = .{ .context = &rotating_fast_a, .run = runnerCallback } },
        .{ .name = "fast-b", .runner = .{ .context = &rotating_fast_b, .run = runnerCallback } },
        .{ .name = "slow", .runner = .{ .context = &rotating_slow, .run = runnerCallback } },
    };
    var rotating = try bench.compareMany(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, &runners);
    defer rotating.deinit();

    const rotating_comparison = rotating.comparisonOf("slow", "fast-a").?;

    return .{
        .true_ratio = true_ratio,
        .sequential_ratio = sequential.speedup(),
        .rotating_ratio = rotating_comparison.speedup(),
        .sequential_error = relativeError(sequential.speedup(), true_ratio),
        .rotating_error = relativeError(rotating_comparison.speedup(), true_ratio),
    };
}

pub const OverheadResult = struct {
    empty_internal_ns: f64,
    empty_harness_ns: f64,
    small_internal_ns: f64,
    small_harness_ns: f64,
};

pub fn runOverhead(alloc: Allocator, io: std.Io, config: Config) !OverheadResult {
    var empty = NoopWorkload{};
    const empty_start = std.Io.Clock.Timestamp.now(io, .awake);
    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        bench.blackBox(try empty.run(std.heap.page_allocator, io));
    }
    const empty_internal_ns = @as(f64, @floatFromInt(
        empty_start.untilNow(io).raw.toNanoseconds(),
    )) / 1000.0;

    var empty_stats = try bench.runRuntime(alloc, io, .{
        .warmup_iterations = 10,
        .iterations = 50,
        .batch_size = 1000,
    }, &empty, noopRuntime);
    defer empty_stats.deinit(alloc);

    var small = Workload.init(400, 0, null, 71);
    const small_internal = try internalBlock(io, &small, config.warmup, 100);
    var small_stats = try harnessBlock(alloc, io, &small, config);
    defer small_stats.deinit(alloc);

    return .{
        .empty_internal_ns = empty_internal_ns,
        .empty_harness_ns = empty_stats.distribution.median,
        .small_internal_ns = @floatFromInt(small_internal),
        .small_harness_ns = small_stats.distribution.median,
    };
}

fn medianOf(values: []f64) f64 {
    const sorted = std.heap.page_allocator.dupe(f64, values) catch return 0;
    defer std.heap.page_allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    if (sorted.len == 0) return 0;
    return sorted[sorted.len / 2];
}

fn percentileOf(values: []f64, percentile: usize) f64 {
    const sorted = std.heap.page_allocator.dupe(f64, values) catch return 0;
    defer std.heap.page_allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    if (sorted.len == 0) return 0;
    const index = @min(sorted.len - 1, sorted.len * percentile / 100);
    return sorted[index];
}

fn relativeError(measured: f64, expected: f64) f64 {
    if (expected == 0) return 0;
    return @abs(measured - expected) / expected;
}

//! Adoption evidence: compares the ad-hoc benchmark style used by downstream
//! Project-Z repositories with harnessz's sampled comparisons.
//!
//! The tool is deliberately outside `zig build test`: it reports wall-clock
//! numbers, which are host- and load-dependent. Unit tests cover the
//! structural and statistical logic instead.
//!
//! Scenarios:
//! - `false_positive`: baseline and candidate do identical work, with
//!   deterministic per-call jitter. A good method should rarely flag a
//!   regression.
//! - `detect_10pct`: the candidate does 10% more work. A good method should
//!   flag it reliably.
//! - `ordering`: three implementations measured while the machine drifts
//!   (cost grows with cumulative call count). Compares sequential measurement
//!   with harnessz's rotating interleaved measurement.
//! - `overhead`: per-call cost of an empty and a small workload measured with
//!   both styles.
//!
//! The "internal" style mirrors the timing loops in zev/bench/compare.zig,
//! spectra/bench/*.zig, and iris/examples/bench.zig: warmup followed by one
//! timed block (or repeated blocks), a ratio gate, and no significance test.

const std = @import("std");
const harnessz = @import("harnessz");

const Allocator = std.mem.Allocator;
const bench = harnessz.bench;

const Config = struct {
    trials: usize = 40,
    samples: usize = 15,
    iterations: usize = 20,
    warmup: usize = 3,
    jitter_percent: u64 = 20,
    seed: u64 = 1,
};

/// Deterministic CPU work with optional multiplicative jitter and a shared
/// drift clock that models a machine slowing down as the run progresses.
const Workload = struct {
    base_loops: u64,
    jitter_percent: u64 = 0,
    drift: ?*DriftState = null,
    calls: u64 = 0,
    state: u64,

    fn init(base_loops: u64, jitter_percent: u64, drift: ?*DriftState, seed: u64) Workload {
        return .{
            .base_loops = base_loops,
            .jitter_percent = jitter_percent,
            .drift = drift,
            .state = seed | 1,
        };
    }

    fn reset(self: *Workload) void {
        self.calls = 0;
        self.state = (self.state *% 6364136223846793005 +% 1442695040888963407) | 1;
    }

    fn run(self: *Workload, _: Allocator, _: std.Io) !u64 {
        self.calls +%= 1;
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;

        var loops = self.base_loops;
        if (self.jitter_percent != 0) {
            const jitter = (self.state >> 33) % (self.jitter_percent + 1);
            loops = loops * (100 + jitter) / 100;
        }
        if (self.drift) |drift| {
            drift.progress +%= 1;
            // After 1000 calls the machine is 400% slower.
            loops = loops * (1000 + drift.progress / 2) / 1000;
        }

        var value = self.state;
        var index: u64 = 0;
        while (index < loops) : (index += 1) {
            value ^= value << 13;
            value ^= value >> 7;
            value ^= value << 17;
        }
        bench.blackBox(value);
        return value;
    }
};

const DriftState = struct {
    progress: u64 = 0,
};

const NoopWorkload = struct {
    calls: u64 = 0,

    fn run(self: *NoopWorkload, _: Allocator, _: std.Io) !u64 {
        self.calls +%= 1;
        return self.calls;
    }
};

fn runRuntime(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    const workload: *Workload = @ptrCast(@alignCast(context));
    return workload.run(alloc, io);
}

fn noopRuntime(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    const workload: *NoopWorkload = @ptrCast(@alignCast(context));
    return workload.run(alloc, io);
}

/// Downstream style: warmup calls followed by one timed block; the result is
/// the per-call average.
fn internalBlock(
    io: std.Io,
    workload: *Workload,
    warmup: usize,
    iterations: usize,
) !u64 {
    var index: usize = 0;
    while (index < warmup) : (index += 1) {
        bench.blackBox(try workload.run(std.heap.page_allocator, io));
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    index = 0;
    while (index < iterations) : (index += 1) {
        bench.blackBox(try workload.run(std.heap.page_allocator, io));
    }
    const elapsed_ns = start.untilNow(io).raw.toNanoseconds();
    if (elapsed_ns < 0) return error.ClockWentBackwards;
    return @intCast(@divTrunc(elapsed_ns, iterations));
}

/// harnessz style: warmup, then `samples` blocks of `iterations` calls each.
fn harnessBlock(
    alloc: Allocator,
    io: std.Io,
    workload: *Workload,
    config: Config,
) !bench.Stats {
    return bench.runRuntime(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, workload, runRuntime);
}

const Trial = struct {
    internal_ratio: f64,
    internal_flagged: bool,
    harness_ratio: f64,
    harness_p: f64,
    harness_flagged: bool,
};

const ScenarioResult = struct {
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

fn runScenario(
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

const OrderingResult = struct {
    true_ratio: f64,
    sequential_ratio: f64,
    rotating_ratio: f64,
    sequential_error: f64,
    rotating_error: f64,
};

const RunnerContext = struct {
    workload: Workload,
};

fn runnerCallback(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    const runner: *RunnerContext = @ptrCast(@alignCast(context));
    return runner.workload.run(alloc, io);
}

fn runOrdering(alloc: Allocator, io: std.Io, config: Config) !OrderingResult {
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

const OverheadResult = struct {
    empty_internal_ns: f64,
    empty_harness_ns: f64,
    small_internal_ns: f64,
    small_harness_ns: f64,
};

fn runOverhead(alloc: Allocator, io: std.Io, config: Config) !OverheadResult {
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

fn writeTextReport(
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

fn writeJsonReport(
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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var config: Config = .{};
    var json_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--trials")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.trials = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.samples = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.iterations = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.warmup = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--jitter")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.jitter_percent = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.seed = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            json_path = args[index];
        } else {
            return error.InvalidArguments;
        }
    }

    if (config.trials == 0 or config.samples < 2 or config.iterations == 0) {
        return error.InvalidArguments;
    }

    const false_positive = try runScenario(alloc, io, config, "false_positive", 100);
    const detect_10pct = try runScenario(alloc, io, config, "detect_10pct", 110);
    const detect_20pct = try runScenario(alloc, io, config, "detect_20pct", 120);
    const ordering = try runOrdering(alloc, io, config);
    const overhead = try runOverhead(alloc, io, config);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try writeTextReport(
        out,
        config,
        false_positive,
        detect_10pct,
        detect_20pct,
        ordering,
        overhead,
    );
    try out.flush();

    if (json_path) |path| {
        const json = try writeJsonReport(
            alloc,
            config,
            false_positive,
            detect_10pct,
            detect_20pct,
            ordering,
            overhead,
        );
        defer alloc.free(json);
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }
}

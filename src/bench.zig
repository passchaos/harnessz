//! Benchmark harness with warmup, minimum-time sampling, interleaved A/B
//! comparison, gate logic, and JSON/CSV rendering.
//!
//! Timing values are intentionally not asserted by unit tests. Gate logic is
//! tested through `Comparison.fromSamples`, which works on synthetic samples.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stats = @import("stats.zig");

/// Host environment controls: CPU pinning, peak RSS, and a counting
/// allocator.
pub const system = @import("bench/system.zig");

/// Process-isolated benchmark support: JSON protocol, child registry,
/// child entrypoint, and parent process runner.
pub const protocol = @import("bench/protocol.zig");
pub const registry = @import("bench/registry.zig");
pub const child = @import("bench/child.zig");
pub const process = @import("bench/process.zig");
pub const stderr_capture = @import("bench/stderr_capture.zig");
pub const watchdog = @import("bench/watchdog.zig");

/// Interleaved multi-implementation comparison.
pub const multi = @import("bench/multi.zig");
pub const NamedRunner = multi.NamedRunner;
pub const MultiComparison = multi.MultiComparison;
pub const compareMany = multi.compareMany;

/// In-process suites over a benchmark registry.
pub const suite = @import("bench/suite.zig");
pub const SuiteOptions = suite.SuiteOptions;
pub const SuiteResult = suite.SuiteResult;
pub const runSuite = suite.runSuite;

/// Benchmark configuration policy checks.
pub const policy = @import("bench/policy.zig");
pub const Policy = policy.Policy;
pub const PolicyViolation = policy.Violation;
pub const validatePolicy = policy.validate;

/// Type-erased benchmark callback used by `runRuntime` and the child
/// registry.
pub const Runner = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, Allocator, std.Io) anyerror!u64,

    pub fn call(self: Runner, alloc: Allocator, io: std.Io) !u64 {
        return self.run(self.context, alloc, io);
    }
};

pub const CpuMask = system.CpuMask;
pub const CountingAllocator = system.CountingAllocator;
pub const affinityMask = system.affinityMask;
pub const pinToCpu = system.pinToCpu;
pub const currentCpu = system.currentCpu;
pub const peakRssBytes = system.peakRssBytes;

/// Keep `value` observable to the optimizer. Zig 0.16 exposes this through
/// `std.mem.doNotOptimizeAway`, which emits an empty volatile asm block (or a
/// volatile store on backends without asm support).
pub fn blackBox(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

pub const Options = struct {
    warmup_iterations: usize = 1,
    iterations: usize = 10,
    /// Number of callback invocations per timed sample. The stored sample is
    /// the per-call average. Increase this when a single callback is shorter
    /// than the clock resolution. Warmup still runs `warmup_iterations`
    /// callback calls, not batches.
    batch_size: usize = 1,
    /// When non-zero, keep sampling until this much wall time has elapsed,
    /// with an effective cap of `max(iterations, max_iterations)` samples.
    min_time_ns: u64 = 0,
    /// Upper bound for min-time sampling when it is at least `iterations`.
    /// At least `iterations` samples are always collected.
    max_iterations: usize = 1000,
    clock: std.Io.Clock = .awake,
};

pub const Stats = struct {
    warmup_iterations: usize,
    /// Callback invocations per sample used to produce `samples_ns`.
    batch_size: usize = 1,
    samples_ns: []u64,
    distribution: stats.Summary,
    /// Result returned by the last measured callback invocation. Useful as a
    /// deterministic checksum when the callback computes one.
    last_result: u64 = 0,

    pub fn deinit(self: *Stats, alloc: Allocator) void {
        alloc.free(self.samples_ns);
        self.* = undefined;
    }

    pub fn writeJson(self: Stats, writer: *std.Io.Writer) !void {
        const Wire = struct {
            warmup_iterations: usize,
            batch_size: usize,
            iterations: usize,
            distribution: stats.Summary,
        };
        try std.json.Stringify.value(Wire{
            .warmup_iterations = self.warmup_iterations,
            .batch_size = self.batch_size,
            .iterations = self.samples_ns.len,
            .distribution = self.distribution,
        }, .{ .whitespace = .indent_2 }, writer);
    }

    pub fn toJson(self: Stats, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeCsv(self: Stats, writer: *std.Io.Writer) !void {
        try writer.writeAll("metric,value\n");
        try writer.print("warmup_iterations,{d}\n", .{self.warmup_iterations});
        try writer.print("batch_size,{d}\n", .{self.batch_size});
        try writer.print("iterations,{d}\n", .{self.samples_ns.len});
        try writeSummaryCsv(writer, self.distribution);
    }

    pub fn toCsv(self: Stats, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeCsv(&out.writer);
        return out.toOwnedSlice();
    }
};

pub const GateResult = struct {
    passed: bool,
    speedup: f64,
    min_ratio: f64,
};

pub const Comparison = struct {
    a: stats.Summary,
    b: stats.Summary,
    rounds: usize,
    /// Two-sided Welch t-test p-value using the normal approximation. Values
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
            stats.WelchResult{ .t = 0, .degrees_of_freedom = 0, .p_approx = 1 };
        const rank_result = stats.mannWhitneyU(u64, a_samples, b_samples) catch
            stats.RankResult{ .u = 0, .z = 0, .p_approx = 1, .tie_groups = 0 };
        return .{
            .a = stats.summarize(u64, a_samples),
            .b = stats.summarize(u64, b_samples),
            .rounds = @min(a_samples.len, b_samples.len),
            .p_value = welch_result.p_approx,
            .significant = welch_result.p_approx <= significance_alpha,
            .robust_p_value = rank_result.p_approx,
            .robust_significant = rank_result.p_approx <= significance_alpha,
        };
    }

    /// `a.median / b.median`; values above 1 mean `b` is faster.
    pub fn speedup(self: Comparison) f64 {
        return safeDiv(self.a.median, self.b.median);
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
            .speedup = finiteOptional(self.speedup()),
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

/// Timing plus optional host measurements captured by `runMeasured`.
pub const MeasuredStats = struct {
    timing: Stats,
    /// Process peak RSS in bytes, or null when unsupported.
    peak_rss_bytes: ?u64,
    /// Peak live bytes allocated through the allocator passed to the
    /// callback during the measured phase.
    peak_allocated_bytes: u64,

    pub fn deinit(self: *MeasuredStats, alloc: Allocator) void {
        self.timing.deinit(alloc);
        self.* = undefined;
    }
};

/// Run `func` for warmup then timed iterations. Callback signature:
/// `fn (context, allocator, io) anyerror!u64`
pub fn run(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime func: anytype,
) !Stats {
    var context_copy = context;
    const Adapter = struct {
        fn invoke(ptr: *anyopaque, callback_alloc: Allocator, io_value: std.Io) anyerror!u64 {
            const typed: *@TypeOf(context_copy) = @ptrCast(@alignCast(ptr));
            return func(typed.*, callback_alloc, io_value);
        }
    };
    return runInternal(
        alloc,
        alloc,
        io,
        options,
        .{ .context = @ptrCast(&context_copy), .run = Adapter.invoke },
        null,
    );
}

/// Like `run`, but for an already type-erased callback. This is the entry
/// point used by process-isolated child benchmarks and the registry.
pub fn runRuntime(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: *anyopaque,
    func: *const fn (*anyopaque, Allocator, std.Io) anyerror!u64,
) !Stats {
    return runInternal(
        alloc,
        alloc,
        io,
        options,
        .{ .context = context, .run = func },
        null,
    );
}

/// Like `run`, but also reports peak process RSS and peak bytes allocated
/// through the callback allocator. The callback receives a counting
/// allocator wrapper; harness bookkeeping still uses `alloc`. The wrapper is
/// not thread-safe, so the callback must not share it across threads.
///
/// Peak allocation tracking is reset after warmup, so warmup allocations that
/// are released before the measured phase do not count.
pub fn runMeasured(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime func: anytype,
) !MeasuredStats {
    var context_copy = context;
    const Adapter = struct {
        fn invoke(ptr: *anyopaque, callback_alloc: Allocator, io_value: std.Io) anyerror!u64 {
            const typed: *@TypeOf(context_copy) = @ptrCast(@alignCast(ptr));
            return func(typed.*, callback_alloc, io_value);
        }
    };
    var counting = system.CountingAllocator.init(alloc);
    const timing = try runInternal(
        alloc,
        counting.allocator(),
        io,
        options,
        .{ .context = @ptrCast(&context_copy), .run = Adapter.invoke },
        &counting,
    );
    errdefer {
        var owned = timing;
        owned.deinit(alloc);
    }

    // A missing or unreadable procfs entry simply leaves the field null.
    const rss: ?u64 = system.peakRssBytes(io) catch null;
    return .{
        .timing = timing,
        .peak_rss_bytes = rss,
        .peak_allocated_bytes = counting.peakBytes(),
    };
}

/// Type-erased counterpart to `runMeasured`, used by process-isolated child
/// benchmarks that report memory metrics alongside timing samples. The
/// callback allocator is a single-threaded `CountingAllocator` wrapper.
pub fn runMeasuredRuntime(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: *anyopaque,
    func: *const fn (*anyopaque, Allocator, std.Io) anyerror!u64,
) !MeasuredStats {
    var counting = system.CountingAllocator.init(alloc);
    const timing = try runInternal(
        alloc,
        counting.allocator(),
        io,
        options,
        .{ .context = context, .run = func },
        &counting,
    );
    errdefer {
        var owned = timing;
        owned.deinit(alloc);
    }

    // A missing or unreadable procfs entry simply leaves the field null.
    const rss: ?u64 = system.peakRssBytes(io) catch null;
    return .{
        .timing = timing,
        .peak_rss_bytes = rss,
        .peak_allocated_bytes = counting.peakBytes(),
    };
}

fn runInternal(
    alloc: Allocator,
    callback_alloc: Allocator,
    io: std.Io,
    options: Options,
    runner: Runner,
    counting: ?*system.CountingAllocator,
) !Stats {
    if (options.iterations == 0 or options.batch_size == 0) {
        return error.InvalidOptions;
    }

    var warmup_index: usize = 0;
    while (warmup_index < options.warmup_iterations) : (warmup_index += 1) {
        const result = try runner.call(callback_alloc, io);
        blackBox(result);
    }
    if (counting) |counter| counter.resetPeak();

    var samples: std.ArrayList(u64) = .empty;
    errdefer samples.deinit(alloc);

    const has_min_time = options.min_time_ns != 0;
    const limit = if (has_min_time)
        @max(options.iterations, options.max_iterations)
    else
        options.iterations;

    var total_ns: u64 = 0;
    var last_result: u64 = 0;
    while (samples.items.len < limit) {
        if (has_min_time and
            samples.items.len >= options.iterations and
            total_ns >= options.min_time_ns)
        {
            break;
        }
        const measurement = try measureRunner(
            callback_alloc,
            io,
            options.clock,
            runner,
            options.batch_size,
        );
        last_result = measurement.result;
        try samples.append(alloc, measurement.elapsed_ns);
        // The time budget is wall-clock time, not the sum of per-call averages.
        total_ns = total_ns +| measurement.wall_ns;
    }

    if (samples.items.len == 0) return error.InvalidOptions;
    const owned = try samples.toOwnedSlice(alloc);
    errdefer alloc.free(owned);
    return .{
        .warmup_iterations = options.warmup_iterations,
        .batch_size = options.batch_size,
        .samples_ns = owned,
        .distribution = stats.summarize(u64, owned),
        .last_result = last_result,
    };
}

/// Interleaved A/B comparison. One A call and one B call form a round; the
/// order alternates each round to reduce ordering bias. `options.iterations`
/// is the number of rounds; `min_time_ns` is ignored for comparisons.
pub fn compare(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    ctx_a: anytype,
    comptime fn_a: anytype,
    ctx_b: anytype,
    comptime fn_b: anytype,
) !Comparison {
    if (options.iterations == 0 or options.batch_size == 0) {
        return error.InvalidOptions;
    }

    var warmup_index: usize = 0;
    while (warmup_index < options.warmup_iterations) : (warmup_index += 1) {
        const result_a = try fn_a(ctx_a, alloc, io);
        blackBox(result_a);
        const result_b = try fn_b(ctx_b, alloc, io);
        blackBox(result_b);
    }

    var a_samples: std.ArrayList(u64) = .empty;
    defer a_samples.deinit(alloc);
    var b_samples: std.ArrayList(u64) = .empty;
    defer b_samples.deinit(alloc);

    var round: usize = 0;
    while (round < options.iterations) : (round += 1) {
        if (round % 2 == 0) {
            try a_samples.append(alloc, try measure(
                alloc,
                io,
                options.clock,
                ctx_a,
                fn_a,
                options.batch_size,
            ));
            try b_samples.append(alloc, try measure(
                alloc,
                io,
                options.clock,
                ctx_b,
                fn_b,
                options.batch_size,
            ));
        } else {
            try b_samples.append(alloc, try measure(
                alloc,
                io,
                options.clock,
                ctx_b,
                fn_b,
                options.batch_size,
            ));
            try a_samples.append(alloc, try measure(
                alloc,
                io,
                options.clock,
                ctx_a,
                fn_a,
                options.batch_size,
            ));
        }
    }

    return Comparison.fromSamples(a_samples.items, b_samples.items);
}

const measure_lib = @import("bench/measure.zig");

fn measure(
    alloc: Allocator,
    io: std.Io,
    clock: std.Io.Clock,
    context: anytype,
    comptime func: anytype,
    batch_size: usize,
) !u64 {
    return measure_lib.perCall(alloc, io, clock, context, func, batch_size);
}

const Measurement = measure_lib.RunnerMeasurement;

fn measureRunner(
    alloc: Allocator,
    io: std.Io,
    clock: std.Io.Clock,
    runner: Runner,
    batch_size: usize,
) !Measurement {
    return measure_lib.runner(alloc, io, clock, runner, batch_size);
}

fn writeSummaryCsv(writer: *std.Io.Writer, summary: stats.Summary) !void {
    try writer.print("min_ns,{d}\n", .{summary.min});
    try writer.print("max_ns,{d}\n", .{summary.max});
    try writer.print("mean_ns,{d}\n", .{summary.mean});
    try writer.print("stddev_ns,{d}\n", .{summary.stddev});
    try writer.print("median_ns,{d}\n", .{summary.median});
    try writer.print("p90_ns,{d}\n", .{summary.p90});
    try writer.print("p99_ns,{d}\n", .{summary.p99});
}

fn writeSummaryPairCsv(writer: *std.Io.Writer, a: stats.Summary, b: stats.Summary) !void {
    try writer.print("min_ns,{d},{d}\n", .{ a.min, b.min });
    try writer.print("max_ns,{d},{d}\n", .{ a.max, b.max });
    try writer.print("mean_ns,{d},{d}\n", .{ a.mean, b.mean });
    try writer.print("stddev_ns,{d},{d}\n", .{ a.stddev, b.stddev });
    try writer.print("median_ns,{d},{d}\n", .{ a.median, b.median });
    try writer.print("p90_ns,{d},{d}\n", .{ a.p90, b.p90 });
    try writer.print("p99_ns,{d},{d}\n", .{ a.p99, b.p99 });
}

fn safeDiv(numerator: f64, denominator: f64) f64 {
    if (denominator == 0) {
        if (numerator == 0) return 0;
        return if (numerator > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    return numerator / denominator;
}

/// JSON cannot represent infinity or NaN; map non-finite values to null.
fn finiteOptional(value: f64) ?f64 {
    return if (std.math.isFinite(value)) value else null;
}

test {
    _ = @import("bench_test.zig");
    // Force analysis of the process-isolation submodules so their tests are
    // included in the package test run.
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(registry);
    std.testing.refAllDecls(child);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(stderr_capture);
    std.testing.refAllDecls(watchdog);
    std.testing.refAllDecls(multi);
    std.testing.refAllDecls(suite);
    std.testing.refAllDecls(policy);
    std.testing.refAllDecls(measure_lib);
}

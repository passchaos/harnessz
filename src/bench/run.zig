//! Core benchmark execution: warmup, timed sampling, batch sizes, minimum
//! sampling time, and the interleaved A/B comparison entry point.
//!
//! Timing values are intentionally not asserted by unit tests. Structural
//! behaviour (callback counts, sample lengths, batch sizes) is tested in
//! `bench_test.zig`, and gate logic is tested through
//! `bench.Comparison.fromSamples`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stats = @import("../stats.zig");
const system = @import("system.zig");
const measure_lib = @import("measure.zig");
const comparison_mod = @import("comparison.zig");

/// Type-erased benchmark callback used by `runRuntime` and the child
/// registry.
pub const Runner = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, Allocator, std.Io) anyerror!u64,

    pub fn call(self: Runner, alloc: Allocator, io: std.Io) !u64 {
        return self.run(self.context, alloc, io);
    }
};

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

/// Timing plus optional host measurements captured by `runMeasured`.
pub const MeasuredStats = struct {
    timing: Stats,
    /// Process peak RSS in bytes, or null when unsupported.
    peak_rss_bytes: ?u64,
    /// Peak live bytes allocated through the allocator passed to the
    /// callback during the measured phase.
    peak_allocated_bytes: u64,
    /// Successful allocations through the callback allocator during the
    /// measured phase. Warmup allocations are excluded.
    allocation_count: u64 = 0,
    /// Frees through the callback allocator during the measured phase.
    free_count: u64 = 0,

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
        .allocation_count = @intCast(counting.allocation_count),
        .free_count = @intCast(counting.free_count),
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
        .allocation_count = @intCast(counting.allocation_count),
        .free_count = @intCast(counting.free_count),
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
        measure_lib.blackBox(result);
    }
    if (counting) |counter| {
        counter.resetPeak();
        counter.resetCounts();
    }

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
        const measurement = try measure_lib.runner(
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
) !comparison_mod.Comparison {
    if (options.iterations == 0 or options.batch_size == 0) {
        return error.InvalidOptions;
    }

    var warmup_index: usize = 0;
    while (warmup_index < options.warmup_iterations) : (warmup_index += 1) {
        const result_a = try fn_a(ctx_a, alloc, io);
        measure_lib.blackBox(result_a);
        const result_b = try fn_b(ctx_b, alloc, io);
        measure_lib.blackBox(result_b);
    }

    var a_samples: std.ArrayList(u64) = .empty;
    defer a_samples.deinit(alloc);
    var b_samples: std.ArrayList(u64) = .empty;
    defer b_samples.deinit(alloc);

    var round: usize = 0;
    while (round < options.iterations) : (round += 1) {
        if (round % 2 == 0) {
            try a_samples.append(alloc, try measure_lib.perCall(
                alloc,
                io,
                options.clock,
                ctx_a,
                fn_a,
                options.batch_size,
            ));
            try b_samples.append(alloc, try measure_lib.perCall(
                alloc,
                io,
                options.clock,
                ctx_b,
                fn_b,
                options.batch_size,
            ));
        } else {
            try b_samples.append(alloc, try measure_lib.perCall(
                alloc,
                io,
                options.clock,
                ctx_b,
                fn_b,
                options.batch_size,
            ));
            try a_samples.append(alloc, try measure_lib.perCall(
                alloc,
                io,
                options.clock,
                ctx_a,
                fn_a,
                options.batch_size,
            ));
        }
    }

    return comparison_mod.Comparison.fromSamples(a_samples.items, b_samples.items);
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

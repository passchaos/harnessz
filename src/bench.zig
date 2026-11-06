//! Benchmark harness with warmup, minimum-time sampling, interleaved A/B
//! comparison, gate logic, and JSON/CSV rendering.
//!
//! Timing values are intentionally not asserted by unit tests. Gate logic is
//! tested through `Comparison.fromSamples`, which works on synthetic samples.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stats = @import("stats.zig");

/// Keep `value` observable to the optimizer. Zig 0.16 exposes this through
/// `std.mem.doNotOptimizeAway`, which emits an empty volatile asm block (or a
/// volatile store on backends without asm support).
pub fn blackBox(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

pub const Options = struct {
    warmup_iterations: usize = 1,
    iterations: usize = 10,
    /// When non-zero, keep sampling until this much wall time has elapsed,
    /// up to `max_iterations`.
    min_time_ns: u64 = 0,
    max_iterations: usize = 1000,
    clock: std.Io.Clock = .awake,
};

pub const Stats = struct {
    warmup_iterations: usize,
    samples_ns: []u64,
    distribution: stats.Summary,

    pub fn deinit(self: *Stats, alloc: Allocator) void {
        alloc.free(self.samples_ns);
        self.* = undefined;
    }

    pub fn writeJson(self: Stats, writer: *std.Io.Writer) !void {
        const Wire = struct {
            warmup_iterations: usize,
            iterations: usize,
            distribution: stats.Summary,
        };
        try std.json.Stringify.value(Wire{
            .warmup_iterations = self.warmup_iterations,
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

    /// Build a comparison from already-collected samples. This makes gate
    /// logic testable without running a timer.
    pub fn fromSamples(a_samples: []const u64, b_samples: []const u64) Comparison {
        return .{
            .a = stats.summarize(u64, a_samples),
            .b = stats.summarize(u64, b_samples),
            .rounds = @min(a_samples.len, b_samples.len),
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

    pub fn writeJson(self: Comparison, writer: *std.Io.Writer) !void {
        const Wire = struct {
            rounds: usize,
            speedup: f64,
            a: stats.Summary,
            b: stats.Summary,
        };
        try std.json.Stringify.value(Wire{
            .rounds = self.rounds,
            .speedup = self.speedup(),
            .a = self.a,
            .b = self.b,
        }, .{ .whitespace = .indent_2 }, writer);
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
    }

    pub fn toCsv(self: Comparison, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeCsv(&out.writer);
        return out.toOwnedSlice();
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
    if (options.iterations == 0) return error.InvalidOptions;

    var warmup_index: usize = 0;
    while (warmup_index < options.warmup_iterations) : (warmup_index += 1) {
        const result = try func(context, alloc, io);
        blackBox(result);
    }

    var samples: std.ArrayList(u64) = .empty;
    errdefer samples.deinit(alloc);

    const has_min_time = options.min_time_ns != 0;
    const limit = if (has_min_time)
        @max(options.iterations, options.max_iterations)
    else
        options.iterations;

    var total_ns: u64 = 0;
    while (samples.items.len < limit) {
        if (has_min_time and
            samples.items.len >= options.iterations and
            total_ns >= options.min_time_ns)
        {
            break;
        }
        const elapsed = try measure(alloc, io, options.clock, context, func);
        try samples.append(alloc, elapsed);
        total_ns = total_ns +| elapsed;
    }

    if (samples.items.len == 0) return error.InvalidOptions;
    const owned = try samples.toOwnedSlice(alloc);
    errdefer alloc.free(owned);
    return .{
        .warmup_iterations = options.warmup_iterations,
        .samples_ns = owned,
        .distribution = stats.summarize(u64, owned),
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
    if (options.iterations == 0) return error.InvalidOptions;

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
            try a_samples.append(alloc, try measure(alloc, io, options.clock, ctx_a, fn_a));
            try b_samples.append(alloc, try measure(alloc, io, options.clock, ctx_b, fn_b));
        } else {
            try b_samples.append(alloc, try measure(alloc, io, options.clock, ctx_b, fn_b));
            try a_samples.append(alloc, try measure(alloc, io, options.clock, ctx_a, fn_a));
        }
    }

    return Comparison.fromSamples(a_samples.items, b_samples.items);
}

fn measure(
    alloc: Allocator,
    io: std.Io,
    clock: std.Io.Clock,
    context: anytype,
    comptime func: anytype,
) !u64 {
    const start = std.Io.Clock.Timestamp.now(io, clock);
    const result = try func(context, alloc, io);
    blackBox(result);
    const elapsed_ns = start.untilNow(io).raw.toNanoseconds();
    if (elapsed_ns < 0) return error.ClockWentBackwards;
    return @intCast(elapsed_ns);
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

const RunContext = struct {
    calls: usize = 0,
};

fn countedWork(context: *RunContext, alloc: Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    context.calls += 1;
    return @intCast(context.calls);
}

test "bench run: structural iteration counts" {
    const alloc = std.testing.allocator;
    var context: RunContext = .{};
    var result = try run(alloc, std.testing.io, .{
        .warmup_iterations = 2,
        .iterations = 5,
    }, &context, countedWork);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 7), context.calls);
    try std.testing.expectEqual(@as(usize, 5), result.samples_ns.len);
    try std.testing.expectEqual(@as(usize, 5), result.distribution.count);
    try std.testing.expectEqual(@as(usize, 2), result.warmup_iterations);
}

test "bench run: min-time sampling is bounded structurally" {
    const alloc = std.testing.allocator;
    var context: RunContext = .{};
    var result = try run(alloc, std.testing.io, .{
        .warmup_iterations = 0,
        .iterations = 2,
        .min_time_ns = 1,
        .max_iterations = 6,
    }, &context, countedWork);
    defer result.deinit(alloc);

    try std.testing.expect(result.samples_ns.len >= 2);
    try std.testing.expect(result.samples_ns.len <= 6);
    try std.testing.expectEqual(result.samples_ns.len, context.calls);
}

test "bench run: zero iterations is invalid" {
    const alloc = std.testing.allocator;
    var context: RunContext = .{};
    try std.testing.expectError(error.InvalidOptions, run(
        alloc,
        std.testing.io,
        .{ .iterations = 0 },
        &context,
        countedWork,
    ));
}

const OrderContext = struct {
    order: *std.ArrayList(u8),
    alloc: Allocator,
    calls: usize = 0,
};

fn orderA(context: *OrderContext, alloc: Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    try context.order.append(context.alloc, 'A');
    context.calls += 1;
    return 1;
}

fn orderB(context: *OrderContext, alloc: Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    try context.order.append(context.alloc, 'B');
    context.calls += 1;
    return 2;
}

test "bench compare: structural rounds and alternating order" {
    const alloc = std.testing.allocator;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(alloc);

    var ctx_a: OrderContext = .{ .order = &order, .alloc = alloc };
    var ctx_b: OrderContext = .{ .order = &order, .alloc = alloc };

    const comparison = try compare(
        alloc,
        std.testing.io,
        .{ .warmup_iterations = 0, .iterations = 4 },
        &ctx_a,
        orderA,
        &ctx_b,
        orderB,
    );

    try std.testing.expectEqualStrings("ABBAABBA", order.items);
    try std.testing.expectEqual(@as(usize, 4), comparison.rounds);
    try std.testing.expectEqual(@as(usize, 4), comparison.a.count);
    try std.testing.expectEqual(@as(usize, 4), comparison.b.count);
    try std.testing.expectEqual(@as(usize, 4), ctx_a.calls);
    try std.testing.expectEqual(@as(usize, 4), ctx_b.calls);
}

test "bench compare: warmup calls both sides" {
    const alloc = std.testing.allocator;
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(alloc);

    var ctx_a: OrderContext = .{ .order = &order, .alloc = alloc };
    var ctx_b: OrderContext = .{ .order = &order, .alloc = alloc };

    _ = try compare(
        alloc,
        std.testing.io,
        .{ .warmup_iterations = 2, .iterations = 1 },
        &ctx_a,
        orderA,
        &ctx_b,
        orderB,
    );
    try std.testing.expectEqual(@as(usize, 3), ctx_a.calls);
    try std.testing.expectEqual(@as(usize, 3), ctx_b.calls);
}

test "bench gate: synthetic samples" {
    const baseline = [_]u64{ 100, 100, 100, 100 };
    const candidate = [_]u64{ 50, 50, 50, 50 };
    const comparison = Comparison.fromSamples(&baseline, &candidate);

    try std.testing.expectEqual(@as(f64, 2), comparison.speedup());
    try std.testing.expect(comparison.gate(1.5));
    try std.testing.expect(comparison.gate(2.0));
    try std.testing.expect(!comparison.gate(2.5));

    const gate_result = comparison.gateResult(1.5);
    try std.testing.expect(gate_result.passed);
    try std.testing.expectEqual(@as(f64, 2), gate_result.speedup);
    try std.testing.expectEqual(@as(f64, 1.5), gate_result.min_ratio);

    const regression = Comparison.fromSamples(&candidate, &baseline);
    try std.testing.expect(!regression.gate(1.0));
}

test "bench comparison: JSON and CSV output" {
    const alloc = std.testing.allocator;
    const baseline = [_]u64{ 100, 100, 100 };
    const candidate = [_]u64{ 80, 80, 80 };
    const comparison = Comparison.fromSamples(&baseline, &candidate);

    const json = try comparison.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"speedup\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"median\"") != null);

    const csv = try comparison.toCsv(alloc);
    defer alloc.free(csv);
    try std.testing.expect(std.mem.find(u8, csv, "metric,a,b") != null);
    try std.testing.expect(std.mem.find(u8, csv, "median_ns") != null);
}

test "bench stats: JSON and CSV output" {
    const alloc = std.testing.allocator;
    var context: RunContext = .{};
    var result = try run(alloc, std.testing.io, .{
        .warmup_iterations = 0,
        .iterations = 3,
    }, &context, countedWork);
    defer result.deinit(alloc);

    const json = try result.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"iterations\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"median\"") != null);

    const csv = try result.toCsv(alloc);
    defer alloc.free(csv);
    try std.testing.expect(std.mem.find(u8, csv, "metric,value") != null);
    try std.testing.expect(std.mem.find(u8, csv, "median_ns") != null);
}

fn computeObservableValue(input: u64) u64 {
    return input * 3 + 1;
}

test "bench blackBox: computed value survives through a volatile sink" {
    var sink: u64 = 0;
    const value = computeObservableValue(7);
    blackBox(value);

    const volatile_sink: *volatile u64 = &sink;
    volatile_sink.* = value;
    try std.testing.expectEqual(@as(u64, 22), volatile_sink.*);

    // Pointers and arrays are also accepted by the generic helper.
    var array = [_]u64{ 1, 2, 3 };
    blackBox(&array);
    blackBox(array);
    const volatile_array: *volatile [3]u64 = &array;
    try std.testing.expectEqual(@as(u64, 2), volatile_array.*[1]);
}

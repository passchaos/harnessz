//! Tests for the benchmark runner and comparison gates.

const std = @import("std");
const bench = @import("bench.zig");
const Allocator = std.mem.Allocator;

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
    var result = try bench.run(alloc, std.testing.io, .{
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
    var result = try bench.run(alloc, std.testing.io, .{
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
    try std.testing.expectError(error.InvalidOptions, bench.run(
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

    const comparison = try bench.compare(
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

    _ = try bench.compare(
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
    const comparison = bench.Comparison.fromSamples(&baseline, &candidate);

    try std.testing.expectEqual(@as(f64, 2), comparison.speedup());
    try std.testing.expect(comparison.gate(1.5));
    try std.testing.expect(comparison.gate(2.0));
    try std.testing.expect(!comparison.gate(2.5));

    const gate_result = comparison.gateResult(1.5);
    try std.testing.expect(gate_result.passed);
    try std.testing.expectEqual(@as(f64, 2), gate_result.speedup);
    try std.testing.expectEqual(@as(f64, 1.5), gate_result.min_ratio);

    const regression = bench.Comparison.fromSamples(&candidate, &baseline);
    try std.testing.expect(!regression.gate(1.0));
}

test "bench significance: clearly different distributions" {
    const baseline = [_]u64{ 100, 101, 99, 100, 102, 100 };
    const candidate = [_]u64{ 50, 51, 49, 50, 52, 50 };
    const comparison = bench.Comparison.fromSamples(&baseline, &candidate);

    try std.testing.expect(comparison.significant);
    try std.testing.expect(comparison.p_value < 0.01);
    try std.testing.expect(comparison.gateSignificant(1.5, 0.01));
    try std.testing.expect(!comparison.gateSignificant(3.0, 0.01));
}

test "bench significance: identical distributions are not significant" {
    const values = [_]u64{ 100, 101, 99, 100, 102 };
    const comparison = bench.Comparison.fromSamples(&values, &values);

    try std.testing.expect(!comparison.significant);
    try std.testing.expectEqual(@as(f64, 1), comparison.p_value);
    try std.testing.expect(comparison.gate(0.5));
    try std.testing.expect(!comparison.gateSignificant(0.5, 0.05));
    try std.testing.expect(!comparison.gateSignificant(0.5, 2.0));
}

test "bench significance: single samples are not significant" {
    const comparison = bench.Comparison.fromSamples(&[_]u64{100}, &[_]u64{50});
    try std.testing.expect(!comparison.significant);
    try std.testing.expectEqual(@as(f64, 1), comparison.p_value);
    try std.testing.expect(!comparison.gateSignificant(1.0, 1.0));
}

test "bench comparison: JSON and CSV output" {
    const alloc = std.testing.allocator;
    const baseline = [_]u64{ 100, 100, 100 };
    const candidate = [_]u64{ 80, 80, 80 };
    const comparison = bench.Comparison.fromSamples(&baseline, &candidate);

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
    var result = try bench.run(alloc, std.testing.io, .{
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

const AllocMeasureContext = struct {
    bytes: usize,
};

fn measuredAllocWork(
    context: *AllocMeasureContext,
    alloc: Allocator,
    io: std.Io,
) !u64 {
    _ = io;
    const buffer = try alloc.alloc(u8, context.bytes);
    defer alloc.free(buffer);
    @memset(buffer, 0xAB);
    bench.blackBox(buffer[0]);
    return @intCast(buffer.len);
}

test "bench runMeasured: reports allocated bytes and timing structure" {
    const alloc = std.testing.allocator;
    var context: AllocMeasureContext = .{ .bytes = 4096 };
    var measured = try bench.runMeasured(alloc, std.testing.io, .{
        .warmup_iterations = 1,
        .iterations = 3,
    }, &context, measuredAllocWork);
    defer measured.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), measured.timing.samples_ns.len);
    try std.testing.expectEqual(@as(usize, 3), measured.timing.distribution.count);
    try std.testing.expectEqual(@as(u64, 4096), measured.peak_allocated_bytes);
    if (measured.peak_rss_bytes) |rss| {
        try std.testing.expect(rss > 0);
    }
}

test "bench runMeasured: zero iterations is invalid" {
    const alloc = std.testing.allocator;
    var context: AllocMeasureContext = .{ .bytes = 8 };
    try std.testing.expectError(error.InvalidOptions, bench.runMeasured(
        alloc,
        std.testing.io,
        .{ .iterations = 0 },
        &context,
        measuredAllocWork,
    ));
}

test {
    std.testing.refAllDecls(bench.system);
}

test "bench blackBox: computed value survives through a volatile sink" {
    var sink: u64 = 0;
    const value = computeObservableValue(7);
    bench.blackBox(value);

    const volatile_sink: *volatile u64 = &sink;
    volatile_sink.* = value;
    try std.testing.expectEqual(@as(u64, 22), volatile_sink.*);

    // Pointers and arrays are also accepted by the generic helper.
    var array = [_]u64{ 1, 2, 3 };
    bench.blackBox(&array);
    bench.blackBox(array);
    const volatile_array: *volatile [3]u64 = &array;
    try std.testing.expectEqual(@as(u64, 2), volatile_array.*[1]);
}

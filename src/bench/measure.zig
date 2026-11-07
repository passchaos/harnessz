//! Internal timing helpers shared by the single- and multi-implementation
//! benchmark runners.
//!
//! These functions only collect wall-clock samples; statistics and gates are
//! layered on top by `bench.Stats`, `bench.Comparison`, and
//! `bench.MultiComparison`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Keep `value` observable to the optimizer. Mirrors `bench.blackBox`.
pub fn blackBox(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

/// Time `batch_size` invocations of `func` and return the per-call average.
pub fn perCall(
    alloc: Allocator,
    io: std.Io,
    clock: std.Io.Clock,
    context: anytype,
    comptime func: anytype,
    batch_size: usize,
) !u64 {
    const start = std.Io.Clock.Timestamp.now(io, clock);
    var index: usize = 0;
    while (index < batch_size) : (index += 1) {
        const result = try func(context, alloc, io);
        blackBox(result);
    }
    const elapsed_ns = start.untilNow(io).raw.toNanoseconds();
    if (elapsed_ns < 0) return error.ClockWentBackwards;
    const wall_ns: u64 = @intCast(elapsed_ns);
    return wall_ns / @as(u64, @intCast(batch_size));
}

pub const RunnerMeasurement = struct {
    /// Per-call average stored in benchmark samples.
    elapsed_ns: u64,
    /// Total wall time for the batch, used for `min_time_ns`.
    wall_ns: u64,
    result: u64,
};

/// `perCall` for a type-erased `bench.Runner`.
pub fn runner(
    alloc: Allocator,
    io: std.Io,
    clock: std.Io.Clock,
    candidate: anytype,
    batch_size: usize,
) !RunnerMeasurement {
    const start = std.Io.Clock.Timestamp.now(io, clock);
    var last_result: u64 = 0;
    var index: usize = 0;
    while (index < batch_size) : (index += 1) {
        last_result = try candidate.call(alloc, io);
        blackBox(last_result);
    }
    const elapsed_ns = start.untilNow(io).raw.toNanoseconds();
    if (elapsed_ns < 0) return error.ClockWentBackwards;
    const wall_ns: u64 = @intCast(elapsed_ns);
    return .{
        .elapsed_ns = wall_ns / @as(u64, @intCast(batch_size)),
        .wall_ns = wall_ns,
        .result = last_result,
    };
}

test "measure: perCall divides the batch and forwards the callback result" {
    const Counter = struct {
        fn run(context: *anyopaque, _: Allocator, _: std.Io) anyerror!u64 {
            const value: *u64 = @ptrCast(@alignCast(context));
            value.* += 1;
            return value.*;
        }
    };

    var count: u64 = 0;
    const elapsed = try perCall(
        std.testing.allocator,
        std.testing.io,
        .awake,
        &count,
        Counter.run,
        3,
    );
    try std.testing.expectEqual(@as(u64, 3), count);
    // Timing itself is not asserted; a successful sample is a u64 value.
    _ = elapsed;
}

test "measure: runner forwards through a type-erased callback" {
    // `runner` only requires a `call(alloc, io)` method, so this test does not
    // need the parent `bench` module.
    const Counter = struct {
        value: u64 = 0,

        fn call(self: *@This(), _: Allocator, _: std.Io) !u64 {
            self.value += 1;
            return self.value;
        }
    };

    var counter: Counter = .{};
    const measured = try runner(
        std.testing.allocator,
        std.testing.io,
        .awake,
        &counter,
        2,
    );
    try std.testing.expectEqual(@as(u64, 2), counter.value);
    try std.testing.expectEqual(@as(u64, 2), measured.result);
}

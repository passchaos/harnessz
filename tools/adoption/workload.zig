//! Deterministic workloads and timing styles used by the adoption tool.
//!
//! The "internal" style mirrors downstream ad-hoc harnesses: warmup followed by
//! one timed block, a ratio gate, and no significance test. The harnessz style
//! uses `bench.runRuntime` / `bench.compareMany` with sampled distributions.

const std = @import("std");
const harnessz = @import("harnessz");
const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;
const bench = harnessz.bench;

/// Deterministic CPU work with optional multiplicative jitter and a shared
/// drift clock that models a machine slowing down as the run progresses.
pub const Workload = struct {
    base_loops: u64,
    jitter_percent: u64 = 0,
    drift: ?*DriftState = null,
    calls: u64 = 0,
    state: u64,

    pub fn init(
        base_loops: u64,
        jitter_percent: u64,
        drift: ?*DriftState,
        seed: u64,
    ) Workload {
        return .{
            .base_loops = base_loops,
            .jitter_percent = jitter_percent,
            .drift = drift,
            .state = seed | 1,
        };
    }

    pub fn reset(self: *Workload) void {
        self.calls = 0;
        self.state = (self.state *% 6364136223846793005 +% 1442695040888963407) | 1;
    }

    pub fn run(self: *Workload, _: Allocator, _: std.Io) !u64 {
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

pub const DriftState = struct {
    progress: u64 = 0,
};

pub const NoopWorkload = struct {
    calls: u64 = 0,

    pub fn run(self: *NoopWorkload, _: Allocator, _: std.Io) !u64 {
        self.calls +%= 1;
        return self.calls;
    }
};

pub const RunnerContext = struct {
    workload: Workload,
};

pub fn runnerCallback(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    const runner: *RunnerContext = @ptrCast(@alignCast(context));
    return runner.workload.run(alloc, io);
}

pub fn noopRuntime(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    const workload: *NoopWorkload = @ptrCast(@alignCast(context));
    return workload.run(alloc, io);
}

/// Downstream style: warmup calls followed by one timed block; the result is
/// the per-call average.
pub fn internalBlock(
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
pub fn harnessBlock(
    alloc: Allocator,
    io: std.Io,
    workload: *Workload,
    config: Config,
) !bench.Stats {
    return bench.runRuntime(alloc, io, .{
        .warmup_iterations = config.warmup,
        .iterations = config.samples,
        .batch_size = config.iterations,
    }, workload, runnerCallback);
}

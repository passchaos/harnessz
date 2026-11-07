//! Real threaded determinism runs with per-lane buffers and spawn fallback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("options.zig").Options;
const oracle = @import("../oracle.zig");
const LockedAllocator = @import("../locked_allocator.zig").LockedAllocator;

pub const ThreadedReport = struct {
    /// Requested thread-count cases, in execution order.
    thread_counts: []const usize = &.{},
    /// Repetitions per thread-count case.
    thread_runs: usize = 0,
    stable: bool = true,
    /// Number of lanes that ran on the caller because `std.Thread.spawn`
    /// failed.
    spawn_fallbacks: usize = 0,
    /// Thread count of the case whose checksums are reported.
    case_thread_count: usize = 0,
    /// Per-thread checksums for the first divergent case, or the last case
    /// when all cases were stable. Owned by the report; call `deinit`.
    thread_checksums: []u64 = &.{},
    reference_checksum: u64 = 0,
    reference_len: usize = 0,
    /// Index of the first thread whose bytes differed from thread 0.
    first_divergence_thread: ?usize = null,
    divergence_offset: ?usize = null,
    divergence_checksum: ?u64 = null,
    divergence_len: ?usize = null,
    /// Set when a worker returned an error. The report remains valid so the
    /// caller can inspect checksums from the lanes that completed.
    worker_error: ?anyerror = null,
    worker_thread: ?usize = null,
    allocator: Allocator = std.heap.page_allocator,

    pub fn ok(self: ThreadedReport) bool {
        return self.stable and self.worker_error == null;
    }

    pub fn deinit(self: *ThreadedReport) void {
        if (self.thread_checksums.len != 0) {
            self.allocator.free(self.thread_checksums);
        }
        self.* = undefined;
    }
};

/// Spawn real OS threads for each entry in `options.thread_counts` and compare
/// every thread's output against thread 0.
///
/// Worker signature:
/// `fn (context, thread_index: usize, *std.Io.Writer) anyerror!void`
///
/// `options.thread_runs` controls repetitions per thread count. `options.runs`
/// is not used by this entry point. Each lane owns its output buffer; if a
/// spawn fails, that lane runs on the caller and `spawn_fallbacks` records it.
/// The returned report owns `thread_checksums`; call `deinit`.
pub fn runThreaded(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime worker: anytype,
) !ThreadedReport {
    return runThreadedImpl(alloc, io, options, context, worker, null);
}

fn runThreadedImpl(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime worker: anytype,
    simulated_spawn_failure_lane: ?usize,
) !ThreadedReport {
    if (options.thread_counts.len == 0) return error.InvalidOptions;
    if (options.thread_runs == 0) return error.InvalidOptions;

    var report: ThreadedReport = .{
        .thread_counts = options.thread_counts,
        .thread_runs = options.thread_runs,
        .allocator = alloc,
    };
    errdefer report.deinit();

    for (options.thread_counts) |thread_count| {
        if (thread_count == 0) return error.InvalidOptions;

        var run_index: usize = 0;
        while (run_index < options.thread_runs) : (run_index += 1) {
            var case = try runThreadCase(
                alloc,
                io,
                thread_count,
                options.max_bytes,
                context,
                worker,
                simulated_spawn_failure_lane,
            );
            defer case.deinit(alloc);

            if (report.thread_checksums.len != 0) {
                alloc.free(report.thread_checksums);
            }
            report.thread_checksums = case.checksums;
            case.checksums = &.{};
            report.case_thread_count = thread_count;
            report.reference_checksum = case.reference_checksum;
            report.reference_len = case.reference_len;
            report.spawn_fallbacks += case.spawn_fallbacks;

            if (case.worker_error) |err| {
                report.stable = false;
                report.worker_error = err;
                report.worker_thread = case.worker_thread;
                report.first_divergence_thread = case.worker_thread;
                return report;
            }
            if (!case.stable) {
                report.stable = false;
                report.first_divergence_thread = case.first_divergence_thread;
                report.divergence_offset = case.divergence_offset;
                report.divergence_checksum = case.divergence_checksum;
                report.divergence_len = case.divergence_len;
                return report;
            }
        }
    }

    return report;
}

const Lane = struct {
    index: usize,
    writer: std.Io.Writer.Allocating,
    err: ?anyerror = null,
};

const CaseReport = struct {
    checksums: []u64 = &.{},
    spawn_fallbacks: usize = 0,
    stable: bool = true,
    reference_checksum: u64 = 0,
    reference_len: usize = 0,
    first_divergence_thread: ?usize = null,
    divergence_offset: ?usize = null,
    divergence_checksum: ?u64 = null,
    divergence_len: ?usize = null,
    worker_error: ?anyerror = null,
    worker_thread: ?usize = null,
    allocator: Allocator = std.heap.page_allocator,

    fn deinit(self: *CaseReport, alloc: Allocator) void {
        if (self.checksums.len != 0) alloc.free(self.checksums);
        self.* = undefined;
    }
};

fn runThreadCase(
    alloc: Allocator,
    io: std.Io,
    thread_count: usize,
    max_bytes: usize,
    context: anytype,
    comptime worker: anytype,
    simulated_spawn_failure_lane: ?usize,
) !CaseReport {
    const Context = @TypeOf(context);
    const Runner = struct {
        fn run(ctx: Context, lane: *Lane) void {
            worker(ctx, lane.index, &lane.writer.writer) catch |err| {
                lane.err = err;
            };
        }
    };

    // Lane buffers are written concurrently. Serialize the caller-supplied
    // allocator so non-thread-safe allocators are still safe here.
    var locked: LockedAllocator = .{ .child = alloc, .io = io };
    const lane_allocator = locked.allocator();

    const lanes = try alloc.alloc(Lane, thread_count);
    defer alloc.free(lanes);

    var initialized: usize = 0;
    defer {
        while (initialized > 0) {
            initialized -= 1;
            lanes[initialized].writer.deinit();
        }
    }
    for (lanes, 0..) |*lane, index| {
        lane.* = .{
            .index = index,
            .writer = .init(lane_allocator),
        };
        initialized += 1;
    }

    const threads = try alloc.alloc(?std.Thread, thread_count);
    defer alloc.free(threads);
    @memset(threads, null);

    var spawn_fallbacks: usize = 0;
    for (lanes) |*lane| {
        const simulate_failure = if (simulated_spawn_failure_lane) |index|
            lane.index == index
        else
            false;

        if (!simulate_failure) {
            threads[lane.index] = std.Thread.spawn(.{}, Runner.run, .{ context, lane }) catch null;
        }
        if (threads[lane.index]) |thread| {
            _ = thread;
        } else {
            // Spawn failed (or was simulated): run this lane on the caller.
            spawn_fallbacks += 1;
            Runner.run(context, lane);
        }
    }

    for (threads) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }

    var worker_error: ?anyerror = null;
    var worker_thread: ?usize = null;
    for (lanes) |*lane| {
        if (lane.err) |err| {
            if (worker_error == null) {
                worker_error = err;
                worker_thread = lane.index;
            }
        }
    }

    var too_large = false;
    for (lanes) |*lane| {
        if (lane.writer.written().len > max_bytes) too_large = true;
    }

    const checksums = try alloc.alloc(u64, thread_count);
    errdefer alloc.free(checksums);
    for (lanes) |*lane| {
        checksums[lane.index] = oracle.checksum(lane.writer.written());
    }

    var case: CaseReport = .{
        .checksums = checksums,
        .spawn_fallbacks = spawn_fallbacks,
        .reference_checksum = checksums[0],
        .reference_len = lanes[0].writer.written().len,
        .worker_error = worker_error,
        .worker_thread = worker_thread,
        .allocator = alloc,
    };

    if (worker_error != null) {
        case.stable = false;
        return case;
    }
    if (too_large) return error.OutputTooLarge;

    const reference = lanes[0].writer.written();
    var index: usize = 1;
    while (index < lanes.len) : (index += 1) {
        const comparison = oracle.compareBytes(reference, lanes[index].writer.written());
        if (!comparison.equal) {
            case.stable = false;
            case.first_divergence_thread = index;
            case.divergence_offset = comparison.first_mismatch;
            case.divergence_checksum = checksums[index];
            case.divergence_len = lanes[index].writer.written().len;
            break;
        }
    }
    return case;
}

const ThreadedContext = struct {
    calls: std.atomic.Value(usize) = .init(0),
};

fn threadedStableWorker(
    context: *ThreadedContext,
    thread_index: usize,
    out: *std.Io.Writer,
) !void {
    _ = thread_index;
    _ = context.calls.fetchAdd(1, .monotonic);
    try out.writeAll("stable across threads\n");
}

fn threadedIndexedWorker(
    context: *ThreadedContext,
    thread_index: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    try out.print("thread={d}\n", .{thread_index});
}

fn threadedFailingWorker(
    context: *ThreadedContext,
    thread_index: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    if (thread_index == 1) return error.Boom;
    try out.writeAll("ok\n");
}

test "determinism threaded: stable producer passes with real threads" {
    var context: ThreadedContext = .{};
    var report = try runThreaded(std.testing.allocator, std.testing.io, .{
        .thread_counts = &.{ 1, 2, 4 },
        .thread_runs = 2,
    }, &context, threadedStableWorker);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expect(report.stable);
    try std.testing.expectEqual(@as(usize, 0), report.spawn_fallbacks);
    try std.testing.expectEqual(@as(usize, 4), report.case_thread_count);
    try std.testing.expectEqual(@as(usize, 4), report.thread_checksums.len);
    for (report.thread_checksums) |checksum| {
        try std.testing.expectEqual(oracle.checksum("stable across threads\n"), checksum);
    }
    try std.testing.expectEqual(@as(?usize, null), report.first_divergence_thread);
    try std.testing.expectEqual(@as(usize, 14), context.calls.load(.monotonic));
}

test "determinism threaded: thread-index-dependent producer fails" {
    var context: ThreadedContext = .{};
    var report = try runThreaded(std.testing.allocator, std.testing.io, .{
        .thread_counts = &.{4},
        .thread_runs = 1,
    }, &context, threadedIndexedWorker);
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expect(!report.stable);
    try std.testing.expectEqual(@as(?usize, 1), report.first_divergence_thread);
    try std.testing.expectEqual(@as(?usize, 7), report.divergence_offset);
    try std.testing.expectEqual(@as(?u64, oracle.checksum("thread=1\n")), report.divergence_checksum);
    try std.testing.expectEqual(@as(?usize, "thread=1\n".len), report.divergence_len);
    try std.testing.expectEqual(@as(usize, 4), report.thread_checksums.len);
    try std.testing.expectEqual(oracle.checksum("thread=0\n"), report.thread_checksums[0]);
    try std.testing.expectEqual(oracle.checksum("thread=3\n"), report.thread_checksums[3]);
}

test "determinism threaded: spawn failure falls back to the caller" {
    var context: ThreadedContext = .{};
    var report = try runThreadedImpl(std.testing.allocator, std.testing.io, .{
        .thread_counts = &.{2},
        .thread_runs = 1,
    }, &context, threadedStableWorker, 1);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.spawn_fallbacks);
    try std.testing.expectEqual(@as(usize, 2), report.thread_checksums.len);
    try std.testing.expectEqual(report.thread_checksums[0], report.thread_checksums[1]);
}

test "determinism threaded: worker errors are reported" {
    var context: ThreadedContext = .{};
    var report = try runThreaded(std.testing.allocator, std.testing.io, .{
        .thread_counts = &.{2},
        .thread_runs = 1,
    }, &context, threadedFailingWorker);
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(?anyerror, error.Boom), report.worker_error);
    try std.testing.expectEqual(@as(?usize, 1), report.worker_thread);
    try std.testing.expectEqual(@as(usize, 2), report.thread_checksums.len);
}

test "determinism threaded: invalid options" {
    var context: ThreadedContext = .{};
    try std.testing.expectError(error.InvalidOptions, runThreaded(
        std.testing.allocator,
        std.testing.io,
        .{ .thread_counts = &.{} },
        &context,
        threadedStableWorker,
    ));
    try std.testing.expectError(error.InvalidOptions, runThreaded(
        std.testing.allocator,
        std.testing.io,
        .{ .thread_counts = &.{2}, .thread_runs = 0 },
        &context,
        threadedStableWorker,
    ));
    try std.testing.expectError(error.InvalidOptions, runThreaded(
        std.testing.allocator,
        std.testing.io,
        .{ .thread_counts = &.{0}, .thread_runs = 1 },
        &context,
        threadedStableWorker,
    ));
}

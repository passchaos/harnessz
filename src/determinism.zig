//! Determinism checks: run a producer repeatedly and compare the bytes it
//! emits. An optional thread-count matrix verifies that the same producer is
//! stable across requested concurrency levels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oracle = @import("oracle.zig");

pub const Options = struct {
    /// Number of baseline executions at thread count 1. Must be at least 1.
    runs: usize = 3,
    /// Maximum accepted output size per execution.
    max_bytes: usize = 16 * 1024 * 1024,
    /// Additional thread counts to exercise. Empty disables the matrix.
    thread_counts: []const usize = &.{},
    /// Executions per thread count in the matrix.
    thread_runs: usize = 1,
};

pub const Report = struct {
    runs: usize,
    stable: bool = true,
    reference_checksum: u64 = 0,
    reference_len: usize = 0,
    first_divergence: ?usize = null,
    divergence_offset: ?usize = null,
    divergence_checksum: ?u64 = null,
    divergence_len: ?usize = null,
    thread_stable: bool = true,
    thread_counts: []const usize = &.{},
    thread_first_divergence: ?usize = null,
    thread_divergence_offset: ?usize = null,

    pub fn ok(self: Report) bool {
        return self.stable and self.thread_stable;
    }
};

/// Run `func` `options.runs` times with thread count 1 and compare the output.
/// If `options.thread_counts` is non-empty, also run the matrix and compare
/// each result against the baseline reference.
///
/// Callback signature:
/// `fn (context, allocator, io, threads, *std.Io.Writer) anyerror!void`
pub fn run(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime func: anytype,
) !Report {
    if (options.runs == 0) return error.InvalidOptions;

    var report: Report = .{
        .runs = options.runs,
        .thread_counts = options.thread_counts,
    };

    const reference = try capture(alloc, io, options.max_bytes, context, func, 1);
    defer alloc.free(reference);
    report.reference_checksum = oracle.checksum(reference);
    report.reference_len = reference.len;

    var run_index: usize = 1;
    while (run_index < options.runs) : (run_index += 1) {
        const output = try capture(alloc, io, options.max_bytes, context, func, 1);
        defer alloc.free(output);
        const comparison = oracle.compareBytes(reference, output);
        if (!comparison.equal) {
            report.stable = false;
            report.first_divergence = run_index;
            report.divergence_offset = comparison.first_mismatch;
            report.divergence_checksum = oracle.checksum(output);
            report.divergence_len = output.len;
            return report;
        }
    }

    if (options.thread_counts.len != 0) {
        if (options.thread_runs == 0) return error.InvalidOptions;
        matrix: for (options.thread_counts, 0..) |thread_count, count_index| {
            var thread_run: usize = 0;
            while (thread_run < options.thread_runs) : (thread_run += 1) {
                const output = try capture(
                    alloc,
                    io,
                    options.max_bytes,
                    context,
                    func,
                    thread_count,
                );
                defer alloc.free(output);
                const comparison = oracle.compareBytes(reference, output);
                if (!comparison.equal) {
                    report.thread_stable = false;
                    report.thread_first_divergence = count_index;
                    report.thread_divergence_offset = comparison.first_mismatch;
                    break :matrix;
                }
            }
        }
    }

    return report;
}

/// Explicit thread-matrix entry point. Equivalent to `run` with a non-empty
/// `thread_counts` option; returns `error.InvalidOptions` when the matrix is
/// empty.
pub fn runThreadMatrix(
    alloc: Allocator,
    io: std.Io,
    options: Options,
    context: anytype,
    comptime func: anytype,
) !Report {
    if (options.thread_counts.len == 0) return error.InvalidOptions;
    return run(alloc, io, options, context, func);
}

fn capture(
    alloc: Allocator,
    io: std.Io,
    max_bytes: usize,
    context: anytype,
    comptime func: anytype,
    threads: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try func(context, alloc, io, threads, &out.writer);
    const bytes = try out.toOwnedSlice();
    if (bytes.len > max_bytes) {
        alloc.free(bytes);
        return error.OutputTooLarge;
    }
    return bytes;
}

const StableContext = struct {
    calls: usize = 0,
};

fn stableProducer(
    context: *StableContext,
    alloc: Allocator,
    io: std.Io,
    threads: usize,
    out: *std.Io.Writer,
) !void {
    _ = alloc;
    _ = io;
    _ = threads;
    context.calls += 1;
    try out.writeAll("stable output\n");
}

fn unstableProducer(
    context: *StableContext,
    alloc: Allocator,
    io: std.Io,
    threads: usize,
    out: *std.Io.Writer,
) !void {
    _ = alloc;
    _ = io;
    _ = threads;
    context.calls += 1;
    try out.print("call={d}\n", .{context.calls});
}

fn threadInvariantProducer(
    context: *StableContext,
    alloc: Allocator,
    io: std.Io,
    threads: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    _ = alloc;
    _ = io;
    _ = threads;
    try out.writeAll("same regardless of threads\n");
}

fn threadVaryingProducer(
    context: *StableContext,
    alloc: Allocator,
    io: std.Io,
    threads: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    _ = alloc;
    _ = io;
    try out.print("threads={d}\n", .{threads});
}

test "determinism: stable output passes" {
    var context: StableContext = .{};
    const report = try run(std.testing.allocator, std.testing.io, .{ .runs = 4 }, &context, stableProducer);
    try std.testing.expect(report.ok());
    try std.testing.expect(report.stable);
    try std.testing.expectEqual(@as(?usize, null), report.first_divergence);
    try std.testing.expectEqual(@as(usize, 4), context.calls);
    try std.testing.expectEqual(oracle.checksum("stable output\n"), report.reference_checksum);
}

test "determinism: unstable output reports the first divergence" {
    var context: StableContext = .{};
    const report = try run(std.testing.allocator, std.testing.io, .{ .runs = 3 }, &context, unstableProducer);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(?usize, 1), report.first_divergence);
    try std.testing.expectEqual(@as(?usize, 5), report.divergence_offset);
    try std.testing.expectEqual(@as(?u64, oracle.checksum("call=2\n")), report.divergence_checksum);
    try std.testing.expectEqual(@as(?usize, "call=2\n".len), report.divergence_len);
}

test "determinism: thread matrix passes for invariant output" {
    var context: StableContext = .{};
    const report = try run(std.testing.allocator, std.testing.io, .{
        .runs = 2,
        .thread_counts = &.{ 1, 2, 4 },
        .thread_runs = 2,
    }, &context, threadInvariantProducer);
    try std.testing.expect(report.ok());
    try std.testing.expect(report.thread_stable);
    try std.testing.expectEqual(@as(?usize, null), report.thread_first_divergence);
}

test "determinism: thread matrix reports divergent output" {
    var context: StableContext = .{};
    const report = try run(std.testing.allocator, std.testing.io, .{
        .runs = 1,
        .thread_counts = &.{ 1, 2, 4 },
        .thread_runs = 1,
    }, &context, threadVaryingProducer);
    try std.testing.expect(!report.ok());
    try std.testing.expect(!report.thread_stable);
    try std.testing.expectEqual(@as(?usize, 1), report.thread_first_divergence);
    try std.testing.expectEqual(@as(?usize, 8), report.thread_divergence_offset);
}

test "determinism: explicit thread matrix entry point" {
    var context: StableContext = .{};
    const report = try runThreadMatrix(std.testing.allocator, std.testing.io, .{
        .runs = 1,
        .thread_counts = &.{ 1, 2 },
        .thread_runs = 1,
    }, &context, threadInvariantProducer);
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 2), report.thread_counts.len);
}

test "determinism: zero runs is invalid" {
    var context: StableContext = .{};
    try std.testing.expectError(error.InvalidOptions, run(
        std.testing.allocator,
        std.testing.io,
        .{ .runs = 0 },
        &context,
        stableProducer,
    ));
}

//! Example process-isolated benchmark child executable.
//!
//! It registers small deterministic benchmarks plus fixtures used by the
//! integration tests:
//!
//! - `checksum`     deterministic work used for protocol assertions
//! - `call-count`   returns a monotonic call counter (batch-size assertions)
//! - `alloc`        allocates a fixed buffer (memory-metric assertions)
//! - `slow`         sleeps long enough for the parent timeout to win
//! - `fail`         returns a benchmark error
//! - `stderr-ok`    writes a diagnostic to stderr and succeeds
//! - `stderr-fail`  writes a diagnostic to stderr and fails
//! - `stderr-flood` writes far more stderr than the parent retains
//! - `tree`         spawns a sleeping grandchild before blocking
//! - `invalid-output` writes invalid JSON to stdout (parent protocol test)
//! - `exit-failure`  exits nonzero without writing a response
//! - `empty-response` writes a valid response with no samples and exits
//!
//! `childMain` keeps stdout protocol-only; the malformed-response fixtures
//! deliberately violate that rule so the parent's error mapping can be
//! tested. All diagnostics go to stderr.

const std = @import("std");
const builtin = @import("builtin");
const harnessz = @import("harnessz");

const BenchContext = struct {
    /// Per-call sleep for the timeout test. Kept large enough that a short
    /// parent timeout wins even on a loaded machine.
    slow_ns: u64 = 2 * std.time.ns_per_s,
    /// Sleep after spawning the grandchild. Also larger than any test timeout.
    tree_sleep_ns: u64 = 10 * std.time.ns_per_s,
    /// Monotonic callback counter used to verify batch_size across the
    /// process boundary.
    calls: u64 = 0,
};

/// Deterministic FNV-1a-style checksum. The exact value is part of the test
/// fixture: integration tests assert it through the response checksum field.
fn checksumWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    _ = io;

    var hash: u64 = 0xcbf29ce484222325;
    var index: u64 = 0;
    while (index < 1024) : (index += 1) {
        hash ^= (index *% 0x9e3779b97f4a7c15) >> 7;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn callCountWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    context.calls += 1;
    return context.calls;
}

fn allocWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = io;
    const buffer = try alloc.alloc(u8, 4096);
    defer alloc.free(buffer);
    @memset(buffer, 0xab);
    return buffer.len;
}

fn slowWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = alloc;
    try io.sleep(std.Io.Duration.fromNanoseconds(@intCast(context.slow_ns)), .awake);
    return 1;
}

fn failingWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    _ = io;
    return error.SyntheticBenchFailure;
}

fn stderrOkWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "harnessz-bench-child: stderr-ok diagnostic\n",
    );
    return 42;
}

fn stderrFailWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "harnessz-bench-child: deliberate stderr failure\n",
    );
    return error.SyntheticBenchFailure;
}

fn stderrFloodWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    var written: usize = 0;
    while (written < 256 * 1024) : (written += chunk.len) {
        try std.Io.File.stderr().writeStreamingAll(io, &chunk);
    }
    return 7;
}

fn invalidOutputWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    // Deliberate protocol violation: the parent must report InvalidJson.
    try std.Io.File.stdout().writeStreamingAll(io, "not json");
    return 0;
}

fn exitFailureWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    _ = io;
    // Exit without a response so the parent reports ChildExitFailure.
    std.process.exit(7);
}

fn emptyResponseWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    // Deliberate early exit with a syntactically valid but empty response.
    try std.Io.File.stdout().writeStreamingAll(io, "{\"samples_ns\":[]}");
    std.process.exit(0);
}

fn treeWork(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    if (comptime harnessz.bench.watchdog.posix_process_control and builtin.os.tag == .linux) {
        return treeWorkPosix(context, alloc, io);
    } else {
        return error.Unsupported;
    }
}

fn treeWorkPosix(context: *BenchContext, alloc: std.mem.Allocator, io: std.Io) !u64 {
    _ = alloc;

    const grandchild = std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        // Do not let the grandchild hold the protocol pipes open.
        .stderr = .ignore,
    }) catch |err| {
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "harnessz-bench-child: grandchild spawn failed: {s}\n",
            .{@errorName(err)},
        ) catch "harnessz-bench-child: grandchild spawn failed\n";
        std.Io.File.stderr().writeStreamingAll(io, message) catch {};
        return err;
    };
    const grandchild_id = grandchild.id orelse return error.GrandchildSpawnFailed;

    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "harnessz-bench-child: pid={d} pgid={d} grandchild={d}\n",
        .{
            harnessz.bench.child.processId(),
            harnessz.bench.child.processGroupId(),
            grandchild_id,
        },
    ) catch "harnessz-bench-child: tree started\n";
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};

    try io.sleep(
        std.Io.Duration.fromNanoseconds(@intCast(context.tree_sleep_ns)),
        .awake,
    );
    return 1;
}

fn checksumEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return checksumWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn callCountEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return callCountWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn allocEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return allocWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn slowEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return slowWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn failingEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return failingWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn stderrOkEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return stderrOkWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn stderrFailEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return stderrFailWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn stderrFloodEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return stderrFloodWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn invalidOutputEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return invalidOutputWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn exitFailureEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return exitFailureWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn emptyResponseEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return emptyResponseWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn treeEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return treeWork(@ptrCast(@alignCast(context)), alloc, io);
}

pub fn main(init: std.process.Init) !u8 {
    var registry = harnessz.bench.registry.Registry.init(init.gpa);
    defer registry.deinit();

    var context: BenchContext = .{};
    try registry.add("checksum", .{ .context = &context, .run = checksumEntry });
    try registry.add("call-count", .{ .context = &context, .run = callCountEntry });
    try registry.add("alloc", .{ .context = &context, .run = allocEntry });
    try registry.add("slow", .{ .context = &context, .run = slowEntry });
    try registry.add("fail", .{ .context = &context, .run = failingEntry });
    try registry.add("stderr-ok", .{ .context = &context, .run = stderrOkEntry });
    try registry.add("stderr-fail", .{ .context = &context, .run = stderrFailEntry });
    try registry.add("stderr-flood", .{ .context = &context, .run = stderrFloodEntry });
    try registry.add("tree", .{ .context = &context, .run = treeEntry });
    try registry.add("invalid-output", .{ .context = &context, .run = invalidOutputEntry });
    try registry.add("exit-failure", .{ .context = &context, .run = exitFailureEntry });
    try registry.add("empty-response", .{ .context = &context, .run = emptyResponseEntry });

    return harnessz.bench.child.mainInit(init, &registry);
}

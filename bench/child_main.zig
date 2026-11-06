//! Example process-isolated benchmark child executable.
//!
//! It registers a small deterministic benchmark, a deliberately failing
//! benchmark, and a deliberately slow benchmark used by the timeout
//! integration test. `childMain` keeps stdout protocol-only.

const std = @import("std");
const harnessz = @import("harnessz");

const BenchContext = struct {
    /// Per-call sleep for the timeout test. Kept large enough that a short
    /// parent timeout wins even on a loaded machine.
    slow_ns: u64 = 2 * std.time.ns_per_s,
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

fn checksumEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return checksumWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn slowEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return slowWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn failingEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    return failingWork(@ptrCast(@alignCast(context)), alloc, io);
}

pub fn main(init: std.process.Init) !u8 {
    var registry = harnessz.bench.registry.Registry.init(init.gpa);
    defer registry.deinit();

    var context: BenchContext = .{};
    try registry.add("checksum", .{ .context = &context, .run = checksumEntry });
    try registry.add("slow", .{ .context = &context, .run = slowEntry });
    try registry.add("fail", .{ .context = &context, .run = failingEntry });

    return harnessz.bench.child.mainInit(init, &registry);
}

//! Host environment controls for benchmarks: CPU affinity, peak RSS, and a
//! counting allocator.
//!
//! Linux is the only supported platform for CPU pinning and RSS sampling.
//! Elsewhere these helpers return `error.Unsupported` so benchmarks can skip
//! the probe instead of failing.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// A process CPU-affinity mask.
pub const CpuMask = struct {
    set: std.os.linux.cpu_set_t,

    /// Whether `cpu` is a member of the mask.
    pub fn isSet(self: CpuMask, cpu: usize) bool {
        if (cpu >= std.os.linux.CPU_SETSIZE) return false;
        const word = cpu / @bitSizeOf(usize);
        const bit: std.math.Log2Int(usize) = @intCast(cpu % @bitSizeOf(usize));
        return (self.set[word] & (@as(usize, 1) << bit)) != 0;
    }

    /// Number of CPUs in the mask.
    pub fn count(self: CpuMask) usize {
        return std.os.linux.CPU_COUNT(self.set);
    }
};

/// Return the calling thread's current CPU-affinity mask.
///
/// Only Linux is supported; other platforms return `error.Unsupported`.
pub fn affinityMask() !CpuMask {
    if (comptime builtin.os.tag == .linux) {
        var set: std.os.linux.cpu_set_t = @splat(0);
        const rc = std.os.linux.sched_getaffinity(
            0,
            @sizeOf(std.os.linux.cpu_set_t),
            &set,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.Unsupported;
        return .{ .set = set };
    } else {
        return error.Unsupported;
    }
}

/// Pin the calling thread to `cpu`.
///
/// On Linux, `sched_setaffinity(0, ...)` affects the calling thread only;
/// other threads in the process keep their current masks. Save
/// `affinityMask()` and restore it when the benchmark finishes.
///
/// Only Linux is supported; other platforms return `error.Unsupported`.
/// `cpu` must be a valid CPU index and must be permitted by the current
/// affinity mask, otherwise `error.PinFailed` is returned.
pub fn pinToCpu(cpu: usize) !void {
    if (comptime builtin.os.tag == .linux) {
        if (cpu >= std.os.linux.CPU_SETSIZE) return error.InvalidCpu;

        var set: std.os.linux.cpu_set_t = @splat(0);
        const word = cpu / @bitSizeOf(usize);
        const bit: std.math.Log2Int(usize) = @intCast(cpu % @bitSizeOf(usize));
        set[word] = @as(usize, 1) << bit;

        std.os.linux.sched_setaffinity(0, &set) catch return error.PinFailed;
    } else {
        return error.Unsupported;
    }
}

/// Return the CPU the calling thread most recently ran on.
///
/// Only Linux is supported; other platforms (or kernels that reject the
/// `getcpu` syscall) return `error.Unsupported`.
pub fn currentCpu() !usize {
    if (comptime builtin.os.tag == .linux) {
        var cpu: usize = 0;
        const rc = std.os.linux.getcpu(&cpu, null);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.Unsupported;
        return cpu;
    } else {
        return error.Unsupported;
    }
}

/// Read the process peak resident set size (VmHWM) in bytes from
/// `/proc/self/status`.
///
/// Only Linux is supported; other platforms, or systems without procfs,
/// return `error.Unsupported`.
pub fn peakRssBytes(io: std.Io) !u64 {
    if (comptime builtin.os.tag == .linux) {
        var file = std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{}) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => return error.Unsupported,
            else => return err,
        };
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const bytes = reader.interface.allocRemaining(
            std.heap.page_allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.MalformedProcStatus,
            error.ReadFailed => return reader.err orelse error.ReadFailed,
        };
        defer std.heap.page_allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "VmHWM:")) continue;
            var tokens = std.mem.tokenizeAny(u8, line["VmHWM:".len..], " \t\r");
            const value = tokens.next() orelse return error.MalformedProcStatus;
            const kib = std.fmt.parseInt(u64, value, 10) catch return error.MalformedProcStatus;
            return std.math.mul(u64, kib, 1024) catch return error.MalformedProcStatus;
        }
        return error.MalformedProcStatus;
    } else {
        return error.Unsupported;
    }
}

/// Allocator wrapper that tracks live and peak allocated bytes.
///
/// The byte counts are the sum of requested allocation lengths, not the
/// underlying allocator's bookkeeping overhead. The wrapper is not
/// thread-safe; use one instance per benchmark lane.
pub const CountingAllocator = struct {
    child: Allocator,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,
    allocation_count: usize = 0,
    free_count: usize = 0,

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    /// An `Allocator` value that routes through this wrapper.
    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Bytes currently allocated through this wrapper.
    pub fn currentBytes(self: *const CountingAllocator) u64 {
        return @intCast(self.current_bytes);
    }

    /// Highest number of bytes allocated through this wrapper so far.
    pub fn peakBytes(self: *const CountingAllocator) u64 {
        return @intCast(self.peak_bytes);
    }

    /// Restart peak tracking at the current live byte count. Useful after a
    /// warmup phase so the peak covers the measured phase only.
    pub fn resetPeak(self: *CountingAllocator) void {
        self.peak_bytes = self.current_bytes;
    }

    /// Reset allocation and free counters without touching live/peak bytes.
    pub fn resetCounts(self: *CountingAllocator) void {
        self.allocation_count = 0;
        self.free_count = 0;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn noteAlloc(self: *CountingAllocator, len: usize) void {
        self.current_bytes +|= len;
        self.allocation_count +%= 1;
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
    }

    fn noteFree(self: *CountingAllocator, len: usize) void {
        self.current_bytes -|= len;
        self.free_count +%= 1;
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.noteAlloc(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.noteFree(memory.len);
        self.noteAlloc(new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse
            return null;
        self.noteFree(memory.len);
        self.noteAlloc(new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
        self.noteFree(memory.len);
    }
};

test "counting allocator: current and peak bytes" {
    var counting = CountingAllocator.init(std.heap.page_allocator);
    const alloc = counting.allocator();

    const first = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), counting.currentBytes());
    try std.testing.expectEqual(@as(u64, 100), counting.peakBytes());

    const second = try alloc.alloc(u8, 50);
    try std.testing.expectEqual(@as(u64, 150), counting.currentBytes());
    try std.testing.expectEqual(@as(u64, 150), counting.peakBytes());

    alloc.free(first);
    try std.testing.expectEqual(@as(u64, 50), counting.currentBytes());
    try std.testing.expectEqual(@as(u64, 150), counting.peakBytes());

    alloc.free(second);
    try std.testing.expectEqual(@as(u64, 0), counting.currentBytes());
    try std.testing.expectEqual(@as(u64, 150), counting.peakBytes());
    try std.testing.expectEqual(@as(usize, 2), counting.allocation_count);
    try std.testing.expectEqual(@as(usize, 2), counting.free_count);

    counting.resetPeak();
    try std.testing.expectEqual(@as(u64, 0), counting.peakBytes());

    counting.resetCounts();
    try std.testing.expectEqual(@as(usize, 0), counting.allocation_count);
    try std.testing.expectEqual(@as(usize, 0), counting.free_count);
    try std.testing.expectEqual(@as(u64, 0), counting.currentBytes());
}

test "counting allocator: allocation failure is not counted" {
    var counting = CountingAllocator.init(std.testing.failing_allocator);
    const alloc = counting.allocator();
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 64));
    try std.testing.expectEqual(@as(u64, 0), counting.currentBytes());
    try std.testing.expectEqual(@as(u64, 0), counting.peakBytes());
    try std.testing.expectEqual(@as(usize, 0), counting.allocation_count);
}

test "pinToCpu: pins to an allowed CPU and restores the original mask" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const original = affinityMask() catch return error.SkipZigTest;

    var cpu: ?usize = null;
    var index: usize = 0;
    while (index < std.os.linux.CPU_SETSIZE) : (index += 1) {
        if (original.isSet(index)) {
            cpu = index;
            break;
        }
    }
    const target = cpu orelse return error.SkipZigTest;

    defer std.os.linux.sched_setaffinity(0, &original.set) catch {};

    try pinToCpu(target);
    const pinned = try affinityMask();
    try std.testing.expect(pinned.isSet(target));
    try std.testing.expectEqual(@as(usize, 1), pinned.count());

    if (currentCpu()) |current| {
        try std.testing.expect(pinned.isSet(current));
        try std.testing.expectEqual(target, current);
    } else |_| {}
}

test "pinToCpu: invalid CPU is rejected" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(
        error.InvalidCpu,
        pinToCpu(std.os.linux.CPU_SETSIZE),
    );
}

test "peakRssBytes: reports a positive value" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const rss = peakRssBytes(std.testing.io) catch return error.SkipZigTest;
    try std.testing.expect(rss > 0);
}

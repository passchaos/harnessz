//! Bounded child-stderr capture for process-isolated benchmarks.
//!
//! The parent gives the child a stderr pipe and drains it on a dedicated
//! background task while stdout is read on the main task. Draining continues
//! after the retention limit is reached so a chatty child can never block on a
//! full pipe. Only the first `max_bytes` bytes are retained; the rest are
//! discarded and `truncated` is set.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Capture = struct {
    allocator: Allocator,
    io: std.Io,
    /// Read end of the child's stderr pipe. `run` closes it.
    file: std.Io.File,
    max_bytes: usize,
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    read_failed: bool = false,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        file: std.Io.File,
        max_bytes: usize,
    ) Capture {
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Capture) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Read until EOF, retaining at most `max_bytes`. This is the body run by
    /// the stderr capture thread; it closes the pipe on exit.
    pub fn run(self: *Capture) void {
        defer self.file.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var reader = self.file.readerStreaming(self.io, &read_buffer);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const count = reader.interface.readSliceShort(&chunk) catch |err| switch (err) {
                error.ReadFailed => {
                    self.read_failed = true;
                    return;
                },
            };
            if (count == 0) return;

            const remaining = self.max_bytes -| self.bytes.items.len;
            if (remaining == 0) {
                self.truncated = true;
                continue;
            }
            const keep = @min(remaining, count);
            self.bytes.appendSlice(self.allocator, chunk[0..keep]) catch {
                self.read_failed = true;
                self.truncated = true;
                continue;
            };
            if (keep < count) self.truncated = true;
        }
    }

    /// Transfer the retained bytes to the caller. The capture may still be
    /// deinitialized afterwards; an empty result is a static slice.
    pub fn toOwnedSlice(self: *Capture) Allocator.Error![]u8 {
        if (self.bytes.items.len == 0) return @constCast(&[_]u8{});
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

test "stderr capture: retains the bound and drains the rest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "0123456789abcdefghijklmnopqrstuv";
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr.txt", .data = payload });
    const file = try tmp.dir.openFile(io, "stderr.txt", .{});
    var capture = Capture.init(alloc, io, file, 8);
    defer capture.deinit();

    capture.run();

    try std.testing.expectEqualStrings("01234567", capture.bytes.items);
    try std.testing.expect(capture.truncated);
    try std.testing.expect(!capture.read_failed);

    const owned = try capture.toOwnedSlice();
    defer if (owned.len != 0) alloc.free(owned);
    try std.testing.expectEqualStrings("01234567", owned);
}

test "stderr capture: zero limit drains without retaining" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "stderr.txt", .data = "diagnostic" });
    const file = try tmp.dir.openFile(io, "stderr.txt", .{});
    var capture = Capture.init(alloc, io, file, 0);
    defer capture.deinit();

    capture.run();

    try std.testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
    try std.testing.expect(capture.truncated);
}

test "stderr capture: empty stream is not truncated" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    const file = try tmp.dir.openFile(io, "empty.txt", .{});
    var capture = Capture.init(alloc, io, file, 64);
    defer capture.deinit();

    capture.run();

    try std.testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
    try std.testing.expect(!capture.truncated);
    try std.testing.expect(!capture.read_failed);
}

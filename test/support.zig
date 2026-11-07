//! Shared helpers for process-isolated integration tests.

const std = @import("std");

pub fn expectedBenchChecksum() u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var index: u64 = 0;
    while (index < 1024) : (index += 1) {
        hash ^= (index *% 0x9e3779b97f4a7c15) >> 7;
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub fn diagnosticNumber(bytes: []const u8, marker: []const u8) !i64 {
    const start = std.mem.find(u8, bytes, marker) orelse
        return error.MissingDiagnostic;
    const rest = bytes[start + marker.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return error.MissingDiagnostic;
    return std.fmt.parseInt(i64, rest[0..end], 10);
}

pub fn expectProcGone(io: std.Io, pid: i64) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}", .{pid});
        const exists = blk: {
            std.Io.Dir.accessAbsolute(io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) return;
        try io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    return error.ProcessStillAlive;
}

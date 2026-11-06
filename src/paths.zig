//! Small path helpers shared by golden, snapshot, and fixture resolution.

const std = @import("std");

/// Reject empty, absolute, NUL-containing, and parent-traversing paths.
pub fn validRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// Test whether `path` exists relative to `dir` (or absolutely when the path
/// is absolute). Only `error.FileNotFound` is treated as absence.
pub fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    } else {
        dir.access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    }
    return true;
}

test "validRelative rejects escapes and absolute paths" {
    try std.testing.expect(validRelative("testdata/a.bin"));
    try std.testing.expect(validRelative("a/b/c"));
    try std.testing.expect(!validRelative(""));
    try std.testing.expect(!validRelative("../a"));
    try std.testing.expect(!validRelative("a/../../b"));
    try std.testing.expect(!validRelative("/etc/passwd"));
}

test "exists distinguishes present and missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "present", .data = "x" });
    try std.testing.expect(try exists(std.testing.io, tmp.dir, "present"));
    try std.testing.expect(!try exists(std.testing.io, tmp.dir, "missing"));
}

//! Environment lookup shared by golden, snapshot, and fixture resolution.
//!
//! An explicitly supplied environment always wins. Tests fall back to the
//! runner-provided environment; non-test callers that omit an environment get
//! "no environment" so environment-driven behaviour stays opt-in.

const std = @import("std");
const builtin = @import("builtin");

/// Return the environment block to use.
///
/// An explicitly supplied environment always wins. In tests, the runner-provided
/// environment is used when no explicit block is supplied. Applications should
/// pass `std.process.Init.environ` when they want environment-driven behaviour.
pub fn default(environ: ?std.process.Environ) ?std.process.Environ {
    if (environ) |e| return e;
    if (builtin.is_test) return std.testing.environ;
    return null;
}

/// Look up an environment variable and return an owned copy.
pub fn getOwned(
    alloc: std.mem.Allocator,
    environ: ?std.process.Environ,
    key: []const u8,
) !?[]u8 {
    const env = default(environ) orelse return null;
    var map = try std.process.Environ.createMap(env, alloc);
    defer map.deinit();
    const value = map.get(key) orelse return null;
    return try alloc.dupe(u8, value);
}

/// Return true when the variable is exactly `1` or `true` (ASCII case-insensitive).
pub fn flag(
    alloc: std.mem.Allocator,
    environ: ?std.process.Environ,
    key: []const u8,
) !bool {
    const value = (try getOwned(alloc, environ, key)) orelse return false;
    defer alloc.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

test "env lookup and flag semantics" {
    const alloc = std.testing.allocator;
    // PATH is virtually always present in the test runner environment.
    const path = try getOwned(alloc, null, "PATH");
    if (path) |value| {
        defer alloc.free(value);
        try std.testing.expect(value.len > 0);
    }
    try std.testing.expect(!try flag(alloc, null, "HARNESSZ_UPDATE_NOT_SET_FOR_TEST"));
}

test "explicit empty environment returns null" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try getOwned(alloc, std.process.Environ.empty, "PATH")) == null);
}

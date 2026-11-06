//! Fixture path resolution using `HARNESSZ_FIXTURES` or a `testdata/` fallback.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");
const paths = @import("paths.zig");

pub const Options = struct {
    /// Environment block used for `HARNESSZ_FIXTURES`.
    environ: ?std.process.Environ = null,
    /// Explicit root that takes precedence over the environment.
    fixtures_root: ?[]const u8 = null,
    /// Fallback root when the environment variable is unset.
    testdata_dir: []const u8 = "testdata",
    /// Directory used to check relative paths. Defaults to the process cwd.
    base_dir: ?std.Io.Dir = null,
    /// Return `error.FixtureNotFound` when the resolved path is absent.
    require_exists: bool = true,
};

pub const Source = enum { explicit, env, testdata };

pub const Resolved = struct {
    path: []u8,
    source: Source,

    pub fn deinit(self: *Resolved, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

/// Resolve a fixture-relative path against the configured root.
pub fn resolve(
    alloc: Allocator,
    io: std.Io,
    relative: []const u8,
    options: Options,
) !Resolved {
    if (!paths.validRelative(relative)) return error.InvalidPath;

    var env_root: ?[]u8 = null;
    defer if (env_root) |value| alloc.free(value);

    const root: []const u8, const source: Source = blk: {
        if (options.fixtures_root) |explicit| {
            break :blk .{ explicit, .explicit };
        }
        if (try env.getOwned(alloc, options.environ, "HARNESSZ_FIXTURES")) |value| {
            if (value.len != 0) {
                env_root = value;
                break :blk .{ value, .env };
            }
            alloc.free(value);
        }
        break :blk .{ options.testdata_dir, .testdata };
    };

    const joined = try std.fs.path.join(alloc, &.{ root, relative });
    errdefer alloc.free(joined);

    if (options.require_exists) {
        const dir = options.base_dir orelse std.Io.Dir.cwd();
        if (!try paths.exists(io, dir, joined)) return error.FixtureNotFound;
    }

    return .{ .path = joined, .source = source };
}

/// Absolute path of the current workspace (process cwd).
pub fn workspace(alloc: Allocator, io: std.Io) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    return alloc.dupe(u8, cwd);
}

/// Join a workspace-relative path with the current workspace path.
pub fn workspaceJoin(
    alloc: Allocator,
    io: std.Io,
    relative: []const u8,
) ![]u8 {
    if (!paths.validRelative(relative)) return error.InvalidPath;
    const cwd = try workspace(alloc, io);
    defer alloc.free(cwd);
    return std.fs.path.join(alloc, &.{ cwd, relative });
}

/// The directory handle corresponding to the workspace root.
pub fn workspaceDir() std.Io.Dir {
    return std.Io.Dir.cwd();
}

test "fixture: testdata fallback" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "testdata/images");
    try tmp.dir.writeFile(io, .{ .sub_path = "testdata/images/a.bin", .data = "abc" });

    var resolved = try resolve(alloc, io, "images/a.bin", .{ .base_dir = tmp.dir });
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Source.testdata, resolved.source);
    try std.testing.expectEqualStrings("testdata/images/a.bin", resolved.path);
}

test "fixture: explicit root wins over testdata" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "custom");
    try tmp.dir.writeFile(io, .{ .sub_path = "custom/a.bin", .data = "abc" });

    var resolved = try resolve(alloc, io, "a.bin", .{
        .base_dir = tmp.dir,
        .fixtures_root = "custom",
    });
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Source.explicit, resolved.source);
    try std.testing.expectEqualStrings("custom/a.bin", resolved.path);
}

test "fixture: HARNESSZ_FIXTURES environment root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "envdata");
    try tmp.dir.writeFile(io, .{ .sub_path = "envdata/a.bin", .data = "abc" });

    const raw_entries = [_]?[*:0]const u8{ "HARNESSZ_FIXTURES=envdata", null };
    const fake_environ: std.process.Environ = .{
        .block = .{ .slice = raw_entries[0..1 :null] },
    };

    var resolved = try resolve(alloc, io, "a.bin", .{
        .base_dir = tmp.dir,
        .environ = fake_environ,
    });
    defer resolved.deinit(alloc);

    try std.testing.expectEqual(Source.env, resolved.source);
    try std.testing.expectEqualStrings("envdata/a.bin", resolved.path);
}

test "fixture: missing and invalid paths" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.FixtureNotFound, resolve(
        alloc,
        io,
        "missing.bin",
        .{ .base_dir = tmp.dir },
    ));
    try std.testing.expectError(error.InvalidPath, resolve(
        alloc,
        io,
        "../escape.bin",
        .{ .base_dir = tmp.dir },
    ));
}

test "fixture: require_exists false returns the candidate path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var resolved = try resolve(alloc, io, "missing.bin", .{
        .base_dir = tmp.dir,
        .require_exists = false,
    });
    defer resolved.deinit(alloc);
    try std.testing.expectEqualStrings("testdata/missing.bin", resolved.path);
}

test "fixture: workspace helpers" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try workspace(alloc, io);
    defer alloc.free(cwd);
    try std.testing.expect(cwd.len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(cwd));

    const joined = try workspaceJoin(alloc, io, "src/root.zig");
    defer alloc.free(joined);
    try std.testing.expect(std.mem.endsWith(u8, joined, "src/root.zig"));
}

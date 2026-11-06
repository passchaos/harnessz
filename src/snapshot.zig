//! Named snapshot registry with in-memory and file-backed modes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("diff.zig");
const env = @import("env.zig");
const paths = @import("paths.zig");

pub const Options = struct {
    /// When non-null, snapshots are persisted under this directory. Otherwise
    /// the registry is purely in-memory and accepts the first value for a name.
    dir: ?std.Io.Dir = null,
    /// Directory prefix inside `dir` for persisted snapshots.
    prefix: []const u8 = "snapshots",
    /// Rewrite mismatched snapshots instead of failing.
    /// `HARNESSZ_UPDATE=1` (or `true`) also enables this.
    update: bool = false,
    max_bytes: usize = 64 * 1024 * 1024,
    max_diff_lines: usize = 40,
    context_lines: usize = 3,
    environ: ?std.process.Environ = null,
    /// Print diagnostics to stderr on mismatch.
    report: bool = true,
};

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    options: Options,
    update: bool,
    entries: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    checks: usize = 0,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        options: Options,
    ) !Registry {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .update = options.update or
                try env.flag(allocator, options.environ, "HARNESSZ_UPDATE"),
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn updateMode(self: *const Registry) bool {
        return self.update;
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Registry, name: []const u8) ?[]const u8 {
        return self.entries.get(name);
    }

    pub fn check(self: *Registry, name: []const u8, bytes: []const u8) !void {
        if (!paths.validRelative(name)) return error.InvalidSnapshotName;
        self.checks += 1;
        if (self.options.dir) |dir| return self.checkFile(dir, name, bytes);
        return self.checkMemory(name, bytes);
    }

    pub fn checkFmt(
        self: *Registry,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(rendered);
        try self.check(name, rendered);
    }

    fn checkMemory(self: *Registry, name: []const u8, bytes: []const u8) !void {
        if (self.entries.getPtr(name)) |value_ptr| {
            if (std.mem.eql(u8, value_ptr.*, bytes)) return;
            if (self.update) {
                const replacement = try self.allocator.dupe(u8, bytes);
                self.allocator.free(value_ptr.*);
                value_ptr.* = replacement;
                return;
            }
            if (self.options.report) self.reportMismatch(name, value_ptr.*, bytes);
            return error.SnapshotMismatch;
        }

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(value);
        try self.entries.put(self.allocator, key, value);
    }

    fn checkFile(self: *Registry, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
        const path = try self.snapshotPath(name);
        defer self.allocator.free(path);

        const existing = dir.readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(self.options.max_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            error.StreamTooLong => return error.SnapshotTooLarge,
            else => return err,
        };

        if (existing) |old| {
            defer self.allocator.free(old);
            if (std.mem.eql(u8, old, bytes)) {
                try self.remember(name, bytes);
                return;
            }
            if (self.update) {
                try self.writeSnapshot(dir, path, bytes);
                try self.remember(name, bytes);
                return;
            }
            if (self.options.report) self.reportMismatch(name, old, bytes);
            return error.SnapshotMismatch;
        }

        if (!self.update) return error.SnapshotMissing;
        try self.writeSnapshot(dir, path, bytes);
        try self.remember(name, bytes);
    }

    fn remember(self: *Registry, name: []const u8, bytes: []const u8) !void {
        if (self.entries.getPtr(name)) |value_ptr| {
            const replacement = try self.allocator.dupe(u8, bytes);
            self.allocator.free(value_ptr.*);
            value_ptr.* = replacement;
            return;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(value);
        try self.entries.put(self.allocator, key, value);
    }

    fn writeSnapshot(
        self: *Registry,
        dir: std.Io.Dir,
        path: []const u8,
        bytes: []const u8,
    ) !void {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) try dir.createDirPath(self.io, parent);
        }
        var file = try dir.createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
    }

    fn snapshotPath(self: *Registry, name: []const u8) ![]u8 {
        if (self.options.prefix.len != 0 and
            !paths.validRelative(self.options.prefix))
        {
            return error.InvalidSnapshotName;
        }
        const joined = if (self.options.prefix.len == 0)
            try self.allocator.dupe(u8, name)
        else
            try std.fs.path.join(self.allocator, &.{ self.options.prefix, name });
        defer self.allocator.free(joined);
        return std.fmt.allocPrint(self.allocator, "{s}.snap", .{joined});
    }

    fn reportMismatch(
        self: *Registry,
        name: []const u8,
        expected: []const u8,
        actual: []const u8,
    ) void {
        const rendered = diff.unified(self.allocator, expected, actual, .{
            .context = self.options.context_lines,
            .max_diff_lines = self.options.max_diff_lines,
            .header_a = name,
            .header_b = name,
        }) catch return;
        defer self.allocator.free(rendered);
        std.debug.print("snapshot mismatch: {s}\n{s}", .{ name, rendered });
    }
};

test "snapshot memory: accepts first value, matches second" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, std.testing.io, .{ .report = false });
    defer registry.deinit();

    try registry.check("greeting", "hello");
    try registry.check("greeting", "hello");
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqualStrings("hello", registry.get("greeting").?);
}

test "snapshot memory: mismatch fails and update rewrites" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, std.testing.io, .{ .report = false });
    defer registry.deinit();

    try registry.check("value", "old");
    try std.testing.expectError(error.SnapshotMismatch, registry.check("value", "new"));

    var updating = try Registry.init(alloc, std.testing.io, .{
        .update = true,
        .report = false,
    });
    defer updating.deinit();
    try updating.check("value", "old");
    try updating.check("value", "new");
    try std.testing.expectEqualStrings("new", updating.get("value").?);
}

test "snapshot file: create, match, mismatch, update" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var missing = try Registry.init(alloc, io, .{ .dir = tmp.dir, .report = false });
    defer missing.deinit();
    try std.testing.expectError(error.SnapshotMissing, missing.check("render/basic", "v1"));

    var writer = try Registry.init(alloc, io, .{
        .dir = tmp.dir,
        .update = true,
        .report = false,
    });
    defer writer.deinit();
    try writer.check("render/basic", "v1");
    try writer.check("render/basic", "v1");

    const stored = try tmp.dir.readFileAlloc(io, "snapshots/render/basic.snap", alloc, .limited(64));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("v1", stored);

    var reader = try Registry.init(alloc, io, .{ .dir = tmp.dir, .report = false });
    defer reader.deinit();
    try reader.check("render/basic", "v1");
    try std.testing.expectError(error.SnapshotMismatch, reader.check("render/basic", "v2"));

    try writer.check("render/basic", "v2");
    const updated = try tmp.dir.readFileAlloc(io, "snapshots/render/basic.snap", alloc, .limited(64));
    defer alloc.free(updated);
    try std.testing.expectEqualStrings("v2", updated);
}

test "snapshot fmt and invalid names" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, std.testing.io, .{ .report = false });
    defer registry.deinit();

    try registry.checkFmt("count", "n={d}", .{7});
    try std.testing.expectEqualStrings("n=7", registry.get("count").?);
    try std.testing.expectError(error.InvalidSnapshotName, registry.check("../escape", "x"));
    try std.testing.expectError(error.InvalidSnapshotName, registry.check("", "x"));
}

test "snapshot: invalid prefix is rejected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var registry = try Registry.init(alloc, std.testing.io, .{
        .dir = tmp.dir,
        .prefix = "../escape",
        .update = true,
        .report = false,
    });
    defer registry.deinit();
    try std.testing.expectError(error.InvalidSnapshotName, registry.check("value", "x"));
}

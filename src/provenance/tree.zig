//! Deterministic directory traversal for source and artifact hashing.
//!
//! `hashTree` hashes every regular file under a directory in sorted path
//! order. VCS/cache/output directories are skipped by default, and traversal
//! is bounded by file count and total bytes so an accidental large tree cannot
//! stall a build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_mod = @import("hash.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const TreeOptions = struct {
    /// Directory names skipped at any depth. Defaults to VCS/cache/output
    /// directories that should not affect a source fingerprint.
    skip_dirs: []const []const u8 = &.{ ".git", ".zig-cache", "zig-cache", "zig-out" },
    max_files: usize = 100_000,
    max_total_bytes: u64 = 4 * 1024 * 1024 * 1024,
    /// When true, symlinks to regular files are hashed as their target
    /// contents. Symlinked directories are never traversed.
    follow_symlinks: bool = false,
};

/// Deterministic SHA-256 over every regular file under `dir`.
///
/// The directory does not need to be opened with `.iterate = true`; `hashTree`
/// opens its own iterable handle. Paths are sorted lexicographically before
/// hashing. Each entry contributes its path length, path bytes, and the file's
/// SHA-256 digest. Files are bounded by `max_files` and `max_total_bytes`;
/// exceeding either returns `error.ProvenanceTooLarge`.
pub fn hashTree(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: TreeOptions,
) !hash_mod.Hash {
    var root = try dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| alloc.free(path);
        paths.deinit(alloc);
    }

    var total_bytes: u64 = 0;
    try collectTree(alloc, io, root, "", &paths, &total_bytes, options);
    std.mem.sort([]u8, paths.items, {}, pathLessThan);

    var hasher = Sha256.init(.{});
    for (paths.items) |path| {
        const digest = try hash_mod.hashFile(io, root, path);
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(path.len), .big);
        hasher.update(&length);
        hasher.update(path);
        hasher.update(&digest);
    }

    var result: hash_mod.Hash = undefined;
    hasher.final(&result);
    return result;
}

/// `hashTree` rendered as lowercase hex. Caller frees the result.
pub fn hashTreeHex(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: TreeOptions,
) ![]u8 {
    return hash_mod.hexAlloc(alloc, try hashTree(alloc, io, dir, options));
}

/// Deterministically list regular files under `dir`, sorted by relative path.
/// The same skip and bounds rules as `hashTree` apply. The caller owns the
/// outer slice and every path; free each with `allocator.free`.
pub fn listTree(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    options: TreeOptions,
) ![][]u8 {
    var root = try dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| alloc.free(path);
        paths.deinit(alloc);
    }
    var total_bytes: u64 = 0;
    try collectTree(alloc, io, root, "", &paths, &total_bytes, options);
    std.mem.sort([]u8, paths.items, {}, pathLessThan);
    return paths.toOwnedSlice(alloc);
}

const CollectError = Allocator.Error ||
    std.Io.Dir.Iterator.Error ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError ||
    error{ProvenanceTooLarge};

fn collectTree(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    paths: *std.ArrayList([]u8),
    total_bytes: *u64,
    options: TreeOptions,
) CollectError!void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (prefix.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });

        var owned = false;
        defer if (!owned) alloc.free(relative);

        switch (entry.kind) {
            .directory => {
                if (skipDirectory(entry.name, options.skip_dirs)) continue;
                try collectChildDir(
                    alloc,
                    io,
                    dir,
                    entry.name,
                    relative,
                    paths,
                    total_bytes,
                    options,
                );
            },
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                try appendTreePath(alloc, paths, relative, stat.size, total_bytes, options);
                owned = true;
            },
            .sym_link => {
                if (!options.follow_symlinks) continue;
                const stat = dir.statFile(io, entry.name, .{
                    .follow_symlinks = true,
                }) catch continue;
                if (stat.kind != .file) continue;
                try appendTreePath(alloc, paths, relative, stat.size, total_bytes, options);
                owned = true;
            },
            // Some filesystems report `.unknown` and require a stat to learn
            // the entry kind. Treat it exactly like a reported kind.
            .unknown => {
                const stat = dir.statFile(io, entry.name, .{
                    .follow_symlinks = options.follow_symlinks,
                }) catch continue;
                switch (stat.kind) {
                    .directory => {
                        if (skipDirectory(entry.name, options.skip_dirs)) continue;
                        try collectChildDir(
                            alloc,
                            io,
                            dir,
                            entry.name,
                            relative,
                            paths,
                            total_bytes,
                            options,
                        );
                    },
                    .file => {
                        try appendTreePath(
                            alloc,
                            paths,
                            relative,
                            stat.size,
                            total_bytes,
                            options,
                        );
                        owned = true;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn collectChildDir(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    relative: []const u8,
    paths: *std.ArrayList([]u8),
    total_bytes: *u64,
    options: TreeOptions,
) !void {
    var child = try dir.openDir(io, name, .{ .iterate = true });
    defer child.close(io);
    try collectTree(alloc, io, child, relative, paths, total_bytes, options);
}

fn appendTreePath(
    alloc: Allocator,
    paths: *std.ArrayList([]u8),
    relative: []u8,
    size: u64,
    total_bytes: *u64,
    options: TreeOptions,
) !void {
    if (paths.items.len >= options.max_files) return error.ProvenanceTooLarge;
    total_bytes.* = std.math.add(u64, total_bytes.*, size) catch
        return error.ProvenanceTooLarge;
    if (total_bytes.* > options.max_total_bytes) {
        return error.ProvenanceTooLarge;
    }
    try paths.append(alloc, relative);
}

fn skipDirectory(name: []const u8, skip_dirs: []const []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn pathLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "provenance tree: hash is deterministic and content-sensitive" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha" });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/b.txt", .data = "beta" });

    const first = try hashTree(alloc, io, tmp.dir, .{});
    const second = try hashTree(alloc, io, tmp.dir, .{});
    try std.testing.expectEqualSlices(u8, &first, &second);

    const hex = try hashTreeHex(alloc, io, tmp.dir, .{});
    defer alloc.free(hex);
    try std.testing.expectEqual(@as(usize, 64), hex.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "nested/b.txt", .data = "gamma" });
    const changed = try hashTree(alloc, io, tmp.dir, .{});
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "provenance tree: listTree returns sorted relative paths" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "z.txt", .data = "z" });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/a.txt", .data = "a" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/ignored", .data = "x" });

    const listed = try listTree(alloc, io, tmp.dir, .{});
    defer {
        for (listed) |path| alloc.free(path);
        alloc.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("nested/a.txt", listed[0]);
    try std.testing.expectEqualStrings("z.txt", listed[1]);
}

test "provenance tree: file symlinks are followed only when requested" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "alpha" });
    tmp.dir.symLink(io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const without_links = try hashTree(alloc, io, tmp.dir, .{});
    const with_links = try hashTree(alloc, io, tmp.dir, .{ .follow_symlinks = true });
    try std.testing.expect(!std.mem.eql(u8, &without_links, &with_links));

    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "beta" });
    const changed = try hashTree(alloc, io, tmp.dir, .{ .follow_symlinks = true });
    try std.testing.expect(!std.mem.eql(u8, &with_links, &changed));
}

test "provenance tree: cache directories are skipped and bounds are enforced" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha" });
    const before = try hashTree(alloc, io, tmp.dir, .{});

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/ignored", .data = "ignored" });
    const after = try hashTree(alloc, io, tmp.dir, .{});
    try std.testing.expectEqualSlices(u8, &before, &after);

    try std.testing.expectError(error.ProvenanceTooLarge, hashTree(
        alloc,
        io,
        tmp.dir,
        .{ .max_files = 0 },
    ));
}

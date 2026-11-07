//! Benchmark provenance: source/artifact hashing and a stable fingerprint for
//! baseline storage.
//!
//! The fingerprint is an opaque tag intended for `baseline.Entry.environment_fingerprint`.
//! It combines the target, CPU identity, build mode, source/binary hashes,
//! commit, dirty state, and a caller-supplied extra tag. Equality is the only
//! supported operation; the exact string format is not a stable API.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [Sha256.digest_length]u8;

/// SHA-256 of `bytes`.
pub fn hashBytes(bytes: []const u8) Hash {
    var digest: Hash = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// SHA-256 of `bytes`, rendered as lowercase hex. Caller frees the result.
pub fn hashBytesHex(alloc: Allocator, bytes: []const u8) ![]u8 {
    return hexAlloc(alloc, hashBytes(bytes));
}

/// SHA-256 of a file. `path` is relative to `dir` unless it is absolute.
pub fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8) !Hash {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try dir.openFile(io, path, .{});
    defer file.close(io);

    var hasher = Sha256.init(.{});
    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }

    var digest: Hash = undefined;
    hasher.final(&digest);
    return digest;
}

/// SHA-256 of a file, rendered as lowercase hex. Caller frees the result.
pub fn hashFileHex(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    return hexAlloc(alloc, try hashFile(io, dir, path));
}

/// Render a digest as lowercase hex. Caller frees the result.
pub fn hexAlloc(alloc: Allocator, digest: Hash) ![]u8 {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, encoded[0..]);
}

pub const LoadOptions = struct {
    max_bytes: u64 = 64 * 1024 * 1024,
    /// When false, a zero-length file returns `error.FileEmpty`.
    allow_empty: bool = true,
    /// Called after the bounded read and before the stability re-check. A
    /// hook that mutates the file makes the load fail with
    /// `error.ChangedDuringRead`.
    after_read: ?*const fn (?*anyopaque) anyerror!void = null,
    context: ?*anyopaque = null,
};

/// A verified file snapshot: owned bytes plus their SHA-256 digest.
pub const VerifiedFile = struct {
    allocator: Allocator,
    bytes: []u8,
    digest: Hash,

    pub fn deinit(self: *VerifiedFile) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Digest as lowercase hex. Caller frees the result.
    pub fn digestHex(self: VerifiedFile, alloc: Allocator) ![]u8 {
        return hexAlloc(alloc, self.digest);
    }
};

/// Read an absolute path as a stable, non-symlinked regular file and hash it.
///
/// The path is canonicalized and must equal the input (any symlinked component
/// is rejected), the opened inode must be a regular file, and the file
/// metadata must be unchanged before and after the read. The result owns the
/// bytes; call `deinit()`.
pub fn loadVerifiedFile(
    io: std.Io,
    alloc: Allocator,
    absolute_path: []const u8,
    options: LoadOptions,
) !VerifiedFile {
    if (std.mem.findScalar(u8, absolute_path, 0) != null) {
        return error.PathContainsNul;
    }
    if (!std.fs.path.isAbsolute(absolute_path)) return error.PathNotAbsolute;

    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        absolute_path,
        alloc,
    );
    defer alloc.free(canonical);
    if (!std.mem.eql(u8, canonical, absolute_path)) return error.SymlinkRejected;

    const path_stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{
        .follow_symlinks = false,
    });
    if (path_stat.kind == .sym_link) return error.SymlinkRejected;
    if (path_stat.kind != .file) return error.NotRegularFile;
    if (path_stat.size > options.max_bytes) return error.FileTooLarge;
    if (path_stat.size == 0 and !options.allow_empty) return error.FileEmpty;

    var file = try std.Io.Dir.cwd().openFile(io, absolute_path, .{
        .mode = .read_only,
        .allow_directory = true,
        .follow_symlinks = false,
    });
    defer file.close(io);

    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (!sameSnapshot(path_stat, before)) return error.ChangedDuringRead;
    if (before.size > options.max_bytes) return error.FileTooLarge;
    if (before.size == 0 and !options.allow_empty) return error.FileEmpty;

    const size = std.math.cast(usize, before.size) orelse return error.FileTooLarge;
    var reader: std.Io.File.Reader = .initSize(file, io, &.{}, before.size);
    const bytes = reader.interface.readAlloc(alloc, size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    errdefer alloc.free(bytes);

    if (options.after_read) |hook| try hook(options.context);

    const after = try file.stat(io);
    const final_path_stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{
        .follow_symlinks = false,
    });
    const final_canonical = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        absolute_path,
        alloc,
    );
    defer alloc.free(final_canonical);
    if (!sameSnapshot(before, after) or
        !sameSnapshot(before, final_path_stat) or
        !std.mem.eql(u8, final_canonical, absolute_path))
    {
        return error.ChangedDuringRead;
    }

    return .{
        .allocator = alloc,
        .bytes = bytes,
        .digest = hashBytes(bytes),
    };
}

fn sameSnapshot(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and
        a.inode == b.inode and
        a.nlink == b.nlink and
        a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds;
}

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
) !Hash {
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
        const digest = try hashFile(io, root, path);
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(path.len), .big);
        hasher.update(&length);
        hasher.update(path);
        hasher.update(&digest);
    }

    var result: Hash = undefined;
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
    return hexAlloc(alloc, try hashTree(alloc, io, dir, options));
}

pub const FingerprintOptions = struct {
    build_mode: []const u8 = "",
    source_hash: []const u8 = "",
    binary_hash: []const u8 = "",
    commit: []const u8 = "",
    dirty: bool = false,
    extra: []const u8 = "",
};

/// Build a stable environment fingerprint for `baseline.Entry`.
///
/// Linux probes for the CPU model and scaling governor; unsupported or
/// unreadable probes become `unknown` instead of failing the fingerprint.
pub fn fingerprint(
    alloc: Allocator,
    io: std.Io,
    options: FingerprintOptions,
) ![]u8 {
    const model = cpuModel(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (model) |value| alloc.free(value);

    const governor = cpuGovernor(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (governor) |value| alloc.free(value);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    return std.fmt.allocPrint(
        alloc,
        "{s}/{s}/cpu{d}/{s}/gov={s}/mode={s}/src={s}/bin={s}/commit={s}{s}/extra={s}",
        .{
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            cpu_count,
            model orelse "unknown",
            governor orelse "unknown",
            options.build_mode,
            options.source_hash,
            options.binary_hash,
            options.commit,
            if (options.dirty) "+dirty" else "",
            options.extra,
        },
    );
}

/// CPU model name from `/proc/cpuinfo`. Linux only; other platforms return
/// `error.Unsupported`.
pub fn cpuModel(alloc: Allocator, io: std.Io) ![]u8 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;

    const bytes = try readAbsolute(alloc, io, "/proc/cpuinfo", 1024 * 1024);
    defer alloc.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (value.len == 0) continue;
        return alloc.dupe(u8, value);
    }
    return error.Unsupported;
}

/// CPU scaling governor for CPU 0. Linux only; other platforms or missing
/// cpufreq data return `error.Unsupported`.
pub fn cpuGovernor(alloc: Allocator, io: std.Io) ![]u8 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;

    const bytes = readAbsolute(
        alloc,
        io,
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        => return error.Unsupported,
        else => return err,
    };
    defer alloc.free(bytes);

    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return error.Unsupported;
    return alloc.dupe(u8, value);
}

fn readAbsolute(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    return reader.interface.allocRemaining(alloc, .limited(limit));
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

test "provenance: SHA-256 of known bytes" {
    const digest = hashBytes("abc");
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &encoded,
    );

    const alloc = std.testing.allocator;
    const hex = try hashBytesHex(alloc, "abc");
    defer alloc.free(hex);
    try std.testing.expectEqualStrings(&encoded, hex);
}

test "provenance: file hashing matches byte hashing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "artifact.bin", .data = "abc" });
    const file_hash = try hashFile(io, tmp.dir, "artifact.bin");
    try std.testing.expectEqualSlices(u8, &hashBytes("abc"), &file_hash);

    const hex = try hashFileHex(alloc, io, tmp.dir, "artifact.bin");
    defer alloc.free(hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}

fn absolutePathInDir(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
) ![]u8 {
    const root = try dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

test "provenance: verified file load hashes stable regular files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "artifact.bin", .data = "abc" });
    const absolute = try absolutePathInDir(alloc, io, tmp.dir, "artifact.bin");
    defer alloc.free(absolute);

    var loaded = try loadVerifiedFile(io, alloc, absolute, .{});
    defer loaded.deinit();
    try std.testing.expectEqualStrings("abc", loaded.bytes);
    try std.testing.expectEqualSlices(u8, &hashBytes("abc"), &loaded.digest);

    const hex = try loaded.digestHex(alloc);
    defer alloc.free(hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}

test "provenance: verified file load rejects relative, empty, and oversized files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.PathNotAbsolute,
        loadVerifiedFile(io, alloc, "relative.bin", .{}),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.bin", .data = "" });
    const empty_path = try absolutePathInDir(alloc, io, tmp.dir, "empty.bin");
    defer alloc.free(empty_path);

    var empty = try loadVerifiedFile(io, alloc, empty_path, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
    try std.testing.expectError(
        error.FileEmpty,
        loadVerifiedFile(io, alloc, empty_path, .{ .allow_empty = false }),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "abc" });
    const big_path = try absolutePathInDir(alloc, io, tmp.dir, "big.bin");
    defer alloc.free(big_path);
    try std.testing.expectError(
        error.FileTooLarge,
        loadVerifiedFile(io, alloc, big_path, .{ .max_bytes = 2 }),
    );
}

test "provenance: verified file load rejects symlinks" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "target.bin", .data = "abc" });
    tmp.dir.symLink(io, "target.bin", "link.bin", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const link_path = try absolutePathInDir(alloc, io, tmp.dir, "link.bin");
    defer alloc.free(link_path);

    try std.testing.expectError(
        error.SymlinkRejected,
        loadVerifiedFile(io, alloc, link_path, .{}),
    );
}

const MutateContext = struct {
    io: std.Io,
    path: []const u8,
};

fn mutateFile(context: ?*anyopaque) anyerror!void {
    const typed: *MutateContext = @ptrCast(@alignCast(context.?));
    var file = try std.Io.Dir.createFileAbsolute(typed.io, typed.path, .{});
    defer file.close(typed.io);
    try file.writeStreamingAll(typed.io, "changed-and-longer");
}

test "provenance: verified file load detects a file changed during read" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "artifact.bin", .data = "abc" });
    const absolute = try absolutePathInDir(alloc, io, tmp.dir, "artifact.bin");
    defer alloc.free(absolute);

    var context: MutateContext = .{ .io = io, .path = absolute };
    try std.testing.expectError(
        error.ChangedDuringRead,
        loadVerifiedFile(io, alloc, absolute, .{
            .after_read = mutateFile,
            .context = &context,
        }),
    );
}

test "provenance: tree hash is deterministic and content-sensitive" {
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

test "provenance: tree hash follows file symlinks only when requested" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
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

test "provenance: tree hash skips cache directories and enforces bounds" {
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

test "provenance: fingerprint is stable and includes caller fields" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const options: FingerprintOptions = .{
        .build_mode = "ReleaseFast",
        .source_hash = "source123",
        .binary_hash = "binary456",
        .commit = "deadbeef",
        .dirty = true,
        .extra = "local",
    };

    const first = try fingerprint(alloc, io, options);
    defer alloc.free(first);
    const second = try fingerprint(alloc, io, options);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);

    try std.testing.expect(std.mem.find(u8, first, "mode=ReleaseFast") != null);
    try std.testing.expect(std.mem.find(u8, first, "src=source123") != null);
    try std.testing.expect(std.mem.find(u8, first, "bin=binary456") != null);
    try std.testing.expect(std.mem.find(u8, first, "commit=deadbeef+dirty") != null);
    try std.testing.expect(std.mem.find(u8, first, "extra=local") != null);

    const other = try fingerprint(alloc, io, .{
        .build_mode = "ReleaseFast",
        .source_hash = "source123",
        .binary_hash = "binary456",
        .commit = "deadbeef",
        .dirty = true,
        .extra = "other",
    });
    defer alloc.free(other);
    try std.testing.expect(!std.mem.eql(u8, first, other));
}

test "provenance: Linux CPU probes or unsupported" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const model = cpuModel(alloc, io) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(model);
    try std.testing.expect(model.len > 0);

    const governor = cpuGovernor(alloc, io) catch |err| switch (err) {
        error.Unsupported => return,
        else => return err,
    };
    defer alloc.free(governor);
    try std.testing.expect(governor.len > 0);
}

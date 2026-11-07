//! SHA-256 hashing for bytes, files, and verified file snapshots.
//!
//! `loadVerifiedFile` is the strict entry point for benchmark artifacts and
//! dependency closures: it rejects symlinked paths, non-regular files,
//! empty/oversized inputs, and files that change during the read.

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

test "provenance hash: SHA-256 of known bytes" {
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

test "provenance hash: file hashing matches byte hashing" {
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

test "provenance hash: verified file load hashes stable regular files" {
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

test "provenance hash: verified file load rejects relative, empty, and oversized files" {
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

test "provenance hash: verified file load rejects symlinks" {
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

test "provenance hash: verified file load detects a file changed during read" {
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

//! Artifact manifests: JSON lists of relative paths and SHA-256 digests with
//! verification against a directory tree.
//!
//! This replaces the per-repository artifact-descriptor checks used by
//! downstream benchmark pipelines: a manifest is strict JSON, paths must stay
//! relative, digests must be lowercase SHA-256 hex, and verification reports
//! missing, mismatched, and (optionally) extra files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provenance = @import("provenance.zig");
const paths = @import("paths.zig");

pub const Entry = struct {
    path: []const u8,
    /// Lowercase SHA-256 hex.
    sha256: []const u8,
};

const Wire = struct {
    artifacts: []const Entry = &.{},
};

pub const Manifest = struct {
    allocator: Allocator,
    arena: ?*std.heap.ArenaAllocator = null,
    artifacts: []const Entry = &.{},

    /// Borrow caller-owned entries. `deinit` only releases manifest-owned
    /// storage, so borrowed entries stay valid as long as the caller keeps
    /// them alive.
    pub fn init(allocator: Allocator, artifacts: []const Entry) Manifest {
        return .{ .allocator = allocator, .artifacts = artifacts };
    }

    pub fn deinit(self: *Manifest) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    /// Parse strict JSON. Unknown or duplicate fields, invalid paths, invalid
    /// digests, and duplicate paths are rejected.
    pub fn fromJson(allocator: Allocator, bytes: []const u8) !Manifest {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();

        const wire = std.json.parseFromSliceLeaky(
            Wire,
            arena.allocator(),
            bytes,
            .{ .allocate = .alloc_always },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidManifest,
        };

        for (wire.artifacts, 0..) |entry, index| {
            if (!paths.validRelative(entry.path)) return error.InvalidManifest;
            if (!isLowerSha256(entry.sha256)) return error.InvalidManifest;
            for (wire.artifacts[0..index]) |previous| {
                if (std.mem.eql(u8, previous.path, entry.path)) {
                    return error.DuplicateEntry;
                }
            }
        }

        return .{
            .allocator = allocator,
            .arena = arena,
            .artifacts = wire.artifacts,
        };
    }

    pub fn toJson(self: Manifest, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(Wire{ .artifacts = self.artifacts }, .{
            .whitespace = .indent_2,
        }, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn save(
        self: Manifest,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        if (!paths.validRelative(path)) return error.InvalidPath;

        const json = try self.toJson(self.allocator);
        defer self.allocator.free(json);

        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) try dir.createDirPath(io, parent);
        }
        try dir.writeFile(io, .{ .sub_path = path, .data = json });
    }

    pub fn load(
        allocator: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Manifest {
        if (!paths.validRelative(path)) return error.InvalidPath;

        const bytes = dir.readFileAlloc(
            io,
            path,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.ManifestTooLarge,
            else => return err,
        };
        defer allocator.free(bytes);
        return fromJson(allocator, bytes);
    }

    pub fn has(self: Manifest, path: []const u8) bool {
        for (self.artifacts) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return true;
        }
        return false;
    }

    /// Hash every artifact and compare it with the recorded digest. The
    /// returned report owns its strings; call `deinit()`.
    pub fn verify(
        self: Manifest,
        io: std.Io,
        dir: std.Io.Dir,
        options: VerifyOptions,
    ) !VerifyReport {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = .init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var missing: std.ArrayList([]const u8) = .empty;
        var mismatched: std.ArrayList(Mismatch) = .empty;
        var present: usize = 0;

        for (self.artifacts) |entry| {
            const actual = provenance.hashFileHex(alloc, io, dir, entry.path) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.IsDir => {
                    try missing.append(alloc, try alloc.dupe(u8, entry.path));
                    continue;
                },
                else => return err,
            };
            present += 1;
            if (std.mem.eql(u8, actual, entry.sha256)) continue;

            try mismatched.append(alloc, .{
                .path = try alloc.dupe(u8, entry.path),
                .expected = try alloc.dupe(u8, entry.sha256),
                .actual = actual,
            });
        }

        var extra: [][]const u8 = &.{};
        if (options.reject_extra) {
            const listed = try provenance.listTree(alloc, io, dir, .{
                .skip_dirs = options.skip_dirs,
                .max_files = options.max_files,
                .max_total_bytes = options.max_total_bytes,
            });
            var extra_list: std.ArrayList([]const u8) = .empty;
            for (listed) |path| {
                if (self.has(path)) continue;
                try extra_list.append(alloc, path);
            }
            extra = try extra_list.toOwnedSlice(alloc);
        }

        return .{
            .allocator = self.allocator,
            .arena = arena,
            .missing = try missing.toOwnedSlice(alloc),
            .mismatched = try mismatched.toOwnedSlice(alloc),
            .extra = extra,
            .present = present,
            .total = self.artifacts.len,
        };
    }
};

pub const VerifyOptions = struct {
    /// Report files under the tree that are not in the manifest.
    reject_extra: bool = false,
    skip_dirs: []const []const u8 = &.{ ".git", ".zig-cache", "zig-cache", "zig-out" },
    max_files: usize = 100_000,
    max_total_bytes: u64 = 4 * 1024 * 1024 * 1024,
};

pub const Mismatch = struct {
    path: []const u8,
    expected: []const u8,
    actual: []const u8,
};

pub const VerifyReport = struct {
    allocator: Allocator = std.heap.page_allocator,
    arena: ?*std.heap.ArenaAllocator = null,
    missing: [][]const u8 = &.{},
    mismatched: []Mismatch = &.{},
    extra: [][]const u8 = &.{},
    /// Artifacts that exist on disk (matched or mismatched).
    present: usize = 0,
    /// Total artifacts in the manifest.
    total: usize = 0,

    pub fn deinit(self: *VerifyReport) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    pub fn ok(self: VerifyReport) bool {
        return self.missing.len == 0 and
            self.mismatched.len == 0 and
            self.extra.len == 0;
    }
};

fn isLowerSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test "artifact: JSON round-trip and strict validation" {
    const alloc = std.testing.allocator;
    const alpha = try provenance.hashBytesHex(alloc, "alpha");
    defer alloc.free(alpha);
    const beta = try provenance.hashBytesHex(alloc, "beta");
    defer alloc.free(beta);

    const json = try std.fmt.allocPrint(
        alloc,
        "{{\"artifacts\":[{{\"path\":\"a.bin\",\"sha256\":\"{s}\"}},{{\"path\":\"nested/b.bin\",\"sha256\":\"{s}\"}}]}}",
        .{ alpha, beta },
    );
    defer alloc.free(json);

    var manifest = try Manifest.fromJson(alloc, json);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.artifacts.len);
    try std.testing.expectEqualStrings("a.bin", manifest.artifacts[0].path);
    try std.testing.expect(manifest.has("nested/b.bin"));
    try std.testing.expect(!manifest.has("missing.bin"));

    const emitted = try manifest.toJson(alloc);
    defer alloc.free(emitted);
    var reparsed = try Manifest.fromJson(alloc, emitted);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(
        manifest.artifacts[1].sha256,
        reparsed.artifacts[1].sha256,
    );

    try std.testing.expectError(
        error.InvalidManifest,
        Manifest.fromJson(alloc, "{\"artifacts\":[{\"path\":\"a\",\"sha256\":\"bad\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        Manifest.fromJson(alloc, "{\"artifacts\":[{\"path\":\"/abs\",\"sha256\":\"" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "\"}]}"),
    );
    try std.testing.expectError(
        error.DuplicateEntry,
        Manifest.fromJson(alloc, "{\"artifacts\":[{\"path\":\"a\",\"sha256\":\"" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "\"},{\"path\":\"a\",\"sha256\":\"" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        Manifest.fromJson(alloc, "{\"artifacts\":[{\"path\":\"a\",\"sha256\":\"" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "\",\"extra\":1}]}"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        Manifest.fromJson(alloc, "{\"artifacts\":[{\"path\":\"a\"}]}"),
    );
}

test "artifact: verify reports match, mismatch, missing, and extra files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.bin", .data = "alpha" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.bin", .data = "beta" });

    const alpha = try provenance.hashBytesHex(alloc, "alpha");
    defer alloc.free(alpha);
    const beta = try provenance.hashBytesHex(alloc, "beta");
    defer alloc.free(beta);
    const wrong = try provenance.hashBytesHex(alloc, "gamma");
    defer alloc.free(wrong);

    const entries = [_]Entry{
        .{ .path = "a.bin", .sha256 = alpha },
        .{ .path = "b.bin", .sha256 = wrong },
        .{ .path = "c.bin", .sha256 = alpha },
    };
    var manifest = Manifest.init(alloc, &entries);
    defer manifest.deinit();

    var report = try manifest.verify(io, tmp.dir, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.missing.len);
    try std.testing.expectEqual(@as(usize, 1), report.mismatched.len);
    try std.testing.expectEqual(@as(usize, 0), report.extra.len);
    try std.testing.expectEqual(@as(usize, 2), report.present);
    try std.testing.expectEqual(@as(usize, 3), report.total);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("b.bin", report.mismatched[0].path);
    try std.testing.expectEqualStrings(wrong, report.mismatched[0].expected);
    try std.testing.expectEqualStrings(beta, report.mismatched[0].actual);

    try tmp.dir.writeFile(io, .{ .sub_path = "extra.bin", .data = "extra" });
    var extra_report = try manifest.verify(io, tmp.dir, .{ .reject_extra = true });
    defer extra_report.deinit();
    try std.testing.expectEqual(@as(usize, 1), extra_report.extra.len);
    try std.testing.expectEqualStrings("extra.bin", extra_report.extra[0]);

    const correct = [_]Entry{
        .{ .path = "a.bin", .sha256 = alpha },
        .{ .path = "b.bin", .sha256 = wrong },
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "b.bin", .data = "gamma" });
    var correct_manifest = Manifest.init(alloc, &correct);
    defer correct_manifest.deinit();
    var ok_report = try correct_manifest.verify(io, tmp.dir, .{});
    defer ok_report.deinit();
    try std.testing.expect(ok_report.ok());
    try std.testing.expectEqual(@as(usize, 2), ok_report.present);
}

test "artifact: save, load, and invalid paths" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const digest = try provenance.hashBytesHex(alloc, "alpha");
    defer alloc.free(digest);
    const entries = [_]Entry{.{ .path = "a.bin", .sha256 = digest }};
    const manifest = Manifest.init(alloc, &entries);

    try manifest.save(io, tmp.dir, "meta/artifacts.json");
    var loaded = try Manifest.load(alloc, io, tmp.dir, "meta/artifacts.json");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.artifacts.len);
    try std.testing.expectEqualStrings("a.bin", loaded.artifacts[0].path);

    try std.testing.expectError(
        error.InvalidPath,
        manifest.save(io, tmp.dir, "../escape.json"),
    );
    try std.testing.expectError(
        error.InvalidPath,
        Manifest.load(alloc, io, tmp.dir, "/absolute.json"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        Manifest.load(alloc, io, tmp.dir, "missing.json"),
    );
}

test "artifact: empty manifest verifies cleanly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manifest = try Manifest.fromJson(alloc, "{\"artifacts\":[]}");
    defer manifest.deinit();
    var report = try manifest.verify(std.testing.io, tmp.dir, .{});
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 0), report.total);
}

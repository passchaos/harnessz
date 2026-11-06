//! Evidence manifests: machine-readable implementation/test/evidence status.

const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");

pub const Status = enum {
    implemented,
    partial,
    planned,
    deferred,
};

pub const Entry = struct {
    id: []const u8,
    status: Status = .planned,
    implementation_paths: []const []const u8 = &.{},
    test_names: []const []const u8 = &.{},
    evidence_paths: []const []const u8 = &.{},
    notes: []const u8 = "",
};

pub const Summary = struct {
    total: usize = 0,
    implemented: usize = 0,
    partial: usize = 0,
    planned: usize = 0,
    deferred: usize = 0,
    with_evidence: usize = 0,
};

pub const PathKind = enum { implementation, evidence };

pub const MissingPath = struct {
    entry_id: []const u8,
    path: []const u8,
    kind: PathKind,
};

pub const ValidationReport = struct {
    total_paths: usize,
    missing: []const MissingPath,
    allocator: Allocator,

    pub fn valid(self: ValidationReport) bool {
        return self.missing.len == 0;
    }

    pub fn deinit(self: *ValidationReport) void {
        self.allocator.free(self.missing);
        self.* = undefined;
    }
};

/// Wire representation. Keeping this separate from `Manifest` prevents
/// allocator/arena bookkeeping fields from entering the JSON schema.
const Wire = struct {
    entries: []const Entry = &.{},
};

pub const Manifest = struct {
    entries: []const Entry = &.{},
    allocator: Allocator = std.heap.page_allocator,
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn init(allocator: Allocator) Manifest {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manifest) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    pub fn toJson(self: Manifest, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(Wire{ .entries = self.entries }, .{
            .whitespace = .indent_2,
        }, &out.writer);
        return out.toOwnedSlice();
    }

    /// Parse a manifest. All returned slices are owned by the manifest and
    /// released by `deinit`.
    pub fn fromJson(allocator: Allocator, bytes: []const u8) !Manifest {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();

        const wire = try std.json.parseFromSliceLeaky(
            Wire,
            arena.allocator(),
            bytes,
            .{},
        );
        return .{
            .entries = wire.entries,
            .allocator = allocator,
            .arena = arena,
        };
    }

    pub fn summary(self: Manifest) Summary {
        var result: Summary = .{ .total = self.entries.len };
        for (self.entries) |entry| {
            switch (entry.status) {
                .implemented => result.implemented += 1,
                .partial => result.partial += 1,
                .planned => result.planned += 1,
                .deferred => result.deferred += 1,
            }
            if (entry.evidence_paths.len != 0) result.with_evidence += 1;
        }
        return result;
    }

    /// Check implementation and evidence paths against `dir`. Missing paths
    /// are returned in the report; other filesystem errors are propagated.
    pub fn validatePaths(
        self: *Manifest,
        io: std.Io,
        dir: std.Io.Dir,
    ) !ValidationReport {
        var missing: std.ArrayList(MissingPath) = .empty;
        errdefer missing.deinit(self.allocator);
        var total_paths: usize = 0;

        for (self.entries) |entry| {
            for (entry.implementation_paths) |path| {
                total_paths += 1;
                if (!try paths.exists(io, dir, path)) {
                    try missing.append(self.allocator, .{
                        .entry_id = entry.id,
                        .path = path,
                        .kind = .implementation,
                    });
                }
            }
            for (entry.evidence_paths) |path| {
                total_paths += 1;
                if (!try paths.exists(io, dir, path)) {
                    try missing.append(self.allocator, .{
                        .entry_id = entry.id,
                        .path = path,
                        .kind = .evidence,
                    });
                }
            }
        }

        return .{
            .total_paths = total_paths,
            .missing = try missing.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }
};

test "evidence: JSON round-trip" {
    const alloc = std.testing.allocator;
    const manifest: Manifest = .{
        .allocator = alloc,
        .entries = &.{
            .{
                .id = "golden",
                .status = .implemented,
                .implementation_paths = &.{ "src/golden.zig", "src/diff.zig" },
                .test_names = &.{"golden: first run creates, second matches"},
                .evidence_paths = &.{"docs/evidence/golden.md"},
                .notes = "golden files and update mode",
            },
            .{
                .id = "bench",
                .status = .partial,
                .implementation_paths = &.{"src/bench.zig"},
                .test_names = &.{"bench gate: synthetic samples"},
                .notes = "timing gates are synthetic only",
            },
        },
    };

    const json = try manifest.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"implemented\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"partial\"") != null);

    var parsed = try Manifest.fromJson(alloc, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("golden", parsed.entries[0].id);
    try std.testing.expectEqual(Status.implemented, parsed.entries[0].status);
    try std.testing.expectEqualStrings("src/golden.zig", parsed.entries[0].implementation_paths[0]);
    try std.testing.expectEqualStrings("docs/evidence/golden.md", parsed.entries[0].evidence_paths[0]);
    try std.testing.expectEqualStrings("golden files and update mode", parsed.entries[0].notes);
    try std.testing.expectEqual(Status.partial, parsed.entries[1].status);
    try std.testing.expectEqual(@as(usize, 0), parsed.entries[1].evidence_paths.len);
}

test "evidence: summary counts statuses and evidence" {
    const manifest: Manifest = .{
        .entries = &.{
            .{ .id = "a", .status = .implemented, .evidence_paths = &.{"docs/a.md"} },
            .{ .id = "b", .status = .partial },
            .{ .id = "c", .status = .planned },
            .{ .id = "d", .status = .deferred, .evidence_paths = &.{"docs/d.md"} },
        },
    };
    const summary = manifest.summary();
    try std.testing.expectEqual(@as(usize, 4), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.implemented);
    try std.testing.expectEqual(@as(usize, 1), summary.partial);
    try std.testing.expectEqual(@as(usize, 1), summary.planned);
    try std.testing.expectEqual(@as(usize, 1), summary.deferred);
    try std.testing.expectEqual(@as(usize, 2), summary.with_evidence);
}

test "evidence: missing-path validation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/present.zig", .data = "pub const x = 1;\n" });

    var manifest: Manifest = .{
        .allocator = alloc,
        .entries = &.{
            .{
                .id = "present",
                .status = .implemented,
                .implementation_paths = &.{"src/present.zig"},
                .evidence_paths = &.{"docs/present.md"},
            },
            .{
                .id = "missing",
                .status = .partial,
                .implementation_paths = &.{"src/missing.zig"},
                .evidence_paths = &.{"docs/missing.md"},
            },
        },
    };

    var report = try manifest.validatePaths(io, tmp.dir);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 4), report.total_paths);
    try std.testing.expect(!report.valid());
    try std.testing.expectEqual(@as(usize, 3), report.missing.len);
    try std.testing.expectEqualStrings("present", report.missing[0].entry_id);
    try std.testing.expectEqualStrings("docs/present.md", report.missing[0].path);
    try std.testing.expectEqual(PathKind.evidence, report.missing[0].kind);
    try std.testing.expectEqualStrings("src/missing.zig", report.missing[1].path);
    try std.testing.expectEqual(PathKind.implementation, report.missing[1].kind);
    try std.testing.expectEqualStrings("docs/missing.md", report.missing[2].path);
}

test "evidence: all paths present validates" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "x" });

    var manifest: Manifest = .{
        .allocator = alloc,
        .entries = &.{.{
            .id = "ok",
            .status = .implemented,
            .implementation_paths = &.{"a.zig"},
        }},
    };
    var report = try manifest.validatePaths(io, tmp.dir);
    defer report.deinit();
    try std.testing.expect(report.valid());
    try std.testing.expectEqual(@as(usize, 1), report.total_paths);
    try std.testing.expectEqual(@as(usize, 0), report.missing.len);
}

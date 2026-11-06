//! Package-level integration tests for the public `harnessz` module.

const std = @import("std");
const harnessz = @import("harnessz");

test "integration: golden, snapshot, and oracle workflow" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/render.txt",
        "pixels\n",
        .{ .update = true, .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.created, first.outcome);

    const second = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/render.txt",
        "pixels\n",
        .{ .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.matched, second.outcome);

    var snapshots = try harnessz.snapshot.Registry.init(alloc, io, .{
        .dir = tmp.dir,
        .update = true,
        .report = false,
    });
    defer snapshots.deinit();
    try snapshots.check("render/hash", "abc");
    try snapshots.check("render/hash", "abc");

    const stored = try tmp.dir.readFileAlloc(
        io,
        "snapshots/render/hash.snap",
        alloc,
        .limited(16),
    );
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("abc", stored);

    const bytes_report = harnessz.oracle.compareBytes("abc", stored);
    try std.testing.expect(bytes_report.ok());
    try std.testing.expectEqual(
        harnessz.oracle.checksum("abc"),
        harnessz.oracle.checksum(stored),
    );
}

test "integration: evidence manifest round-trip and path validation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/lib.zig", .data = "pub const x = 1;\n" });

    var original: harnessz.evidence.Manifest = .{
        .allocator = alloc,
        .entries = &.{
            .{
                .id = "feature",
                .status = .implemented,
                .implementation_paths = &.{"src/lib.zig"},
                .test_names = &.{"integration: feature"},
                .evidence_paths = &.{"docs/evidence/feature.md"},
                .notes = "integration fixture",
            },
        },
    };

    const json = try original.toJson(alloc);
    defer alloc.free(json);

    var parsed = try harnessz.evidence.Manifest.fromJson(alloc, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("feature", parsed.entries[0].id);

    var report = try parsed.validatePaths(io, tmp.dir);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.total_paths);
    try std.testing.expectEqual(@as(usize, 1), report.missing.len);
    try std.testing.expectEqualStrings("docs/evidence/feature.md", report.missing[0].path);
}

test "integration: bench gate from synthetic samples" {
    const baseline = [_]u64{ 100, 100, 100 };
    const candidate = [_]u64{ 40, 40, 40 };
    const comparison = harnessz.bench.Comparison.fromSamples(&baseline, &candidate);
    try std.testing.expect(comparison.gate(2.0));
    try std.testing.expect(!comparison.gate(3.0));
    try std.testing.expectEqual(@as(f64, 2.5), comparison.speedup());
}

test "integration: fixture resolution" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "testdata");
    try tmp.dir.writeFile(io, .{ .sub_path = "testdata/sample.bin", .data = "data" });

    var resolved = try harnessz.fixture.resolve(alloc, io, "sample.bin", .{
        .base_dir = tmp.dir,
    });
    defer resolved.deinit(alloc);
    try std.testing.expectEqualStrings("testdata/sample.bin", resolved.path);
    try std.testing.expectEqual(harnessz.fixture.Source.testdata, resolved.source);
}

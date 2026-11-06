//! Tests for golden-directory comparison and update.

const std = @import("std");
const dir = @import("dir.zig");

test "golden directory: create, match, and update" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = [_]dir.Entry{
        .{ .relative_path = "a.txt", .bytes = "alpha" },
        .{ .relative_path = "nested/b.bin", .bytes = "\x00\x01\x02" },
    };

    var created = try dir.expectDirectory(io, tmp.dir, "golden", &expected, .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    defer created.deinit();
    try std.testing.expectEqual(dir.Outcome.created, created.outcome);
    try std.testing.expectEqual(@as(usize, 2), created.changes.len);
    try std.testing.expect(!created.ok());

    const stored_a = try tmp.dir.readFileAlloc(io, "golden/a.txt", alloc, .limited(32));
    defer alloc.free(stored_a);
    try std.testing.expectEqualStrings("alpha", stored_a);
    const stored_b = try tmp.dir.readFileAlloc(io, "golden/nested/b.bin", alloc, .limited(32));
    defer alloc.free(stored_b);
    try std.testing.expectEqualSlices(u8, "\x00\x01\x02", stored_b);

    var matched = try dir.expectDirectory(io, tmp.dir, "golden", &expected, .{
        .allocator = alloc,
        .report = false,
    });
    defer matched.deinit();
    try std.testing.expectEqual(dir.Outcome.matched, matched.outcome);
    try std.testing.expect(matched.ok());
    try std.testing.expectEqual(@as(usize, 0), matched.changes.len);
}

test "golden directory: changed, missing, and extra files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = [_]dir.Entry{
        .{ .relative_path = "a.txt", .bytes = "alpha" },
        .{ .relative_path = "nested/b.bin", .bytes = "\x00\x01\x02" },
    };
    var created = try dir.expectDirectory(io, tmp.dir, "golden", &initial, .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    created.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "golden/a.txt", .data = "changed" });
    try tmp.dir.deleteFile(io, "golden/nested/b.bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "golden/extra.txt", .data = "extra" });

    var report = try dir.expectDirectory(io, tmp.dir, "golden", &initial, .{
        .allocator = alloc,
        .report = false,
    });
    defer report.deinit();
    try std.testing.expectEqual(dir.Outcome.mismatched, report.outcome);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 3), report.changes.len);

    try std.testing.expectEqual(dir.ChangeKind.changed, report.changes[0].kind);
    try std.testing.expectEqualStrings("a.txt", report.changes[0].relative_path);
    try std.testing.expectEqual(dir.ChangeKind.extra, report.changes[1].kind);
    try std.testing.expectEqualStrings("extra.txt", report.changes[1].relative_path);
    try std.testing.expectEqual(dir.ChangeKind.missing, report.changes[2].kind);
    try std.testing.expectEqualStrings("nested/b.bin", report.changes[2].relative_path);
}

test "golden directory: update repairs the tree" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = [_]dir.Entry{
        .{ .relative_path = "a.txt", .bytes = "alpha" },
        .{ .relative_path = "nested/b.bin", .bytes = "\x00\x01\x02" },
    };
    var created = try dir.expectDirectory(io, tmp.dir, "golden", &expected, .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    created.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "golden/a.txt", .data = "changed" });
    try tmp.dir.writeFile(io, .{ .sub_path = "golden/extra.txt", .data = "extra" });
    try tmp.dir.deleteFile(io, "golden/nested/b.bin");

    var updated = try dir.expectDirectory(io, tmp.dir, "golden", &expected, .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    defer updated.deinit();
    try std.testing.expectEqual(dir.Outcome.updated, updated.outcome);
    try std.testing.expectEqual(@as(usize, 3), updated.changes.len);

    var matched = try dir.expectDirectory(io, tmp.dir, "golden", &expected, .{
        .allocator = alloc,
        .report = false,
    });
    defer matched.deinit();
    try std.testing.expectEqual(dir.Outcome.matched, matched.outcome);
    try std.testing.expect(matched.ok());

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.deleteFile(io, "golden/extra.txt"),
    );
}

test "golden directory: missing root is reported as missing files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = [_]dir.Entry{
        .{ .relative_path = "a.txt", .bytes = "a" },
        .{ .relative_path = "b.txt", .bytes = "b" },
    };
    var report = try dir.expectDirectory(io, tmp.dir, "absent", &expected, .{
        .allocator = alloc,
        .report = false,
    });
    defer report.deinit();
    try std.testing.expectEqual(dir.Outcome.mismatched, report.outcome);
    try std.testing.expectEqual(@as(usize, 2), report.changes.len);
    try std.testing.expectEqual(dir.ChangeKind.missing, report.changes[0].kind);
    try std.testing.expectEqual(dir.ChangeKind.missing, report.changes[1].kind);
}

test "golden directory: bounds and invalid input" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const two = [_]dir.Entry{
        .{ .relative_path = "a", .bytes = "a" },
        .{ .relative_path = "b", .bytes = "b" },
    };
    try std.testing.expectError(error.GoldenDirectoryTooLarge, dir.expectDirectory(
        io,
        tmp.dir,
        "bounds",
        &two,
        .{ .update = true, .allocator = alloc, .max_files = 1, .report = false },
    ));
    try std.testing.expectError(error.GoldenFileTooLarge, dir.expectDirectory(
        io,
        tmp.dir,
        "bounds",
        &two,
        .{ .update = true, .allocator = alloc, .max_file_bytes = 0, .report = false },
    ));
    try std.testing.expectError(error.InvalidPath, dir.expectDirectory(
        io,
        tmp.dir,
        "../escape",
        &two,
        .{ .update = true, .allocator = alloc, .report = false },
    ));
    try std.testing.expectError(error.InvalidPath, dir.expectDirectory(
        io,
        tmp.dir,
        "bounds",
        &[_]dir.Entry{.{ .relative_path = "../a", .bytes = "a" }},
        .{ .update = true, .allocator = alloc, .report = false },
    ));
    const duplicate = [_]dir.Entry{
        .{ .relative_path = "same", .bytes = "a" },
        .{ .relative_path = "same", .bytes = "b" },
    };
    try std.testing.expectError(error.DuplicateEntry, dir.expectDirectory(
        io,
        tmp.dir,
        "bounds",
        &duplicate,
        .{ .update = true, .allocator = alloc, .report = false },
    ));
}

test "golden directory: traversal bounds apply to existing files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/b", .data = "b" });

    try std.testing.expectError(error.GoldenDirectoryTooLarge, dir.expectDirectory(
        io,
        tmp.dir,
        "tree",
        &.{},
        .{ .allocator = alloc, .max_files = 1, .report = false },
    ));
}

test "golden directory: report order is deterministic" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/z.txt", .data = "z" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "a" });

    var report = try dir.expectDirectory(io, tmp.dir, "tree", &.{}, .{
        .allocator = alloc,
        .report = false,
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.changes.len);
    try std.testing.expectEqualStrings("a.txt", report.changes[0].relative_path);
    try std.testing.expectEqualStrings("z.txt", report.changes[1].relative_path);
}

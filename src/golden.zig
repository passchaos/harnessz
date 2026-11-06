//! Golden-file assertions with update mode and readable diffs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const diff = @import("diff.zig");
const env = @import("env.zig");
const oracle = @import("oracle.zig");
const paths = @import("paths.zig");

pub const Mode = enum { text, binary };

pub const Options = struct {
    /// Rewrite the golden file instead of failing on mismatch or absence.
    /// `HARNESSZ_UPDATE=1` (or `true`) also enables this.
    update: bool = false,
    mode: Mode = .text,
    max_diff_lines: usize = 40,
    context_lines: usize = 3,
    /// Maximum golden file size that will be read.
    max_bytes: usize = 64 * 1024 * 1024,
    /// Allocator used for reading, diffing, and environment lookup.
    allocator: Allocator = std.heap.page_allocator,
    /// Environment block used for `HARNESSZ_UPDATE`. In tests this defaults to
    /// the test runner environment; applications should pass `init.environ`.
    environ: ?std.process.Environ = null,
    /// Print diagnostics to stderr on mismatch.
    report: bool = true,
};

pub const Outcome = enum { matched, created, updated };

pub const Result = struct {
    outcome: Outcome,
};

pub const StringOptions = struct {
    mode: Mode = .text,
    max_diff_lines: usize = 40,
    context_lines: usize = 3,
    allocator: Allocator = std.heap.page_allocator,
    report: bool = true,
};

/// Compare `actual` against `dir/path`, creating it in update mode.
pub fn expectFile(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    actual: []const u8,
    options: Options,
) !Result {
    if (!paths.validRelative(path)) return error.InvalidPath;

    const update = options.update or
        try env.flag(options.allocator, options.environ, "HARNESSZ_UPDATE");

    const existing = dir.readFileAlloc(
        io,
        path,
        options.allocator,
        .limited(options.max_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => return error.GoldenTooLarge,
        else => return err,
    };

    if (existing) |old| {
        defer options.allocator.free(old);
        if (std.mem.eql(u8, old, actual)) return .{ .outcome = .matched };
        if (update) {
            try writeGolden(io, dir, path, actual);
            return .{ .outcome = .updated };
        }
        if (options.report) reportMismatch(path, old, actual, options);
        return error.GoldenMismatch;
    }

    if (!update) return error.GoldenMissing;
    try writeGolden(io, dir, path, actual);
    return .{ .outcome = .created };
}

/// Compare two in-memory byte strings. Text mode prints a unified diff;
/// binary mode prints the first differing offset.
pub fn expectString(
    expected: []const u8,
    actual: []const u8,
    options: StringOptions,
) !void {
    if (std.mem.eql(u8, expected, actual)) return;
    if (options.report) {
        switch (options.mode) {
            .text => {
                const rendered = diff.unified(options.allocator, expected, actual, .{
                    .context = options.context_lines,
                    .max_diff_lines = options.max_diff_lines,
                    .header_a = "expected",
                    .header_b = "actual",
                }) catch return error.GoldenMismatch;
                defer options.allocator.free(rendered);
                std.debug.print("golden string mismatch:\n{s}", .{rendered});
            },
            .binary => reportBinary("string", expected, actual),
        }
    }
    return error.GoldenMismatch;
}

fn writeGolden(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    bytes: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) try dir.createDirPath(io, parent);
    }
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn reportMismatch(
    path: []const u8,
    expected: []const u8,
    actual: []const u8,
    options: Options,
) void {
    switch (options.mode) {
        .text => {
            const rendered = diff.unified(options.allocator, expected, actual, .{
                .context = options.context_lines,
                .max_diff_lines = options.max_diff_lines,
                .header_a = path,
                .header_b = path,
            }) catch return;
            defer options.allocator.free(rendered);
            std.debug.print("golden mismatch: {s}\n{s}", .{ path, rendered });
        },
        .binary => reportBinary(path, expected, actual),
    }
}

fn reportBinary(name: []const u8, expected: []const u8, actual: []const u8) void {
    const cmp = oracle.compareBytes(expected, actual);
    const offset = cmp.first_mismatch orelse 0;
    std.debug.print(
        "golden mismatch: {s} (binary)\nexpected {d} bytes, actual {d} bytes, first difference at offset {d}\n",
        .{ name, expected.len, actual.len, offset },
    );
    const start = offset -| 16;
    const expected_end = @min(expected.len, offset + 16);
    const actual_end = @min(actual.len, offset + 16);
    std.debug.print("expected[{d}..{d}]:", .{ start, expected_end });
    for (expected[start..expected_end]) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\nactual[{d}..{d}]:", .{ start, actual_end });
    for (actual[start..actual_end]) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

test "golden: HARNESSZ_UPDATE environment enables update" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const raw_entries = [_]?[*:0]const u8{ "HARNESSZ_UPDATE=1", null };
    const fake_environ: std.process.Environ = .{
        .block = .{ .slice = raw_entries[0..1 :null] },
    };

    const result = try expectFile(io, tmp.dir, "env.txt", "value", .{
        .allocator = alloc,
        .environ = fake_environ,
        .report = false,
    });
    try std.testing.expectEqual(Outcome.created, result.outcome);
}

test "golden: first run creates, second matches" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const options: Options = .{ .update = true, .allocator = alloc, .report = false };
    const first = try expectFile(io, tmp.dir, "cases/example.txt", "hello\n", options);
    try std.testing.expectEqual(Outcome.created, first.outcome);

    const stored = try tmp.dir.readFileAlloc(io, "cases/example.txt", alloc, .limited(64));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("hello\n", stored);

    const second = try expectFile(io, tmp.dir, "cases/example.txt", "hello\n", .{
        .allocator = alloc,
        .report = false,
    });
    try std.testing.expectEqual(Outcome.matched, second.outcome);
}

test "golden: mismatch reports an error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try expectFile(io, tmp.dir, "case.txt", "old\n", .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    try std.testing.expectError(error.GoldenMismatch, expectFile(io, tmp.dir, "case.txt", "new\n", .{
        .allocator = alloc,
        .report = false,
    }));
}

test "golden: update mode rewrites the file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try expectFile(io, tmp.dir, "case.txt", "old\n", .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    const updated = try expectFile(io, tmp.dir, "case.txt", "new\n", .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });
    try std.testing.expectEqual(Outcome.updated, updated.outcome);

    const stored = try tmp.dir.readFileAlloc(io, "case.txt", alloc, .limited(64));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("new\n", stored);
}

test "golden: missing file without update is an error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.GoldenMissing, expectFile(
        std.testing.io,
        tmp.dir,
        "missing.txt",
        "x",
        .{ .allocator = alloc, .report = false },
    ));
}

test "golden: invalid paths are rejected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.InvalidPath, expectFile(
        std.testing.io,
        tmp.dir,
        "../escape.txt",
        "x",
        .{ .update = true, .allocator = alloc, .report = false },
    ));
}

test "golden string: match and mismatch" {
    try expectString("same\n", "same\n", .{ .report = false });
    try std.testing.expectError(error.GoldenMismatch, expectString("a\n", "b\n", .{
        .report = false,
    }));
    try std.testing.expectError(error.GoldenMismatch, expectString("a", "b", .{
        .mode = .binary,
        .report = false,
    }));
}

test "golden binary mode reads and writes arbitrary bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = [_]u8{ 0, 1, 2, 255, 10 };
    _ = try expectFile(io, tmp.dir, "blob.bin", &bytes, .{
        .update = true,
        .mode = .binary,
        .allocator = alloc,
        .report = false,
    });
    _ = try expectFile(io, tmp.dir, "blob.bin", &bytes, .{
        .mode = .binary,
        .allocator = alloc,
        .report = false,
    });
}

//! Golden-file assertions with update mode and readable diffs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const diff = @import("diff.zig");
const env = @import("env.zig");
const normalize = @import("golden/normalize.zig");
const oracle = @import("oracle.zig");
const paths = @import("paths.zig");

pub const Mode = enum { text, binary };

pub const NormalizeOptions = normalize.NormalizeOptions;

pub const Options = struct {
    /// Rewrite the golden file instead of failing on mismatch or absence.
    /// `HARNESSZ_UPDATE=1` (or `true`) also enables this.
    update: bool = false,
    mode: Mode = .text,
    /// Text-only normalization applied before comparison. Binary mode ignores
    /// these options.
    normalize: NormalizeOptions = .{},
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
    /// Text-only normalization applied before comparison. Binary mode ignores
    /// these options.
    normalize: NormalizeOptions = .{},
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

    const use_normalization = options.mode == .text and
        normalize.enabled(options.normalize);

    if (existing) |old| {
        defer options.allocator.free(old);

        var normalized_old: ?[]u8 = null;
        defer if (normalized_old) |value| options.allocator.free(value);
        var normalized_actual: ?[]u8 = null;
        defer if (normalized_actual) |value| options.allocator.free(value);

        // Normalization is applied even when the raw bytes are equal so that
        // `json_canonical` rejects invalid JSON consistently.
        const compare_old = if (use_normalization) blk: {
            normalized_old = try normalize.normalizeText(options.allocator, old, options.normalize);
            break :blk normalized_old.?;
        } else old;
        const compare_actual = if (use_normalization) blk: {
            normalized_actual = try normalize.normalizeText(options.allocator, actual, options.normalize);
            break :blk normalized_actual.?;
        } else actual;

        if (std.mem.eql(u8, compare_old, compare_actual)) {
            return .{ .outcome = .matched };
        }
        if (update) {
            // Update mode always persists the original bytes, not the
            // normalized comparison form.
            try writeGolden(io, dir, path, actual);
            return .{ .outcome = .updated };
        }
        if (options.report) reportMismatch(path, compare_old, compare_actual, options);
        return error.GoldenMismatch;
    }

    if (!update) return error.GoldenMissing;
    if (use_normalization) {
        // Validate the bytes before creating a new golden file when
        // normalization is requested; the original bytes are still written.
        const normalized = try normalize.normalizeText(options.allocator, actual, options.normalize);
        options.allocator.free(normalized);
    }
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
    const use_normalization = options.mode == .text and
        normalize.enabled(options.normalize);
    if (!use_normalization and std.mem.eql(u8, expected, actual)) return;

    var normalized_expected: ?[]u8 = null;
    defer if (normalized_expected) |value| options.allocator.free(value);
    var normalized_actual: ?[]u8 = null;
    defer if (normalized_actual) |value| options.allocator.free(value);

    const compare_expected = if (use_normalization) blk: {
        normalized_expected = try normalize.normalizeText(options.allocator, expected, options.normalize);
        break :blk normalized_expected.?;
    } else expected;
    const compare_actual = if (use_normalization) blk: {
        normalized_actual = try normalize.normalizeText(options.allocator, actual, options.normalize);
        break :blk normalized_actual.?;
    } else actual;

    if (std.mem.eql(u8, compare_expected, compare_actual)) return;

    if (options.report) {
        switch (options.mode) {
            .text => {
                const rendered = diff.unified(
                    options.allocator,
                    compare_expected,
                    compare_actual,
                    .{
                        .context = options.context_lines,
                        .max_diff_lines = options.max_diff_lines,
                        .header_a = "expected",
                        .header_b = "actual",
                    },
                ) catch return error.GoldenMismatch;
                defer options.allocator.free(rendered);
                std.debug.print("golden string mismatch:\n{s}", .{rendered});
            },
            .binary => reportBinary("string", compare_expected, compare_actual),
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

test "golden normalize: line endings and trailing whitespace" {
    const line_options: StringOptions = .{
        .normalize = .{ .line_endings = true },
        .report = false,
    };
    try expectString("a\r\nb\r\nc", "a\nb\nc", line_options);
    try expectString("a\rb", "a\nb", line_options);
    try std.testing.expectError(error.GoldenMismatch, expectString("a\r\nb", "a\nc", line_options));

    const trim_options: StringOptions = .{
        .normalize = .{ .trailing_whitespace = true },
        .report = false,
    };
    try expectString("a  \nb\t\n", "a\nb\n", trim_options);
    try std.testing.expectError(error.GoldenMismatch, expectString("a \n b", "a\nb", trim_options));

    const combined: StringOptions = .{
        .normalize = .{ .line_endings = true, .trailing_whitespace = true },
        .report = false,
    };
    try expectString("a  \r\nb\t\r\n", "a\nb\n", combined);

    // Normalization stays off by default.
    try std.testing.expectError(error.GoldenMismatch, expectString("a  \n", "a\n", .{
        .report = false,
    }));
}

test "golden normalize: JSON canonical comparison" {
    const options: StringOptions = .{
        .normalize = .{ .json_canonical = true },
        .report = false,
    };
    try expectString(
        "{\"b\":1,\"a\":{\"d\":2,\"c\":3}}",
        "{\"a\":{\"c\":3,\"d\":2},\"b\":1}",
        options,
    );
    try expectString("[{\"z\":0,\"y\":1},2]", "[{\"y\":1,\"z\":0},2]", options);
    try std.testing.expectError(
        error.GoldenMismatch,
        expectString("[1,2]", "[2,1]", options),
    );
}

test "golden normalize: invalid JSON returns InvalidJson" {
    const options: StringOptions = .{
        .normalize = .{ .json_canonical = true },
        .report = false,
    };
    try std.testing.expectError(
        error.InvalidJson,
        expectString("{\"a\":1}", "{\"a\":}", options),
    );
    try std.testing.expectError(
        error.InvalidJson,
        expectString("not json", "not json", options),
    );
}

test "golden normalize: update writes the original bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try expectFile(io, tmp.dir, "case.json", "{\"b\":1,\"a\":2}", .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });

    const original = "{\"a\":3,  \r\n\"b\":1}";
    const result = try expectFile(io, tmp.dir, "case.json", original, .{
        .update = true,
        .allocator = alloc,
        .report = false,
        .normalize = .{ .json_canonical = true },
    });
    try std.testing.expectEqual(Outcome.updated, result.outcome);

    const stored = try tmp.dir.readFileAlloc(io, "case.json", alloc, .limited(128));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings(original, stored);
}

test "golden normalize: normalized-equal file matches without rewriting" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try expectFile(io, tmp.dir, "case.txt", "a\r\nb\r\n", .{
        .update = true,
        .allocator = alloc,
        .report = false,
    });

    const result = try expectFile(io, tmp.dir, "case.txt", "a\nb\n", .{
        .update = true,
        .allocator = alloc,
        .report = false,
        .normalize = .{ .line_endings = true },
    });
    try std.testing.expectEqual(Outcome.matched, result.outcome);

    const stored = try tmp.dir.readFileAlloc(io, "case.txt", alloc, .limited(64));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("a\r\nb\r\n", stored);
}

test "golden normalize: binary mode ignores text normalization" {
    try std.testing.expectError(error.GoldenMismatch, expectString("a\r\n", "a\n", .{
        .mode = .binary,
        .normalize = .{ .line_endings = true },
        .report = false,
    }));
}

test {
    std.testing.refAllDecls(normalize);
}

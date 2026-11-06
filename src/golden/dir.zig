//! Golden-directory assertions.
//!
//! A golden directory is a tree of regular files rooted at a relative path.
//! Traversal is deterministic (files are collected recursively and sorted by
//! relative path) and bounded by file count and byte limits.
//!
//! Update mode creates missing files, rewrites changed files, and removes
//! extra files so the tree matches `expected` exactly. Compare mode never
//! mutates the tree; it returns a report describing missing, extra, and
//! changed files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const env = @import("../env.zig");
const paths = @import("../paths.zig");

/// One expected file in the golden directory.
pub const Entry = struct {
    relative_path: []const u8,
    bytes: []const u8,
};

pub const Options = struct {
    /// Rewrite the tree to match `expected`. `HARNESSZ_UPDATE=1` (or `true`)
    /// also enables this.
    update: bool = false,
    allocator: Allocator = std.heap.page_allocator,
    environ: ?std.process.Environ = null,
    /// Maximum number of files in the expected tree and in the existing tree.
    max_files: usize = 4096,
    /// Maximum total bytes across the expected tree and the existing tree.
    max_total_bytes: u64 = 256 * 1024 * 1024,
    /// Maximum size of a single file.
    max_file_bytes: u64 = 64 * 1024 * 1024,
    /// Print a summary to stderr on mismatch.
    report: bool = true,
};

pub const Outcome = enum { matched, mismatched, created, updated };

pub const ChangeKind = enum { missing, extra, changed, created };

pub const Change = struct {
    kind: ChangeKind,
    /// Owned by the report; released by `Report.deinit`.
    relative_path: []const u8,
};

pub const Report = struct {
    outcome: Outcome,
    /// Sorted by relative path (ties broken by kind). Update-mode reports
    /// contain `created`, `changed`, and `extra` entries.
    changes: []const Change,
    allocator: Allocator,

    /// True only when the comparison matched exactly (or update mode had
    /// nothing to do).
    pub fn ok(self: Report) bool {
        return self.outcome == .matched;
    }

    pub fn deinit(self: *Report) void {
        for (self.changes) |change| self.allocator.free(change.relative_path);
        self.allocator.free(self.changes);
        self.* = undefined;
    }
};

/// Compare or update the directory at `dir/path` against `expected`.
///
/// `path` must be relative and must not contain `..`. Expected entries must
/// have unique relative paths. In compare mode a missing root is reported as
/// every expected file missing rather than as an I/O error.
pub fn expectDirectory(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    expected: []const Entry,
    options: Options,
) !Report {
    if (!paths.validRelative(path)) return error.InvalidPath;
    try validateExpected(expected, options);

    const update = options.update or
        try env.flag(options.allocator, options.environ, "HARNESSZ_UPDATE");

    const sorted_expected = try options.allocator.dupe(Entry, expected);
    defer options.allocator.free(sorted_expected);
    std.mem.sort(Entry, sorted_expected, {}, entryLessThan);

    var root_handle: ?std.Io.Dir = dir.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (root_handle) |handle| handle.close(io);

    var root_created = false;
    if (root_handle == null and update) {
        try dir.createDirPath(io, path);
        root_handle = try dir.openDir(io, path, .{ .iterate = true });
        root_created = true;
    }

    var existing: std.ArrayList(ExistingFile) = .empty;
    defer {
        for (existing.items) |file| options.allocator.free(file.relative_path);
        existing.deinit(options.allocator);
    }
    if (root_handle) |root| {
        try collectFiles(io, options.allocator, root, "", &existing, options);
        std.mem.sort(ExistingFile, existing.items, {}, existingLessThan);
    }

    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |change| options.allocator.free(change.relative_path);
        changes.deinit(options.allocator);
    }

    const root = root_handle;

    for (sorted_expected) |entry| {
        const found = findExisting(existing.items, entry.relative_path);
        if (found != null) {
            const old = try readExisting(
                io,
                root.?,
                entry.relative_path,
                options,
            );
            defer options.allocator.free(old);
            if (std.mem.eql(u8, old, entry.bytes)) continue;

            if (update) {
                try writeEntry(io, root.?, entry.relative_path, entry.bytes);
            }
            try appendChange(
                &changes,
                options.allocator,
                .changed,
                entry.relative_path,
            );
        } else {
            if (update) {
                try writeEntry(io, root.?, entry.relative_path, entry.bytes);
                try appendChange(
                    &changes,
                    options.allocator,
                    .created,
                    entry.relative_path,
                );
            } else {
                try appendChange(
                    &changes,
                    options.allocator,
                    .missing,
                    entry.relative_path,
                );
            }
        }
    }

    for (existing.items) |file| {
        if (findExpected(sorted_expected, file.relative_path) != null) continue;
        if (update) {
            try root.?.deleteFile(io, file.relative_path);
        }
        try appendChange(
            &changes,
            options.allocator,
            .extra,
            file.relative_path,
        );
    }

    std.mem.sort(Change, changes.items, {}, changeLessThan);

    const outcome: Outcome = if (update) blk: {
        if (root_created) break :blk .created;
        if (changes.items.len == 0) break :blk .matched;
        break :blk .updated;
    } else if (changes.items.len == 0)
        .matched
    else
        .mismatched;

    if (options.report and outcome == .mismatched) {
        std.debug.print(
            "golden directory mismatch: {s} ({d} changes)\n",
            .{ path, changes.items.len },
        );
        for (changes.items) |change| {
            std.debug.print("  {s}: {s}\n", .{
                @tagName(change.kind),
                change.relative_path,
            });
        }
    }

    return .{
        .outcome = outcome,
        .changes = try changes.toOwnedSlice(options.allocator),
        .allocator = options.allocator,
    };
}

const ExistingFile = struct {
    relative_path: []u8,
    size: u64,
};

fn validateExpected(expected: []const Entry, options: Options) !void {
    if (expected.len > options.max_files) return error.GoldenDirectoryTooLarge;

    var total_bytes: u64 = 0;
    for (expected) |entry| {
        if (!paths.validRelative(entry.relative_path)) return error.InvalidPath;
        if (entry.bytes.len > options.max_file_bytes) return error.GoldenFileTooLarge;
        total_bytes = std.math.add(
            u64,
            total_bytes,
            @intCast(entry.bytes.len),
        ) catch return error.GoldenDirectoryTooLarge;
        if (total_bytes > options.max_total_bytes) {
            return error.GoldenDirectoryTooLarge;
        }
    }

    // Duplicate detection uses a sorted copy of the paths. Entries are few
    // enough that this is cheaper than maintaining a hash map.
    const sorted_paths = try options.allocator.alloc([]const u8, expected.len);
    defer options.allocator.free(sorted_paths);
    for (expected, 0..) |entry, index| sorted_paths[index] = entry.relative_path;
    std.mem.sort([]const u8, sorted_paths, {}, stringLessThan);
    var index: usize = 1;
    while (index < sorted_paths.len) : (index += 1) {
        if (std.mem.eql(u8, sorted_paths[index - 1], sorted_paths[index])) {
            return error.DuplicateEntry;
        }
    }
}

fn collectFiles(
    io: std.Io,
    allocator: Allocator,
    dir: std.Io.Dir,
    prefix: []const u8,
    files: *std.ArrayList(ExistingFile),
    options: Options,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

        var owned = false;
        defer if (!owned) allocator.free(relative);

        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try collectFiles(io, allocator, child, relative, files, options);
            },
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                try appendExisting(files, allocator, relative, stat.size, options);
                owned = true;
            },
            .sym_link => {
                const stat = dir.statFile(io, entry.name, .{
                    .follow_symlinks = true,
                }) catch continue;
                if (stat.kind != .file) continue;
                try appendExisting(files, allocator, relative, stat.size, options);
                owned = true;
            },
            else => {},
        }
    }
}

fn appendExisting(
    files: *std.ArrayList(ExistingFile),
    allocator: Allocator,
    relative: []u8,
    size: u64,
    options: Options,
) !void {
    if (size > options.max_file_bytes) return error.GoldenFileTooLarge;
    if (files.items.len + 1 > options.max_files) {
        return error.GoldenDirectoryTooLarge;
    }
    var total_bytes: u64 = 0;
    for (files.items) |file| total_bytes = total_bytes +| file.size;
    total_bytes = std.math.add(u64, total_bytes, size) catch
        return error.GoldenDirectoryTooLarge;
    if (total_bytes > options.max_total_bytes) {
        return error.GoldenDirectoryTooLarge;
    }
    try files.append(allocator, .{
        .relative_path = relative,
        .size = size,
    });
}

fn readExisting(
    io: std.Io,
    root: std.Io.Dir,
    relative_path: []const u8,
    options: Options,
) ![]u8 {
    const limit = std.math.add(u64, options.max_file_bytes, 1) catch
        options.max_file_bytes;
    const bytes = root.readFileAlloc(
        io,
        relative_path,
        options.allocator,
        .limited64(limit),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.GoldenFileTooLarge,
        else => return err,
    };
    if (bytes.len > options.max_file_bytes) {
        options.allocator.free(bytes);
        return error.GoldenFileTooLarge;
    }
    return bytes;
}

fn writeEntry(
    io: std.Io,
    root: std.Io.Dir,
    relative_path: []const u8,
    bytes: []const u8,
) !void {
    if (std.fs.path.dirname(relative_path)) |parent| {
        if (parent.len != 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn appendChange(
    changes: *std.ArrayList(Change),
    allocator: Allocator,
    kind: ChangeKind,
    relative_path: []const u8,
) !void {
    const owned = try allocator.dupe(u8, relative_path);
    errdefer allocator.free(owned);
    try changes.append(allocator, .{ .kind = kind, .relative_path = owned });
}

fn findExisting(files: []const ExistingFile, path: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = files.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, files[middle].relative_path, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn findExpected(expected: []const Entry, path: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = expected.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, expected[middle].relative_path, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.relative_path, b.relative_path);
}

fn existingLessThan(_: void, a: ExistingFile, b: ExistingFile) bool {
    return std.mem.lessThan(u8, a.relative_path, b.relative_path);
}

fn changeLessThan(_: void, a: Change, b: Change) bool {
    const order = std.mem.order(u8, a.relative_path, b.relative_path);
    if (order == .eq) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return order == .lt;
}

test {
    _ = @import("dir_test.zig");
}

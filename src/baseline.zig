//! Benchmark baseline storage and regression detection.
//!
//! A baseline file is JSON with a top-level `entries` array. Each entry stores
//! a name, an environment fingerprint, raw nanosecond samples, and a summary.
//! The environment fingerprint keeps baselines from different machines or
//! build configurations from being compared silently.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const stats = @import("stats.zig");
const paths = @import("paths.zig");

pub const Entry = struct {
    name: []const u8,
    environment_fingerprint: []const u8 = "",
    samples_ns: []const u64 = &.{},
    summary: stats.Summary = .{},
};

/// Wire representation; keeps allocator/arena bookkeeping out of the schema.
const Wire = struct {
    entries: []const Entry = &.{},
};

pub const Options = struct {
    /// A regression is reported when
    /// `current_median > baseline_median * max_regression_ratio`.
    /// Values greater than 1 allow some noise; 1.0 flags any slowdown.
    max_regression_ratio: f64 = 1.05,
};

pub const Regression = struct {
    name: []const u8 = "",
    baseline_median: f64 = 0,
    current_median: f64 = 0,
    /// `baseline_median / current_median`; values above 1 mean the current
    /// run is faster.
    speedup: f64 = 0,
    regressed: bool = false,
};

pub const Store = struct {
    entries: []const Entry = &.{},
    allocator: Allocator = std.heap.page_allocator,
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn init(allocator: Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    pub fn toJson(self: Store, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(Wire{ .entries = self.entries }, .{
            .whitespace = .indent_2,
        }, &out.writer);
        return out.toOwnedSlice();
    }

    /// Parse a baseline store. All returned slices are owned by the store and
    /// released by `deinit`.
    pub fn fromJson(allocator: Allocator, bytes: []const u8) !Store {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();

        const wire = try std.json.parseFromSliceLeaky(
            Wire,
            arena.allocator(),
            bytes,
            .{ .allocate = .alloc_always },
        );
        return .{
            .entries = wire.entries,
            .allocator = allocator,
            .arena = arena,
        };
    }

    pub fn save(
        self: *const Store,
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

    /// Replace this store's contents from `dir/path`. The previous contents
    /// are released. Missing files propagate `error.FileNotFound`.
    pub fn load(
        self: *Store,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        if (!paths.validRelative(path)) return error.InvalidPath;

        const bytes = dir.readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(64 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.BaselineTooLarge,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var loaded = try fromJson(self.allocator, bytes);
        errdefer loaded.deinit();

        const old_arena = self.arena;
        self.arena = loaded.arena;
        self.entries = loaded.entries;
        loaded.arena = null;
        loaded.entries = &.{};

        if (old_arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
    }

    pub fn get(self: *const Store, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Replace the entry with the same `name`. Missing names return
    /// `error.MissingBaseline`; use `fromJson` or a fresh store to add entries.
    pub fn update(self: *Store, entry: Entry) !void {
        var found = false;
        for (self.entries) |existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingBaseline;

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = .init(self.allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const new_entries = try arena_allocator.alloc(Entry, self.entries.len);
        for (self.entries, 0..) |existing, index| {
            const source = if (std.mem.eql(u8, existing.name, entry.name))
                entry
            else
                existing;
            new_entries[index] = try copyEntry(arena_allocator, source);
        }

        const old_arena = self.arena;
        self.arena = arena;
        self.entries = new_entries;
        if (old_arena) |old| {
            const child = old.child_allocator;
            old.deinit();
            child.destroy(old);
        }
    }

    pub fn compare(
        self: *const Store,
        name: []const u8,
        current_samples: []const u64,
        options: Options,
    ) !Regression {
        if (current_samples.len == 0) return error.InvalidOptions;
        if (!std.math.isFinite(options.max_regression_ratio) or
            options.max_regression_ratio <= 0)
        {
            return error.InvalidOptions;
        }

        const entry = self.get(name) orelse return error.MissingBaseline;
        if (entry.samples_ns.len == 0) return error.InvalidBaseline;

        const baseline_median = stats.median(u64, entry.samples_ns);
        const current_median = stats.median(u64, current_samples);
        return .{
            .name = entry.name,
            .baseline_median = baseline_median,
            .current_median = current_median,
            .speedup = safeDiv(baseline_median, current_median),
            .regressed = current_median >
                baseline_median * options.max_regression_ratio,
        };
    }
};

fn copyEntry(allocator: Allocator, entry: Entry) !Entry {
    return .{
        .name = try allocator.dupe(u8, entry.name),
        .environment_fingerprint = try allocator.dupe(
            u8,
            entry.environment_fingerprint,
        ),
        .samples_ns = try allocator.dupe(u64, entry.samples_ns),
        .summary = entry.summary,
    };
}

fn safeDiv(numerator: f64, denominator: f64) f64 {
    if (denominator == 0) {
        if (numerator == 0) return 0;
        return if (numerator > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    return numerator / denominator;
}

/// Build a stable environment tag from the target architecture, operating
/// system, CPU count, and a caller-supplied tag (for example a build mode or
/// machine label). `io` is reserved for future host-specific probes.
pub fn environmentFingerprint(
    allocator: Allocator,
    io: std.Io,
    extra: []const u8,
) ![]u8 {
    _ = io;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return std.fmt.allocPrint(allocator, "{s}/{s}/cpu{d}/{s}", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        cpu_count,
        extra,
    });
}

test "baseline: JSON round-trip" {
    const alloc = std.testing.allocator;
    const samples = [_]u64{ 100, 110, 90 };
    const store: Store = .{
        .allocator = alloc,
        .entries = &.{.{
            .name = "render",
            .environment_fingerprint = "x86_64/linux/cpu8/test",
            .samples_ns = &samples,
            .summary = stats.summarize(u64, &samples),
        }},
    };

    const json = try store.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"entries\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"samples_ns\"") != null);

    var parsed = try Store.fromJson(alloc, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("render", parsed.entries[0].name);
    try std.testing.expectEqualStrings(
        "x86_64/linux/cpu8/test",
        parsed.entries[0].environment_fingerprint,
    );
    try std.testing.expectEqualSlices(u64, &samples, parsed.entries[0].samples_ns);
    try std.testing.expectEqual(@as(f64, 100), parsed.entries[0].summary.median);
    try std.testing.expectEqual(@as(usize, 3), parsed.entries[0].summary.count);
}

test "baseline: save and load" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const samples = [_]u64{ 10, 20, 30 };
    const store: Store = .{
        .allocator = alloc,
        .entries = &.{.{
            .name = "parse",
            .samples_ns = &samples,
            .summary = stats.summarize(u64, &samples),
        }},
    };
    try store.save(io, tmp.dir, "bench/baseline.json");

    var loaded = Store.init(alloc);
    defer loaded.deinit();
    try loaded.load(io, tmp.dir, "bench/baseline.json");
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try std.testing.expectEqualStrings("parse", loaded.entries[0].name);
    try std.testing.expectEqualSlices(u64, &samples, loaded.entries[0].samples_ns);

    try std.testing.expectError(error.InvalidPath, loaded.load(
        io,
        tmp.dir,
        "../escape.json",
    ));
    try std.testing.expectError(error.FileNotFound, loaded.load(
        io,
        tmp.dir,
        "bench/missing.json",
    ));
}

test "baseline: update replaces an existing entry" {
    const alloc = std.testing.allocator;
    const first_samples = [_]u64{ 1, 2, 3 };
    const second_samples = [_]u64{ 4, 5, 6 };
    const json = try std.fmt.allocPrint(alloc,
        \\{{"entries":[
        \\  {{"name":"a","samples_ns":[1,2,3]}},
        \\  {{"name":"b","samples_ns":[7,8,9]}}
        \\]}}
    , .{});
    defer alloc.free(json);

    var store = try Store.fromJson(alloc, json);
    defer store.deinit();

    try store.update(.{
        .name = "a",
        .environment_fingerprint = "updated",
        .samples_ns = &second_samples,
        .summary = stats.summarize(u64, &second_samples),
    });

    try std.testing.expectEqual(@as(usize, 2), store.entries.len);
    try std.testing.expectEqualStrings("a", store.entries[0].name);
    try std.testing.expectEqualStrings("updated", store.entries[0].environment_fingerprint);
    try std.testing.expectEqualSlices(u64, &second_samples, store.entries[0].samples_ns);
    try std.testing.expectEqualStrings("b", store.entries[1].name);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 7, 8, 9 }, store.entries[1].samples_ns);

    try std.testing.expectError(error.MissingBaseline, store.update(.{
        .name = "missing",
        .samples_ns = &first_samples,
    }));
}

test "baseline: regression comparison" {
    const baseline_samples = [_]u64{ 100, 100, 100 };
    const store: Store = .{
        .entries = &.{.{
            .name = "work",
            .samples_ns = &baseline_samples,
            .summary = stats.summarize(u64, &baseline_samples),
        }},
    };

    const faster = [_]u64{ 50, 50, 50 };
    const improved = try store.compare("work", &faster, .{});
    try std.testing.expectEqual(@as(f64, 100), improved.baseline_median);
    try std.testing.expectEqual(@as(f64, 50), improved.current_median);
    try std.testing.expectEqual(@as(f64, 2), improved.speedup);
    try std.testing.expect(!improved.regressed);

    const slower = [_]u64{ 120, 120, 120 };
    const regressed = try store.compare("work", &slower, .{});
    try std.testing.expect(regressed.regressed);
    try std.testing.expect(regressed.speedup < 1);

    const boundary = [_]u64{ 105, 105, 105 };
    const allowed = try store.compare("work", &boundary, .{ .max_regression_ratio = 1.05 });
    try std.testing.expect(!allowed.regressed);

    try std.testing.expectError(error.MissingBaseline, store.compare(
        "missing",
        &faster,
        .{},
    ));
    try std.testing.expectError(error.InvalidOptions, store.compare(
        "work",
        &.{},
        .{},
    ));
    try std.testing.expectError(error.InvalidOptions, store.compare(
        "work",
        &faster,
        .{ .max_regression_ratio = 0 },
    ));
}

test "baseline: environment fingerprint includes target and tag" {
    const alloc = std.testing.allocator;
    const first = try environmentFingerprint(alloc, std.testing.io, "debug");
    defer alloc.free(first);
    const second = try environmentFingerprint(alloc, std.testing.io, "debug");
    defer alloc.free(second);
    const release = try environmentFingerprint(alloc, std.testing.io, "release");
    defer alloc.free(release);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(!std.mem.eql(u8, first, release));
    try std.testing.expect(std.mem.find(u8, first, @tagName(builtin.cpu.arch)) != null);
    try std.testing.expect(std.mem.find(u8, first, @tagName(builtin.os.tag)) != null);
    try std.testing.expect(std.mem.find(u8, first, "/cpu") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, "/debug"));
}

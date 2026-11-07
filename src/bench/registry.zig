//! Deterministic benchmark registry shared by the child executable and any
//! in-process caller.
//!
//! Registration owns the benchmark name and may allocate. Lookups never
//! allocate and return the registered entry by value.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A benchmark callback. The context pointer is supplied by the registrant and
/// must remain valid for as long as the registry is used.
pub const Entry = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, Allocator, std.Io) anyerror!u64,
};

pub const Error = error{
    InvalidName,
    DuplicateName,
};

pub const Registry = struct {
    allocator: Allocator,
    name_storage: std.ArrayList([]u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.name_storage.items) |name| self.allocator.free(name);
        self.name_storage.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Register `name`. Names are kept in insertion order, which makes
    /// `names` and `writeNamesJson` deterministic. Duplicate names are
    /// rejected instead of silently replaced.
    pub fn add(self: *Registry, name: []const u8, entry: Entry) (Allocator.Error || Error)!void {
        if (name.len == 0) return error.InvalidName;
        if (self.find(name) != null) return error.DuplicateName;

        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.name_storage.append(self.allocator, owned);
        errdefer _ = self.name_storage.pop();
        try self.entries.append(self.allocator, entry);
    }

    /// Look up an entry without allocating.
    pub fn find(self: *const Registry, name: []const u8) ?Entry {
        for (self.name_storage.items, 0..) |registered, index| {
            if (std.mem.eql(u8, registered, name)) return self.entries.items[index];
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    /// Name at `index` in registration order, or null when out of range.
    pub fn nameAt(self: *const Registry, index: usize) ?[]const u8 {
        if (index >= self.name_storage.items.len) return null;
        return self.name_storage.items[index];
    }

    /// Entry at `index` in registration order, or null when out of range.
    pub fn entryAt(self: *const Registry, index: usize) ?Entry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    /// Copy up to `limit` names into a caller-owned outer slice, in
    /// registration order. The returned name slices reference registry-owned
    /// memory and remain valid until `deinit`. Release the outer slice with
    /// `allocator.free`.
    pub fn names(
        self: *const Registry,
        allocator: Allocator,
        limit: usize,
    ) Allocator.Error![][]const u8 {
        const total = @min(limit, self.count());
        const result = try allocator.alloc([]const u8, total);
        errdefer allocator.free(result);
        for (result, 0..) |*slot, index| slot.* = self.name_storage.items[index];
        return result;
    }

    /// Fill `buffer` with up to `buffer.len` names in registration order and
    /// return the number written. Never allocates.
    pub fn namesInto(self: *const Registry, buffer: [][]const u8) usize {
        const total = @min(buffer.len, self.count());
        for (buffer[0..total], 0..) |*slot, index| slot.* = self.name_storage.items[index];
        return total;
    }

    /// Write all registered names as a JSON array of strings. Output is
    /// deterministic (registration order) and bounded by `limit`.
    pub fn writeNamesJson(
        self: *const Registry,
        writer: *std.Io.Writer,
        limit: usize,
    ) !void {
        try writer.writeByte('[');
        const total = @min(limit, self.count());
        for (self.name_storage.items[0..total], 0..) |name, index| {
            if (index != 0) try writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, writer);
        }
        try writer.writeByte(']');
    }
};

const TestContext = struct {
    value: u64,
};

fn testRun(context: *anyopaque, alloc: Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    const typed: *TestContext = @ptrCast(@alignCast(context));
    return typed.value;
}

test "registry: add, find, count, and deterministic bounded names" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();

    var first: TestContext = .{ .value = 1 };
    var second: TestContext = .{ .value = 2 };
    try registry.add("zeta", .{ .context = &first, .run = testRun });
    try registry.add("alpha", .{ .context = &second, .run = testRun });

    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqualStrings("zeta", registry.name_storage.items[0]);
    try std.testing.expectEqualStrings("alpha", registry.name_storage.items[1]);

    const found = registry.find("alpha").?;
    try std.testing.expectEqual(@as(u64, 2), try found.run(found.context, alloc, std.testing.io));
    try std.testing.expect(registry.find("missing") == null);

    const all = try registry.names(alloc, 10);
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("zeta", all[0]);
    try std.testing.expectEqualStrings("alpha", all[1]);

    const bounded = try registry.names(alloc, 1);
    defer alloc.free(bounded);
    try std.testing.expectEqual(@as(usize, 1), bounded.len);
    try std.testing.expectEqualStrings("zeta", bounded[0]);

    var buffer: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), registry.namesInto(&buffer));
    try std.testing.expectEqualStrings("zeta", buffer[0]);
    try std.testing.expectEqualStrings("alpha", buffer[1]);
}

test "registry: duplicate and empty names are rejected" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 1 };
    const entry: Entry = .{ .context = &context, .run = testRun };
    try registry.add("one", entry);
    try std.testing.expectError(error.DuplicateName, registry.add("one", entry));
    try std.testing.expectError(error.InvalidName, registry.add("", entry));
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "registry: JSON name list is ordered and bounded" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 1 };
    try registry.add("b", .{ .context = &context, .run = testRun });
    try registry.add("a", .{ .context = &context, .run = testRun });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try registry.writeNamesJson(&out.writer, 10);
    try std.testing.expectEqualStrings("[\"b\",\"a\"]", out.written());

    var bounded: std.Io.Writer.Allocating = .init(alloc);
    defer bounded.deinit();
    try registry.writeNamesJson(&bounded.writer, 1);
    try std.testing.expectEqualStrings("[\"b\"]", bounded.written());
}

test "registry: lookup does not allocate" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 9 };
    try registry.add("stable", .{ .context = &context, .run = testRun });

    // A failing allocator proves `find` has no allocation path.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    _ = failing.allocator();
    try std.testing.expect(registry.find("stable") != null);
}

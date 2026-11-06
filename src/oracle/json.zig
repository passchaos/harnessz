//! Structural JSON oracle.
//!
//! Values are parsed with `std.json` and compared recursively:
//! - object key order is ignored,
//! - array order is significant,
//! - numbers may be compared with absolute/relative tolerance,
//! - the first difference is reported with a path such as `a.b[2].c`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    allocator: Allocator = std.heap.page_allocator,
    /// `|a - b| <= abs_tolerance + rel_tolerance * max(|a|, |b|)`.
    abs_tolerance: f64 = 0,
    rel_tolerance: f64 = 0,
    /// Maximum nesting depth; deeper inputs return `error.JsonTooDeep`.
    max_depth: usize = 128,
};

pub const DifferenceKind = enum {
    type_mismatch,
    missing_key,
    extra_key,
    value_mismatch,
    length_mismatch,
};

pub const Difference = struct {
    /// Owned by the report; released by `Report.deinit`.
    path: []const u8,
    kind: DifferenceKind,
};

pub const Report = struct {
    equal: bool,
    first_difference: ?Difference,
    allocator: Allocator,

    pub fn ok(self: Report) bool {
        return self.equal;
    }

    pub fn deinit(self: *Report) void {
        if (self.first_difference) |difference| {
            self.allocator.free(difference.path);
        }
        self.* = undefined;
    }
};

/// Parse and structurally compare two JSON documents.
///
/// Invalid JSON on either side returns `error.InvalidJson`. Negative or
/// non-finite tolerances and a zero `max_depth` return `error.InvalidOptions`.
pub fn compareJson(
    expected: []const u8,
    actual: []const u8,
    options: Options,
) !Report {
    if (!std.math.isFinite(options.abs_tolerance) or
        options.abs_tolerance < 0 or
        !std.math.isFinite(options.rel_tolerance) or
        options.rel_tolerance < 0 or
        options.max_depth == 0)
    {
        return error.InvalidOptions;
    }

    var expected_parsed = parseDocument(options.allocator, expected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer expected_parsed.deinit();

    var actual_parsed = parseDocument(options.allocator, actual) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer actual_parsed.deinit();

    var context: Context = .{
        .allocator = options.allocator,
        .options = options,
    };
    defer context.path.deinit(options.allocator);

    const equal = try compareValue(
        &context,
        expected_parsed.value,
        actual_parsed.value,
        0,
    );
    return .{
        .equal = equal,
        .first_difference = context.difference,
        .allocator = options.allocator,
    };
}

fn parseDocument(
    allocator: Allocator,
    bytes: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .parse_numbers = true },
    );
}

const Context = struct {
    allocator: Allocator,
    options: Options,
    path: std.ArrayList(u8) = .empty,
    difference: ?Difference = null,

    fn setDifference(self: *Context, kind: DifferenceKind) !void {
        std.debug.assert(self.difference == null);
        const owned = try self.allocator.dupe(u8, self.path.items);
        self.difference = .{ .path = owned, .kind = kind };
    }
};

const CompareError = error{ OutOfMemory, JsonTooDeep };

fn compareValue(
    context: *Context,
    expected: std.json.Value,
    actual: std.json.Value,
    depth: usize,
) CompareError!bool {
    if (depth > context.options.max_depth) return error.JsonTooDeep;

    if (isNumber(expected) and isNumber(actual)) {
        if (numbersEqual(expected, actual, context.options)) return true;
        try context.setDifference(.value_mismatch);
        return false;
    }

    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
        try context.setDifference(.type_mismatch);
        return false;
    }

    return switch (expected) {
        .null => true,
        .bool => |value| blk: {
            if (value == actual.bool) break :blk true;
            try context.setDifference(.value_mismatch);
            break :blk false;
        },
        .string => |value| blk: {
            if (std.mem.eql(u8, value, actual.string)) break :blk true;
            try context.setDifference(.value_mismatch);
            break :blk false;
        },
        .array => |items| compareArray(context, items.items, actual.array.items, depth),
        .object => |object| compareObject(context, object, actual.object, depth),
        .integer, .float, .number_string => unreachable,
    };
}

fn compareArray(
    context: *Context,
    expected: []const std.json.Value,
    actual: []const std.json.Value,
    depth: usize,
) CompareError!bool {
    const common = @min(expected.len, actual.len);
    var index: usize = 0;
    while (index < common) : (index += 1) {
        const mark = context.path.items.len;
        try context.path.print(context.allocator, "[{d}]", .{index});
        const equal = try compareValue(context, expected[index], actual[index], depth + 1);
        context.path.shrinkRetainingCapacity(mark);
        if (!equal) return false;
    }

    if (expected.len != actual.len) {
        const mark = context.path.items.len;
        try context.path.print(context.allocator, "[{d}]", .{common});
        try context.setDifference(.length_mismatch);
        context.path.shrinkRetainingCapacity(mark);
        return false;
    }
    return true;
}

fn compareObject(
    context: *Context,
    expected: std.json.ObjectMap,
    actual: std.json.ObjectMap,
    depth: usize,
) CompareError!bool {
    const expected_keys = try context.allocator.alloc([]const u8, expected.count());
    defer context.allocator.free(expected_keys);
    var key_index: usize = 0;
    var iterator = expected.iterator();
    while (iterator.next()) |entry| {
        expected_keys[key_index] = entry.key_ptr.*;
        key_index += 1;
    }
    std.mem.sort([]const u8, expected_keys, {}, stringLessThan);

    for (expected_keys) |key| {
        const mark = context.path.items.len;
        try appendKey(context, key);
        const actual_value = actual.get(key) orelse {
            try context.setDifference(.missing_key);
            context.path.shrinkRetainingCapacity(mark);
            return false;
        };
        const equal = try compareValue(
            context,
            expected.get(key).?,
            actual_value,
            depth + 1,
        );
        context.path.shrinkRetainingCapacity(mark);
        if (!equal) return false;
    }

    var extra: ?[]const u8 = null;
    var actual_iterator = actual.iterator();
    while (actual_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (expected.contains(key)) continue;
        if (extra == null or std.mem.lessThan(u8, key, extra.?)) extra = key;
    }
    if (extra) |key| {
        const mark = context.path.items.len;
        try appendKey(context, key);
        try context.setDifference(.extra_key);
        context.path.shrinkRetainingCapacity(mark);
        return false;
    }
    return true;
}

fn appendKey(context: *Context, key: []const u8) !void {
    if (context.path.items.len != 0) {
        try context.path.append(context.allocator, '.');
    }
    try context.path.appendSlice(context.allocator, key);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isNumber(value: std.json.Value) bool {
    return switch (value) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

fn numbersEqual(
    expected: std.json.Value,
    actual: std.json.Value,
    options: Options,
) bool {
    if (expected == .integer and actual == .integer and
        options.abs_tolerance == 0 and options.rel_tolerance == 0)
    {
        return expected.integer == actual.integer;
    }

    const a = numberAsF64(expected) orelse return false;
    const b = numberAsF64(actual) orelse return false;
    if (a == b) return true;
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return false;

    const difference = @abs(a - b);
    const scale = @max(@abs(a), @abs(b));
    return difference <=
        options.abs_tolerance + options.rel_tolerance * scale;
}

fn numberAsF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

test "json: object key order is ignored" {
    var report = try compareJson(
        "{\"b\":1,\"a\":{\"d\":2,\"c\":3}}",
        "{\"a\":{\"c\":3,\"d\":2},\"b\":1}",
        .{},
    );
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expect(report.first_difference == null);
}

test "json: array order is significant" {
    var report = try compareJson("[1,2,3]", "[3,2,1]", .{});
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("[0]", report.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.value_mismatch,
        report.first_difference.?.kind,
    );
}

test "json: numeric tolerance" {
    var strict = try compareJson("{\"x\":1.0}", "{\"x\":1.05}", .{});
    defer strict.deinit();
    try std.testing.expect(!strict.ok());
    try std.testing.expectEqualStrings("x", strict.first_difference.?.path);

    var tolerant = try compareJson("{\"x\":1.0}", "{\"x\":1.05}", .{
        .abs_tolerance = 0.1,
    });
    defer tolerant.deinit();
    try std.testing.expect(tolerant.ok());

    var relative = try compareJson("{\"x\":100.0}", "{\"x\":101.0}", .{
        .rel_tolerance = 0.01,
    });
    defer relative.deinit();
    try std.testing.expect(relative.ok());

    var outside = try compareJson("{\"x\":100.0}", "{\"x\":102.0}", .{
        .rel_tolerance = 0.01,
    });
    defer outside.deinit();
    try std.testing.expect(!outside.ok());
}

test "json: integer and float compare numerically" {
    var report = try compareJson("{\"x\":1}", "{\"x\":1.0}", .{});
    defer report.deinit();
    try std.testing.expect(report.ok());

    var exact = try compareJson(
        "{\"x\":9007199254740993}",
        "{\"x\":9007199254740993}",
        .{},
    );
    defer exact.deinit();
    try std.testing.expect(exact.ok());
}

test "json: type mismatch and path" {
    var report = try compareJson("{\"a\":{\"b\":1}}", "{\"a\":{\"b\":\"1\"}}", .{});
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("a.b", report.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.type_mismatch,
        report.first_difference.?.kind,
    );

    var root = try compareJson("1", "\"1\"", .{});
    defer root.deinit();
    try std.testing.expect(!root.ok());
    try std.testing.expectEqualStrings("", root.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.type_mismatch,
        root.first_difference.?.kind,
    );
}

test "json: nested first-difference path" {
    var report = try compareJson(
        "{\"a\":{\"b\":[0,1,{\"c\":2}]}}",
        "{\"a\":{\"b\":[0,1,{\"c\":3}]}}",
        .{},
    );
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("a.b[2].c", report.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.value_mismatch,
        report.first_difference.?.kind,
    );
}

test "json: missing and extra object keys" {
    var missing = try compareJson("{\"a\":1}", "{}", .{});
    defer missing.deinit();
    try std.testing.expect(!missing.ok());
    try std.testing.expectEqualStrings("a", missing.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.missing_key,
        missing.first_difference.?.kind,
    );

    var extra = try compareJson("{}", "{\"b\":1,\"a\":2}", .{});
    defer extra.deinit();
    try std.testing.expect(!extra.ok());
    try std.testing.expectEqualStrings("a", extra.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.extra_key,
        extra.first_difference.?.kind,
    );
}

test "json: array length mismatch" {
    var report = try compareJson("[1,2,3]", "[1,2]", .{});
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("[2]", report.first_difference.?.path);
    try std.testing.expectEqual(
        DifferenceKind.length_mismatch,
        report.first_difference.?.kind,
    );
}

test "json: invalid documents and options" {
    try std.testing.expectError(
        error.InvalidJson,
        compareJson("{\"a\":}", "{}", .{}),
    );
    try std.testing.expectError(
        error.InvalidJson,
        compareJson("{}", "not json", .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        compareJson("{}", "{}", .{ .abs_tolerance = -1 }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        compareJson("{}", "{}", .{ .rel_tolerance = std.math.inf(f64) }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        compareJson("{}", "{}", .{ .max_depth = 0 }),
    );
}

test "json: depth limit" {
    try std.testing.expectError(
        error.JsonTooDeep,
        compareJson("[[[[1]]]]", "[[[[1]]]]", .{ .max_depth = 2 }),
    );
}

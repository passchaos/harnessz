//! Canonical JSON emission used by golden normalization.
//!
//! Canonical form is minified JSON with object keys sorted recursively by
//! byte order. Array order is preserved. Numbers, strings, and escapes are
//! re-emitted through `std.json.Stringify`, so the result is valid JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parse `bytes` as JSON and return a canonical, minified re-emission.
/// Invalid JSON returns `error.InvalidJson`.
pub fn canonicalize(alloc: Allocator, bytes: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeCanonical(alloc, parsed.value, &out.writer);
    return out.toOwnedSlice();
}

/// Write `value` as canonical JSON. Object keys are sorted recursively;
/// arrays keep their original order.
pub fn writeCanonical(
    alloc: Allocator,
    value: std.json.Value,
    writer: *std.Io.Writer,
) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |inner| try writer.writeAll(if (inner) "true" else "false"),
        .integer => |inner| try writer.print("{d}", .{inner}),
        .float => |inner| try std.json.Stringify.value(inner, .{}, writer),
        .number_string => |inner| try writer.writeAll(inner),
        .string => |inner| try std.json.Stringify.value(inner, .{}, writer),
        .array => |inner| {
            try writer.writeByte('[');
            for (inner.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonical(alloc, item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |inner| {
            const keys = try alloc.dupe([]const u8, inner.keys());
            defer alloc.free(keys);
            std.mem.sort([]const u8, keys, {}, keyLessThan);

            try writer.writeByte('{');
            for (keys, 0..) |key, index| {
                if (index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonical(alloc, inner.get(key).?, writer);
            }
            try writer.writeByte('}');
        },
    }
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "json_canon: recursively sorts object keys" {
    const alloc = std.testing.allocator;
    const input =
        \\{"b":1,"a":{"d":2,"c":3},"list":[{"z":0,"y":1},2,1]}
    ;
    const canonical = try canonicalize(alloc, input);
    defer alloc.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"a\":{\"c\":3,\"d\":2},\"b\":1,\"list\":[{\"y\":1,\"z\":0},2,1]}",
        canonical,
    );
}

test "json_canon: arrays keep stable order" {
    const alloc = std.testing.allocator;
    const first = try canonicalize(alloc, "[3,1,2]");
    defer alloc.free(first);
    const second = try canonicalize(alloc, "[3,1,2]");
    defer alloc.free(second);
    try std.testing.expectEqualStrings("[3,1,2]", first);
    try std.testing.expectEqualStrings(first, second);

    const reordered = try canonicalize(alloc, "[1,2,3]");
    defer alloc.free(reordered);
    try std.testing.expect(!std.mem.eql(u8, first, reordered));
}

test "json_canon: scalars and escapes round-trip canonically" {
    const alloc = std.testing.allocator;

    const number = try canonicalize(alloc, " 1.5 ");
    defer alloc.free(number);
    try std.testing.expectEqualStrings("1.5", number);

    const string = try canonicalize(alloc, "\"a\\nb\"");
    defer alloc.free(string);
    try std.testing.expectEqualStrings("\"a\\nb\"", string);

    const empty_object = try canonicalize(alloc, "{}");
    defer alloc.free(empty_object);
    try std.testing.expectEqualStrings("{}", empty_object);
}

test "json_canon: invalid input returns InvalidJson" {
    const alloc = std.testing.allocator;
    const invalid = [_][]const u8{ "", "not json", "{\"a\":}", "[1,", "{\"a\" 1}" };
    for (invalid) |input| {
        try std.testing.expectError(error.InvalidJson, canonicalize(alloc, input));
    }
}

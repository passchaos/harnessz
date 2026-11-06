//! Text normalization helpers used by golden comparisons.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_canon = @import("../json_canon.zig");

/// Text comparison normalization. All options default to off, preserving the
/// exact-byte behaviour of earlier releases.
pub const NormalizeOptions = struct {
    /// Convert CRLF and lone CR line endings to LF before comparing.
    line_endings: bool = false,
    /// Strip spaces and tabs at the end of each line before comparing.
    trailing_whitespace: bool = false,
    /// Parse both sides as JSON and compare canonical re-emissions with
    /// recursively sorted object keys and stable array order. Invalid JSON
    /// returns `error.InvalidJson`. This option takes precedence over the
    /// text-only options. Update mode still writes the original `actual`
    /// bytes, never the canonical form.
    json_canonical: bool = false,
};

pub fn enabled(options: NormalizeOptions) bool {
    return options.line_endings or options.trailing_whitespace or options.json_canonical;
}

pub fn normalizeText(
    alloc: Allocator,
    bytes: []const u8,
    options: NormalizeOptions,
) ![]u8 {
    if (options.json_canonical) return json_canon.canonicalize(alloc, bytes);
    if (!options.line_endings and !options.trailing_whitespace) {
        return alloc.dupe(u8, bytes);
    }

    var line_normalized: ?[]u8 = null;
    defer if (line_normalized) |value| alloc.free(value);

    var source = bytes;
    if (options.line_endings) {
        line_normalized = try normalizeLineEndings(alloc, bytes);
        source = line_normalized.?;
    }
    if (!options.trailing_whitespace) {
        if (line_normalized) |value| {
            line_normalized = null; // transfer ownership to the caller
            return value;
        }
        return alloc.dupe(u8, bytes);
    }
    return trimTrailingWhitespace(alloc, source);
}

fn normalizeLineEndings(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        if (byte == '\r') {
            try out.writer.writeByte('\n');
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
        } else {
            try out.writer.writeByte(byte);
        }
    }
    return out.toOwnedSlice();
}

fn trimTrailingWhitespace(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var start: usize = 0;
    while (start < bytes.len) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const end = newline orelse bytes.len;
        var line_end = end;
        while (line_end > start and
            (bytes[line_end - 1] == ' ' or bytes[line_end - 1] == '\t'))
        {
            line_end -= 1;
        }
        try out.writer.writeAll(bytes[start..line_end]);
        if (newline) |position| {
            try out.writer.writeByte('\n');
            start = position + 1;
        } else break;
    }
    return out.toOwnedSlice();
}

test "normalize: line endings" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeText(alloc, "a\r\nb\rc", .{ .line_endings = true });
    defer alloc.free(normalized);
    try std.testing.expectEqualStrings("a\nb\nc", normalized);
}

test "normalize: trailing whitespace" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeText(alloc, "a  \nb\t\n", .{ .trailing_whitespace = true });
    defer alloc.free(normalized);
    try std.testing.expectEqualStrings("a\nb\n", normalized);
}

test "normalize: invalid canonical JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidJson,
        normalizeText(alloc, "{bad", .{ .json_canonical = true }),
    );
}

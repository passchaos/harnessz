//! Line-oriented unified diff generation used by the golden and snapshot
//! helpers. This is intentionally small: it is a diagnostic aid, not a patch
//! application engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Number of unchanged lines to show around each change.
    context: usize = 3,
    /// Stop after this many added/removed lines. Zero means unlimited.
    max_diff_lines: usize = 40,
    /// Bound for the O(n*m) LCS table. Larger inputs fall back to a
    /// delete-all-then-insert-all representation of the differing middle.
    max_lcs_cells: usize = 1_000_000,
    header_a: []const u8 = "expected",
    header_b: []const u8 = "actual",
};

const Line = struct {
    text: []const u8,
    has_newline: bool,
};

const Kind = enum { equal, delete, insert };

const Op = struct {
    kind: Kind,
    line: Line,
};

pub fn unified(
    alloc: Allocator,
    expected: []const u8,
    actual: []const u8,
    options: Options,
) ![]u8 {
    if (std.mem.eql(u8, expected, actual)) return alloc.alloc(u8, 0);

    const a = try splitLines(alloc, expected);
    defer alloc.free(a);
    const b = try splitLines(alloc, actual);
    defer alloc.free(b);

    const ops = try computeOps(alloc, a, b, options.max_lcs_cells);
    defer alloc.free(ops);

    return render(alloc, ops, options);
}

fn splitLines(alloc: Allocator, bytes: []const u8) ![]Line {
    var list: std.ArrayList(Line) = .empty;
    errdefer list.deinit(alloc);

    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '\n') continue;
        try list.append(alloc, .{
            .text = bytes[start..i],
            .has_newline = true,
        });
        start = i + 1;
    }
    if (start < bytes.len) {
        try list.append(alloc, .{
            .text = bytes[start..],
            .has_newline = false,
        });
    }
    return list.toOwnedSlice(alloc);
}

fn lineEql(a: Line, b: Line) bool {
    return a.has_newline == b.has_newline and std.mem.eql(u8, a.text, b.text);
}

fn computeOps(
    alloc: Allocator,
    a: []const Line,
    b: []const Line,
    max_lcs_cells: usize,
) ![]Op {
    var list: std.ArrayList(Op) = .empty;
    errdefer list.deinit(alloc);

    var prefix: usize = 0;
    while (prefix < a.len and prefix < b.len and lineEql(a[prefix], b[prefix])) {
        prefix += 1;
    }
    var suffix: usize = 0;
    while (suffix < a.len - prefix and
        suffix < b.len - prefix and
        lineEql(a[a.len - 1 - suffix], b[b.len - 1 - suffix]))
    {
        suffix += 1;
    }

    for (a[0..prefix]) |line| {
        try list.append(alloc, .{ .kind = .equal, .line = line });
    }
    try appendMiddle(
        alloc,
        &list,
        a[prefix .. a.len - suffix],
        b[prefix .. b.len - suffix],
        max_lcs_cells,
    );
    for (a[a.len - suffix ..]) |line| {
        try list.append(alloc, .{ .kind = .equal, .line = line });
    }
    return list.toOwnedSlice(alloc);
}

fn appendMiddle(
    alloc: Allocator,
    list: *std.ArrayList(Op),
    a: []const Line,
    b: []const Line,
    max_lcs_cells: usize,
) !void {
    const n = a.len;
    const m = b.len;
    if (n == 0) {
        for (b) |line| try list.append(alloc, .{ .kind = .insert, .line = line });
        return;
    }
    if (m == 0) {
        for (a) |line| try list.append(alloc, .{ .kind = .delete, .line = line });
        return;
    }

    const use_lcs = n <= max_lcs_cells / m and
        (n + 1) * (m + 1) <= max_lcs_cells;
    if (!use_lcs) {
        for (a) |line| try list.append(alloc, .{ .kind = .delete, .line = line });
        for (b) |line| try list.append(alloc, .{ .kind = .insert, .line = line });
        return;
    }

    const cols = m + 1;
    const table = try alloc.alloc(u32, (n + 1) * cols);
    defer alloc.free(table);
    @memset(table, 0);

    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var j: usize = 1;
        while (j <= m) : (j += 1) {
            table[i * cols + j] = if (lineEql(a[i - 1], b[j - 1]))
                table[(i - 1) * cols + (j - 1)] + 1
            else
                @max(table[(i - 1) * cols + j], table[i * cols + (j - 1)]);
        }
    }

    var reversed: std.ArrayList(Op) = .empty;
    defer reversed.deinit(alloc);

    var ai = n;
    var bi = m;
    while (ai > 0 or bi > 0) {
        if (ai > 0 and bi > 0 and lineEql(a[ai - 1], b[bi - 1])) {
            try reversed.append(alloc, .{ .kind = .equal, .line = a[ai - 1] });
            ai -= 1;
            bi -= 1;
        } else if (bi > 0 and
            (ai == 0 or table[ai * cols + (bi - 1)] >= table[(ai - 1) * cols + bi]))
        {
            try reversed.append(alloc, .{ .kind = .insert, .line = b[bi - 1] });
            bi -= 1;
        } else {
            try reversed.append(alloc, .{ .kind = .delete, .line = a[ai - 1] });
            ai -= 1;
        }
    }

    var k = reversed.items.len;
    while (k > 0) {
        k -= 1;
        try list.append(alloc, reversed.items[k]);
    }
}

fn render(alloc: Allocator, ops: []const Op, options: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("--- {s}\n+++ {s}\n", .{ options.header_a, options.header_b });

    const old_before = try alloc.alloc(usize, ops.len + 1);
    defer alloc.free(old_before);
    const new_before = try alloc.alloc(usize, ops.len + 1);
    defer alloc.free(new_before);

    var old_pos: usize = 0;
    var new_pos: usize = 0;
    for (ops, 0..) |op, idx| {
        old_before[idx] = old_pos;
        new_before[idx] = new_pos;
        if (op.kind != .insert) old_pos += 1;
        if (op.kind != .delete) new_pos += 1;
    }
    old_before[ops.len] = old_pos;
    new_before[ops.len] = new_pos;

    var i: usize = 0;
    var changes_emitted: usize = 0;
    var truncated = false;

    while (i < ops.len) {
        if (ops[i].kind == .equal) {
            i += 1;
            continue;
        }

        var last_change = i;
        var j = i + 1;
        while (j < ops.len) {
            if (ops[j].kind != .equal) {
                last_change = j;
            } else if (j - last_change > options.context) {
                break;
            }
            j += 1;
        }

        const start = if (i >= options.context) i - options.context else 0;
        const end = @min(ops.len, last_change + options.context + 1);
        const old_count = old_before[end] - old_before[start];
        const new_count = new_before[end] - new_before[start];
        const old_start = old_before[start] + @intFromBool(old_count != 0);
        const new_start = new_before[start] + @intFromBool(new_count != 0);

        try w.print("@@ -{d},{d} +{d},{d} @@\n", .{
            old_start, old_count, new_start, new_count,
        });

        var k = start;
        while (k < end) : (k += 1) {
            const op = ops[k];
            if (op.kind != .equal) {
                if (options.max_diff_lines != 0 and changes_emitted >= options.max_diff_lines) {
                    truncated = true;
                    break;
                }
                changes_emitted += 1;
            }
            try writeOp(w, op);
        }

        if (truncated) break;
        i = end;
    }

    if (truncated) try w.writeAll("... diff truncated ...\n");
    return out.toOwnedSlice();
}

fn writeOp(w: *std.Io.Writer, op: Op) !void {
    const prefix: u8 = switch (op.kind) {
        .equal => ' ',
        .delete => '-',
        .insert => '+',
    };
    try w.writeAll(&[_]u8{prefix});
    try w.writeAll(op.line.text);
    try w.writeAll("\n");
    if (!op.line.has_newline) try w.writeAll("\\ No newline at end of file\n");
}

test "unified diff reports replacement with context" {
    const alloc = std.testing.allocator;
    const out = try unified(
        alloc,
        "alpha\nold\nomega\n",
        "alpha\nnew\nomega\n",
        .{ .context = 3 },
    );
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "--- expected") != null);
    try std.testing.expect(std.mem.find(u8, out, "+++ actual") != null);
    try std.testing.expect(std.mem.find(u8, out, "@@ -1,3 +1,3 @@") != null);
    try std.testing.expect(std.mem.find(u8, out, "-old\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+new\n") != null);
}

test "unified diff equal input is empty" {
    const alloc = std.testing.allocator;
    const out = try unified(alloc, "same\n", "same\n", .{});
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "unified diff truncates after max_diff_lines" {
    const alloc = std.testing.allocator;
    const out = try unified(
        alloc,
        "a\nb\nc\n",
        "x\ny\nz\n",
        .{ .max_diff_lines = 2, .context = 0 },
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "-a\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "-b\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "-c\n") == null);
    try std.testing.expect(std.mem.find(u8, out, "diff truncated") != null);
}

test "unified diff marks missing trailing newline" {
    const alloc = std.testing.allocator;
    const out = try unified(alloc, "a\nb", "a\nc", .{ .context = 1 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\\ No newline at end of file") != null);
}

test "unified diff falls back when LCS budget is exceeded" {
    const alloc = std.testing.allocator;
    const out = try unified(
        alloc,
        "a\nb\n",
        "c\nd\n",
        .{ .max_lcs_cells = 1, .context = 0 },
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "-a\n-b\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+c\n+d\n") != null);
}

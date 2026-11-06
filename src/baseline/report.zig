//! Deterministic baseline comparison report.
//!
//! `report` merges a baseline store with the current run's entries, writes a
//! text table to the supplied writer, and returns a `Report` with the same
//! rows plus regression/improvement/missing/extra counts. Rows are sorted by
//! name so output is stable across runs. `Report.writeJson` emits the same
//! data for machine consumption.
//!
//! Medians come from raw samples when present, otherwise from a non-empty
//! summary. A p-value is included only when both sides have at least two raw
//! samples (Welch's test requires two samples per side).

const std = @import("std");
const Allocator = std.mem.Allocator;
const baseline = @import("store.zig");
const stats = @import("../stats.zig");

pub const Options = struct {
    /// A row is `regressed` when
    /// `current_median > baseline_median * max_regression_ratio`. A row is
    /// `improved` when `baseline_median > current_median *
    /// max_regression_ratio`, making the improvement threshold symmetric.
    max_regression_ratio: f64 = 1.05,
};

pub const Status = enum {
    unchanged,
    regressed,
    improved,
    missing,
    extra,

    /// Uppercase marker used by the text table.
    pub fn marker(self: Status) []const u8 {
        return switch (self) {
            .unchanged => "UNCHANGED",
            .regressed => "REGRESSED",
            .improved => "IMPROVED",
            .missing => "MISSING",
            .extra => "EXTRA",
        };
    }
};

pub const Row = struct {
    name: []const u8,
    baseline_median_ns: ?f64 = null,
    current_median_ns: ?f64 = null,
    /// `baseline_median / current_median`; above 1 means the current run is
    /// faster.
    speedup: ?f64 = null,
    p_value: ?f64 = null,
    status: Status = .unchanged,
};

pub const Report = struct {
    allocator: Allocator,
    rows: []Row = &.{},
    regressions: usize = 0,
    improvements: usize = 0,
    /// Baseline entries with no current entry (or with no usable current
    /// measurement).
    missing: usize = 0,
    /// Current entries with no baseline entry.
    extra: usize = 0,

    pub fn deinit(self: *Report) void {
        for (self.rows) |row| self.allocator.free(row.name);
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.* = undefined;
    }

    /// True when no row regressed.
    pub fn ok(self: Report) bool {
        return self.regressions == 0;
    }

    pub fn writeText(self: Report, writer: *std.Io.Writer) !void {
        try writer.writeAll(
            "name                     baseline_ns   current_ns   speedup   p_value   status\n" ++
                "------------------------ ------------ ------------ --------- --------- ----------\n",
        );
        for (self.rows) |row| {
            var baseline_buffer: [32]u8 = undefined;
            var current_buffer: [32]u8 = undefined;
            var speedup_buffer: [32]u8 = undefined;
            var p_buffer: [32]u8 = undefined;
            try writer.print("{s:<24} {s:>12} {s:>12} {s:>9} {s:>9} {s}\n", .{
                row.name,
                formatOptional(&baseline_buffer, row.baseline_median_ns, "{d:.0}"),
                formatOptional(&current_buffer, row.current_median_ns, "{d:.0}"),
                formatOptional(&speedup_buffer, row.speedup, "{d:.2}x"),
                formatOptional(&p_buffer, row.p_value, "{d:.4}"),
                row.status.marker(),
            });
        }
        try writer.print(
            "summary: regressions={d} improvements={d} missing={d} extra={d}\n",
            .{ self.regressions, self.improvements, self.missing, self.extra },
        );
    }

    pub fn toText(self: Report, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeText(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeJson(self: Report, writer: *std.Io.Writer) !void {
        const Wire = struct {
            summary: Summary,
            rows: []const Row,

            const Summary = struct {
                regressions: usize,
                improvements: usize,
                missing: usize,
                extra: usize,
            };
        };
        try std.json.Stringify.value(Wire{
            .summary = .{
                .regressions = self.regressions,
                .improvements = self.improvements,
                .missing = self.missing,
                .extra = self.extra,
            },
            .rows = self.rows,
        }, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        }, writer);
    }

    pub fn toJson(self: Report, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};

/// Compare `store` with `current`, write a deterministic text table to
/// `writer`, and return the structured report. The caller owns the report and
/// must call `deinit`.
pub fn report(
    allocator: Allocator,
    writer: *std.Io.Writer,
    store: *const baseline.Store,
    current: []const baseline.Entry,
    options: Options,
) !Report {
    if (!std.math.isFinite(options.max_regression_ratio) or
        options.max_regression_ratio <= 0)
    {
        return error.InvalidOptions;
    }
    try validateUnique(current);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (store.entries) |entry| try names.append(allocator, entry.name);
    for (current) |entry| try names.append(allocator, entry.name);
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |row| allocator.free(row.name);
        rows.deinit(allocator);
    }

    var result: Report = .{ .allocator = allocator };
    var index: usize = 0;
    while (index < names.items.len) {
        const name = names.items[index];
        index += 1;
        // Skip duplicate baseline names; the first entry wins, matching
        // `Store.get`.
        while (index < names.items.len and std.mem.eql(u8, names.items[index], name)) {
            index += 1;
        }

        const baseline_entry = store.get(name);
        const current_entry = findEntry(current, name);
        var row: Row = .{ .name = try allocator.dupe(u8, name) };
        errdefer allocator.free(row.name);

        if (baseline_entry == null) {
            row.current_median_ns = try entryMedian(current_entry.?.*, true);
            row.status = .extra;
            result.extra += 1;
        } else if (current_entry == null) {
            row.baseline_median_ns = try entryMedian(baseline_entry.?.*, false);
            row.status = .missing;
            result.missing += 1;
        } else {
            const baseline_median = try entryMedian(baseline_entry.?.*, false);
            const current_median = try entryMedian(current_entry.?.*, true);
            row.baseline_median_ns = baseline_median;
            row.current_median_ns = current_median;
            row.speedup = safeDiv(baseline_median, current_median);
            row.p_value = welchPValue(baseline_entry.?.*, current_entry.?.*);

            if (current_median > baseline_median * options.max_regression_ratio) {
                row.status = .regressed;
                result.regressions += 1;
            } else if (baseline_median > current_median * options.max_regression_ratio) {
                row.status = .improved;
                result.improvements += 1;
            }
        }

        try rows.append(allocator, row);
    }

    result.rows = try rows.toOwnedSlice(allocator);
    errdefer result.deinit();
    try result.writeText(writer);
    return result;
}

fn validateUnique(current: []const baseline.Entry) !void {
    for (current, 0..) |entry, index| {
        for (current[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateEntry;
        }
    }
}

fn findEntry(current: []const baseline.Entry, name: []const u8) ?*const baseline.Entry {
    for (current) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn entryMedian(entry: baseline.Entry, is_current: bool) !f64 {
    if (entry.samples_ns.len != 0) return stats.median(u64, entry.samples_ns);
    if (entry.summary.count != 0) return entry.summary.median;
    return if (is_current) error.InvalidEntry else error.InvalidBaseline;
}

fn welchPValue(
    baseline_entry: baseline.Entry,
    current_entry: baseline.Entry,
) ?f64 {
    if (baseline_entry.samples_ns.len < 2 or current_entry.samples_ns.len < 2) {
        return null;
    }
    const welch = stats.welchTTest(
        u64,
        baseline_entry.samples_ns,
        current_entry.samples_ns,
    ) catch return null;
    return welch.p_approx;
}

fn formatOptional(buffer: []u8, value: ?f64, comptime format: []const u8) []const u8 {
    const number = value orelse return "-";
    return std.fmt.bufPrint(buffer, format, .{number}) catch "-";
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn safeDiv(numerator: f64, denominator: f64) f64 {
    if (denominator == 0) {
        if (numerator == 0) return 0;
        return if (numerator > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    return numerator / denominator;
}

fn sampleEntry(name: []const u8, samples: []const u64) baseline.Entry {
    return .{
        .name = name,
        .samples_ns = samples,
        .summary = stats.summarize(u64, samples),
    };
}

test "report: mixed regressions, improvements, missing, and extra" {
    const alloc = std.testing.allocator;
    const baseline_alpha = [_]u64{ 100, 100, 100 };
    const baseline_beta = [_]u64{ 200, 200, 200 };
    const baseline_gamma = [_]u64{ 300, 300, 300 };
    const current_alpha = [_]u64{ 50, 50, 50 };
    const current_beta = [_]u64{ 250, 250, 250 };
    const current_delta = [_]u64{ 75, 75, 75 };

    const store: baseline.Store = .{
        .allocator = alloc,
        .entries = &.{
            sampleEntry("beta", &baseline_beta),
            sampleEntry("gamma", &baseline_gamma),
            sampleEntry("alpha", &baseline_alpha),
        },
    };
    const current = [_]baseline.Entry{
        sampleEntry("delta", &current_delta),
        sampleEntry("beta", &current_beta),
        sampleEntry("alpha", &current_alpha),
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var result = try report(alloc, &out.writer, &store, &current, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.regressions);
    try std.testing.expectEqual(@as(usize, 1), result.improvements);
    try std.testing.expectEqual(@as(usize, 1), result.missing);
    try std.testing.expectEqual(@as(usize, 1), result.extra);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(@as(usize, 4), result.rows.len);

    // Rows are sorted by name: alpha, beta, delta, gamma.
    try std.testing.expectEqualStrings("alpha", result.rows[0].name);
    try std.testing.expectEqual(Status.improved, result.rows[0].status);
    try std.testing.expectEqualStrings("beta", result.rows[1].name);
    try std.testing.expectEqual(Status.regressed, result.rows[1].status);
    try std.testing.expectEqualStrings("delta", result.rows[2].name);
    try std.testing.expectEqual(Status.extra, result.rows[2].status);
    try std.testing.expectEqualStrings("gamma", result.rows[3].name);
    try std.testing.expectEqual(Status.missing, result.rows[3].status);
    try std.testing.expectEqual(@as(?f64, 2), result.rows[0].speedup);
    try std.testing.expectEqual(@as(?f64, 0.8), result.rows[1].speedup);
    try std.testing.expect(result.rows[0].p_value != null);

    try std.testing.expectEqualStrings(
        \\name                     baseline_ns   current_ns   speedup   p_value   status
        \\------------------------ ------------ ------------ --------- --------- ----------
        \\alpha                             100           50     2.00x    0.0000 IMPROVED
        \\beta                              200          250     0.80x    0.0000 REGRESSED
        \\delta                               -           75         -         - EXTRA
        \\gamma                             300            -         -         - MISSING
        \\summary: regressions=1 improvements=1 missing=1 extra=1
        \\
    , out.written());

    const json = try result.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        \\{
        \\  "summary": {
        \\    "regressions": 1,
        \\    "improvements": 1,
        \\    "missing": 1,
        \\    "extra": 1
        \\  },
        \\  "rows": [
        \\    {
        \\      "name": "alpha",
        \\      "baseline_median_ns": 100,
        \\      "current_median_ns": 50,
        \\      "speedup": 2,
        \\      "p_value": 0,
        \\      "status": "improved"
        \\    },
        \\    {
        \\      "name": "beta",
        \\      "baseline_median_ns": 200,
        \\      "current_median_ns": 250,
        \\      "speedup": 0.8,
        \\      "p_value": 0,
        \\      "status": "regressed"
        \\    },
        \\    {
        \\      "name": "delta",
        \\      "current_median_ns": 75,
        \\      "status": "extra"
        \\    },
        \\    {
        \\      "name": "gamma",
        \\      "baseline_median_ns": 300,
        \\      "status": "missing"
        \\    }
        \\  ]
        \\}
    , json);
}

test "report: text snapshot for an empty store" {
    const alloc = std.testing.allocator;
    var store = baseline.Store.init(alloc);
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var result = try report(alloc, &out.writer, &store, &.{}, .{});
    defer result.deinit();

    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqualStrings(
        \\name                     baseline_ns   current_ns   speedup   p_value   status
        \\------------------------ ------------ ------------ --------- --------- ----------
        \\summary: regressions=0 improvements=0 missing=0 extra=0
        \\
    , out.written());
}

test "report: JSON snapshot for an empty store" {
    const alloc = std.testing.allocator;
    var store = baseline.Store.init(alloc);
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var result = try report(alloc, &out.writer, &store, &.{}, .{});
    defer result.deinit();

    const json = try result.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        \\{
        \\  "summary": {
        \\    "regressions": 0,
        \\    "improvements": 0,
        \\    "missing": 0,
        \\    "extra": 0
        \\  },
        \\  "rows": []
        \\}
    , json);
}

test "report: duplicate current names are rejected" {
    const alloc = std.testing.allocator;
    var store = baseline.Store.init(alloc);
    defer store.deinit();

    const samples = [_]u64{ 10, 10 };
    const current = [_]baseline.Entry{
        sampleEntry("same", &samples),
        sampleEntry("same", &samples),
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.testing.expectError(
        error.DuplicateEntry,
        report(alloc, &out.writer, &store, &current, .{}),
    );
}

test "report: invalid regression ratio is rejected" {
    const alloc = std.testing.allocator;
    var store = baseline.Store.init(alloc);
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.testing.expectError(
        error.InvalidOptions,
        report(alloc, &out.writer, &store, &.{}, .{ .max_regression_ratio = 0 }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        report(alloc, &out.writer, &store, &.{}, .{
            .max_regression_ratio = std.math.nan(f64),
        }),
    );
}

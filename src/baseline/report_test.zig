//! Tests for deterministic baseline comparison reports.

const std = @import("std");
const baseline = @import("store.zig");
const stats = @import("../stats.zig");
const report_mod = @import("report.zig");
const report = report_mod.report;
const Status = report_mod.Status;

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

test "report: Markdown snapshot and determinism" {
    const alloc = std.testing.allocator;
    const baseline_samples = [_]u64{ 100, 100, 100 };
    const current_samples = [_]u64{ 130, 130, 130 };

    const store: baseline.Store = .{
        .allocator = alloc,
        .entries = &.{.{
            .name = "render",
            .samples_ns = &baseline_samples,
            .summary = stats.summarize(u64, &baseline_samples),
        }},
    };
    const current = [_]baseline.Entry{.{
        .name = "render",
        .samples_ns = &current_samples,
        .summary = stats.summarize(u64, &current_samples),
    }};

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var result = try report(alloc, &out.writer, &store, &current, .{});
    defer result.deinit();

    const first = try result.toMarkdown(alloc);
    defer alloc.free(first);
    const second = try result.toMarkdown(alloc);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(
        std.mem.find(u8, first, "| name | baseline_ns | current_ns | speedup | p_value | status |") != null,
    );
    try std.testing.expect(std.mem.find(u8, first, "| render | 100 | 130 | 0.77x |") != null);
    try std.testing.expect(std.mem.find(u8, first, "| REGRESSED |") != null);
}

test "report: non-finite speedup is omitted from JSON" {
    const alloc = std.testing.allocator;
    const baseline_samples = [_]u64{ 100, 100, 100 };
    const current_samples = [_]u64{ 0, 0, 0 };
    const store: baseline.Store = .{
        .allocator = alloc,
        .entries = &.{sampleEntry("render", &baseline_samples)},
    };
    const current = [_]baseline.Entry{
        sampleEntry("render", &current_samples),
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var result = try report(alloc, &out.writer, &store, &current, .{});
    defer result.deinit();

    try std.testing.expectEqual(Status.improved, result.rows[0].status);
    try std.testing.expect(std.math.isInf(result.rows[0].speedup.?));

    const json = try result.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"speedup\"") == null);

    // The rendered document must remain parseable JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
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

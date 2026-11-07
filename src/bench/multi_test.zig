//! Tests for rotating multi-implementation comparison.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const stats = @import("../stats.zig");

test "bench multi: compareMany rotates order and keeps per-runner samples" {
    const Log = struct {
        order: [16]usize = undefined,
        len: usize = 0,
    };
    const Slot = struct {
        log: *Log,
        index: usize,

        fn run(context: *anyopaque, _: Allocator, _: std.Io) anyerror!u64 {
            const slot: *@This() = @ptrCast(@alignCast(context));
            if (slot.log.len < slot.log.order.len) {
                slot.log.order[slot.log.len] = slot.index;
                slot.log.len += 1;
            }
            return slot.index + 1;
        }
    };

    var log: Log = .{};
    var slots = [_]Slot{
        .{ .log = &log, .index = 0 },
        .{ .log = &log, .index = 1 },
        .{ .log = &log, .index = 2 },
    };
    const runners = [_]bench.NamedRunner{
        .{ .name = "alpha", .runner = .{ .context = &slots[0], .run = Slot.run } },
        .{ .name = "beta", .runner = .{ .context = &slots[1], .run = Slot.run } },
        .{ .name = "gamma", .runner = .{ .context = &slots[2], .run = Slot.run } },
    };

    var result = try bench.compareMany(std.testing.allocator, std.testing.io, .{
        .warmup_iterations = 1,
        .iterations = 3,
    }, &runners);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.count());
    try std.testing.expectEqual(@as(usize, 3), result.rounds);
    try std.testing.expectEqual(@as(usize, 3), result.pairs.len);
    for (result.samples_ns) |samples| {
        try std.testing.expectEqual(@as(usize, 3), samples.len);
    }

    // One warmup round in registration order, then three measured rounds with
    // a rotating starting point.
    const expected = [_]usize{ 0, 1, 2, 0, 1, 2, 1, 2, 0, 2, 0, 1 };
    try std.testing.expectEqualSlices(usize, &expected, log.order[0..log.len]);
}

test "bench multi: fromSamples computes summaries and pairwise comparisons" {
    const a_samples = [_]u64{ 100, 100, 100 };
    const b_samples = [_]u64{ 200, 200, 200 };
    const c_samples = [_]u64{ 150, 150, 150 };
    const names = [_][]const u8{ "a", "b", "c" };
    const samples = [_][]const u64{ &a_samples, &b_samples, &c_samples };

    var result = try bench.MultiComparison.fromSamples(
        std.testing.allocator,
        &names,
        &samples,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.pairs.len);
    try std.testing.expectEqual(@as(usize, 3), result.rounds);
    try std.testing.expectEqual(@as(f64, 100), result.summaries[0].median);
    try std.testing.expectEqual(@as(f64, 150), result.summaryOf("c").?.median);

    const ab = result.comparisonOf("a", "b").?;
    try std.testing.expectEqual(@as(f64, 0.5), ab.speedup());
    try std.testing.expectEqual(@as(f64, 0), ab.p_value);
    try std.testing.expect(ab.significant);
    // The rank test is conservative with three heavily tied samples, but it
    // still separates the distributions at the conventional level.
    try std.testing.expect(ab.robust_p_value < 0.05);
    try std.testing.expect(ab.robust_significant);

    // Reversed names flip the ratio but keep the two-sided p-value.
    const ba = result.comparisonOf("b", "a").?;
    try std.testing.expectEqual(@as(f64, 2.0), ba.speedup());
    try std.testing.expectEqual(ab.p_value, ba.p_value);

    try std.testing.expect(result.comparisonOf("a", "a") == null);
    try std.testing.expect(result.comparisonOf("a", "missing") == null);

    try std.testing.expect(try result.gatePair("b", "a", 1.9, 0.05));
    try std.testing.expect(!try result.gatePair("a", "b", 0.9, 0.05));
    try std.testing.expect(try result.gateRobustPair("b", "a", 1.9, 0.05));
    try std.testing.expectError(
        error.InvalidPair,
        result.gatePair("a", "a", 1.0, 0.05),
    );
    try std.testing.expectError(
        error.UnknownName,
        result.gatePair("a", "missing", 1.0, 0.05),
    );
}

test "bench multi: text and JSON reports are deterministic" {
    const a_samples = [_]u64{ 100, 110, 90 };
    const b_samples = [_]u64{ 200, 210, 190 };
    const names = [_][]const u8{ "alpha", "beta" };
    const samples = [_][]const u64{ &a_samples, &b_samples };

    var result = try bench.MultiComparison.fromSamples(
        std.testing.allocator,
        &names,
        &samples,
    );
    defer result.deinit();

    const first_text = try result.toText(std.testing.allocator);
    defer std.testing.allocator.free(first_text);
    const second_text = try result.toText(std.testing.allocator);
    defer std.testing.allocator.free(second_text);
    try std.testing.expectEqualStrings(first_text, second_text);
    try std.testing.expect(std.mem.find(u8, first_text, "implementation\titerations") != null);
    try std.testing.expect(std.mem.find(u8, first_text, "alpha\t3\t") != null);
    try std.testing.expect(std.mem.find(u8, first_text, "alpha\tbeta\t0.500") != null);

    const first_json = try result.toJson(std.testing.allocator);
    defer std.testing.allocator.free(first_json);
    const second_json = try result.toJson(std.testing.allocator);
    defer std.testing.allocator.free(second_json);
    try std.testing.expectEqualStrings(first_json, second_json);

    const ParsedRunner = struct {
        name: []const u8,
        iterations: usize,
        summary: stats.Summary,
    };
    const ParsedPair = struct {
        a: []const u8,
        b: []const u8,
        speedup: ?f64,
        p_value: f64,
        significant: bool,
        robust_p_value: f64,
        robust_significant: bool,
    };
    const Parsed = struct {
        rounds: usize,
        batch_size: usize,
        warmup_iterations: usize,
        runners: []const ParsedRunner,
        pairs: []const ParsedPair,
    };

    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        first_json,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.rounds);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.batch_size);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.runners.len);
    try std.testing.expectEqualStrings("alpha", parsed.value.runners[0].name);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.runners[0].iterations);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.pairs.len);
    try std.testing.expectEqualStrings("alpha", parsed.value.pairs[0].a);
    try std.testing.expectEqualStrings("beta", parsed.value.pairs[0].b);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), parsed.value.pairs[0].speedup.?, 1e-12);
}

test "bench multi: rejects invalid names, options, and samples" {
    const Noop = struct {
        fn run(_: *anyopaque, _: Allocator, _: std.Io) anyerror!u64 {
            return 0;
        }
    };

    var dummy: u64 = 0;
    const runners = [_]bench.NamedRunner{
        .{ .name = "one", .runner = .{ .context = &dummy, .run = Noop.run } },
        .{ .name = "two", .runner = .{ .context = &dummy, .run = Noop.run } },
    };

    try std.testing.expectError(
        error.InvalidOptions,
        bench.compareMany(std.testing.allocator, std.testing.io, .{
            .iterations = 0,
        }, &runners),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        bench.compareMany(std.testing.allocator, std.testing.io, .{
            .batch_size = 0,
        }, &runners),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        bench.compareMany(
            std.testing.allocator,
            std.testing.io,
            .{},
            &[_]bench.NamedRunner{},
        ),
    );

    const empty_name = [_]bench.NamedRunner{
        .{ .name = "", .runner = .{ .context = &dummy, .run = Noop.run } },
    };
    try std.testing.expectError(
        error.InvalidName,
        bench.compareMany(std.testing.allocator, std.testing.io, .{}, &empty_name),
    );

    const duplicate = [_]bench.NamedRunner{
        .{ .name = "same", .runner = .{ .context = &dummy, .run = Noop.run } },
        .{ .name = "same", .runner = .{ .context = &dummy, .run = Noop.run } },
    };
    try std.testing.expectError(
        error.DuplicateName,
        bench.compareMany(std.testing.allocator, std.testing.io, .{}, &duplicate),
    );

    const names = [_][]const u8{"a"};
    try std.testing.expectError(
        error.InvalidOptions,
        bench.MultiComparison.fromSamples(std.testing.allocator, &names, &.{}),
    );

    const empty_samples = [_]u64{};
    const empty = [_][]const u64{&empty_samples};
    try std.testing.expectError(
        error.InvalidSamples,
        bench.MultiComparison.fromSamples(std.testing.allocator, &names, &empty),
    );

    const bad_names = [_][]const u8{ "", "" };
    const good_samples = [_][]const u64{ &.{1}, &.{2} };
    try std.testing.expectError(
        error.InvalidName,
        bench.MultiComparison.fromSamples(
            std.testing.allocator,
            &bad_names,
            &good_samples,
        ),
    );

    const duplicate_names = [_][]const u8{ "same", "same" };
    try std.testing.expectError(
        error.DuplicateName,
        bench.MultiComparison.fromSamples(
            std.testing.allocator,
            &duplicate_names,
            &good_samples,
        ),
    );
}

test "bench multi: toEntries borrows names, samples, and summaries" {
    const a_samples = [_]u64{ 100, 110, 90 };
    const b_samples = [_]u64{ 200, 210, 190 };
    const names = [_][]const u8{ "alpha", "beta" };
    const samples = [_][]const u64{ &a_samples, &b_samples };

    var result = try bench.MultiComparison.fromSamples(
        std.testing.allocator,
        &names,
        &samples,
    );
    defer result.deinit();

    const entries = try result.toEntries(std.testing.allocator, "fingerprint");
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("alpha", entries[0].name);
    try std.testing.expectEqualStrings("fingerprint", entries[0].environment_fingerprint);
    try std.testing.expectEqualSlices(u64, &a_samples, entries[0].samples_ns);
    try std.testing.expectEqual(@as(f64, 100), entries[0].summary.median);
}

test "bench multi: a single runner has no pairs" {
    const samples = [_]u64{ 10, 20, 30 };
    const names = [_][]const u8{"only"};
    const sample_slices = [_][]const u64{&samples};

    var result = try bench.MultiComparison.fromSamples(
        std.testing.allocator,
        &names,
        &sample_slices,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqual(@as(usize, 0), result.pairs.len);

    const text = try result.toText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "speedup") == null);
}

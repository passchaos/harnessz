//! Interleaved multi-implementation benchmark comparison.
//!
//! `compareMany` rotates the implementation order every round so ordering bias
//! is spread across all candidates instead of favoring the first or last one.
//! Each candidate keeps its own sample slice, and every pair gets a
//! `bench.Comparison` with a two-sided Welch p-value.
//!
//! Like `bench.compare`, timing values are not asserted by unit tests. The
//! report and gate logic are tested through `MultiComparison.fromSamples`,
//! which works on synthetic samples.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const stats = @import("../stats.zig");
const baseline = @import("../baseline.zig");
const measurement = @import("measure.zig");

pub const NamedRunner = struct {
    name: []const u8,
    runner: bench.Runner,
};

pub const Pair = struct {
    /// Index of the numerator candidate.
    a: usize,
    /// Index of the denominator candidate.
    b: usize,
    comparison: bench.Comparison,
};

pub const MultiComparison = struct {
    allocator: Allocator = std.heap.page_allocator,
    arena: ?*std.heap.ArenaAllocator = null,
    names: [][]const u8 = &.{},
    samples_ns: [][]u64 = &.{},
    summaries: []stats.Summary = &.{},
    /// All `i < j` pairs in lexicographic index order.
    pairs: []Pair = &.{},
    /// Measured rounds. Equal to the shortest sample slice for
    /// `fromSamples`.
    rounds: usize = 0,
    batch_size: usize = 1,
    warmup_iterations: usize = 0,

    pub fn deinit(self: *MultiComparison) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    pub fn count(self: MultiComparison) usize {
        return self.names.len;
    }

    /// Build a comparison from already-collected samples. Names and samples
    /// are copied into an arena owned by the result; call `deinit()`.
    pub fn fromSamples(
        alloc: Allocator,
        names: []const []const u8,
        samples: []const []const u64,
    ) !MultiComparison {
        return fromSamplesImpl(alloc, names, samples);
    }

    pub fn indexOf(self: MultiComparison, name: []const u8) ?usize {
        for (self.names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    pub fn summaryOf(self: MultiComparison, name: []const u8) ?stats.Summary {
        const index = self.indexOf(name) orelse return null;
        return self.summaries[index];
    }

    /// Pairwise comparison with `a_name` as the numerator: `speedup() > 1`
    /// means `b_name` is faster. Returns null for unknown or identical names.
    pub fn comparisonOf(
        self: MultiComparison,
        a_name: []const u8,
        b_name: []const u8,
    ) ?bench.Comparison {
        const a = self.indexOf(a_name) orelse return null;
        const b = self.indexOf(b_name) orelse return null;
        if (a == b) return null;

        const low = @min(a, b);
        const high = @max(a, b);
        for (self.pairs) |pair| {
            if (pair.a != low or pair.b != high) continue;
            return if (a == low) pair.comparison else flip(pair.comparison);
        }
        return null;
    }

    /// `gateSignificant` for a named pair. Unknown names return
    /// `error.UnknownName`; identical names return `error.InvalidPair`.
    pub fn gatePair(
        self: MultiComparison,
        a_name: []const u8,
        b_name: []const u8,
        min_ratio: f64,
        max_p_value: f64,
    ) !bool {
        if (std.mem.eql(u8, a_name, b_name)) return error.InvalidPair;
        const comparison = self.comparisonOf(a_name, b_name) orelse
            return error.UnknownName;
        return comparison.gateSignificant(min_ratio, max_p_value);
    }

    /// `gateRobust` for a named pair. Unknown names return
    /// `error.UnknownName`; identical names return `error.InvalidPair`.
    pub fn gateRobustPair(
        self: MultiComparison,
        a_name: []const u8,
        b_name: []const u8,
        min_ratio: f64,
        max_p_value: f64,
    ) !bool {
        if (std.mem.eql(u8, a_name, b_name)) return error.InvalidPair;
        const comparison = self.comparisonOf(a_name, b_name) orelse
            return error.UnknownName;
        return comparison.gateRobust(min_ratio, max_p_value);
    }

    /// Borrow this comparison's names, samples, and summaries as baseline
    /// entries. The returned slice is allocated with `alloc`; the strings and
    /// sample slices stay owned by `self` and must outlive the entries.
    pub fn toEntries(
        self: MultiComparison,
        alloc: Allocator,
        environment_fingerprint: []const u8,
    ) ![]baseline.Entry {
        const entries = try alloc.alloc(baseline.Entry, self.names.len);
        for (entries, 0..) |*entry, index| {
            entry.* = .{
                .name = self.names[index],
                .environment_fingerprint = environment_fingerprint,
                .samples_ns = self.samples_ns[index],
                .summary = self.summaries[index],
            };
        }
        return entries;
    }

    /// Deterministic text table: one row per implementation in registration
    /// order, followed by one row per pair.
    pub fn writeText(self: MultiComparison, writer: *std.Io.Writer) !void {
        try writer.writeAll(
            "implementation\titerations\tmin_ns\tmean_ns\tmedian_ns\tp90_ns\tp99_ns\n",
        );
        for (self.names, 0..) |name, index| {
            const summary = self.summaries[index];
            try writer.print("{s}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\n", .{
                name,
                self.samples_ns[index].len,
                summary.min,
                summary.mean,
                summary.median,
                summary.p90,
                summary.p99,
            });
        }

        if (self.pairs.len == 0) return;
        try writer.writeAll(
            "\na\tb\tspeedup\tp_value\tsignificant\trobust_p_value\trobust_significant\n",
        );
        for (self.pairs) |pair| {
            try writer.print("{s}\t{s}\t{d:.3}\t{d:.6}\t{s}\t{d:.6}\t{s}\n", .{
                self.names[pair.a],
                self.names[pair.b],
                pair.comparison.speedup(),
                pair.comparison.p_value,
                if (pair.comparison.significant) "yes" else "no",
                pair.comparison.robust_p_value,
                if (pair.comparison.robust_significant) "yes" else "no",
            });
        }
    }

    pub fn toText(self: MultiComparison, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeText(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeJson(self: MultiComparison, writer: *std.Io.Writer) !void {
        const RunnerWire = struct {
            name: []const u8,
            iterations: usize,
            summary: stats.Summary,
        };
        const PairWire = struct {
            a: []const u8,
            b: []const u8,
            /// `null` when the speedup is not finite (for example, a zero
            /// candidate median). JSON has no representation for infinity.
            speedup: ?f64,
            p_value: f64,
            significant: bool,
            robust_p_value: f64,
            robust_significant: bool,
        };
        const Wire = struct {
            rounds: usize,
            batch_size: usize,
            warmup_iterations: usize,
            runners: []const RunnerWire,
            pairs: []const PairWire,
        };

        // `writeJson` takes no allocator; temporary wire arrays use the page
        // allocator, matching the existing stats helpers.
        const alloc = std.heap.page_allocator;
        const runner_wires = try alloc.alloc(RunnerWire, self.names.len);
        defer alloc.free(runner_wires);
        for (runner_wires, 0..) |*wire, index| {
            wire.* = .{
                .name = self.names[index],
                .iterations = self.samples_ns[index].len,
                .summary = self.summaries[index],
            };
        }

        const pair_wires = try alloc.alloc(PairWire, self.pairs.len);
        defer alloc.free(pair_wires);
        for (pair_wires, 0..) |*wire, index| {
            const pair = self.pairs[index];
            wire.* = .{
                .a = self.names[pair.a],
                .b = self.names[pair.b],
                .speedup = finiteOptional(pair.comparison.speedup()),
                .p_value = pair.comparison.p_value,
                .significant = pair.comparison.significant,
                .robust_p_value = pair.comparison.robust_p_value,
                .robust_significant = pair.comparison.robust_significant,
            };
        }

        try std.json.Stringify.value(Wire{
            .rounds = self.rounds,
            .batch_size = self.batch_size,
            .warmup_iterations = self.warmup_iterations,
            .runners = runner_wires,
            .pairs = pair_wires,
        }, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
        }, writer);
    }

    pub fn toJson(self: MultiComparison, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};

fn fromSamplesImpl(
    alloc: Allocator,
    names: []const []const u8,
    samples: []const []const u64,
) !MultiComparison {
    if (names.len == 0 or names.len != samples.len) return error.InvalidOptions;
    try validateNames(names);
    for (samples) |candidate| {
        if (candidate.len == 0) return error.InvalidSamples;
    }

    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const owned_names = try arena_alloc.alloc([]const u8, names.len);
    const owned_samples = try arena_alloc.alloc([]u64, samples.len);
    var rounds: usize = std.math.maxInt(usize);
    for (names, 0..) |name, index| {
        owned_names[index] = try arena_alloc.dupe(u8, name);
        owned_samples[index] = try arena_alloc.dupe(u64, samples[index]);
        rounds = @min(rounds, samples[index].len);
    }

    return build(
        alloc,
        arena,
        owned_names,
        owned_samples,
        rounds,
        1,
        0,
    );
}

/// Interleaved multi-implementation comparison. Each round visits every
/// runner once, rotating the starting point so no candidate is consistently
/// measured first. `options.iterations` is the number of rounds;
/// `options.min_time_ns` is ignored, as for `bench.compare`.
pub fn compareMany(
    alloc: Allocator,
    io: std.Io,
    options: bench.Options,
    runners: []const NamedRunner,
) !MultiComparison {
    if (runners.len == 0 or options.iterations == 0 or options.batch_size == 0) {
        return error.InvalidOptions;
    }
    try validateRunnerNames(runners);

    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const owned_names = try arena_alloc.alloc([]const u8, runners.len);
    const owned_samples = try arena_alloc.alloc([]u64, runners.len);
    for (runners, 0..) |candidate, index| {
        owned_names[index] = try arena_alloc.dupe(u8, candidate.name);
        owned_samples[index] = try arena_alloc.alloc(u64, options.iterations);
    }

    var warmup: usize = 0;
    while (warmup < options.warmup_iterations) : (warmup += 1) {
        for (runners) |candidate| {
            measurement.blackBox(try candidate.runner.call(alloc, io));
        }
    }

    var round: usize = 0;
    while (round < options.iterations) : (round += 1) {
        const offset = round % runners.len;
        for (0..runners.len) |step| {
            const index = (offset + step) % runners.len;
            const measured = try measurement.runner(
                alloc,
                io,
                options.clock,
                runners[index].runner,
                options.batch_size,
            );
            owned_samples[index][round] = measured.elapsed_ns;
        }
    }

    return build(
        alloc,
        arena,
        owned_names,
        owned_samples,
        options.iterations,
        options.batch_size,
        options.warmup_iterations,
    );
}

fn build(
    alloc: Allocator,
    arena: *std.heap.ArenaAllocator,
    names: [][]const u8,
    samples: [][]u64,
    rounds: usize,
    batch_size: usize,
    warmup_iterations: usize,
) !MultiComparison {
    const arena_alloc = arena.allocator();

    const summaries = try arena_alloc.alloc(stats.Summary, names.len);
    for (samples, 0..) |candidate, index| {
        summaries[index] = stats.summarize(u64, candidate);
    }

    const pair_count = names.len * (names.len - 1) / 2;
    const pairs = try arena_alloc.alloc(Pair, pair_count);
    var pair_index: usize = 0;
    for (0..names.len) |a| {
        for (a + 1..names.len) |b| {
            pairs[pair_index] = .{
                .a = a,
                .b = b,
                .comparison = bench.Comparison.fromSamples(samples[a], samples[b]),
            };
            pair_index += 1;
        }
    }

    return .{
        .allocator = alloc,
        .arena = arena,
        .names = names,
        .samples_ns = samples,
        .summaries = summaries,
        .pairs = pairs,
        .rounds = rounds,
        .batch_size = batch_size,
        .warmup_iterations = warmup_iterations,
    };
}

fn validateNames(names: []const []const u8) !void {
    for (names, 0..) |name, index| {
        if (name.len == 0) return error.InvalidName;
        for (names[0..index]) |previous| {
            if (std.mem.eql(u8, previous, name)) return error.DuplicateName;
        }
    }
}

fn validateRunnerNames(runners: []const NamedRunner) !void {
    for (runners, 0..) |candidate, index| {
        if (candidate.name.len == 0) return error.InvalidName;
        for (runners[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, candidate.name)) {
                return error.DuplicateName;
            }
        }
    }
}

fn flip(comparison: bench.Comparison) bench.Comparison {
    return .{
        .a = comparison.b,
        .b = comparison.a,
        .rounds = comparison.rounds,
        .p_value = comparison.p_value,
        .significant = comparison.significant,
        .robust_p_value = comparison.robust_p_value,
        .robust_significant = comparison.robust_significant,
    };
}

/// JSON cannot represent infinity or NaN; map non-finite values to null.
fn finiteOptional(value: f64) ?f64 {
    return if (std.math.isFinite(value)) value else null;
}

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

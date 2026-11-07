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
const num = @import("../num.zig");

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
                .speedup = num.finiteOptional(pair.comparison.speedup()),
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

test {
    _ = @import("multi_test.zig");
}

//! In-process benchmark suites over a `bench.registry.Registry`.
//!
//! Downstream repositories often ship one executable per benchmark kernel.
//! `runSuite` replaces that pattern with one call that runs every registered
//! benchmark in insertion order and returns per-benchmark samples plus a
//! deterministic text/JSON report. Process-isolated execution remains
//! available through `bench.process`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const registry_mod = @import("registry.zig");
const stats = @import("../stats.zig");
const baseline = @import("../baseline.zig");

pub const SuiteOptions = struct {
    run: bench.Options = .{},
    /// Run at most this many benchmarks in registration order. Zero means all.
    max_benchmarks: usize = 0,
    /// Collect peak RSS, peak allocated bytes, and allocation/free counts for
    /// each benchmark. Adds one counting-allocator wrapper per run.
    measure_memory: bool = false,
};

pub const Memory = struct {
    /// Process peak RSS in bytes, or null when unsupported.
    peak_rss_bytes: ?u64 = null,
    /// Peak live bytes allocated through the callback allocator.
    peak_allocated_bytes: u64 = 0,
    allocation_count: u64 = 0,
    free_count: u64 = 0,
};

pub const SuiteResult = struct {
    allocator: Allocator = std.heap.page_allocator,
    names: [][]u8 = &.{},
    results: []bench.Stats = &.{},
    /// Empty unless `SuiteOptions.measure_memory` was true.
    memory: []Memory = &.{},
    warmup_iterations: usize = 0,
    batch_size: usize = 1,

    pub fn deinit(self: *SuiteResult) void {
        for (self.results) |*result| result.deinit(self.allocator);
        for (self.names) |name| self.allocator.free(name);
        self.allocator.free(self.names);
        self.allocator.free(self.results);
        if (self.memory.len != 0) self.allocator.free(self.memory);
        self.* = undefined;
    }

    pub fn count(self: *const SuiteResult) usize {
        return self.names.len;
    }

    /// Find a benchmark by name. The returned pointer is owned by the suite.
    pub fn find(self: *const SuiteResult, name: []const u8) ?*const bench.Stats {
        for (self.names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return &self.results[index];
        }
        return null;
    }

    /// Borrow the suite's names, samples, and summaries as baseline entries.
    /// The returned slice is allocated with `alloc`; the strings and sample
    /// slices stay owned by `self` and must outlive the entries.
    pub fn toEntries(
        self: *const SuiteResult,
        alloc: Allocator,
        environment_fingerprint: []const u8,
    ) ![]baseline.Entry {
        const entries = try alloc.alloc(baseline.Entry, self.names.len);
        for (entries, 0..) |*entry, index| {
            entry.* = .{
                .name = self.names[index],
                .environment_fingerprint = environment_fingerprint,
                .samples_ns = self.results[index].samples_ns,
                .summary = self.results[index].distribution,
            };
        }
        return entries;
    }

    /// Deterministic text table in registration order. Memory columns are
    /// appended when the suite was run with `measure_memory = true`.
    pub fn writeText(self: *const SuiteResult, writer: *std.Io.Writer) !void {
        try writer.writeAll(
            "benchmark\titerations\tmin_ns\tmean_ns\tmedian_ns\tp90_ns\tp99_ns",
        );
        const measured_memory = self.memory.len != 0;
        if (measured_memory) {
            try writer.writeAll(
                "\tpeak_rss_bytes\tpeak_allocated_bytes\tallocations\tfrees",
            );
        }
        try writer.writeByte('\n');

        for (self.names, 0..) |name, index| {
            const summary = self.results[index].distribution;
            try writer.print("{s}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}", .{
                name,
                self.results[index].samples_ns.len,
                summary.min,
                summary.mean,
                summary.median,
                summary.p90,
                summary.p99,
            });
            if (measured_memory) {
                const memory = self.memory[index];
                if (memory.peak_rss_bytes) |rss| {
                    try writer.print("\t{d}", .{rss});
                } else {
                    try writer.writeAll("\t-");
                }
                try writer.print("\t{d}\t{d}\t{d}", .{
                    memory.peak_allocated_bytes,
                    memory.allocation_count,
                    memory.free_count,
                });
            }
            try writer.writeByte('\n');
        }
    }

    pub fn toText(self: *const SuiteResult, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeText(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeJson(self: *const SuiteResult, writer: *std.Io.Writer) !void {
        const MemoryWire = struct {
            peak_rss_bytes: ?u64,
            peak_allocated_bytes: u64,
            allocation_count: u64,
            free_count: u64,
        };
        const BenchWire = struct {
            name: []const u8,
            iterations: usize,
            summary: stats.Summary,
            /// Null unless the suite was run with `measure_memory = true`.
            memory: ?MemoryWire,
        };
        const Wire = struct {
            warmup_iterations: usize,
            batch_size: usize,
            benchmarks: []const BenchWire,
        };

        const alloc = std.heap.page_allocator;
        const wires = try alloc.alloc(BenchWire, self.names.len);
        defer alloc.free(wires);
        for (wires, 0..) |*wire, index| {
            const memory: ?MemoryWire = if (self.memory.len == 0)
                null
            else
                .{
                    .peak_rss_bytes = self.memory[index].peak_rss_bytes,
                    .peak_allocated_bytes = self.memory[index].peak_allocated_bytes,
                    .allocation_count = self.memory[index].allocation_count,
                    .free_count = self.memory[index].free_count,
                };
            wire.* = .{
                .name = self.names[index],
                .iterations = self.results[index].samples_ns.len,
                .summary = self.results[index].distribution,
                .memory = memory,
            };
        }

        try std.json.Stringify.value(Wire{
            .warmup_iterations = self.warmup_iterations,
            .batch_size = self.batch_size,
            .benchmarks = wires,
        }, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
        }, writer);
    }

    pub fn toJson(self: *const SuiteResult, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};

/// Run registered benchmarks in registration order. An empty registry yields
/// an empty result; zero iterations or batch size returns
/// `error.InvalidOptions`. A callback error aborts the suite and releases all
/// partial results.
pub fn runSuite(
    alloc: Allocator,
    io: std.Io,
    registry: *const registry_mod.Registry,
    options: SuiteOptions,
) !SuiteResult {
    if (options.run.iterations == 0 or options.run.batch_size == 0) {
        return error.InvalidOptions;
    }

    const count = if (options.max_benchmarks == 0)
        registry.count()
    else
        @min(options.max_benchmarks, registry.count());

    const names = try alloc.alloc([]u8, count);
    errdefer alloc.free(names);
    var names_initialized: usize = 0;
    errdefer for (names[0..names_initialized]) |name| alloc.free(name);

    const results = try alloc.alloc(bench.Stats, count);
    errdefer alloc.free(results);
    var results_initialized: usize = 0;
    errdefer for (results[0..results_initialized]) |*result| result.deinit(alloc);

    const memory: []Memory = if (options.measure_memory)
        try alloc.alloc(Memory, count)
    else
        &.{};
    errdefer if (memory.len != 0) alloc.free(memory);

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const name = registry.nameAt(index).?;
        const entry = registry.entryAt(index).?;

        names[index] = try alloc.dupe(u8, name);
        names_initialized += 1;

        if (options.measure_memory) {
            const measured = try bench.runMeasuredRuntime(
                alloc,
                io,
                options.run,
                entry.context,
                entry.run,
            );
            results[index] = measured.timing;
            results_initialized += 1;
            memory[index] = .{
                .peak_rss_bytes = measured.peak_rss_bytes,
                .peak_allocated_bytes = measured.peak_allocated_bytes,
                .allocation_count = measured.allocation_count,
                .free_count = measured.free_count,
            };
        } else {
            results[index] = try bench.runRuntime(
                alloc,
                io,
                options.run,
                entry.context,
                entry.run,
            );
            results_initialized += 1;
        }
    }

    return .{
        .allocator = alloc,
        .names = names,
        .results = results,
        .memory = memory,
        .warmup_iterations = options.run.warmup_iterations,
        .batch_size = options.run.batch_size,
    };
}

const TestContext = struct {
    value: u64,
    calls: u64 = 0,
};

fn testRun(context: *anyopaque, _: Allocator, _: std.Io) !u64 {
    const typed: *TestContext = @ptrCast(@alignCast(context));
    typed.calls += 1;
    return typed.value + typed.calls;
}

test "bench suite: runs registry order and keeps per-benchmark samples" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var first: TestContext = .{ .value = 10 };
    var second: TestContext = .{ .value = 20 };
    try registry.add("first", .{ .context = &first, .run = testRun });
    try registry.add("second", .{ .context = &second, .run = testRun });

    var suite = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .warmup_iterations = 1, .iterations = 3 },
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 2), suite.count());
    try std.testing.expectEqualStrings("first", suite.names[0]);
    try std.testing.expectEqualStrings("second", suite.names[1]);
    for (suite.results) |result| {
        try std.testing.expectEqual(@as(usize, 3), result.samples_ns.len);
    }
    // One warmup call plus three measured calls per benchmark.
    try std.testing.expectEqual(@as(u64, 4), first.calls);
    try std.testing.expectEqual(@as(u64, 4), second.calls);
    try std.testing.expectEqual(@as(u64, 14), suite.find("first").?.last_result);
    try std.testing.expectEqual(@as(u64, 24), suite.find("second").?.last_result);
    try std.testing.expect(suite.find("missing") == null);
}

test "bench suite: text and JSON reports are deterministic" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 7 };
    try registry.add("alpha", .{ .context = &context, .run = testRun });
    try registry.add("beta", .{ .context = &context, .run = testRun });

    var suite = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .warmup_iterations = 0, .iterations = 2, .batch_size = 2 },
    });
    defer suite.deinit();

    const first_text = try suite.toText(alloc);
    defer alloc.free(first_text);
    const second_text = try suite.toText(alloc);
    defer alloc.free(second_text);
    try std.testing.expectEqualStrings(first_text, second_text);
    try std.testing.expect(std.mem.find(u8, first_text, "benchmark\titerations") != null);
    try std.testing.expect(std.mem.find(u8, first_text, "alpha\t2\t") != null);

    const first_json = try suite.toJson(alloc);
    defer alloc.free(first_json);
    const second_json = try suite.toJson(alloc);
    defer alloc.free(second_json);
    try std.testing.expectEqualStrings(first_json, second_json);

    const ParsedMemory = struct {
        peak_rss_bytes: ?u64,
        peak_allocated_bytes: u64,
        allocation_count: u64,
        free_count: u64,
    };
    const ParsedBench = struct {
        name: []const u8,
        iterations: usize,
        summary: stats.Summary,
        memory: ?ParsedMemory,
    };
    const Parsed = struct {
        warmup_iterations: usize,
        batch_size: usize,
        benchmarks: []const ParsedBench,
    };
    const parsed = try std.json.parseFromSlice(Parsed, alloc, first_json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.batch_size);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.benchmarks.len);
    try std.testing.expectEqualStrings("alpha", parsed.value.benchmarks[0].name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.benchmarks[0].iterations);
    try std.testing.expect(parsed.value.benchmarks[0].memory == null);
}

test "bench suite: max_benchmarks bounds registration order" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 1 };
    try registry.add("one", .{ .context = &context, .run = testRun });
    try registry.add("two", .{ .context = &context, .run = testRun });

    var suite = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .iterations = 1 },
        .max_benchmarks = 1,
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 1), suite.count());
    try std.testing.expectEqualStrings("one", suite.names[0]);
}

test "bench suite: empty registry and invalid options" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var empty = try runSuite(alloc, std.testing.io, &registry, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.count());

    try std.testing.expectError(
        error.InvalidOptions,
        runSuite(alloc, std.testing.io, &registry, .{ .run = .{ .iterations = 0 } }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        runSuite(alloc, std.testing.io, &registry, .{ .run = .{ .batch_size = 0 } }),
    );
}

test "bench suite: callback failure releases partial results" {
    const Failing = struct {
        fn run(_: *anyopaque, _: Allocator, _: std.Io) anyerror!u64 {
            return error.SyntheticSuiteFailure;
        }
    };

    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 1 };
    try registry.add("good", .{ .context = &context, .run = testRun });
    try registry.add("bad", .{ .context = &context, .run = Failing.run });

    try std.testing.expectError(
        error.SyntheticSuiteFailure,
        runSuite(alloc, std.testing.io, &registry, .{
            .run = .{ .iterations = 1 },
        }),
    );
}

test "bench suite: toEntries borrows names, samples, and summaries" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var context: TestContext = .{ .value = 3 };
    try registry.add("bench", .{ .context = &context, .run = testRun });

    var suite = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .iterations = 2 },
    });
    defer suite.deinit();

    const entries = try suite.toEntries(alloc, "fingerprint");
    defer alloc.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("bench", entries[0].name);
    try std.testing.expectEqualStrings("fingerprint", entries[0].environment_fingerprint);
    try std.testing.expectEqual(@as(usize, 2), entries[0].samples_ns.len);
}

const AllocContext = struct {
    calls: u64 = 0,

    fn run(context: *anyopaque, allocator: Allocator, _: std.Io) !u64 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        const buffer = try allocator.alloc(u8, 4096);
        defer allocator.free(buffer);
        @memset(buffer, 0xab);
        return buffer.len;
    }
};

test "bench suite: optional memory metrics" {
    const alloc = std.testing.allocator;
    var registry = registry_mod.Registry.init(alloc);
    defer registry.deinit();

    var context: AllocContext = .{};
    try registry.add("alloc", .{ .context = &context, .run = AllocContext.run });

    var suite = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .warmup_iterations = 1, .iterations = 2 },
        .measure_memory = true,
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 1), suite.memory.len);
    try std.testing.expectEqual(@as(u64, 4096), suite.memory[0].peak_allocated_bytes);
    try std.testing.expect(suite.memory[0].allocation_count > 0);
    try std.testing.expect(suite.memory[0].free_count > 0);
    if (suite.memory[0].peak_rss_bytes) |rss| {
        try std.testing.expect(rss > 0);
    }

    const text = try suite.toText(alloc);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "peak_allocated_bytes") != null);

    const json = try suite.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(
        std.mem.find(u8, json, "\"peak_allocated_bytes\": 4096") != null,
    );

    var plain = try runSuite(alloc, std.testing.io, &registry, .{
        .run = .{ .iterations = 1 },
    });
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 0), plain.memory.len);
    const plain_json = try plain.toJson(alloc);
    defer alloc.free(plain_json);
    try std.testing.expect(std.mem.find(u8, plain_json, "\"memory\": null") != null);
}

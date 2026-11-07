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

test {
    _ = @import("suite_test.zig");
}

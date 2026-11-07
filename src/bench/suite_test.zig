//! Tests for in-process benchmark suites.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const registry_mod = @import("registry.zig");
const stats = @import("../stats.zig");
const runSuite = bench.runSuite;

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

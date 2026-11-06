//! Package-level integration tests for the public `harnessz` module.

const std = @import("std");
const harnessz = @import("harnessz");

test "integration: golden, snapshot, and oracle workflow" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/render.txt",
        "pixels\n",
        .{ .update = true, .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.created, first.outcome);

    const second = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/render.txt",
        "pixels\n",
        .{ .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.matched, second.outcome);

    var snapshots = try harnessz.snapshot.Registry.init(alloc, io, .{
        .dir = tmp.dir,
        .update = true,
        .report = false,
    });
    defer snapshots.deinit();
    try snapshots.check("render/hash", "abc");
    try snapshots.check("render/hash", "abc");

    const stored = try tmp.dir.readFileAlloc(
        io,
        "snapshots/render/hash.snap",
        alloc,
        .limited(16),
    );
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("abc", stored);

    const bytes_report = harnessz.oracle.compareBytes("abc", stored);
    try std.testing.expect(bytes_report.ok());
    try std.testing.expectEqual(
        harnessz.oracle.checksum("abc"),
        harnessz.oracle.checksum(stored),
    );
}

test "integration: evidence manifest round-trip and path validation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/lib.zig", .data = "pub const x = 1;\n" });

    var original: harnessz.evidence.Manifest = .{
        .allocator = alloc,
        .entries = &.{
            .{
                .id = "feature",
                .status = .implemented,
                .implementation_paths = &.{"src/lib.zig"},
                .test_names = &.{"integration: feature"},
                .evidence_paths = &.{"docs/evidence/feature.md"},
                .notes = "integration fixture",
            },
        },
    };

    const json = try original.toJson(alloc);
    defer alloc.free(json);

    var parsed = try harnessz.evidence.Manifest.fromJson(alloc, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqualStrings("feature", parsed.entries[0].id);

    var report = try parsed.validatePaths(io, tmp.dir);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.total_paths);
    try std.testing.expectEqual(@as(usize, 1), report.missing.len);
    try std.testing.expectEqualStrings("docs/evidence/feature.md", report.missing[0].path);
}

test "integration: bench gate from synthetic samples" {
    const baseline = [_]u64{ 100, 100, 100 };
    const candidate = [_]u64{ 40, 40, 40 };
    const comparison = harnessz.bench.Comparison.fromSamples(&baseline, &candidate);
    try std.testing.expect(comparison.gate(2.0));
    try std.testing.expect(!comparison.gate(3.0));
    try std.testing.expectEqual(@as(f64, 2.5), comparison.speedup());
}

test "integration: fixture resolution" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "testdata");
    try tmp.dir.writeFile(io, .{ .sub_path = "testdata/sample.bin", .data = "data" });

    var resolved = try harnessz.fixture.resolve(alloc, io, "sample.bin", .{
        .base_dir = tmp.dir,
    });
    defer resolved.deinit(alloc);
    try std.testing.expectEqualStrings("testdata/sample.bin", resolved.path);
    try std.testing.expectEqual(harnessz.fixture.Source.testdata, resolved.source);
}

test "integration: baseline save, load, compare, and update" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const baseline_samples = [_]u64{ 100, 100, 100 };
    const store: harnessz.baseline.Store = .{
        .allocator = alloc,
        .entries = &.{.{
            .name = "render",
            .environment_fingerprint = "integration",
            .samples_ns = &baseline_samples,
            .summary = harnessz.stats.summarize(u64, &baseline_samples),
        }},
    };
    try store.save(io, tmp.dir, "bench/baseline.json");

    var loaded = harnessz.baseline.Store.init(alloc);
    defer loaded.deinit();
    try loaded.load(io, tmp.dir, "bench/baseline.json");
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.len);

    const faster = [_]u64{ 50, 50, 50 };
    const improved = try loaded.compare("render", &faster, .{});
    try std.testing.expect(!improved.regressed);
    try std.testing.expectEqual(@as(f64, 2), improved.speedup);

    const slower = [_]u64{ 130, 130, 130 };
    const regressed = try loaded.compare("render", &slower, .{});
    try std.testing.expect(regressed.regressed);
    try std.testing.expect(regressed.speedup < 1);

    try loaded.update(.{
        .name = "render",
        .environment_fingerprint = "integration-2",
        .samples_ns = &slower,
        .summary = harnessz.stats.summarize(u64, &slower),
    });
    try std.testing.expectEqualStrings("integration-2", loaded.entries[0].environment_fingerprint);
    try std.testing.expectEqualSlices(u64, &slower, loaded.entries[0].samples_ns);

    try std.testing.expectError(
        error.MissingBaseline,
        loaded.compare("missing", &faster, .{}),
    );
}

test "integration: golden normalization and canonical JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "case.json",
        "{\"b\":1,\"a\":{\"d\":2,\"c\":3}}",
        .{ .update = true, .allocator = alloc, .report = false },
    );

    const matched = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "case.json",
        "{\"a\":{\"c\":3,\"d\":2},\"b\":1}",
        .{
            .allocator = alloc,
            .report = false,
            .normalize = .{ .json_canonical = true },
        },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.matched, matched.outcome);

    const original = "{\"a\":{\"c\":3,\"d\":2},\"b\":2}";
    const updated = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "case.json",
        original,
        .{
            .update = true,
            .allocator = alloc,
            .report = false,
            .normalize = .{ .json_canonical = true },
        },
    );
    try std.testing.expectEqual(harnessz.golden.Outcome.updated, updated.outcome);

    const stored = try tmp.dir.readFileAlloc(io, "case.json", alloc, .limited(256));
    defer alloc.free(stored);
    try std.testing.expectEqualStrings(original, stored);
}

const IntegrationThreadedContext = struct {};

fn integrationStableWorker(
    context: *IntegrationThreadedContext,
    thread_index: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    _ = thread_index;
    try out.writeAll("stable\n");
}

fn integrationIndexedWorker(
    context: *IntegrationThreadedContext,
    thread_index: usize,
    out: *std.Io.Writer,
) !void {
    _ = context;
    try out.print("thread={d}\n", .{thread_index});
}

test "integration: threaded determinism stable and divergent producers" {
    var context: IntegrationThreadedContext = .{};

    var stable = try harnessz.determinism.runThreaded(
        std.testing.allocator,
        std.testing.io,
        .{ .thread_counts = &.{ 1, 2 }, .thread_runs = 1 },
        &context,
        integrationStableWorker,
    );
    defer stable.deinit();
    try std.testing.expect(stable.ok());
    try std.testing.expectEqual(@as(usize, 2), stable.thread_checksums.len);

    var divergent = try harnessz.determinism.runThreaded(
        std.testing.allocator,
        std.testing.io,
        .{ .thread_counts = &.{2}, .thread_runs = 1 },
        &context,
        integrationIndexedWorker,
    );
    defer divergent.deinit();
    try std.testing.expect(!divergent.ok());
    try std.testing.expectEqual(@as(?usize, 1), divergent.first_divergence_thread);
    try std.testing.expectEqual(@as(?usize, 7), divergent.divergence_offset);
}

test "integration: streaming stats, histogram, and confidence interval" {
    const alloc = std.testing.allocator;

    var accumulator: harnessz.stats.Accumulator = .init();
    for ([_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 }) |value| accumulator.add(value);
    try std.testing.expectEqual(@as(usize, 8), accumulator.count());
    try std.testing.expectEqual(@as(f64, 5), accumulator.mean());
    try std.testing.expectEqual(@as(f64, 4), accumulator.variance());
    try std.testing.expectEqual(@as(f64, 2), accumulator.summary().stddev);

    const values = [_]f64{ 0, 1, 2, 3 };
    var histogram = try harnessz.stats.Histogram.build(alloc, &values, 2);
    defer histogram.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 2, 2 }, histogram.counts);
    const json = try histogram.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"bucket_count\":2") != null);

    const interval = harnessz.stats.confidenceIntervalMean(&[_]f64{ 10, 10, 10 }, 1.96);
    try std.testing.expectEqual(@as(f64, 10), interval.lower);
    try std.testing.expectEqual(@as(f64, 10), interval.upper);
    try std.testing.expectEqual(@as(f64, 0), interval.margin);

    try std.testing.expectEqual(
        @as(f64, 5.5),
        harnessz.stats.trimmedMean(&[_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, 0.2),
    );
}

test "integration: ULP and complex oracles" {
    const one: f64 = 1.0;
    const next: f64 = @bitCast(@as(u64, @bitCast(one)) + 1);
    const ulp_report = harnessz.oracle.compareUlp(f64, one, next, 1);
    try std.testing.expect(ulp_report.equal);
    try std.testing.expectEqual(@as(u64, 1), ulp_report.ulp_distance);
    try std.testing.expect(!harnessz.oracle.compareUlp(f64, one, next, 0).equal);

    const Complex = std.math.Complex(f64);
    const expected = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
        .{ .re = 3.0, .im = 4.0 },
    };
    const actual = [_]Complex{
        .{ .re = 1.0, .im = 2.0 },
        .{ .re = 3.0 + 1e-9, .im = 4.0 },
    };
    try std.testing.expect(harnessz.oracle.compareComplexSlices(f64, &expected, &actual, .{
        .abs_tolerance = 1e-8,
    }).equal);
    try std.testing.expect(!harnessz.oracle.compareComplexSlices(f64, &expected, &actual, .{}).equal);
}

test "integration: golden directory and structural JSON oracle" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = [_]harnessz.golden.DirEntry{
        .{ .relative_path = "config.json", .bytes = "{\"b\":1,\"a\":2}" },
        .{ .relative_path = "nested/data.bin", .bytes = "\x00\x01" },
    };
    var created = try harnessz.golden.expectDirectory(
        io,
        tmp.dir,
        "golden-tree",
        &expected,
        .{ .update = true, .allocator = alloc, .report = false },
    );
    defer created.deinit();
    try std.testing.expectEqual(harnessz.golden.DirOutcome.created, created.outcome);

    var matched = try harnessz.golden.expectDirectory(
        io,
        tmp.dir,
        "golden-tree",
        &expected,
        .{ .allocator = alloc, .report = false },
    );
    defer matched.deinit();
    try std.testing.expect(matched.ok());

    var json_report = try harnessz.oracle.compareJson(
        "{\"a\":2,\"b\":[1,2]}",
        "{\"b\":[1,2],\"a\":2}",
        .{},
    );
    defer json_report.deinit();
    try std.testing.expect(json_report.ok());
}

test "integration: evidence test-name validation" {
    const alloc = std.testing.allocator;
    var manifest: harnessz.evidence.Manifest = .{
        .allocator = alloc,
        .entries = &.{.{
            .id = "feature",
            .test_names = &.{ "known test", "stale test" },
        }},
    };
    const known = [_][]const u8{"known test"};
    var report = try manifest.validateTests(&known);
    defer report.deinit();
    try std.testing.expect(!report.valid());
    try std.testing.expectEqual(@as(usize, 2), report.total_tests);
    try std.testing.expectEqualStrings("feature", report.unknown[0].entry_id);
    try std.testing.expectEqualStrings("stale test", report.unknown[0].name);
}

test "integration: significant bench gate and fingerprint enforcement" {
    const baseline = [_]u64{ 100, 101, 99, 100, 102, 100 };
    const candidate = [_]u64{ 50, 51, 49, 50, 52, 50 };
    const comparison = harnessz.bench.Comparison.fromSamples(&baseline, &candidate);
    try std.testing.expect(comparison.significant);
    try std.testing.expect(comparison.gateSignificant(1.5, 0.01));
    try std.testing.expect(!comparison.gateSignificant(3.0, 0.01));

    const store: harnessz.baseline.Store = .{
        .entries = &.{.{
            .name = "render",
            .environment_fingerprint = "machine-a/release-safe",
            .samples_ns = &baseline,
            .summary = harnessz.stats.summarize(u64, &baseline),
        }},
    };
    _ = try store.compare("render", &candidate, .{
        .require_fingerprint = true,
        .expected_fingerprint = "machine-a/release-safe",
    });
    try std.testing.expectError(error.EnvironmentMismatch, store.compare(
        "render",
        &candidate,
        .{
            .require_fingerprint = true,
            .expected_fingerprint = "machine-b/debug",
        },
    ));
}

test "integration: bench environment probes" {
    const rss = harnessz.bench.peakRssBytes(std.testing.io) catch
        return error.SkipZigTest;
    try std.testing.expect(rss > 0);

    const mask = harnessz.bench.affinityMask() catch return error.SkipZigTest;
    try std.testing.expect(mask.count() > 0);
}

test "integration: bench blackBox keeps a value observable" {
    var sink: u64 = 0;
    const value = @as(u64, 6) * 7;
    harnessz.bench.blackBox(value);
    const volatile_sink: *volatile u64 = &sink;
    volatile_sink.* = value;
    try std.testing.expectEqual(@as(u64, 42), volatile_sink.*);
}

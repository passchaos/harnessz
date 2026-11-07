//! Package-level integration tests for the public `harnessz` module.

const std = @import("std");
const builtin = @import("builtin");
const harnessz = @import("harnessz");
const bench_child = @import("bench_child");

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

fn expectedBenchChecksum() u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var index: u64 = 0;
    while (index < 1024) : (index += 1) {
        hash ^= (index *% 0x9e3779b97f4a7c15) >> 7;
        hash *%= 0x100000001b3;
    }
    return hash;
}

test "integration: process-isolated bench sample count and checksum" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var response = try harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "checksum",
        .warmup_iterations = 1,
        .iterations = 4,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &response);

    try std.testing.expectEqual(@as(usize, 4), response.samples_ns.len);
    try std.testing.expect(response.error_name == null);
    try std.testing.expectEqual(@as(?u64, expectedBenchChecksum()), response.checksum);

    // A second isolated run must observe the same deterministic checksum.
    var second = try harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "checksum",
        .warmup_iterations = 0,
        .iterations = 2,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &second);
    try std.testing.expectEqual(@as(usize, 2), second.samples_ns.len);
    try std.testing.expectEqual(response.checksum, second.checksum);
}

test "integration: process-isolated bench batch size" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var response = try harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "checksum",
        .warmup_iterations = 1,
        .iterations = 3,
        .batch_size = 4,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &response);

    try std.testing.expectEqual(@as(usize, 3), response.samples_ns.len);
    try std.testing.expectEqual(@as(?u64, expectedBenchChecksum()), response.checksum);
}

test "integration: process-isolated bench batch size calls callback per batch" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var response = try harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "call-count",
        .warmup_iterations = 0,
        .iterations = 2,
        .batch_size = 3,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &response);

    try std.testing.expectEqual(@as(usize, 2), response.samples_ns.len);
    // Two samples of three calls each; the checksum is the last callback's
    // return value, which is the monotonic call counter.
    try std.testing.expectEqual(@as(?u64, 6), response.checksum);
}

test "integration: process-isolated bench reports memory metrics" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var response = try harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "alloc",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &response);

    try std.testing.expectEqual(@as(usize, 1), response.samples_ns.len);
    try std.testing.expectEqual(@as(?u64, 4096), response.checksum);
    try std.testing.expectEqual(@as(?u64, 4096), response.peak_allocated_bytes);
    if (comptime builtin.os.tag == .linux) {
        try std.testing.expect(response.peak_rss_bytes != null);
        try std.testing.expect(response.peak_rss_bytes.? > 0);
    }
}

test "integration: process-isolated bench error propagation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectError(error.BenchmarkFailed, harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "fail",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    }));

    var response = try harnessz.bench.process.runProcessResponse(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "fail",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer harnessz.bench.protocol.freeResponse(alloc, &response);
    try std.testing.expectEqual(@as(usize, 0), response.samples_ns.len);
    try std.testing.expectEqualStrings("SyntheticBenchFailure", response.error_name.?);
    try std.testing.expect(response.error_message != null);

    try std.testing.expectError(error.BenchmarkFailed, harnessz.bench.process.runProcess(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "does-not-exist",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    }));
}

test "integration: process runner typed failures for malformed responses" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Child exits nonzero without writing a protocol response.
    try std.testing.expectError(error.ChildExitFailure, harnessz.bench.process.runProcess(
        alloc,
        io,
        .{
            .argv = &.{bench_child.child_exe},
            .benchmark = "exit-failure",
            .warmup_iterations = 0,
            .iterations = 1,
            .timeout_ns = 10 * std.time.ns_per_s,
        },
    ));

    // Child exits zero but stdout is not a single valid JSON response.
    try std.testing.expectError(error.InvalidJson, harnessz.bench.process.runProcess(
        alloc,
        io,
        .{
            .argv = &.{bench_child.child_exe},
            .benchmark = "invalid-output",
            .warmup_iterations = 0,
            .iterations = 1,
            .timeout_ns = 10 * std.time.ns_per_s,
        },
    ));

    // Child exits zero with a valid response that contains no samples.
    try std.testing.expectError(error.InvalidResponse, harnessz.bench.process.runProcess(
        alloc,
        io,
        .{
            .argv = &.{bench_child.child_exe},
            .benchmark = "empty-response",
            .warmup_iterations = 0,
            .iterations = 1,
            .timeout_ns = 10 * std.time.ns_per_s,
        },
    ));
}

test "integration: process-isolated bench timeout" {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding or builtin.os.tag == .other) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const result = harnessz.bench.process.runProcess(alloc, std.testing.io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "slow",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 100 * std.time.ns_per_ms,
    });
    if (result) |response| {
        var owned = response;
        harnessz.bench.protocol.freeResponse(alloc, &owned);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.Timeout => {},
        // Process control or concurrency is unavailable on this platform.
        error.TimeoutUnavailable, error.SpawnFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "integration: bench child list mode" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ bench_child.child_exe, "--harnessz-list" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var waited = false;
    defer if (!waited) child.kill(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    var read_buffer: [1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buffer);
    try reader.interface.appendRemaining(alloc, &output, .limited(4096));

    const term = try child.wait(io);
    waited = true;
    const exit_code = switch (term) {
        .exited => |code| code,
        else => return error.ChildExitFailure,
    };
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    var parsed = try std.json.parseFromSlice([]const []const u8, alloc, output.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 12), parsed.value.len);
    try std.testing.expectEqualStrings("checksum", parsed.value[0]);
    try std.testing.expectEqualStrings("call-count", parsed.value[1]);
    try std.testing.expectEqualStrings("alloc", parsed.value[2]);
    try std.testing.expectEqualStrings("slow", parsed.value[3]);
    try std.testing.expectEqualStrings("fail", parsed.value[4]);
    try std.testing.expectEqualStrings("stderr-ok", parsed.value[5]);
    try std.testing.expectEqualStrings("stderr-fail", parsed.value[6]);
    try std.testing.expectEqualStrings("stderr-flood", parsed.value[7]);
    try std.testing.expectEqualStrings("tree", parsed.value[8]);
    try std.testing.expectEqualStrings("invalid-output", parsed.value[9]);
    try std.testing.expectEqualStrings("exit-failure", parsed.value[10]);
    try std.testing.expectEqualStrings("empty-response", parsed.value[11]);
}

test "integration: process runner bounds child stdout" {
    try std.testing.expectError(error.OutputTooLarge, harnessz.bench.process.runProcess(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{bench_child.child_exe},
            .benchmark = "checksum",
            .warmup_iterations = 0,
            .iterations = 1,
            .timeout_ns = 10 * std.time.ns_per_s,
            .max_output_bytes = 4,
        },
    ));
}

test "integration: process stderr captured on success" {
    const alloc = std.testing.allocator;
    var result = try harnessz.bench.process.runProcessCapture(alloc, std.testing.io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "stderr-ok",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer result.deinit(alloc);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(?u64, 42), result.response.checksum);
    try std.testing.expectEqual(@as(usize, 1), result.response.samples_ns.len);
    try std.testing.expect(!result.stderr_truncated);
    try std.testing.expect(
        std.mem.find(u8, result.stderr, "stderr-ok diagnostic") != null,
    );
}

test "integration: process stderr captured on benchmark failure" {
    const alloc = std.testing.allocator;
    var result = try harnessz.bench.process.runProcessCapture(alloc, std.testing.io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "stderr-fail",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer result.deinit(alloc);

    try std.testing.expectEqualStrings(
        "SyntheticBenchFailure",
        result.response.error_name.?,
    );
    try std.testing.expect(
        std.mem.find(u8, result.stderr, "deliberate stderr failure") != null,
    );

    // The strict runner still maps the error response to BenchmarkFailed.
    try std.testing.expectError(error.BenchmarkFailed, harnessz.bench.process.runProcess(
        alloc,
        std.testing.io,
        .{
            .argv = &.{bench_child.child_exe},
            .benchmark = "stderr-fail",
            .warmup_iterations = 0,
            .iterations = 1,
            .timeout_ns = 10 * std.time.ns_per_s,
        },
    ));
}

test "integration: oversized stderr is truncated without deadlock" {
    const alloc = std.testing.allocator;
    var result = try harnessz.bench.process.runProcessCapture(alloc, std.testing.io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "stderr-flood",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 10 * std.time.ns_per_s,
        .max_stderr_bytes = 1024,
    });
    defer result.deinit(alloc);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(?u64, 7), result.response.checksum);
    try std.testing.expectEqual(@as(usize, 1024), result.stderr.len);
    try std.testing.expect(result.stderr_truncated);
}

fn diagnosticNumber(bytes: []const u8, marker: []const u8) !i64 {
    const start = std.mem.find(u8, bytes, marker) orelse
        return error.MissingDiagnostic;
    const rest = bytes[start + marker.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return error.MissingDiagnostic;
    return std.fmt.parseInt(i64, rest[0..end], 10);
}

fn expectProcGone(io: std.Io, pid: i64) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}", .{pid});
        const exists = blk: {
            std.Io.Dir.accessAbsolute(io, path, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) return;
        try io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    }
    return error.ProcessStillAlive;
}

test "integration: timeout kills the child process group and grandchild" {
    // The /proc check and process-group semantics are Linux-specific.
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var result = try harnessz.bench.process.runProcessCapture(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .benchmark = "tree",
        .warmup_iterations = 0,
        .iterations = 1,
        .timeout_ns = 200 * std.time.ns_per_ms,
    });
    defer result.deinit(alloc);

    try std.testing.expect(result.timed_out);
    try std.testing.expectEqual(@as(usize, 0), result.response.samples_ns.len);

    const child_pid = try diagnosticNumber(result.stderr, "pid=");
    const child_pgid = try diagnosticNumber(result.stderr, " pgid=");
    const grandchild_pid = try diagnosticNumber(result.stderr, " grandchild=");
    try std.testing.expectEqual(child_pid, child_pgid);

    try expectProcGone(io, grandchild_pid);
    try expectProcGone(io, child_pid);
}

test "integration: baseline report text and JSON" {
    const alloc = std.testing.allocator;
    const baseline_samples = [_]u64{ 100, 100, 100 };
    const current_samples = [_]u64{ 130, 130, 130 };

    const store: harnessz.baseline.Store = .{
        .allocator = alloc,
        .entries = &.{.{
            .name = "render",
            .samples_ns = &baseline_samples,
            .summary = harnessz.stats.summarize(u64, &baseline_samples),
        }},
    };
    const current = [_]harnessz.baseline.Entry{.{
        .name = "render",
        .samples_ns = &current_samples,
        .summary = harnessz.stats.summarize(u64, &current_samples),
    }};

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var report = try harnessz.baseline.report.report(
        alloc,
        &out.writer,
        &store,
        &current,
        .{},
    );
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), report.regressions);
    try std.testing.expect(!report.ok());
    try std.testing.expect(std.mem.find(u8, out.written(), "REGRESSED") != null);

    const json = try report.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"regressions\": 1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"status\": \"regressed\"") != null);
}

test "integration: downstream adoption workflow" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Work = struct {
        value: u64,
        calls: u64 = 0,

        fn run(context: *anyopaque, _: std.mem.Allocator, _: std.Io) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var hash = self.value;
            var index: u64 = 0;
            while (index < 64) : (index += 1) {
                hash ^= (index *% 0x9e3779b97f4a7c15) >> 7;
                hash *%= 0x100000001b3;
            }
            return hash + self.calls;
        }
    };

    var decode_context: Work = .{ .value = 1 };
    var encode_context: Work = .{ .value = 2 };

    var registry = harnessz.bench.registry.Registry.init(alloc);
    defer registry.deinit();
    try registry.add("decode", .{ .context = &decode_context, .run = Work.run });
    try registry.add("encode", .{ .context = &encode_context, .run = Work.run });

    var suite = try harnessz.bench.runSuite(alloc, io, &registry, .{
        .run = .{ .warmup_iterations = 1, .iterations = 5 },
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 2), suite.count());
    try std.testing.expectEqual(@as(usize, 5), suite.find("decode").?.samples_ns.len);

    const fingerprint = try harnessz.provenance.fingerprint(alloc, io, .{
        .build_mode = "test",
        .extra = "adoption-workflow",
    });
    defer alloc.free(fingerprint);

    const entries = try suite.toEntries(alloc, fingerprint);
    defer alloc.free(entries);

    var store = harnessz.baseline.Store.init(alloc);
    defer store.deinit();
    store.entries = entries;
    try store.save(io, tmp.dir, "bench/baseline.json");
    try store.load(io, tmp.dir, "bench/baseline.json");

    const regression = try store.compare("decode", suite.find("decode").?.samples_ns, .{
        .max_regression_ratio = 1.05,
        .require_fingerprint = true,
        .expected_fingerprint = fingerprint,
    });
    try std.testing.expect(!regression.regressed);
    try std.testing.expectError(
        error.EnvironmentMismatch,
        store.compare("decode", suite.find("decode").?.samples_ns, .{
            .require_fingerprint = true,
            .expected_fingerprint = "other",
        }),
    );

    var report_out: std.Io.Writer.Allocating = .init(alloc);
    defer report_out.deinit();
    var comparison = try harnessz.baseline.report.report(
        alloc,
        &report_out.writer,
        &store,
        entries,
        .{},
    );
    defer comparison.deinit();
    try std.testing.expect(comparison.ok());
    try std.testing.expectEqual(@as(usize, 2), comparison.rows.len);
    try std.testing.expect(std.mem.find(u8, report_out.written(), "decode") != null);

    const golden_created = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/decode.txt",
        "decode-ok\n",
        .{ .update = true, .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(
        harnessz.golden.Outcome.created,
        golden_created.outcome,
    );
    const golden_matched = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/decode.txt",
        "decode-ok\n",
        .{ .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(
        harnessz.golden.Outcome.matched,
        golden_matched.outcome,
    );

    const manifest_json =
        \\{"entries":[{"id":"decode","status":"implemented","implementation_paths":["golden/decode.txt"],"test_names":["decode bench"],"evidence_paths":["golden/decode.txt"]}]}
    ;
    var manifest = try harnessz.evidence.Manifest.fromJson(alloc, manifest_json);
    defer manifest.deinit();
    var paths = try manifest.validatePaths(io, tmp.dir);
    defer paths.deinit();
    try std.testing.expect(paths.valid());

    const known = [_][]const u8{"decode bench"};
    var tests = try manifest.validateTests(&known);
    defer tests.deinit();
    try std.testing.expect(tests.valid());

    const first_hash = try harnessz.provenance.hashTreeHex(alloc, io, tmp.dir, .{});
    defer alloc.free(first_hash);
    const second_hash = try harnessz.provenance.hashTreeHex(alloc, io, tmp.dir, .{});
    defer alloc.free(second_hash);
    try std.testing.expectEqualStrings(first_hash, second_hash);
}

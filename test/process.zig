//! Process-isolation integration tests for the public `harnessz` module.

const std = @import("std");
const builtin = @import("builtin");
const harnessz = @import("harnessz");
const bench_child = @import("bench_child");
const support = @import("support.zig");
const expectedBenchChecksum = support.expectedBenchChecksum;
const diagnosticNumber = support.diagnosticNumber;
const expectProcGone = support.expectProcGone;

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
        .forward_stderr = false,
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
        .forward_stderr = false,
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
            .forward_stderr = false,
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

test "integration: process-isolated suite aggregates results and failures" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const names = [_][]const u8{ "checksum", "call-count", "fail" };

    var suite = try harnessz.bench.process_suite.run(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .names = &names,
        .run = .{ .warmup_iterations = 0, .iterations = 3 },
        .timeout_ns = 10 * std.time.ns_per_s,
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 3), suite.count());
    try std.testing.expect(!suite.ok());

    const checksum = suite.find("checksum").?;
    try std.testing.expect(checksum.ok());
    try std.testing.expectEqual(@as(usize, 3), checksum.samples_ns.len);
    try std.testing.expectEqual(@as(?u64, expectedBenchChecksum()), checksum.checksum);

    const call_count = suite.find("call-count").?;
    try std.testing.expect(call_count.ok());
    try std.testing.expectEqual(@as(usize, 3), call_count.samples_ns.len);
    try std.testing.expectEqual(@as(?u64, 3), call_count.checksum);

    const failure = suite.find("fail").?;
    try std.testing.expect(!failure.ok());
    try std.testing.expectEqualStrings("SyntheticBenchFailure", failure.error_name);

    const text = try suite.toText(alloc);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "checksum\t3\t") != null);
    try std.testing.expect(std.mem.find(u8, text, "SyntheticBenchFailure") != null);

    const json = try suite.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(
        std.mem.find(u8, json, "\"error_name\": \"SyntheticBenchFailure\"") != null,
    );

    const entries = try suite.toEntries(alloc, "suite-fingerprint");
    defer alloc.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "integration: process-isolated suite records a timeout and continues" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const names = [_][]const u8{ "slow", "checksum" };

    var suite = try harnessz.bench.process_suite.run(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .names = &names,
        .run = .{ .iterations = 1 },
        .timeout_ns = 100 * std.time.ns_per_ms,
    });
    defer suite.deinit();

    const slow = suite.find("slow").?;
    if (!slow.timed_out and std.mem.eql(u8, slow.error_name, "TimeoutUnavailable")) {
        return error.SkipZigTest;
    }
    try std.testing.expect(slow.timed_out);
    try std.testing.expect(!slow.ok());

    // The suite continues after the timeout.
    try std.testing.expect(suite.find("checksum").?.ok());
}

test "integration: process list-names helper matches list mode" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const names = try harnessz.bench.process.listNames(
        alloc,
        io,
        &.{bench_child.child_exe},
        .{ .max_output_bytes = 4096 },
    );
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }

    try std.testing.expectEqual(@as(usize, 12), names.len);
    try std.testing.expectEqualStrings("checksum", names[0]);
    try std.testing.expectEqualStrings("call-count", names[1]);

    // Discovered names can be fed directly to the isolated suite runner.
    var suite = try harnessz.bench.process_suite.run(alloc, io, .{
        .argv = &.{bench_child.child_exe},
        .names = names,
        .run = .{ .warmup_iterations = 0, .iterations = 2 },
        .timeout_ns = 10 * std.time.ns_per_s,
        .max_benchmarks = 2,
    });
    defer suite.deinit();
    try std.testing.expectEqual(@as(usize, 2), suite.count());
    try std.testing.expect(suite.find("checksum").?.ok());
    try std.testing.expectEqual(
        @as(?u64, expectedBenchChecksum()),
        suite.find("checksum").?.checksum,
    );
}

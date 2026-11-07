//! Tests for the parent-side process runner.

const std = @import("std");
const process_mod = @import("process.zig");
const protocol = @import("protocol.zig");
const runProcess = process_mod.runProcess;
const ProcessResult = process_mod.ProcessResult;

test "process: invalid options are rejected" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidOptions, runProcess(alloc, std.testing.io, .{
        .argv = &.{},
        .benchmark = "x",
    }));
    try std.testing.expectError(error.InvalidOptions, runProcess(alloc, std.testing.io, .{
        .argv = &.{"child"},
        .benchmark = "",
    }));
    try std.testing.expectError(error.InvalidOptions, runProcess(alloc, std.testing.io, .{
        .argv = &.{"child"},
        .benchmark = "x",
        .iterations = 0,
    }));
    try std.testing.expectError(error.InvalidOptions, runProcess(alloc, std.testing.io, .{
        .argv = &.{"child"},
        .benchmark = "x",
        .batch_size = 0,
    }));
    try std.testing.expectError(error.InvalidOptions, runProcess(alloc, std.testing.io, .{
        .argv = &.{"child"},
        .benchmark = "x",
        .max_output_bytes = 0,
    }));
}

test "process: spawn failure is typed" {
    try std.testing.expectError(error.SpawnFailed, runProcess(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{"/definitely/not/a/real/harnessz-child"},
            .benchmark = "x",
        },
    ));
}

test "process: protocol helpers are independent of the child" {
    const alloc = std.testing.allocator;
    const samples = [_]u64{ 4, 5, 6 };
    const encoded = try protocol.encodeResponse(alloc, .{
        .samples_ns = @constCast(&samples),
        .checksum = 7,
    });
    defer alloc.free(encoded);

    var decoded = try protocol.decodeResponse(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u64, &samples, decoded.value.samples_ns);
    try std.testing.expectEqual(@as(?u64, 7), decoded.value.checksum);
}

test "process: result deinit releases response and stderr" {
    const alloc = std.testing.allocator;
    const stderr_bytes = try alloc.dupe(u8, "diagnostic");
    var result: ProcessResult = .{
        .stderr = stderr_bytes,
        .stderr_truncated = true,
        .timed_out = true,
        .exit_code = null,
    };
    result.deinit(alloc);

    var transferred: ProcessResult = .{
        .response = .{
            .samples_ns = try alloc.dupe(u64, &.{ 1, 2 }),
            .error_name = try alloc.dupe(u8, "E"),
        },
    };
    var response = transferred.takeResponse();
    transferred.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), response.samples_ns.len);
    protocol.freeResponse(alloc, &response);
}

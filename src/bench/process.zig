//! Parent-side runner for process-isolated benchmarks.
//!
//! The child is spawned with piped stdin/stdout/stderr and its own process
//! group on POSIX. The request is written to stdin, stdin is closed, stdout is
//! collected with a bounded buffer, stderr is drained on a background task and
//! retained up to `max_stderr_bytes`, and the child is reaped. A dedicated
//! `std.Thread` watchdog terminates the whole process group when `timeout_ns`
//! expires, so sleeping grandchildren are not leaked.
//!
//! This is process isolation, not an OS-level sandbox: the child runs as the
//! same user, inherits the environment and filesystem/network access, and is
//! not subject to extra resource limits.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const stderr_capture = @import("stderr_capture.zig");
const watchdog_mod = @import("watchdog.zig");
const LockedAllocator = @import("../locked_allocator.zig").LockedAllocator;

pub const Options = struct {
    /// Full argv for the child, including the executable path at index zero.
    argv: []const []const u8,
    benchmark: []const u8,
    warmup_iterations: usize = 1,
    iterations: usize = 10,
    min_time_ns: u64 = 0,
    /// Zero disables the timeout. When non-zero, the watchdog starts after the
    /// request has been written and terminates the child's process group if it
    /// has not exited by then. The timeout covers benchmark execution and
    /// response output.
    timeout_ns: u64 = 0,
    /// Upper bound on the child's stdout. Exceeding it returns
    /// `error.OutputTooLarge` and terminates the child.
    max_output_bytes: usize = 16 * 1024 * 1024,
    /// Upper bound on retained child stderr. The pipe is still drained past
    /// this limit, so a chatty child cannot deadlock; excess bytes are
    /// discarded and `ProcessResult.stderr_truncated` is set. Zero retains
    /// nothing while still draining.
    max_stderr_bytes: usize = 64 * 1024,
};

pub const Error = error{
    InvalidOptions,
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    WaitFailed,
    ChildExitFailure,
    Timeout,
    TimeoutUnavailable,
    OutputTooLarge,
    CaptureUnavailable,
    InvalidJson,
    InvalidResponse,
    BenchmarkFailed,
};

/// Full parent-side outcome. `runProcessCapture` returns this even when the
/// child timed out or reported a benchmark failure, so callers can inspect the
/// captured stderr.
pub const ProcessResult = struct {
    /// Parsed protocol response. Empty when the child timed out or exited
    /// outside the protocol.
    response: protocol.Response = .{ .samples_ns = @constCast(&[_]u64{}) },
    /// Captured child stderr, bounded by `Options.max_stderr_bytes`.
    stderr: []const u8 = &.{},
    /// True when stderr exceeded the retention bound and the rest was
    /// discarded.
    stderr_truncated: bool = false,
    /// True when the watchdog terminated the child's process group.
    timed_out: bool = false,
    /// Direct child exit code, or null when it was signaled.
    exit_code: ?u8 = null,

    pub fn deinit(self: *ProcessResult, alloc: Allocator) void {
        protocol.freeResponse(alloc, &self.response);
        if (self.stderr.len != 0) alloc.free(self.stderr);
        self.* = undefined;
    }

    /// Transfer ownership of the protocol response to the caller.
    pub fn takeResponse(self: *ProcessResult) protocol.Response {
        const response = self.response;
        self.response = .{ .samples_ns = @constCast(&[_]u64{}) };
        return response;
    }
};

/// Run the child and return its protocol response. A valid response whose
/// `error_name` is set is returned to the caller; use `runProcess` when
/// benchmark failures should become `error.BenchmarkFailed`.
pub fn runProcessResponse(
    alloc: Allocator,
    io: std.Io,
    options: Options,
) !protocol.Response {
    var result = try runProcessCapture(alloc, io, options);
    defer result.deinit(alloc);
    if (result.timed_out) return error.Timeout;
    return result.takeResponse();
}

/// Strict variant: benchmark failures become `error.BenchmarkFailed` and the
/// captured child stderr is forwarded to the parent's stderr as a diagnostic.
pub fn runProcess(
    alloc: Allocator,
    io: std.Io,
    options: Options,
) !protocol.Response {
    var result = try runProcessCapture(alloc, io, options);
    defer result.deinit(alloc);
    if (result.timed_out) return error.Timeout;
    if (result.response.error_name != null) {
        emitCapturedStderr(io, result.stderr);
        return error.BenchmarkFailed;
    }
    if (result.response.samples_ns.len == 0) return error.InvalidResponse;
    return result.takeResponse();
}

/// Like `runProcessResponse`, but also returns the bounded child stderr.
/// Timeouts and benchmark failures are reported through the result
/// (`timed_out`, `response.error_name`) instead of typed errors, except for
/// spawn/protocol/IO failures.
///
/// `alloc` is used by both the stderr capture task and the main task, but
/// allocations are serialized internally, so a non-thread-safe allocator is
/// safe to pass.
pub fn runProcessCapture(
    alloc: Allocator,
    io: std.Io,
    options: Options,
) !ProcessResult {
    if (options.argv.len == 0 or
        options.benchmark.len == 0 or
        options.iterations == 0 or
        options.max_output_bytes == 0)
    {
        return error.InvalidOptions;
    }

    // The stderr capture task and the stdout reader run concurrently. Route
    // their allocations through a lock so callers may pass an ordinary
    // single-threaded allocator (for example an ArenaAllocator).
    var locked_allocator: LockedAllocator = .{ .child = alloc, .io = io };
    const locked = locked_allocator.allocator();

    const request_json = try protocol.encodeRequest(locked, .{
        .benchmark = options.benchmark,
        .warmup_iterations = options.warmup_iterations,
        .iterations = options.iterations,
        .min_time_ns = options.min_time_ns,
    });
    defer locked.free(request_json);

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // Creating the group in the child between fork and exec removes the
        // race where a watchdog could kill a not-yet-created group. The child
        // entrypoint also calls setpgid(0, 0) defensively.
        .pgid = if (comptime watchdog_mod.posix_process_control) 0 else null,
    }) catch return error.SpawnFailed;

    const child_id = child.id orelse return error.SpawnFailed;
    var child_waited = false;
    defer if (!child_waited) {
        watchdog_mod.terminateProcessGroup(child_id);
        child.kill(io);
    };

    const stdin_file = child.stdin orelse return error.SpawnFailed;
    stdin_file.writeStreamingAll(io, request_json) catch return error.WriteFailed;
    stdin_file.close(io);
    child.stdin = null;

    const stderr_file = child.stderr orelse return error.SpawnFailed;
    child.stderr = null;
    var capture = stderr_capture.Capture.init(
        locked,
        io,
        stderr_file,
        options.max_stderr_bytes,
    );
    defer capture.deinit();

    var capture_started = false;
    var capture_task: TaskHandle = undefined;
    var watchdog: watchdog_mod.Watchdog = .{
        .child_id = child_id,
        .timeout_ns = options.timeout_ns,
        .io = io,
    };
    var watchdog_started = false;
    var watchdog_task: TaskHandle = undefined;

    // Registered before any background task starts so every error path below
    // joins the tasks before their stack state is released.
    errdefer {
        if (!child_waited) {
            watchdog_mod.terminateProcessGroup(child_id);
            if (capture_started) {
                capture_task.join(io);
                capture_started = false;
            }
            if (watchdog_started) {
                watchdog.finish();
                watchdog_task.join(io);
                watchdog_started = false;
            }
            _ = child.wait(io) catch {};
            child_waited = true;
        }
    }

    var capture_uses_io = false;
    capture_task = startTask(
        io,
        stderr_capture.Capture.run,
        .{&capture},
        &capture_uses_io,
    ) catch {
        stderr_file.close(io);
        return error.CaptureUnavailable;
    };
    capture_started = true;

    if (options.timeout_ns != 0) {
        watchdog_task = startTask(
            io,
            watchdog_mod.Watchdog.run,
            .{&watchdog},
            &watchdog.use_io_sleep,
        ) catch return error.TimeoutUnavailable;
        watchdog_started = true;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(locked);

    const stdout_file = child.stdout orelse return error.SpawnFailed;
    var read_buffer: [4096]u8 = undefined;
    var reader = stdout_file.readerStreaming(io, &read_buffer);
    reader.interface.appendRemaining(
        locked,
        &output,
        .limited(options.max_output_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.OutputTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // EOF on stdout means the direct child has closed it. Draining stderr next
    // unblocks the capture task before `wait` closes the pipe descriptors.
    capture_task.join(io);
    capture_started = false;

    const term = child.wait(io) catch return error.WaitFailed;
    child_waited = true;

    if (watchdog_started) {
        watchdog.finish();
        watchdog_task.join(io);
        watchdog_started = false;
    }
    const timed_out = watchdog.fired.load(.acquire);

    var result: ProcessResult = .{
        .stderr = try capture.toOwnedSlice(),
        .stderr_truncated = capture.truncated,
        .timed_out = timed_out,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => null,
        },
    };
    errdefer result.deinit(locked);

    if (timed_out) return result;

    if (result.exit_code) |exit_code| {
        if (exit_code == 0) {
            var parsed = protocol.decodeResponse(locked, output.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJson => return error.InvalidJson,
            };
            defer parsed.deinit();
            result.response = try protocol.cloneResponse(locked, parsed.value);
            return result;
        }

        // A well-formed error response is the expected way for the child to
        // report benchmark failures. Without one, the child crashed or exited
        // outside the protocol.
        if (try parseResponseMaybe(locked, output.items)) |maybe| {
            var response = maybe;
            if (response.error_name != null) {
                result.response = response;
                return result;
            }
            protocol.freeResponse(locked, &response);
        }
        return error.ChildExitFailure;
    }

    return error.ChildExitFailure;
}

const TaskHandle = union(enum) {
    thread: std.Thread,
    future: std.Io.Future(void),

    fn join(self: *TaskHandle, io: std.Io) void {
        switch (self.*) {
            .thread => |thread| thread.join(),
            .future => |*future| future.await(io),
        }
    }
};

/// Start a background task on a dedicated thread, falling back to
/// `Io.concurrent` when threads are unavailable. `uses_io` is set before the
/// task starts so the task body can choose an appropriate sleep primitive.
fn startTask(
    io: std.Io,
    comptime function: anytype,
    args: anytype,
    uses_io: *bool,
) !TaskHandle {
    if (comptime builtin.single_threaded) {
        uses_io.* = true;
        const future = std.Io.concurrent(io, function, args) catch
            return error.ConcurrencyUnavailable;
        return .{ .future = future };
    }
    const thread = std.Thread.spawn(.{}, function, args) catch {
        uses_io.* = true;
        const future = std.Io.concurrent(io, function, args) catch
            return error.ConcurrencyUnavailable;
        return .{ .future = future };
    };
    uses_io.* = false;
    return .{ .thread = thread };
}

fn emitCapturedStderr(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn parseResponseMaybe(alloc: Allocator, bytes: []const u8) !?protocol.Response {
    if (bytes.len == 0) return null;
    var parsed = protocol.decodeResponse(alloc, bytes) catch |err| switch (err) {
        error.InvalidJson => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit();
    return try protocol.cloneResponse(alloc, parsed.value);
}

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

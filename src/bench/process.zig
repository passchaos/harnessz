//! Parent-side runner for process-isolated benchmarks.
//!
//! The child is spawned with piped stdin/stdout and inherited stderr. The
//! request is written to stdin, stdin is closed, stdout is collected with a
//! bounded buffer, and the child is reaped. A watchdog task terminates the
//! child when `timeout_ns` expires.
//!
//! This is process isolation, not an OS-level sandbox: the child runs as the
//! same user, inherits the environment and filesystem/network access, and is
//! not subject to extra resource limits.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

pub const Options = struct {
    /// Full argv for the child, including the executable path at index zero.
    argv: []const []const u8,
    benchmark: []const u8,
    warmup_iterations: usize = 1,
    iterations: usize = 10,
    min_time_ns: u64 = 0,
    /// Zero disables the timeout. When non-zero, the watchdog starts after the
    /// request has been written and terminates the child if it has not exited
    /// by then. The timeout covers benchmark execution and response output.
    timeout_ns: u64 = 0,
    /// Upper bound on the child's stdout. Exceeding it returns
    /// `error.OutputTooLarge` and terminates the child.
    max_output_bytes: usize = 16 * 1024 * 1024,
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
    InvalidJson,
    InvalidResponse,
    BenchmarkFailed,
};

/// Run the child and return a protocol response. A valid response whose
/// `error_name` is set is returned to the caller; use `runProcess` when
/// benchmark failures should become `error.BenchmarkFailed`.
pub fn runProcessResponse(
    alloc: Allocator,
    io: std.Io,
    options: Options,
) !protocol.Response {
    if (options.argv.len == 0 or
        options.benchmark.len == 0 or
        options.iterations == 0 or
        options.max_output_bytes == 0)
    {
        return error.InvalidOptions;
    }

    const request_json = try protocol.encodeRequest(alloc, .{
        .benchmark = options.benchmark,
        .warmup_iterations = options.warmup_iterations,
        .iterations = options.iterations,
        .min_time_ns = options.min_time_ns,
    });
    defer alloc.free(request_json);

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .stdin = .pipe,
        .stdout = .pipe,
        // Inherit stderr so diagnostics cannot fill an unread pipe and remain
        // visible to the caller.
        .stderr = .inherit,
    }) catch return error.SpawnFailed;

    var child_waited = false;
    defer if (!child_waited) child.kill(io);

    const stdin_file = child.stdin orelse return error.SpawnFailed;
    stdin_file.writeStreamingAll(io, request_json) catch return error.WriteFailed;
    stdin_file.close(io);
    child.stdin = null;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);

    var timer: TimeoutTimer = .{
        .io = io,
        .child = &child,
        .timeout_ns = options.timeout_ns,
    };
    var timer_future: ?std.Io.Future(void) = null;
    if (options.timeout_ns != 0) {
        timer_future = std.Io.concurrent(io, TimeoutTimer.run, .{&timer}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.TimeoutUnavailable,
        };
    }
    var timer_active = timer_future != null;
    defer if (timer_active) {
        if (timer_future) |*future| _ = future.cancel(io);
    };

    const stdout_file = child.stdout orelse return error.SpawnFailed;
    var read_buffer: [4096]u8 = undefined;
    var reader = stdout_file.readerStreaming(io, &read_buffer);
    reader.interface.appendRemaining(
        alloc,
        &output,
        .limited(options.max_output_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            cancelTimer(io, &timer_future, &timer_active);
            return error.OutputTooLarge;
        },
        error.ReadFailed => {
            cancelTimer(io, &timer_future, &timer_active);
            return error.ReadFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    cancelTimer(io, &timer_future, &timer_active);
    const timed_out = timer.fired.load(.acquire);

    const term = child.wait(io) catch return error.WaitFailed;
    child_waited = true;

    if (timed_out) return error.Timeout;

    const exit_code = switch (term) {
        .exited => |code| code,
        else => return error.ChildExitFailure,
    };

    if (exit_code != 0) {
        // A well-formed error response is the expected way for the child to
        // report benchmark failures. Without one, the child crashed or exited
        // outside the protocol.
        if (try parseResponseMaybe(alloc, output.items)) |maybe_response| {
            var response = maybe_response;
            if (response.error_name != null) return response;
            protocol.freeResponse(alloc, &response);
        }
        return error.ChildExitFailure;
    }

    var parsed = protocol.decodeResponse(alloc, output.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidJson,
    };
    defer parsed.deinit();
    return try protocol.cloneResponse(alloc, parsed.value);
}

/// Strict variant: benchmark failures become `error.BenchmarkFailed`.
pub fn runProcess(
    alloc: Allocator,
    io: std.Io,
    options: Options,
) !protocol.Response {
    var response = try runProcessResponse(alloc, io, options);
    errdefer protocol.freeResponse(alloc, &response);
    if (response.error_name != null) return error.BenchmarkFailed;
    if (response.samples_ns.len == 0) return error.InvalidResponse;
    return response;
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

fn cancelTimer(
    io: std.Io,
    future: *?std.Io.Future(void),
    active: *bool,
) void {
    if (!active.*) return;
    if (future.*) |*pending| _ = pending.cancel(io);
    future.* = null;
    active.* = false;
}

const TimeoutTimer = struct {
    io: std.Io,
    child: *std.process.Child,
    timeout_ns: u64,
    fired: std.atomic.Value(bool) = .init(false),

    fn run(self: *TimeoutTimer) void {
        const duration = std.Io.Duration.fromNanoseconds(@intCast(self.timeout_ns));
        self.io.sleep(duration, .awake) catch |err| switch (err) {
            // The parent completed first and canceled the watchdog.
            error.Canceled => return,
        };
        self.fired.store(true, .release);
        terminateChild(self.child);
    }
};

/// Send an uncatchable termination request without reaping. The main task
/// remains responsible for `Child.wait`, so `Child` fields are not mutated
/// from the watchdog task.
fn terminateChild(child: *const std.process.Child) void {
    const id = child.id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
        .wasi, .freestanding, .other => {},
        else => std.posix.kill(@intCast(id), .KILL) catch {},
    }
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

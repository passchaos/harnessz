//! Child-side entrypoint for process-isolated benchmarks.
//!
//! `childMain` is the argv-free protocol core: it reads a `Request` JSON
//! document from stdin, runs the named benchmark with the same warmup and
//! sampling logic as `bench.run`, and writes one `Response` JSON document to
//! stdout. `childMainArgs` adds the command-line modes used by an executable:
//!
//!   --harnessz-list             print registered names as a JSON array
//!   --harnessz-bench=<name>     select a benchmark (the request still carries
//!                               the timing parameters)
//!
//! Zig 0.16 supplies argv through `std.process.Init`, so executables should
//! call `mainInit(init, &registry)` from `pub fn main(init: std.process.Init)`.
//! `mainInit` also prepares process isolation: on POSIX it puts the process in
//! its own process group and asks the kernel for `SIGKILL` if the parent dies.
//! Diagnostics are written to stderr; stdout is protocol-only.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const protocol = @import("protocol.zig");
const registry_mod = @import("registry.zig");
const watchdog_mod = @import("watchdog.zig");

pub const default_max_request_bytes: usize = 4 * 1024 * 1024;

pub const Mode = union(enum) {
    protocol,
    list,
    benchmark: []const u8,
};

pub const ParsedArgs = struct {
    mode: Mode = .protocol,
    error_name: ?[]const u8 = null,
};

/// Parse the documented child flags. Unknown flags are rejected so a
/// misspelled option cannot silently change the protocol mode.
pub fn parseArgs(argv: []const []const u8) ParsedArgs {
    var result: ParsedArgs = .{};
    // argv[0] is the executable path; only flags are inspected.
    for (argv, 0..) |arg, index| {
        if (index == 0) continue;
        if (std.mem.eql(u8, arg, "--harnessz-list")) {
            result.mode = .list;
        } else if (std.mem.startsWith(u8, arg, "--harnessz-bench=")) {
            const name = arg["--harnessz-bench=".len..];
            if (name.len == 0) {
                result.error_name = "EmptyBenchmarkName";
                return result;
            }
            result.mode = .{ .benchmark = name };
        } else {
            result.error_name = "UnknownArgument";
            return result;
        }
    }
    return result;
}

/// Run a benchmark in the current process and return an owned response.
///
/// Benchmark callback failures are represented in the response's
/// `error_name`/`error_message` fields rather than as Zig errors. The caller
/// must release the response with `protocol.freeResponse(alloc, &response)`.
pub fn execute(
    alloc: Allocator,
    io: std.Io,
    reg: *const registry_mod.Registry,
    name: []const u8,
    request: protocol.Request,
) !protocol.Response {
    if (request.iterations == 0) return error.InvalidOptions;

    const entry = reg.find(name) orelse return error.UnknownBenchmark;

    var stats = bench.runRuntime(alloc, io, .{
        .warmup_iterations = request.warmup_iterations,
        .iterations = request.iterations,
        .min_time_ns = request.min_time_ns,
    }, entry.context, entry.run) catch |err| {
        return ownedErrorResponse(alloc, @errorName(err), "benchmark execution failed");
    };
    defer stats.deinit(alloc);

    return .{
        .samples_ns = try alloc.dupe(u64, stats.samples_ns),
        .checksum = stats.last_result,
    };
}

/// Protocol core: no argv parsing. Reads a `Request` from stdin and writes a
/// `Response` to stdout. Returns 0 on success and non-zero on failure.
pub fn childMain(
    alloc: Allocator,
    io: std.Io,
    reg: *const registry_mod.Registry,
) !u8 {
    return childMainArgs(alloc, io, reg, &.{});
}

/// Like `childMain`, but also handles `--harnessz-list` and
/// `--harnessz-bench=<name>`. `argv` may include the executable path at index
/// zero, as returned by `std.process.Args.toSlice`.
pub fn childMainArgs(
    alloc: Allocator,
    io: std.Io,
    reg: *const registry_mod.Registry,
    argv: []const []const u8,
) !u8 {
    const parsed = parseArgs(argv);
    if (parsed.error_name) |name| {
        writeErrorResponse(alloc, io, name, "invalid child arguments");
        writeDiagnostic(io, "invalid command-line arguments");
        return 2;
    }

    switch (parsed.mode) {
        .list => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try reg.writeNamesJson(&out.writer, reg.count());
            std.Io.File.stdout().writeStreamingAll(io, out.written()) catch return 1;
            return 0;
        },
        .protocol, .benchmark => {},
    }

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buffer);
    reader.interface.appendRemaining(
        alloc,
        &input,
        .limited(default_max_request_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            writeErrorResponse(alloc, io, "RequestTooLarge", "request exceeds the input limit");
            writeDiagnostic(io, "request exceeds the input limit");
            return 2;
        },
        error.ReadFailed => {
            writeErrorResponse(alloc, io, "RequestReadFailed", "failed to read request");
            writeDiagnostic(io, "failed to read request");
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var parsed_request = protocol.decodeRequest(alloc, input.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => {
            writeErrorResponse(alloc, io, "InvalidRequest", "request is not valid JSON");
            writeDiagnostic(io, "request is not valid JSON");
            return 2;
        },
    };
    defer parsed_request.deinit();

    const requested_name: ?[]const u8 = switch (parsed.mode) {
        .benchmark => |name| name,
        else => null,
    };
    if (requested_name) |name| {
        if (!std.mem.eql(u8, name, parsed_request.value.benchmark)) {
            writeErrorResponse(alloc, io, "BenchmarkMismatch", "argv and request benchmark names differ");
            writeDiagnostic(io, "argv and request benchmark names differ");
            return 2;
        }
    }

    const name = requested_name orelse parsed_request.value.benchmark;
    var response = execute(alloc, io, reg, name, parsed_request.value) catch |err| switch (err) {
        error.UnknownBenchmark => {
            writeErrorResponse(alloc, io, "UnknownBenchmark", name);
            writeDiagnostic(io, "unknown benchmark");
            return 3;
        },
        error.InvalidOptions => {
            writeErrorResponse(alloc, io, "InvalidRequest", "iterations must be greater than zero");
            writeDiagnostic(io, "iterations must be greater than zero");
            return 2;
        },
        else => {
            writeErrorResponse(alloc, io, "ExecutionFailed", @errorName(err));
            writeDiagnostic(io, "benchmark execution failed");
            return 1;
        },
    };
    defer protocol.freeResponse(alloc, &response);

    writeResponse(alloc, io, response) catch {
        writeDiagnostic(io, "failed to write response");
        return 1;
    };

    if (response.error_name != null) {
        writeDiagnostic(io, response.error_name.?);
        return 1;
    }
    return 0;
}

/// Best-effort child process setup, called by the executable entrypoint:
///
/// - POSIX: `setpgid(0, 0)` puts the child in its own process group so the
///   parent can terminate the whole tree with `kill(-pid, SIGKILL)`.
/// - Linux: `PR_SET_PDEATHSIG` asks the kernel to send `SIGKILL` if the parent
///   dies, so a crashed parent does not leave the benchmark running.
///
/// The parent also creates the process group at spawn time; this function is a
/// defensive fallback for callers that start the child themselves. Failures are
/// ignored because a restricted environment may forbid the operation and the
/// direct-child path still works.
pub fn prepareProcess() void {
    if (comptime watchdog_mod.posix_process_control) {
        _ = std.posix.system.setpgid(0, 0);
    }
    if (comptime builtin.os.tag == .linux) {
        _ = std.posix.prctl(
            .SET_PDEATHSIG,
            .{@as(usize, @intFromEnum(std.posix.SIG.KILL))},
        ) catch {};
    }
}

/// Current process id, or -1 when the platform has no `getpid`. Linux uses
/// the raw syscall so the helper works with and without libc.
pub fn processId() i64 {
    if (comptime builtin.os.tag == .linux) {
        return std.os.linux.getpid();
    }
    if (comptime watchdog_mod.posix_process_control) {
        if (comptime @hasDecl(std.posix.system, "getpid")) {
            return @intCast(std.posix.system.getpid());
        }
    }
    return -1;
}

/// Current process group id, or -1 when the platform has no `getpgid`.
/// Used by the child's own diagnostics and the process-tree integration test.
pub fn processGroupId() i64 {
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.getpgid(0);
        if (std.os.linux.errno(rc) != .SUCCESS) return -1;
        return @intCast(rc);
    }
    if (comptime watchdog_mod.posix_process_control) {
        if (comptime @hasDecl(std.posix.system, "getpgid")) {
            const rc = std.posix.system.getpgid(0);
            if (std.posix.errno(rc) != .SUCCESS) return -1;
            return @intCast(rc);
        }
    }
    return -1;
}

/// Convenience entrypoint for `pub fn main(init: std.process.Init)`.
pub fn mainInit(init: std.process.Init, reg: *const registry_mod.Registry) !u8 {
    prepareProcess();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The parent runner supplies no flags, so take the argv-free core
    // directly. Flag-aware invocations use `childMainArgs`.
    if (args.len <= 1) return childMain(init.gpa, init.io, reg);
    return childMainArgs(init.gpa, init.io, reg, args);
}

fn ownedErrorResponse(
    alloc: Allocator,
    error_name: []const u8,
    error_message: []const u8,
) !protocol.Response {
    const owned_name = try alloc.dupe(u8, error_name);
    errdefer alloc.free(owned_name);
    const owned_message = try alloc.dupe(u8, error_message);
    return .{
        .samples_ns = @constCast(&[_]u64{}),
        .error_name = owned_name,
        .error_message = owned_message,
    };
}

fn writeResponse(alloc: Allocator, io: std.Io, response: protocol.Response) !void {
    const json = try protocol.encodeResponse(alloc, response);
    defer alloc.free(json);
    try std.Io.File.stdout().writeStreamingAll(io, json);
}

fn writeErrorResponse(
    alloc: Allocator,
    io: std.Io,
    error_name: []const u8,
    error_message: []const u8,
) void {
    const response: protocol.Response = .{
        .samples_ns = @constCast(&[_]u64{}),
        .error_name = error_name,
        .error_message = error_message,
    };
    writeResponse(alloc, io, response) catch {};
}

fn writeDiagnostic(io: std.Io, message: []const u8) void {
    var buffer: [512]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buffer, "harnessz-bench-child: {s}\n", .{message}) catch message;
    std.Io.File.stderr().writeStreamingAll(io, formatted) catch {};
}

test "child: argument parsing" {
    try std.testing.expectEqual(Mode.protocol, parseArgs(&.{"child"}).mode);
    try std.testing.expectEqual(Mode.list, parseArgs(&.{ "child", "--harnessz-list" }).mode);
    try std.testing.expectEqualStrings(
        "checksum",
        parseArgs(&.{ "child", "--harnessz-bench=checksum" }).mode.benchmark,
    );
    try std.testing.expectEqualStrings(
        "UnknownArgument",
        parseArgs(&.{ "child", "--bogus" }).error_name.?,
    );
    try std.testing.expectEqualStrings(
        "EmptyBenchmarkName",
        parseArgs(&.{ "child", "--harnessz-bench=" }).error_name.?,
    );
}

const ExecuteContext = struct {
    calls: usize = 0,
    checksum: u64,
};

fn executeWork(context: *ExecuteContext, alloc: Allocator, io: std.Io) !u64 {
    _ = alloc;
    _ = io;
    context.calls += 1;
    return context.checksum;
}

fn executeFail(context: *ExecuteContext, alloc: Allocator, io: std.Io) !u64 {
    _ = context;
    _ = alloc;
    _ = io;
    return error.SyntheticBenchFailure;
}

fn executeEntry(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    return executeWork(@ptrCast(@alignCast(context)), alloc, io);
}

fn executeFailEntry(context: *anyopaque, alloc: Allocator, io: std.Io) anyerror!u64 {
    return executeFail(@ptrCast(@alignCast(context)), alloc, io);
}

test "child: execute returns samples, checksum, and callback errors" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();

    var ok_context: ExecuteContext = .{ .checksum = 0x1234_5678 };
    try reg.add("ok", .{ .context = &ok_context, .run = executeEntry });
    var fail_context: ExecuteContext = .{ .checksum = 0 };
    try reg.add("fail", .{ .context = &fail_context, .run = executeFailEntry });

    const request: protocol.Request = .{
        .benchmark = "ok",
        .warmup_iterations = 1,
        .iterations = 3,
        .min_time_ns = 0,
    };

    var response = try execute(alloc, std.testing.io, &reg, "ok", request);
    defer protocol.freeResponse(alloc, &response);
    try std.testing.expectEqual(@as(usize, 3), response.samples_ns.len);
    try std.testing.expectEqual(@as(?u64, 0x1234_5678), response.checksum);
    try std.testing.expect(response.error_name == null);
    try std.testing.expectEqual(@as(usize, 4), ok_context.calls);

    var failed = try execute(alloc, std.testing.io, &reg, "fail", request);
    defer protocol.freeResponse(alloc, &failed);
    try std.testing.expectEqual(@as(usize, 0), failed.samples_ns.len);
    try std.testing.expectEqualStrings("SyntheticBenchFailure", failed.error_name.?);

    try std.testing.expectError(error.UnknownBenchmark, execute(alloc, std.testing.io, &reg, "missing", request));
    var invalid = request;
    invalid.iterations = 0;
    try std.testing.expectError(error.InvalidOptions, execute(alloc, std.testing.io, &reg, "ok", invalid));
}

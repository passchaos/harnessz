# Process-isolated benchmarks

`bench.protocol`, `bench.registry`, `bench.child`, and `bench.process` move
measurement into a separate OS process so the parent's threads, allocator
state, and other benchmarks cannot perturb the samples. This is process
isolation, not OS-level sandboxing; see [Boundaries](#boundaries).

## Protocol

The parent writes one JSON `Request` to the child's stdin and closes it:

```json
{"benchmark":"checksum","warmup_iterations":2,"iterations":20,"batch_size":1,"min_time_ns":0}
```

The child writes exactly one JSON `Response` to stdout:

```json
{"samples_ns":[123,456],"checksum":98765,"peak_rss_bytes":12345678,"peak_allocated_bytes":4096}
{"samples_ns":[],"error_name":"SyntheticBenchFailure","error_message":"benchmark execution failed"}
```

`checksum` is an optional additive extension carrying the benchmark callback's
last returned `u64`. `peak_rss_bytes` and `peak_allocated_bytes` are optional
additive metrics from the child's measured runner; `peak_rss_bytes` is null
when the platform cannot report it. Null optional fields are omitted from the
wire form, and older children simply omit the new fields. `batch_size`
defaults to 1 when omitted by older parents.

The child must not print anything else to stdout; diagnostics go to stderr.
Stderr is **not** part of the wire protocol: the parent captures it
out-of-band and returns it through `process.ProcessResult`.

`bench.protocol` exposes `Request`, `Response`, `writeRequest`,
`writeResponse`, `encodeRequest`, `encodeResponse`, `decodeRequest`, and
`decodeResponse`. Decoding returns arena-backed `OwnedRequest`/`OwnedResponse`
values; call `deinit()`. `cloneResponse`/`freeResponse` manage plain
`Response` values returned by the parent runner.

## Registry

```zig
var registry = harnessz.bench.registry.Registry.init(gpa);
defer registry.deinit();
try registry.add("checksum", .{
    .context = &context,
    .run = checksumEntry, // fn (*anyopaque, Allocator, std.Io) anyerror!u64
});
const entry = registry.find("checksum"); // no allocation
const total = registry.count();
const names = try registry.names(gpa, 32); // bounded, registration order
defer gpa.free(names);
```

Names are unique, kept in insertion order, and bounded by the `limit` passed
to `names`/`writeNamesJson`. Lookups never allocate.

## Child executable

```zig
const std = @import("std");
const harnessz = @import("harnessz");

fn checksumEntry(context: *anyopaque, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    _ = context;
    _ = alloc;
    _ = io;
    return 0x1234;
}

pub fn main(init: std.process.Init) !u8 {
    var registry = harnessz.bench.registry.Registry.init(init.gpa);
    defer registry.deinit();
    var context: u8 = 0;
    try registry.add("checksum", .{ .context = &context, .run = checksumEntry });
    return harnessz.bench.child.mainInit(init, &registry);
}
```

`child.mainInit` also prepares process isolation before dispatching. On POSIX
it calls `setpgid(0, 0)` so the child owns a process group, and on Linux it sets
`PR_SET_PDEATHSIG` to `SIGKILL` so a crashed parent cannot leave the benchmark
running. Both operations are best-effort; the parent also creates the group at
spawn time. Callers that implement their own `main` can call
`child.prepareProcess()` explicitly.

`child.mainInit` extracts argv from `std.process.Init`; with no flags it calls
the argv-free `childMain`, otherwise it calls `childMainArgs`, which supports:

- `--harnessz-bench=<name>`: select the benchmark. The request's `benchmark`
  field must match; the request still carries the warmup/iteration settings.
- `--harnessz-list`: print registered names as a JSON array and exit 0.

`childMain(alloc, io, registry)` is the argv-free protocol core for callers
that already know the benchmark from the request. It reads stdin, runs the
benchmark with the same warmup/min-time/iteration logic as `bench.run`, writes
the response, and returns 0 on success or non-zero on failure. `execute` is the
in-process helper used by `childMainArgs`; it returns a `Response` with
`error_name`/`error_message` for callback failures.

`child.processId()` and `child.processGroupId()` are diagnostic helpers (they
return `-1` when the platform lacks the syscall).

## Parent runner

```zig
var response = try harnessz.bench.process.runProcess(gpa, io, .{
    .argv = &.{ "/path/to/bench-child" },
    .benchmark = "checksum",
    .warmup_iterations = 2,
    .iterations = 20,
    .batch_size = 1,
    .min_time_ns = 0,
    .timeout_ns = 30 * std.time.ns_per_s, // 0 disables
});
defer harnessz.bench.protocol.freeResponse(gpa, &response);
```

`runProcess` returns `error.BenchmarkFailed` when the child produced a valid
response with `error_name` set, and forwards the captured stderr to the
parent's stderr as a diagnostic (set `forward_stderr = false` to suppress it).
Successful responses also carry optional `peak_rss_bytes` and
`peak_allocated_bytes` values measured in the child.
`runProcessResponse` returns that response instead, so callers can inspect
`error_name`/`error_message`.

Other typed errors are `error.SpawnFailed`, `error.ChildExitFailure`,
`error.Timeout`, `error.TimeoutUnavailable`, `error.OutputTooLarge`,
`error.CaptureUnavailable`, `error.InvalidJson`, `error.InvalidResponse`,
`error.WriteFailed`, `error.ReadFailed`, `error.WaitFailed`, and
`error.InvalidOptions`.

For full diagnostics, use `runProcessCapture`, which returns a
`process.ProcessResult` instead of discarding stderr:

```zig
var result = try harnessz.bench.process.runProcessCapture(gpa, io, .{
    .argv = &.{ "/path/to/bench-child" },
    .benchmark = "checksum",
    .iterations = 20,
    .timeout_ns = 30 * std.time.ns_per_s,
    .max_stderr_bytes = 64 * 1024, // default
});
defer result.deinit(gpa);

if (result.timed_out) return error.Timeout;
if (result.response.error_name) |name| {
    std.debug.print("benchmark failed: {s}\nstderr: {s}\n", .{ name, result.stderr });
}
```

`ProcessResult` exposes `response`, `stderr`, `stderr_truncated`, `timed_out`,
and `exit_code`. Timeouts and benchmark-error responses are returned in the
result rather than as errors; spawn, protocol, and IO failures remain typed
errors. `takeResponse()` transfers ownership of the protocol response.

The parent writes the request, closes stdin, reads stdout up to
`max_output_bytes` (default 16 MiB), and drains stderr concurrently. The
stderr pipe is always drained to EOF, so a child that writes more than
`max_stderr_bytes` (default 64 KiB) cannot deadlock; excess bytes are
discarded and `stderr_truncated` is set. Allocations made by the stderr capture
task are serialized with the main task, so the `alloc` passed to the runner
does not need to be thread-safe.

When `timeout_ns` is non-zero, a dedicated `std.Thread` watchdog starts after
the request is written. If the deadline expires it sends `SIGKILL` to the
child's whole process group (`kill(-pid, SIGKILL)`) on POSIX, then the parent
reaps the direct child. This kills sleeping grandchildren as well. When a
thread cannot be started, the watchdog falls back to `Io.concurrent`; only
when neither mechanism is available is `error.TimeoutUnavailable` returned.

## Name discovery

`bench.process.listNames(alloc, io, argv, .{})` runs the child with
`--harnessz-list` and returns its registered names, so callers do not have to
duplicate the registry:

```zig
const names = try harnessz.bench.process.listNames(gpa, io, &.{child_exe}, .{});
defer {
    for (names) |name| gpa.free(name);
    gpa.free(names);
}
```

The caller owns the outer slice and every name. The child's stderr is inherited
in list mode so a chatty list command cannot fill a pipe. This helper does not
enforce a timeout; list mode is a short registry write followed by exit.

## Process-isolated suites

`bench.process_suite.run` spawns the child once per benchmark name, so a crash,
hang, or timeout in one benchmark does not stop the rest:

```zig
const names = [_][]const u8{ "decode", "encode", "slow-path" };
var suite = try harnessz.bench.process_suite.run(gpa, io, .{
    .argv = &.{"zig-out/bin/my-bench-child"},
    .names = &names,
    .run = .{ .warmup_iterations = 2, .iterations = 20 },
    .timeout_ns = 30 * std.time.ns_per_s,
});
defer suite.deinit();

if (!suite.ok()) {
    for (suite.entries) |entry| {
        if (!entry.ok()) {
            std.debug.print("{s}: {s} (timeout={any}, exit={?d})\n", .{
                entry.name, entry.error_name, entry.timed_out, entry.exit_code,
            });
        }
    }
}
```

Each `Entry` carries samples, a summary, memory metrics, checksum, bounded
stderr, timeout/exit status, and the child's error name/message. Text and JSON
reports are deterministic. `toEntries` borrows the successful samples for
baseline reporting. The child executable must register the same names; use the
`bench.registry.Registry` shown above.

## Boundaries

Process isolation is not OS-level sandboxing. The child runs as the same user,
inherits the environment, filesystem, and network access, and has no extra
resource limits. It isolates address space, threads, and allocator state only.

Process-group cleanup is POSIX-only: on Windows the watchdog terminates the
direct child, and grandchildren are not tracked because Zig 0.16 does not
expose job-object helpers. Descendants that escape the process group (for
example by calling `setsid`) are also outside the cleanup guarantee.

A successful child run does not kill lingering descendants; process-group
termination happens on timeout and on output/read failures. A descendant that
keeps the stderr pipe open after the direct child exits can still delay
completion until the pipe closes or the timeout fires.

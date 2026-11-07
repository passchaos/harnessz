# Determinism

`determinism` runs a producer repeatedly and compares every output against a
baseline. It reports the first divergent run/count and byte offset.

## Repeated runs

```zig
fn produce(context: *Ctx, gpa: std.mem.Allocator, io: std.Io, threads: usize, out: *std.Io.Writer) !void {
    _ = gpa;
    _ = io;
    _ = threads;
    try out.writeAll("stable bytes");
}

const report = try harnessz.determinism.run(gpa, io, .{
    .runs = 5,
    .thread_counts = &.{ 1, 2, 4 }, // optional matrix
    .thread_runs = 2,
}, &context, produce);
```

The callback receives the requested thread count and is responsible for
actually using that many threads. The harness compares every output against the
baseline (thread count 1) and reports the first divergent run/count and byte
offset.

## Threaded runs

For real threaded runs, use `runThreaded`:

```zig
fn produceThreaded(context: *Ctx, thread_index: usize, out: *std.Io.Writer) !void {
    try context.writeForThread(thread_index, out);
}

var report = try harnessz.determinism.runThreaded(gpa, io, .{
    .thread_counts = &.{ 1, 2, 4 },
    .thread_runs = 2,
}, &context, produceThreaded);
defer report.deinit();

if (!report.ok()) {
    // report.first_divergence_thread, report.divergence_offset,
    // report.thread_checksums, report.spawn_fallbacks
}
```

`runThreaded` spawns `thread_counts[i]` OS threads per case, gives each lane its
own output buffer, joins all threads, and compares every lane against thread 0.
`options.runs` is ignored; `options.thread_runs` controls repetitions per
thread count. A lane whose spawn fails runs on the caller and increments
`spawn_fallbacks`.

Worker errors are recorded in `report.worker_error` / `report.worker_thread`
and make `ok()` false. The report owns `thread_checksums`; call `deinit()`.

## Test rules

- Test a stable producer and an unstable producer whose first divergence is
  reported.
- Threaded tests must use a producer that is stable regardless of thread index
  and one that depends on the index.
- Run threaded tests repeatedly (at least 10 iterations).
- Ensure every thread is joined; do not detach.
- Never assert absolute timings or scheduler behaviour.

# harnessz

Shared test, benchmark, and oracle infrastructure for Project-Z.

`harnessz` replaces per-repository `build_support/*` golden/bench gates and
`docs/*evidence*` conventions with one small, std-only Zig package. It targets
Zig 0.16.0 and uses `std.Io` with an explicit `io` value.

## Implemented scope

| Module | Purpose |
| --- | --- |
| `golden` | Golden files and directory trees with create/match/mismatch/update, text/binary modes, optional line-ending, trailing-whitespace, and canonical-JSON normalization |
| `snapshot` | Named in-memory or file-backed snapshots with `check`, `checkFmt`, and update mode |
| `oracle` | Byte/integer/float/complex comparisons, structural JSON comparison, tolerances, ULP distance, NaN/inf/signed-zero handling, Wyhash checksums |
| `determinism` | Repeated-run byte stability, first divergence, thread-count matrix, real threaded runs with spawn fallback |
| `stats` | Batch summaries plus streaming Welford accumulation, linear histograms, confidence intervals, trimmed means, and Welch's t-test |
| `bench` | Warmup/timed runs, min-time sampling, interleaved A/B comparison, significance gates, CPU pinning, peak RSS, counting allocator, JSON/CSV, `blackBox`, plus process-isolated child/parent runners with process-group timeouts and bounded stderr capture |
| `baseline` | JSON baseline storage, environment fingerprints, optional fingerprint enforcement, median regression detection, entry updates, and deterministic text/JSON comparison reports |
| `fixture` | `HARNESSZ_FIXTURES` / `testdata/` resolution and workspace helpers |
| `evidence` | Evidence manifests with JSON round-trip, missing-path validation, and test-name validation |
| `json_canon` | Canonical JSON emission with recursively sorted object keys |
| `diff` | Line-oriented unified diff used by golden/snapshot diagnostics |
| `paths` | Shared relative-path validation and existence checks |

Every public module is exported from `src/root.zig`.

## Build and test

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
```

Tests live beside each implementation. Package-level integration tests live in
`test/integration.zig`.

## Golden files

```zig
const harnessz = @import("harnessz");

try harnessz.golden.expectFile(io, dir, "render/basic.txt", actual, .{
    .allocator = gpa,
    .update = false, // or set HARNESSZ_UPDATE=1
    .mode = .text,
});
```

Behaviour:

- Missing file without update returns `error.GoldenMissing`.
- Equal bytes return `.matched`.
- Mismatch without update prints a unified diff and returns
  `error.GoldenMismatch`.
- Update mode creates parent directories and returns `.created` or `.updated`.
- Text mode compares exact bytes by default; the mode only changes mismatch
  diagnostics (line diff versus hex dump).
- `expectString(expected, actual, .{})` performs the same comparison in memory.

Text comparisons can opt into normalization:

```zig
try harnessz.golden.expectFile(io, dir, "render/basic.txt", actual, .{
    .allocator = gpa,
    .normalize = .{
        .line_endings = true,       // CRLF and lone CR become LF
        .trailing_whitespace = true, // strip spaces/tabs at line ends
        .json_canonical = true,     // parse JSON and compare canonical forms
    },
});
```

`json_canonical` recursively sorts object keys, preserves array order, and
returns `error.InvalidJson` for invalid input. Normalization applies only to
text mode. Update mode always writes the original `actual` bytes, never the
normalized form; normalized-equal comparisons return `.matched` without
rewriting the file. Binary mode ignores normalization.

### Golden directories

```zig
const expected = [_]harnessz.golden.DirEntry{
    .{ .relative_path = "a.txt", .bytes = "alpha" },
    .{ .relative_path = "nested/b.bin", .bytes = &blob },
};

var report = try harnessz.golden.expectDirectory(io, dir, "golden/render", &expected, .{
    .allocator = gpa,
    .update = false, // or set HARNESSZ_UPDATE=1
    .max_files = 4096,
    .max_total_bytes = 256 * 1024 * 1024,
    .max_file_bytes = 64 * 1024 * 1024,
});
defer report.deinit();
if (!report.ok()) {
    for (report.changes) |change| {
        // change.kind: missing, extra, changed, or created
        // change.relative_path
    }
}
```

Traversal is deterministic: files are collected recursively and sorted by
relative path. Compare mode reports `missing`, `extra`, and `changed` files
without mutating the tree, and a missing root is reported as every expected
file missing. Update mode creates missing files, rewrites changed files, and
deletes extra files. Both modes enforce `max_files`, `max_total_bytes`, and
`max_file_bytes`; duplicate expected paths return `error.DuplicateEntry`.

## Snapshots

```zig
var registry = try harnessz.snapshot.Registry.init(gpa, io, .{
    .dir = snapshots_dir, // omit for an in-memory registry
    .prefix = "snapshots",
    .update = false,
});
defer registry.deinit();

try registry.check("render/basic", bytes);
try registry.checkFmt("hash/{x}", "{x}", .{checksum});
```

An in-memory registry accepts the first value for a name and compares later
values. A file-backed registry requires update mode to create a missing file.
`HARNESSZ_UPDATE=1` (or `true`) enables update mode in both modes.

## Oracles

```zig
const bytes_report = harnessz.oracle.compareBytes(expected, actual);
const floats_report = harnessz.oracle.compareFloatSlices(f64, expected_f, actual_f, .{
    .abs_tolerance = 1e-9,
    .rel_tolerance = 1e-6,
    .nan_equal = true,
    .max_mismatches = 8,
});
const ints_report = harnessz.oracle.compareIntSlices(i32, expected_i, actual_i);
const hash = harnessz.oracle.checksum(bytes);

const ulp_report = harnessz.oracle.compareUlp(f64, expected_f, actual_f, 2);
const complex_report = harnessz.oracle.compareComplexSlices(
    f64,
    expected_complex,
    actual_complex,
    .{ .abs_tolerance = 1e-9 },
);

var json_report = try harnessz.oracle.compareJson(
    "{\"b\":[1,2],\"a\":2}",
    "{\"a\":2,\"b\":[1,2]}",
    .{ .abs_tolerance = 1e-9, .rel_tolerance = 1e-6 },
);
defer json_report.deinit();
if (!json_report.ok()) {
    // json_report.first_difference.?.path, e.g. "a.b[2].c"
    // json_report.first_difference.?.kind
}
```

Float tolerance passes when:

```text
|a - b| <= abs_tolerance + rel_tolerance * max(|a|, |b|)
```

NaN is unequal by default (`nan_equal = true` changes this). Same-sign
infinities are equal. `+0.0` and `-0.0` are equal by default; set
`signed_zero_equal = false` to require identical signs.

`compareUlp` compares f32/f64 values by representable-step distance. `+0.0`
and `-0.0` are equal (`UlpReason.signed_zero`), NaN never compares equal, and
same-sign infinities are equal. `ulp_distance` is `maxInt(u64)` when the values
are not comparable. `compareComplexSlices` applies the `FloatOptions` policy to
both the real and imaginary parts; one complex element counts as one mismatch
when either part differs.

`compareJson` parses both documents with `std.json` and compares them
structurally. Object key order is ignored, array order is significant, and
integer/float values compare numerically. `abs_tolerance` and `rel_tolerance`
use the same formula as float slices. The first difference is reported as a
path (`a.b[2].c`), and invalid JSON returns `error.InvalidJson`.

## Determinism

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

## Statistics

```zig
const median = harnessz.stats.median(u64, samples);
const p99 = harnessz.stats.percentile(u64, samples, 99);
const summary = harnessz.stats.summarize(u64, samples);
const robust = harnessz.stats.compare(u64, baseline, candidate);
```

`percentile` uses linear interpolation (R-7 / NumPy default). `summarize`
returns count, min, max, mean, population stddev, median, p90, and p99.
Statistics make temporary copies through `std.heap.page_allocator` because the
input slices are const.

Streaming and distribution helpers:

```zig
var accumulator: harnessz.stats.Accumulator = .init();
accumulator.add(120);
accumulator.add(130);
const mean = accumulator.mean();
const variance = accumulator.variance(); // population variance (Welford)
const summary = accumulator.summary();   // median/p90/p99 remain 0

var histogram = try harnessz.stats.Histogram.build(gpa, values, 8);
defer histogram.deinit();
const json = try histogram.toJson(gpa);
defer gpa.free(json);

const interval = harnessz.stats.confidenceIntervalMean(values, 1.96);
const robust_mean = harnessz.stats.trimmedMean(values, 0.1);
```

`Histogram` uses linear buckets from min to max; the last bucket includes the
maximum and all-equal values collapse to a zero-width first bucket.
`confidenceIntervalMean` uses the normal approximation
`mean +/- z * stddev / sqrt(n)` and assumes approximately i.i.d. samples; it is
not an exact Student-t interval. `trimmedMean` discards
`floor(len * trim_fraction)` values from each end, with `trim_fraction` in
`[0, 0.5)`.

Welch's unequal-variance t-test:

```zig
const result = try harnessz.stats.welchTTest(u64, baseline_samples, candidate_samples);
// result.t, result.degrees_of_freedom, result.p_approx
```

Both inputs need at least two samples. The p-value is two-sided and uses a
standard normal approximation (`erfc(|t| / sqrt(2))`) rather than Student's t
distribution. This is documented and intentionally conservative for small
samples; the test statistic and degrees of freedom use the exact Welch
formulas.

## Benchmarks

```zig
fn work(context: *Ctx, gpa: std.mem.Allocator, io: std.Io) !u64 {
    _ = gpa;
    _ = io;
    return context.doWork();
}

var stats = try harnessz.bench.run(gpa, io, .{
    .warmup_iterations = 3,
    .iterations = 20,
    .min_time_ns = 200 * std.time.ns_per_ms,
    .max_iterations = 200,
}, &context, work);
defer stats.deinit(gpa);

const comparison = try harnessz.bench.compare(
    gpa, io, .{ .warmup_iterations = 2, .iterations = 10 },
    &baseline_ctx, baseline_work,
    &candidate_ctx, candidate_work,
);
if (!comparison.gate(1.05)) return error.PerformanceRegression;

const json = try comparison.toJson(gpa);
defer gpa.free(json);
```

`comparison.speedup()` is `a.median / b.median`; values above 1 mean `b` is
faster. A/B rounds are interleaved and alternate order. Callbacks return `u64`
so the harness can keep the result observable with `blackBox`, which wraps the
Zig 0.16 `std.mem.doNotOptimizeAway` primitive.

Gate logic is testable without timing:

```zig
const comparison = harnessz.bench.Comparison.fromSamples(
    &.{ 100, 100, 100 },
    &.{ 50, 50, 50 },
);
try std.testing.expect(comparison.gate(1.5));
try std.testing.expect(comparison.significant); // p_value <= 0.05
try std.testing.expect(comparison.gateSignificant(1.5, 0.01));
```

`fromSamples` computes `p_value` with `stats.welchTTest` and sets
`significant` when `p_value <= 0.05`. With fewer than two samples per side the
p-value is 1 and the comparison is not significant.
`gateSignificant(min_ratio, max_p_value)` passes only when the ratio gate
passes, the comparison is significant at 0.05, and `p_value <= max_p_value`.
The JSON and CSV renderings include both fields.

Measured runs and host controls:

```zig
var measured = try harnessz.bench.runMeasured(gpa, io, .{ .iterations = 20 }, &ctx, work);
defer measured.deinit(gpa);
// measured.timing, measured.peak_rss_bytes, measured.peak_allocated_bytes

try harnessz.bench.pinToCpu(3);          // Linux; error.Unsupported elsewhere
const cpu = try harnessz.bench.currentCpu();
const mask = try harnessz.bench.affinityMask();
const rss = try harnessz.bench.peakRssBytes(io); // VmHWM from /proc/self/status

var counting = harnessz.bench.CountingAllocator.init(gpa);
const samples = try harnessz.bench.run(counting.allocator(), io, .{}, &ctx, work);
defer samples.deinit(counting.allocator());
// counting.currentBytes(), counting.peakBytes()
```

`runMeasured` passes a counting allocator to the callback while harness
bookkeeping uses the supplied allocator; peak allocation tracking resets after
warmup. The counting allocator is not thread-safe and counts requested bytes,
not underlying allocator overhead. CPU pinning and RSS sampling are Linux-only
and return `error.Unsupported` on other platforms.

For already type-erased callbacks, `runRuntime(alloc, io, options, context,
func)` uses the same warmup and sampling loop. `Stats.last_result` records the
last measured callback result, which is how the process protocol carries a
deterministic checksum.

## Process-isolated benchmarks

`bench.protocol`, `bench.registry`, `bench.child`, and `bench.process` move
measurement into a separate OS process so the parent's threads, allocator
state, and other benchmarks cannot perturb the samples.

### Protocol

The parent writes one JSON `Request` to the child's stdin and closes it:

```json
{"benchmark":"checksum","warmup_iterations":2,"iterations":20,"min_time_ns":0}
```

The child writes exactly one JSON `Response` to stdout:

```json
{"samples_ns":[123,456],"checksum":98765}
{"samples_ns":[],"error_name":"SyntheticBenchFailure","error_message":"benchmark execution failed"}
```

`checksum` is an optional additive extension carrying the benchmark callback's
last returned `u64` (useful for deterministic checksums). Null optional fields
are omitted from the wire form. The child must not print anything else to
stdout; diagnostics go to stderr. Stderr is **not** part of the wire protocol:
the parent captures it out-of-band and returns it through
`process.ProcessResult`.

`bench.protocol` exposes `Request`, `Response`, `writeRequest`,
`writeResponse`, `encodeRequest`, `encodeResponse`, `decodeRequest`, and
`decodeResponse`. Decoding returns arena-backed `OwnedRequest`/`OwnedResponse`
values; call `deinit()`. `cloneResponse`/`freeResponse` manage plain
`Response` values returned by the parent runner.

### Registry

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

### Child executable

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

### Parent runner

```zig
var response = try harnessz.bench.process.runProcess(gpa, io, .{
    .argv = &.{ "/path/to/bench-child" },
    .benchmark = "checksum",
    .warmup_iterations = 2,
    .iterations = 20,
    .min_time_ns = 0,
    .timeout_ns = 30 * std.time.ns_per_s, // 0 disables
});
defer harnessz.bench.protocol.freeResponse(gpa, &response);
```

`runProcess` returns `error.BenchmarkFailed` when the child produced a valid
response with `error_name` set, and forwards the captured stderr to the
parent's stderr as a diagnostic. `runProcessResponse` returns that response
instead, so callers can inspect `error_name`/`error_message`. Other typed
errors are `error.SpawnFailed`, `error.ChildExitFailure`, `error.Timeout`,
`error.TimeoutUnavailable`, `error.OutputTooLarge`, `error.CaptureUnavailable`,
`error.InvalidJson`, `error.InvalidResponse`, `error.WriteFailed`,
`error.ReadFailed`, `error.WaitFailed`, and `error.InvalidOptions`.

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
discarded and `stderr_truncated` is set.

When `timeout_ns` is non-zero, a dedicated `std.Thread` watchdog starts after
the request is written. If the deadline expires it sends `SIGKILL` to the
child's whole process group (`kill(-pid, SIGKILL)`) on POSIX, then the parent
reaps the direct child. This kills sleeping grandchildren as well. When a
thread cannot be started, the watchdog falls back to `Io.concurrent`; only
when neither mechanism is available is `error.TimeoutUnavailable` returned.

The package's own `bench/child_main.zig` executable is registered by
`build.zig`, and `test/integration.zig` receives its emitted path through the
`bench_child` build-options module. The integration suite includes a `tree`
benchmark that spawns a sleeping grandchild and verifies through `/proc` that
both the child and grandchild are gone after a timeout (Linux only).

### Process isolation boundaries

This is process isolation, not OS-level sandboxing. The child runs as the same
user, inherits the environment, filesystem, and network access, and has no
extra resource limits. It isolates address space, threads, and allocator state
only. Process-group cleanup is POSIX-only: on Windows the watchdog terminates
the direct child, and grandchildren are not tracked because Zig 0.16 does not
expose job-object helpers. Descendants that escape the process group (for
example by calling `setsid`) are also outside the cleanup guarantee.

## Baselines and regression detection

`baseline` stores benchmark samples as JSON and compares fresh samples against
a recorded median. The environment fingerprint prevents accidentally comparing
different machines or build modes.

```zig
const samples = try harnessz.bench.run(gpa, io, .{ .iterations = 20 }, &ctx, work);
defer samples.deinit(gpa);

const fingerprint = try harnessz.baseline.environmentFingerprint(
    gpa, io, "release-safe",
);
defer gpa.free(fingerprint);

var store = harnessz.baseline.Store.init(gpa);
defer store.deinit();

// Load an existing baseline, or build one with Store.fromJson / save.
try store.load(io, dir, "bench/baseline.json");

const regression = try store.compare("render", samples.samples_ns, .{
    .max_regression_ratio = 1.05,
    // Optional: fail with error.EnvironmentMismatch when the recorded
    // fingerprint differs from the caller's expected fingerprint.
    .require_fingerprint = true,
    .expected_fingerprint = fingerprint,
});
if (regression.regressed) return error.PerformanceRegression;

// Replace the entry by name. Missing names return error.MissingBaseline.
try store.update(.{
    .name = "render",
    .environment_fingerprint = fingerprint,
    .samples_ns = samples.samples_ns,
    .summary = samples.distribution,
});
try store.save(io, dir, "bench/baseline.json");
```

Recommended workflow:

1. Run `bench.run`, summarize, and write an initial JSON store (for example
   via `Store.fromJson` or by constructing a `Store` and calling `save`).
2. Commit the baseline file alongside the benchmark.
3. On later runs, `load`, `compare`, and fail the gate when `regressed` is
   true.
4. Refresh with `update` and `save` only when the change is intentional.

`speedup` is `baseline_median / current_median`; values above 1 mean the
current run is faster. A regression is reported when
`current_median > baseline_median * max_regression_ratio`. Empty current
samples and non-positive ratios return `error.InvalidOptions`.

### Comparison report

`baseline.report.report` merges the whole store with the current entries and
writes a deterministic text table. Rows are sorted by name; a p-value is
included when both sides have at least two raw samples.

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();

var comparison = try harnessz.baseline.report.report(
    gpa,
    &out.writer,
    &store,
    current_entries, // []const harnessz.baseline.Entry
    .{ .max_regression_ratio = 1.05 },
);
defer comparison.deinit();

std.debug.print("{s}", .{out.written()});
if (comparison.regressions != 0) return error.PerformanceRegression;

const json = try comparison.toJson(gpa);
defer gpa.free(json);
```

The text table contains `name`, `baseline_ns`, `current_ns`, `speedup`,
`p_value`, and a status marker (`REGRESSED`, `IMPROVED`, `UNCHANGED`,
`MISSING`, or `EXTRA`). `Report` exposes `regressions`, `improvements`,
`missing`, and `extra` counts plus `ok()`; `writeJson`/`toJson` emit the same
rows with a summary object. `missing` counts baseline entries with no current
counterpart, and `extra` counts current entries with no baseline. Rows without
a usable baseline or current median return `error.InvalidBaseline` or
`error.InvalidEntry`; duplicate current names return `error.DuplicateEntry`.

Fingerprint enforcement is opt-in. With `require_fingerprint = true`, `compare`
returns `error.EnvironmentMismatch` unless the entry's
`environment_fingerprint` equals `expected_fingerprint`; a missing
`expected_fingerprint` returns `error.InvalidOptions`. The default
(`require_fingerprint = false`) keeps the previous behaviour of recording
fingerprints without enforcing them.

## Fixtures

```zig
var resolved = try harnessz.fixture.resolve(gpa, io, "images/basic.png", .{
    .environ = init.minimal.environ, // optional in tests
});
defer resolved.deinit(gpa);
```

Resolution order:

1. `Options.fixtures_root`, when supplied.
2. `HARNESSZ_FIXTURES`, when set and non-empty.
3. `Options.testdata_dir` (default `testdata`).

Relative paths are checked against `Options.base_dir` (default cwd).
`workspace`, `workspaceJoin`, and `workspaceDir` help tests locate the
workspace root.

## Evidence manifests

```zig
var manifest = try harnessz.evidence.Manifest.fromJson(gpa, json_bytes);
defer manifest.deinit();

const summary = manifest.summary();
var report = try manifest.validatePaths(io, repo_dir);
defer report.deinit();
if (!report.valid()) {
    for (report.missing) |missing| {
        std.debug.print("{s}: missing {s} ({s})\n", .{
            missing.entry_id, missing.path, @tagName(missing.kind),
        });
    }
}
```

Entries carry `id`, `status` (`implemented`, `partial`, `planned`, `deferred`),
`implementation_paths`, `test_names`, `evidence_paths`, and `notes`.
`toJson` emits only the manifest schema, not allocator bookkeeping.

Test names can be checked against a list of tests known to the build:

```zig
var test_report = try manifest.validateTests(&known_test_names);
defer test_report.deinit();
if (!test_report.valid()) {
    for (test_report.unknown) |unknown| {
        // unknown.entry_id, unknown.name
    }
}
```

`TestValidationReport` references manifest-owned strings and counts every
declared test name, including duplicates.

## Environment variables

- `HARNESSZ_UPDATE=1` or `true`: golden and snapshot update mode.
- `HARNESSZ_FIXTURES`: fixture root.

In tests, the runner environment is used automatically. In applications, pass
`std.process.Init.minimal.environ` through the relevant `Options.environ`
field. `std.process.Init` in Zig 0.16 exposes the environment at
`init.minimal.environ`; `std.process.Environ` has platform-specific getters and
`createMap`, so `harnessz` uses `createMap` for portable lookups.

## Limitations

- No command-line runner; these are library APIs.
- Text golden normalization is opt-in. `json_canonical` re-emits minified JSON,
  so update mode writes the original bytes rather than the canonical form.
- The diff engine is a diagnostic aid, not a patch application engine. Very
  large differing middles fall back to delete-all/insert-all.
- `stats` allocates temporary sorted copies with `std.heap.page_allocator`;
  slices must be non-empty for the direct statistic functions.
- `runThreaded` creates OS threads; `run`'s thread matrix still delegates
  threading to the callback. A lane whose spawn fails runs on the caller.
- Benchmark callbacks must return `u64`; avoid relying on wall-clock
  assertions in tests.
- `baseline` fingerprint enforcement is opt-in via `require_fingerprint`; the
  default keeps the historical record-only behaviour.
- `stats.welchTTest` uses a normal approximation for the p-value rather than
  an exact Student-t tail. Treat very small samples or heavy-tailed data with
  caution.
- `bench.pinToCpu`, `bench.currentCpu`, `bench.affinityMask`, and
  `bench.peakRssBytes` are Linux-only and return `error.Unsupported`
  elsewhere. `CountingAllocator` is single-threaded and counts requested
  bytes, not allocator overhead.
- Process isolation is not OS-level sandboxing: the child shares the parent's
  user, environment, filesystem, and network. Timeout enforcement uses a
  dedicated `std.Thread` watchdog and falls back to `Io.concurrent`; only when
  neither mechanism exists does it return `error.TimeoutUnavailable`.
  Process-group cleanup is POSIX-only; on Windows only the direct child is
  terminated, and descendants that call `setsid` escape the group.
- The process runner captures stderr into a pipe and retains at most
  `max_stderr_bytes` (default 64 KiB). The pipe is always drained to EOF, so
  oversized stderr is truncated rather than deadlocking. A descendant that
  keeps the stderr pipe open after the direct child exits can still delay
  completion until the pipe closes or the timeout fires.
- A successful child run does not kill lingering descendants; process-group
  termination happens on timeout and on output/read failures.
- Golden directory update mode prunes extra files under the managed root.
  Compare mode never mutates the tree.
- `std.fs` file APIs are not used; `std.fs.path` remains in use for pure path
  manipulation. Directory creation uses `std.Io.Dir.createDirPath` (the Zig
  0.16 name for the recursive make-path operation).

# harnessz

Shared test, benchmark, and oracle infrastructure for Project-Z.

`harnessz` replaces per-repository `build_support/*` golden/bench gates and
`docs/*evidence*` conventions with one small, std-only Zig package. It targets
Zig 0.16.0 and uses `std.Io` with an explicit `io` value.

## Implemented scope

| Module | Purpose |
| --- | --- |
| `golden` | Golden files with create/match/mismatch/update, text and binary modes, unified diffs |
| `snapshot` | Named in-memory or file-backed snapshots with `check`, `checkFmt`, and update mode |
| `oracle` | Byte/integer/float comparisons, tolerances, NaN/inf/signed-zero handling, Wyhash checksums |
| `determinism` | Repeated-run byte stability, first divergence, optional thread-count matrix |
| `stats` | Median, percentile, mean, stddev, min, max, summaries, robust comparison |
| `bench` | Warmup/timed runs, min-time sampling, interleaved A/B comparison, gates, JSON/CSV |
| `fixture` | `HARNESSZ_FIXTURES` / `testdata/` resolution and workspace helpers |
| `evidence` | Evidence manifests with JSON round-trip and missing-path validation |
| `diff` | Line-oriented unified diff used by golden/snapshot diagnostics |
| `paths` | Shared relative-path validation and existence checks |

Every public module is exported from `src/root.zig`.

## Build and test

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
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
- Text mode compares exact bytes; the mode only changes mismatch diagnostics
  (line diff versus hex dump).
- `expectString(expected, actual, .{})` performs the same comparison in memory.

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
```

Float tolerance passes when:

```text
|a - b| <= abs_tolerance + rel_tolerance * max(|a|, |b|)
```

NaN is unequal by default (`nan_equal = true` changes this). Same-sign
infinities are equal. `+0.0` and `-0.0` are equal by default; set
`signed_zero_equal = false` to require identical signs.

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
so the harness can keep the result observable with
`std.mem.doNotOptimizeAway`.

Gate logic is testable without timing:

```zig
const comparison = harnessz.bench.Comparison.fromSamples(
    &.{ 100, 100, 100 },
    &.{ 50, 50, 50 },
);
try std.testing.expect(comparison.gate(1.5));
```

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
- Text golden mode does not normalize line endings or trailing whitespace.
- The diff engine is a diagnostic aid, not a patch application engine. Very
  large differing middles fall back to delete-all/insert-all.
- `stats` allocates temporary sorted copies with `std.heap.page_allocator`;
  slices must be non-empty for the direct statistic functions.
- The thread matrix does not create threads; the callback owns that policy.
- Benchmark callbacks must return `u64`; avoid relying on wall-clock
  assertions in tests.
- `std.fs` file APIs are not used; `std.fs.path` remains in use for pure path
  manipulation. Directory creation uses `std.Io.Dir.createDirPath` (the Zig
  0.16 name for the recursive make-path operation).

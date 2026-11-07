# Baselines and regression detection

`baseline` stores benchmark samples as JSON and compares fresh samples against a
recorded median. The environment fingerprint prevents accidentally comparing
different machines or build modes.

## Store

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

`speedup` is `baseline_median / current_median`; values above 1 mean the
current run is faster. A regression is reported when
`current_median > baseline_median * max_regression_ratio`. Empty current
samples and non-positive ratios return `error.InvalidOptions`.

`Store` owns an arena; call `deinit()`. `compare` requires an existing entry,
and `update` replaces an entry by name and returns `error.MissingBaseline` for
unknown names. The store lives in `src/baseline/store.zig` and is re-exported
from `src/baseline.zig`.

## Recommended workflow

1. Run `bench.run`, summarize, and write an initial JSON store (for example
   via `Store.fromJson` or by constructing a `Store` and calling `save`).
2. Commit the baseline file alongside the benchmark.
3. On later runs, `load`, `compare`, and fail the gate when `regressed` is
   true.
4. Refresh with `update` and `save` only when the change is intentional.
5. Record `environmentFingerprint` in entries so different machines or build
   modes are visible. Pass `require_fingerprint = true` plus
   `expected_fingerprint` when a mismatch must fail with
   `error.EnvironmentMismatch`; enforcement is off by default.

Fingerprint enforcement is opt-in. With `require_fingerprint = true`, `compare`
returns `error.EnvironmentMismatch` unless the entry's
`environment_fingerprint` equals `expected_fingerprint`; a missing
`expected_fingerprint` returns `error.InvalidOptions`. The default
(`require_fingerprint = false`) keeps the record-only behaviour.

## Comparison report

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
rows with a summary object. `writeMarkdown`/`toMarkdown` render a deterministic
Markdown table for committed benchmark-history documents.

A row is `regressed` above `baseline * max_regression_ratio` and `improved`
below `baseline / max_regression_ratio`. `missing` counts baseline entries with
no current counterpart, and `extra` counts current entries with no baseline.
Rows without a usable baseline or current median return
`error.InvalidBaseline` or `error.InvalidEntry`; duplicate current names return
`error.DuplicateEntry`.

## Feeding suites and comparisons

Both `SuiteResult.toEntries` and `MultiComparison.toEntries` produce
`baseline.Entry` slices that borrow the owner's names and samples. Keep the
suite/comparison alive until the entries and the report are done.

```zig
const entries = try suite.toEntries(gpa, fingerprint);
defer gpa.free(entries);

var store = harnessz.baseline.Store.init(gpa);
defer store.deinit();
store.entries = entries; // borrowed
try store.save(io, dir, "bench/baseline.json");
```

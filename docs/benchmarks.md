# Benchmarks

`bench` measures callbacks with warmup, timed samples, optional batching,
minimum sampling time, interleaved comparisons, gates, suites, and process
isolation. Timing values are never asserted by unit tests; structure (callback
counts, sample lengths, batch sizes, checksums) is tested instead.

## Single workload

```zig
fn work(context: *Ctx, gpa: std.mem.Allocator, io: std.Io) !u64 {
    _ = gpa;
    _ = io;
    return context.doWork();
}

var stats = try harnessz.bench.run(gpa, io, .{
    .warmup_iterations = 3,
    .iterations = 20,
    .batch_size = 1, // raise for callbacks shorter than the clock resolution
    .min_time_ns = 200 * std.time.ns_per_ms,
    .max_iterations = 200,
}, &context, work);
defer stats.deinit(gpa);
```

`Stats` contains the warmup count, batch size, raw `samples_ns`, a
`distribution` summary, and `last_result` (the last measured callback result,
useful as a deterministic checksum). `toJson`/`writeJson` and
`toCsv`/`writeCsv` render the same values.

When `min_time_ns` is non-zero, sampling collects at least `iterations` samples
and continues until the time budget is met, capped at
`max(iterations, max_iterations)` samples. A zero candidate median produces an
infinite speedup, which JSON renders as `null`.

`batch_size` invokes the callback that many times per timed sample and stores
the per-call average; `Stats.batch_size` records the value. Warmup still runs
`warmup_iterations` callback calls, not batches.

`runRuntime` is the type-erased counterpart for callers that already have a
`bench.Runner` (`context` plus `fn (*anyopaque, Allocator, std.Io)
anyerror!u64`).

## A/B comparison

```zig
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
faster. A/B rounds are interleaved and alternate order.

## Gate logic without timing

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

Welch's test is sensitive to timing outliers: one scheduler hiccup can inflate
the variance enough to hide a real shift. `fromSamples` therefore also runs the
tie-corrected Mann-Whitney U test and exposes `robust_p_value` and
`robust_significant`. `gateRobust(min_ratio, max_p_value)` is the
outlier-tolerant counterpart:

```zig
// Same 10% slowdown, with one 1000 ns outlier in the candidate.
const comparison = harnessz.bench.Comparison.fromSamples(
    &.{ 110, 111, 109, 110, 1000 },
    &.{ 100, 101, 99, 100, 100 },
);
try std.testing.expect(!comparison.gateSignificant(1.05, 0.05)); // Welch
try std.testing.expect(comparison.gateRobust(1.05, 0.05));        // rank-sum
```

## Multi-implementation comparison

`compareMany` measures any number of named implementations in one interleaved
run. Each round visits every candidate once, rotating the starting point, so
ordering bias is spread instead of favoring the first or last entry. Every pair
gets the same `Comparison` type used by `bench.compare`.

```zig
const runners = [_]harnessz.bench.NamedRunner{
    .{ .name = "scalar", .runner = .{ .context = &scalar_ctx, .run = scalarWork } },
    .{ .name = "simd", .runner = .{ .context = &simd_ctx, .run = simdWork } },
    .{ .name = "gpu", .runner = .{ .context = &gpu_ctx, .run = gpuWork } },
};

var result = try harnessz.bench.compareMany(gpa, io, .{
    .warmup_iterations = 2,
    .iterations = 20,
}, &runners);
defer result.deinit();

try result.writeText(writer);
if (!try result.gatePair("scalar", "simd", 1.05, 0.01)) {
    return error.PerformanceRegression;
}

// Feed the same run into baseline tracking.
const entries = try result.toEntries(gpa, fingerprint);
defer gpa.free(entries);
```

`MultiComparison` owns its names and samples until `deinit()`. `rounds` is the
number of measured rounds, `samples_ns[i]` holds one sample per round,
`summaries[i]` is the usual distribution summary, and `pairs` contains every
`i < j` comparison.

`comparisonOf(a, b)` returns the pair with `a` as the numerator, flipping the
stored pair when needed. `gatePair` applies `gateSignificant` and returns
`error.UnknownName` or `error.InvalidPair` for unknown or identical names.
`gateRobustPair` is the rank-sum counterpart. Each pair carries both p-values.
Text and JSON reports are deterministic and follow registration order.
`MultiComparison.fromSamples` builds the same structure from synthetic samples
for tests and offline analysis.

## Benchmark suites

When a repository has many named kernels, `runSuite` runs a
`bench.registry.Registry` in registration order and returns per-benchmark
samples plus deterministic text/JSON:

```zig
var registry = harnessz.bench.registry.Registry.init(gpa);
defer registry.deinit();
try registry.add("decode", .{ .context = &ctx, .run = decodeWork });
try registry.add("encode", .{ .context = &ctx, .run = encodeWork });

var suite = try harnessz.bench.runSuite(gpa, io, &registry, .{
    .run = .{ .warmup_iterations = 2, .iterations = 20 },
    .max_benchmarks = 0, // 0 = all
});
defer suite.deinit();

try suite.writeText(writer);
const entries = try suite.toEntries(gpa, fingerprint);
defer gpa.free(entries);
```

`SuiteResult` owns names and `Stats` (including samples) until `deinit()`;
`find(name)` returns a benchmark's stats, and a callback error aborts the suite
and releases partial results. `max_benchmarks` bounds the run in registration
order. An empty registry yields an empty result.

Set `measure_memory = true` to wrap each callback allocator with the counting
allocator. `SuiteResult.memory` then records `peak_rss_bytes` (nullable on
unsupported platforms), `peak_allocated_bytes`, `allocation_count`, and
`free_count` for every benchmark; text and JSON reports add the same columns.
Warmup allocations are excluded from all four metrics.

Use `bench.process` when each benchmark must run in its own process; see
[Process isolation](process-isolation.md).

## Benchmark policy

`bench.validatePolicy` checks a build-mode tag and sample-count bounds before a
benchmark runs. This is the runtime counterpart of release-build requirements
in downstream benchmark gates:

```zig
try harnessz.bench.validatePolicy(@tagName(builtin.mode), .{
    .warmup_iterations = 3,
    .iterations = 20,
    .batch_size = 1,
}, .{
    .required_build_mode = "ReleaseFast",
    .min_warmup_iterations = 2,
    .min_iterations = 10,
});
```

`bench.policy.check` returns the first `PolicyViolation` instead of an error;
`bench.policy.describe` renders a diagnostic. An empty `required_build_mode`
disables the build check, and inconsistent bounds return
`error.InvalidPolicy`.

## Memory measurement and host controls

```zig
var measured = try harnessz.bench.runMeasured(gpa, io, .{ .iterations = 20 }, &ctx, work);
defer measured.deinit(gpa);
// measured.timing, measured.peak_rss_bytes, measured.peak_allocated_bytes,
// measured.allocation_count, measured.free_count

try harnessz.bench.pinToCpu(3);          // Linux; pins the calling thread
const cpu = try harnessz.bench.currentCpu();
const mask = try harnessz.bench.affinityMask();
const rss = try harnessz.bench.peakRssBytes(io); // VmHWM from /proc/self/status

var counting = harnessz.bench.CountingAllocator.init(gpa);
const samples = try harnessz.bench.run(counting.allocator(), io, .{}, &ctx, work);
defer samples.deinit(counting.allocator());
// counting.currentBytes(), counting.peakBytes()
```

`runMeasured` passes a counting allocator to the callback while harness
bookkeeping uses the supplied allocator; peak bytes and allocation/free counts
reset after warmup. `runMeasuredRuntime` is its type-erased counterpart.

The counting allocator is not thread-safe and counts requested bytes, not
underlying allocator overhead. CPU pinning and RSS sampling are Linux-only and
return `error.Unsupported` on other platforms. `pinToCpu` pins only the calling
thread; save `affinityMask()` and restore it when the benchmark finishes.

`Stats.last_result` records the last measured callback result, which is how the
process protocol carries a deterministic checksum.

## Environment variables

Benchmarks themselves do not read environment variables. The shared update and
fixture variables are documented in [Environment](environment.md).

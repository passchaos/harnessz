# Adoption comparison: harnessz vs downstream ad-hoc harnesses

This document records why the Project-Z libraries should replace their
per-repository benchmark and evidence plumbing with `harnessz`, and what was
measured on the current host. It covers `imx`, `iris`, `pdfz`, `zev`, and
`spectra`; sibling repositories were inspected read-only and not modified.

The machine-readable artifact for the measured section is
[`adoption-bench.json`](adoption-bench.json). The tool that produced it lives in
`tools/adoption_bench.zig` and runs through `zig build adoption-bench`.

## Downstream inventory

The counts are source lines in each repository at the time of inspection. They
include benchmark kernels, not only harness code; the point is the scale of the
per-repository infrastructure that `harnessz` can replace or complement.

| Repository | Internal artifacts | Size | Observed approach | harnessz replacement |
| --- | --- | --- | --- | --- |
| `zev` | `bench/compare.zig`, `bench/highway_baseline.cpp` | ~28,500 lines | One large executable; 20 iterations x 5 repeats per kernel; ratio of the last repeat with a `min_ratio` gate; no significance test; implementations measured sequentially | `bench.compareMany` (rotating interleaved N-way), Welch + Mann-Whitney gates, deterministic text/JSON |
| `spectra` | `bench/*.zig` (141 files) | ~15,000 lines | Per-file `main`; parse argv, warm up, one timed loop, print `elapsed_ns` and a checksum; no distribution or gate | `bench.runSuite`, `bench.run`/`runMeasured`, `bench.compareMany`, `baseline.report` |
| `pdfz` | `tools/benchmark*.py`, `build/benchmark_provenance.zig` | ~15,400 lines | Python policy/artifact pipeline plus Zig provenance: dependency-closure SHA-256, ReleaseFast requirement, feature profile, artifact verification | `bench` sampling/isolation, `provenance.hashTree`/`loadVerifiedFile`/`fingerprint`, `artifact.Manifest`, `baseline.Store` |
| `imx` | `examples/bench_*.zig` (91 files), `build_support/*.zig` (85 files) | ~25,000 + ~6,600 lines | Per-codec benchmark executables and build-time oracle scripts; ad-hoc timing and golden checks | `bench.runSuite`, `oracle`, `golden`, `evidence` |
| `iris` | `examples/bench*.zig` (9 files) | ~1,900 lines | Single timed render/recording run; prints elapsed nanoseconds; no warmup sampling or statistics | `bench.run`/`runMeasured`, `bench.compareMany`, `baseline` |

## What the internal style does

The common pattern is:

1. Warm up by calling the workload a few times.
2. Time one block of iterations (or one block per repeat).
3. Divide elapsed time by the iteration count.
4. Compare the resulting ratio against a fixed threshold.

That is fast to write, but it has three structural weaknesses:

- **No uncertainty estimate.** One block has no distribution, so a scheduler
  hiccup or a frequency transition silently changes the conclusion.
- **Ordering bias.** Measuring baseline first and candidate second couples the
  result to any machine drift during the run.
- **No outlier handling.** A single interrupted sample can dominate the mean
  and hide a real regression (or invent one).

## Measured comparison

The tool models the internal style as one warmup block plus one timed block,
with a 5% ratio gate. The harnessz style uses `bench.compareMany` with 15
samples, 3 warmup rounds, a batch of 20 calls per sample, and
`Comparison.gateRobust(1.05, 0.05)`. Both styles run the same deterministic
xorshift workload; per-call jitter is uniform in `[0, 20%]`. Trials are
independent and seeded deterministically.

Command:

```sh
zig build adoption-bench -- \
  --trials 100 --samples 15 --iterations 20 \
  --json docs/evidence/adoption-bench.json
```

Results from the recorded run (100 trials per scenario):

| Scenario | Internal style | harnessz | Interpretation |
| --- | --- | --- | --- |
| No change, 5% gate | 12% false regressions | 0% | Welch/rank significance removes noise-driven alarms |
| +10% work | 95% detected | 98% detected | Comparable sensitivity with no false alarms |
| +20% work | 100% detected | 100% detected | Both see large regressions |
| Drifting machine, 3-way ratio | 13.5% ratio error | 3.5% ratio error | Rotating interleaving cancels drift |

The same command was repeated several times on this host. Observed ranges:

- False regressions on unchanged code: internal 8-16%, harnessz 0-2%.
- Detection of a 10% regression: internal 97-100%, harnessz 97-99%.
- Detection of a 20% regression: both 100%.
- Ordering error under drift: internal 13.5-25.1%, harnessz 1.8-8.0%.

Per-call overhead measured with an empty callback was 9.7 ns for the internal
loop and 22 ns for harnessz sampling in the recorded run (the extra work is
one clock read per sample plus bookkeeping). Empty-callback timings are noisy
because they measure the clock itself; repeated runs ranged from 16-22 ns for
harnessz and 9.7-17.4 ns for the internal loop. The meaningful comparison is
the ~640 ns workload, where the medians were 640 ns and 652 ns, a difference
under 2%. Sampling cost therefore does not distort real
benchmarks; it buys the distribution and significance data the internal style
lacks.

### Robustness to outliers

The measured run exposed a real limitation of Welch's t-test on this host: a
single scheduler interrupt produced samples such as `1984` against a ~710 ns
baseline, inflating the variance enough to hide a true 10% shift. `harnessz`
now computes a tie-corrected Mann-Whitney U test alongside Welch and exposes
`robust_p_value`, `robust_significant`, and `gateRobust`. The unit suite pins
the behavior:

```zig
const comparison = harnessz.bench.Comparison.fromSamples(
    &.{ 110, 111, 109, 110, 1000 }, // candidate with one outlier
    &.{ 100, 101, 99, 100, 100 },
);
try std.testing.expect(!comparison.gateSignificant(1.05, 0.05)); // Welch
try std.testing.expect(comparison.gateRobust(1.05, 0.05));        // rank-sum
```

This is the kind of failure the internal ratio gate cannot even express: it
has no significance model to be robust or non-robust.

## Capability comparison

| Capability | Typical internal approach | harnessz |
| --- | --- | --- |
| Sampling | One timed block, or repeats whose last block is used | Warmup + N samples, optional batch size and minimum sampling time |
| Configuration policy | Ad-hoc release/sample checks | `bench.validatePolicy` with typed violations and diagnostics |
| Memory metrics | Per-file custom tracking allocators | `bench.runMeasured` and `runSuite(.measure_memory = true)` with peak bytes, peak RSS, allocation/free counts |
| Named suites | One executable per kernel | `bench.runSuite` over a registry, deterministic text/JSON |
| Distribution | Elapsed total or per-iteration average | min, max, mean, stddev, median, p90, p99, count |
| Significance | None; fixed ratio gate | Welch t-test with an exact Student-t tail and Mann-Whitney U, both with configurable gates |
| Ordering bias | Sequential implementations | Rotating interleaved A/B and N-way comparison |
| Regression tracking | Ad-hoc thresholds or shell scripts | JSON `baseline.Store`, environment fingerprints, deterministic text/JSON reports |
| Isolation | Same process; a hang stops the run | Child process per benchmark (`process_suite` + `listNames`), process-group timeout, bounded stderr, protocol-only stdout |
| Provenance | Python scripts or git commands per repo | SHA-256 of bytes/files/source trees, verified artifact loading, strict artifact manifests, and a stable environment fingerprint |
| Golden data | Per-repo comparison helpers | `golden.expectFile`/`expectDirectory` with update mode, normalization, bounds |
| Evidence | Markdown conventions checked by hand | `evidence.Manifest` with path and test-name validation |
| Output | Free-form text | Deterministic text, JSON, CSV, and Markdown history tables |

## Adoption recipe

1. Add `harnessz` as a path dependency and import it in the benchmark module.
2. Wrap each implementation in `bench.NamedRunner` (a `bench.Runner` is a
   context pointer plus `fn (*anyopaque, Allocator, std.Io) anyerror!u64`).
3. Replace per-file executables with `bench.runSuite` over a registry, or use
   `bench.run` for a single workload and `bench.compareMany` for matrices.
4. Gate with `gateRobust` (noisy hosts) or `gateSignificant` (clean hosts),
   and call `bench.validatePolicy` before measuring.
5. Record samples in `baseline.Store` and gate on `compare`/`baseline.report`.
6. Fill `Entry.environment_fingerprint` with `provenance.fingerprint`, using
   `provenance.hashTreeHex` for source hashes and `loadVerifiedFile` for
   artifacts or dependency closures.
7. Keep golden and evidence checks in the same package instead of per-repo
   helpers.

The recipe is exercised end-to-end by the package integration test
`integration: downstream adoption workflow` in `test/integration.zig`: it runs
a registry through `runSuite`, saves and reloads a baseline, compares with
fingerprint enforcement, renders a report, checks a golden file, validates an
evidence manifest, and hashes the workspace tree.

Dependency wiring:

```zig
// build.zig.zon
.dependencies = .{
    .harnessz = .{ .path = "../harnessz" },
},

// build.zig
const harnessz = b.dependency("harnessz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("harnessz", harnessz.module("harnessz"));
```

The wiring above is exercised by `examples/consumer/`, a standalone package
that depends on harnessz by path. `cd examples/consumer && zig build run`
prints a `consumer smoke ok` line after covering the bench, provenance,
artifact, golden, and baseline APIs.

## Migration map

| Repository | Keep | Replace |
| --- | --- | --- |
| `zev` | SIMD/scalar kernels and the Highway baseline | `BenchmarkResult`, `nsPerIter`, `printResultChecked`, and the `min_ratio` loop with `compareMany`, `gateRobust`, and `baseline.report` (including Markdown history); use `process_suite` to keep the one-process-per-kernel isolation of the current executable |
| `spectra` | Per-format benchmark kernels and checksums | Per-file `main` argv parsing/timing/output with a registry plus `runSuite` (or `process_suite` when each kernel must keep its own process); use `measure_memory = true` for allocation/RSS numbers instead of per-file tracking allocators |
| `iris` | Renderer/scene setup | The single `Clock.awake.now` block with `bench.runMeasured` or `compareMany` across renderer configurations |
| `imx` | Codec kernels and reference-library oracles | Ad-hoc byte comparisons with `oracle.compareBytes`/`compareJson`; golden writes with `golden.expectFile`/`expectDirectory`; benchmark mains with `runSuite` |
| `pdfz` | Corpus cases and performance thresholds | Closure file loading with `provenance.loadVerifiedFile`; artifact descriptors with `artifact.Manifest.fromTree`/`verify`; ReleaseFast/sample checks with `bench.validatePolicy`; threshold history with `baseline.Store`/`baseline.report` |

The kernels and corpus definitions stay in the downstream repository. The
shared package only owns sampling, statistics, gates, isolation, provenance,
and reporting, so migration does not move domain code out of its repository.

## Verification

Recorded on 2026-11-08:

- `zig build test`: 269/269 tests passed (Debug).
- `zig build test -Doptimize=ReleaseSafe`: passed.
- `zig build test -Doptimize=ReleaseFast`: passed.
- `zig build check-cross`: Windows x86_64-gnu, macOS aarch64, and Linux
  x86_64-gnu child executables compile.
- `cd examples/consumer && zig build run`: prints `consumer smoke ok`.
- `zig build adoption-bench -- --trials 100 --samples 15 --iterations 20
  --json docs/evidence/adoption-bench.json`: produced the results above.

The package integration suite also contains `integration: downstream adoption
workflow`, which composes the suite, baseline, provenance, golden, and evidence
APIs in one temporary workspace.

## Caveats

- The measured workload is synthetic. It isolates harness methodology (sampling,
  significance, ordering), not the performance of any downstream codec or
  renderer.
- Absolute timings depend on the host, load, and frequency governor. Only the
  structural comparisons are meaningful; the JSON artifact records one run.
- The downstream line counts include benchmark kernels, so they overstate the
  amount of pure harness code. The repeated per-file `main`/timing boilerplate
  is the part that disappears first.
- `harnessz` process isolation is not a sandbox: the child shares the user,
  environment, filesystem, and network. It isolates address space, threads,
  allocator state, and process-group lifetime.
- Per the workspace boundary, no sibling repository was modified. Adoption is
  demonstrated through the measured comparison and the migration recipe, not by
  editing downstream build files.

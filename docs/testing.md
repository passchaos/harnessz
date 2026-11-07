# Testing

The package has no external dependencies and no command-line test runner. Tests
are Zig test declarations beside the implementation, plus a package-level
integration suite.

## Gates

Run the smallest relevant test first, then the full gate:

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build check-cross        # compile child for Windows/macOS/Linux targets
```

`zig build check` combines formatting, tests, and the cross-compile gate:

```sh
zig build check
zig build fmt-check          # check formatting only
zig build fmt                # rewrite source formatting in place
```

After public API or packaging changes, run the external consumer:

```sh
cd examples/consumer && zig build run
```

It must build and run using only the path dependency and the public `harnessz`
module.

Threaded tests must be repeated (at least 10 iterations) to check determinism.
Never assert absolute timings, speedups, or scheduler behaviour in unit tests;
they are flaky. Test structure instead: iteration counts, sample lengths,
callback call counts, checksums, error kinds, and deterministic report text.

## Test layout

| File | Covers |
| --- | --- |
| `src/*.zig`, `src/*/*.zig` | Unit tests beside the implementation |
| `src/bench_test.zig` | Benchmark sampling, gates, batching, memory measurement |
| `src/bench/multi_test.zig` | Rotating N-way comparison and reports |
| `src/bench/suite_test.zig` | Registry suites, bounds, memory metrics |
| `src/baseline/report_test.zig` | Text/JSON/Markdown reports and error cases |
| `test/core.zig` | Golden, oracle, stats, determinism, baseline, evidence, fixtures |
| `test/process.zig` | Process-isolated benchmarks, stderr capture, timeout cleanup, suites |
| `test/workflow.zig` | Downstream adoption workflow across suite, baseline, provenance, golden, evidence |
| `test/support.zig` | Shared helpers for the process integration tests |

`test/integration.zig` only wires the integration groups into the test binary;
add new group files there rather than growing one large file.

## What each area must cover

- **Golden:** first-run creation, matching, mismatch diagnostics, update
  rewriting, every normalization option, and original-byte persistence in
  update mode. Directory goldens cover create/update/match,
  missing/extra/changed detection, pruning, ordering, and bounds.
- **Oracle:** exact matches, first-mismatch offsets, NaN/infinity, signed zero,
  absolute/relative tolerance boundaries, ULP distances, complex
  real/imaginary mismatches, and structural JSON differences.
- **Determinism:** stable output, an unstable producer whose first divergence
  is reported, and threaded runs with stable and index-dependent producers.
  Every thread is joined.
- **Streaming stats:** Welford mean/variance, histogram bucket boundaries,
  normal and Student-t confidence-interval margins, and trimmed means.
- **Welch:** a known statistic/degrees-of-freedom pair with its exact Student-t
  p-value, reference critical values, symmetry, identical distributions, zero
  variance, the two-sample minimum, and invalid/NaN/infinite inputs.
- **Mann-Whitney:** complete separation, symmetry, identical distributions,
  ties, the two-sample minimum, and an outlier case where Welch is not
  significant but the rank test is.
- **Bench environment:** skip cleanly when Linux probes return
  `error.Unsupported`; CPU-pinning tests restore the original affinity mask;
  RSS tests assert positivity only.
- **Counting allocator:** exact requested byte counts, peak retention after
  free, and failed-allocation behaviour.
- **Process isolation:** protocol round-trips, registry ordering and bounds,
  child argument parsing, typed parent errors, bounded stderr, process-tree
  cleanup after a timeout, isolated suites that continue after failures, and
  name discovery.
- **Baselines:** JSON round-trip, save/load, update replacement, missing-name
  errors, fingerprints (including opt-in enforcement), and synthetic regression
  comparisons.
- **Baseline reports:** mixed regressions/improvements/missing/extra rows,
  deterministic text, JSON, and Markdown snapshots, the empty store, invalid
  ratios, and duplicate current names.
- **Provenance:** known SHA-256 vectors, file/byte hash agreement,
  deterministic and content-sensitive tree hashes, skipped cache directories,
  traversal bounds, symlink policy, verified-file loading, and fingerprint
  stability plus caller fields.
- **Artifacts:** strict JSON validation, verification of matching, mismatched,
  missing, and extra files, save/load, the empty manifest, and
  `Manifest.fromTree` plus a post-generation mismatch.
- **Policy:** a valid configuration, build-mode mismatch and empty-mode opt-out,
  each sample-count bound, inconsistent bounds, the deterministic first
  violation, and descriptions for every violation.
- **Evidence:** JSON round-trip, missing-path validation, known test names, and
  unknown test-name reporting with entry id and name.

## Platform skips

Linux-only probes and process-group checks return `error.SkipZigTest` when the
platform or kernel facility is unavailable. Do not turn an unsupported feature
into a failure; tests must skip cleanly. The cross-compile gate catches
compile-time platform regressions even when runtime coverage is Linux-first.

## Process tests

The integration suite spawns the `harnessz-bench-child` executable installed by
`build.zig`. The emitted path reaches the test through the `bench_child` build
options module. Keep child stdout protocol-only; diagnostics go to stderr.

Timeout and process-tree tests use `/proc` and POSIX process groups. They skip
on non-Linux platforms and when process control is unavailable. A successful
run does not kill lingering descendants; cleanup is a timeout/failure
behaviour.

## Adoption tool

`zig build adoption-bench` is deliberately outside `zig build test` because it
reports host-dependent wall-clock numbers. It writes an optional JSON artifact:

```sh
zig build adoption-bench -- --trials 100 --samples 15 --iterations 20 \
  --json docs/evidence/adoption-bench.json
```

Results and methodology are recorded in
[evidence/adoption-comparison.md](evidence/adoption-comparison.md).

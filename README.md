# harnessz

Shared test, benchmark, and oracle infrastructure for Project-Z.

`harnessz` replaces per-repository `build_support/*` golden/bench gates and
`docs/*evidence*` conventions in `imx`, `iris`, `pdfz`, `zev`, and `spectra`
with one std-only Zig 0.16 package. It owns benchmark baseline storage and
regression detection as well as golden, oracle, determinism, provenance, and
evidence helpers.

## Design principles

- **One package, no dependencies.** Every module uses only `std` and an
  explicit `io: std.Io`.
- **Deterministic output.** Reports, JSON, CSV, and Markdown are stable across
  runs and follow registration or name order.
- **Opt-in strictness.** Update mode, normalization, fingerprint enforcement,
  and extra-artifact rejection are explicit options.
- **Structure over wall-clock assertions.** Tests assert counts, sample
  lengths, checksums, and error kinds, never absolute timings.
- **Process isolation is not sandboxing.** Isolated benchmarks get separate
  address space, threads, allocator state, and process-group lifetime; they
  still share the user, environment, filesystem, and network.

## Requirements

- Zig `0.16.0` or newer.
- No external dependencies.
- Package name `.harnessz`, version `0.0.1`.

## Install

```zig
// build.zig.zon
.dependencies = .{
    .harnessz = .{ .path = "../harnessz" },
},
```

```zig
// build.zig
const harnessz = b.dependency("harnessz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("harnessz", harnessz.module("harnessz"));
```

A standalone consumer lives in [`examples/consumer/`](examples/consumer); it
imports only the public `harnessz` module.

## Quick start

```zig
const std = @import("std");
const harnessz = @import("harnessz");

fn work(context: *Ctx, alloc: std.mem.Allocator, io: std.Io) anyerror!u64 {
    _ = alloc;
    _ = io;
    return context.doWork();
}

pub fn main(init: std.process.Init) !void {
    var context: Ctx = .{};

    var stats = try harnessz.bench.run(init.gpa, init.io, .{
        .warmup_iterations = 3,
        .iterations = 20,
    }, &context, work);
    defer stats.deinit(init.gpa);

    const baseline = [_]u64{ 100, 101, 99, 100, 102, 100 };
    const comparison = harnessz.bench.Comparison.fromSamples(
        &baseline,
        stats.samples_ns,
    );
    if (!comparison.gateRobust(1.05, 0.05)) return error.PerformanceRegression;
}
```

## Modules

| Module | Purpose | Guide |
| --- | --- | --- |
| `golden` | Golden files and directory trees with create/match/mismatch/update, text/binary modes, optional line-ending, trailing-whitespace, and canonical-JSON normalization | [Golden files](docs/golden.md) |
| `snapshot` | Named in-memory or file-backed snapshots with `check`, `checkFmt`, and update mode | [Golden files](docs/golden.md#snapshots) |
| `oracle` | Byte/integer/float/complex comparisons, structural JSON comparison, tolerances, ULP distance, NaN/inf/signed-zero handling, Wyhash checksums | [Oracles](docs/oracles.md) |
| `determinism` | Repeated-run byte stability, first divergence, thread-count matrix, real threaded runs with spawn fallback | [Determinism](docs/determinism.md) |
| `stats` | Batch summaries, streaming Welford accumulation, histograms, confidence intervals, trimmed means, Welch's t-test with an exact Student-t tail, tie-corrected Mann-Whitney U | [Statistics](docs/statistics.md) |
| `bench` | Warmup/timed runs, min-time sampling, interleaved A/B and N-way comparison, significance and robust gates, CPU pinning, peak RSS, counting allocator, JSON/CSV, suites, policy checks, process isolation | [Benchmarks](docs/benchmarks.md) |
| `baseline` | JSON baseline storage, environment fingerprints, optional enforcement, regression detection, deterministic text/JSON/Markdown reports | [Baselines](docs/baselines.md) |
| `fixture` | `HARNESSZ_FIXTURES` / `testdata/` resolution and workspace helpers | [Fixtures](docs/fixtures.md) |
| `evidence` | Evidence manifests with JSON round-trip, missing-path validation, and test-name validation | [Evidence](docs/evidence.md) |
| `provenance` | SHA-256 of bytes, files, verified snapshots, and source trees plus a stable environment fingerprint | [Provenance](docs/provenance.md) |
| `artifact` | Strict JSON artifact manifests with SHA-256 verification and missing/mismatch/extra reporting | [Artifacts](docs/artifacts.md) |
| `json_canon` | Canonical JSON emission with recursively sorted object keys | [Oracles](docs/oracles.md#structural-json) |
| `diff` | Line-oriented unified diff used by golden/snapshot diagnostics | [Golden files](docs/golden.md) |
| `paths` | Shared relative-path validation and existence checks | [Architecture](docs/architecture.md) |

Every public module is exported from `src/root.zig`. Public names are
re-exported from parent modules; callers never import a submodule directly.

## Validation

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build check-cross        # compile child for Windows/macOS/Linux targets
zig build check              # formatting + tests + cross-compile
zig build fmt-check          # formatting only
```

After public API or packaging changes, run the external consumer:

```sh
cd examples/consumer && zig build run
```

The adoption comparison tool is host-dependent and deliberately outside
`zig build test`:

```sh
zig build adoption-bench -- --trials 100 --samples 15 --iterations 20
```

See [Testing](docs/testing.md) for the full gate and test taxonomy.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture](docs/architecture.md) — module layers, ownership, file layout
- [Testing](docs/testing.md) — gates and per-module coverage
- [Environment](docs/environment.md) — Zig 0.16 `std.Io`, environment variables
- [Migration](docs/migration.md) — replacing downstream harness code
- [Adoption evidence](docs/evidence/adoption-comparison.md) — measured
  comparison against downstream ad-hoc harnesses

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
- Benchmark callbacks must return `u64`; tests must not assert wall-clock
  behaviour.
- `baseline` fingerprint enforcement is opt-in via `require_fingerprint`.
- `stats.welchTTest` uses the exact Student-t tail; the Mann-Whitney U p-value
  uses a tie-corrected normal approximation. Heavy-tailed data remains a reason
  to prefer the rank-sum gate.
- `bench.pinToCpu`, `bench.currentCpu`, `bench.affinityMask`, and
  `bench.peakRssBytes` are Linux-only and return `error.Unsupported` elsewhere.
  Pinning affects the calling thread, not every thread in the process.
  `CountingAllocator` is single-threaded and counts requested bytes, not
  allocator overhead.
- Process isolation is not OS-level sandboxing. Timeout cleanup is POSIX-only;
  on Windows only the direct child is terminated, and descendants that call
  `setsid` escape the group.
- The process runner retains at most `max_stderr_bytes` (default 64 KiB) but
  always drains the pipe, so oversized stderr is truncated rather than
  deadlocking. A successful run does not kill lingering descendants.
- Golden directory update mode prunes extra files under the managed root.
  Compare mode never mutates the tree.
- `std.fs` file APIs are not used; `std.fs.path` remains in use for pure path
  manipulation. Directory creation uses `std.Io.Dir.createDirPath`.

## License

BSD 2-Clause License, Copyright (c) 2026 Greedwolf DSS. See `LICENSE`.

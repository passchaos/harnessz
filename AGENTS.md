# AGENTS.md — harnessz

## Mission

`harnessz` is the shared test, benchmark, and oracle infrastructure for
Project-Z. It replaces per-repository golden/bench gates and evidence
conventions in imx, iris, pdfz, zev, and spectra with one std-only Zig 0.16
package. It also owns benchmark baseline storage and regression detection.

## Boundaries

- This repository owns only `/home/passchaos/project-z/harnessz`.
- Do not modify sibling repositories from this workspace.
- Public API lives in `src/root.zig`; modules are re-exported from there.
- Keep modules focused. Split by stable responsibility before a file grows past
  roughly 500 lines. Submodules live under `src/stats/`, `src/oracle/`,
  `src/golden/`, `src/bench/`, and `src/determinism/` and are re-exported from
  their parent module. Large test suites may live in a sibling `*_test.zig`
  file imported from a small `test` block in the implementation file.
- Tests live beside implementation. Package-level integration tests live in
  `test/`. When tests live in a re-exported submodule, add a small
  `refAllDecls` test in the parent so the package test run includes them.
- Use `std.Io.Dir` / `std.Io.File` with an explicit `io: std.Io`; do not add
  `std.fs` file APIs. `std.fs.path` is acceptable for pure path manipulation.

## Validation rules

- Run the smallest relevant test first, then the full gate:
  - `zig build test`
  - `zig build test -Doptimize=ReleaseSafe`
  - `zig build test -Doptimize=ReleaseFast`
- Run threaded tests repeatedly (at least 10 iterations) to check
  determinism.
- Never assert absolute timings, speedups, or scheduler behaviour in unit
  tests. They are flaky.
- Test `bench` structurally (iteration counts, sample lengths, callback call
  counts) and test gate logic with `bench.Comparison.fromSamples` and synthetic
  samples.
- Golden tests must cover first-run creation, matching, mismatch diagnostics,
  update rewriting, and each normalization option. Update mode must persist the
  original bytes, not the normalized form.
- Oracle tests must cover exact matches, first-mismatch offsets, NaN/infinity,
  signed zero, absolute/relative tolerance boundaries, ULP distances, and
  complex real/imaginary mismatches.
- Determinism tests must cover stable output and an unstable producer whose
  first divergence is reported. Threaded tests must use a producer that is
  stable regardless of thread index and one that depends on the index; run
  them repeatedly and ensure every thread is joined.
- Baseline tests must cover JSON round-trip, save/load, update replacement,
  missing-name errors, environment fingerprints, and synthetic regression
  comparisons.
- Streaming stats tests must cover Welford mean/variance, histogram bucket
  boundaries, confidence-interval margins, and trimmed means.
- Welch tests must cover a known statistic/degrees-of-freedom pair, symmetry,
  identical distributions, zero variance, and the two-sample minimum.
- Bench environment tests must skip cleanly when Linux probes return
  `error.Unsupported`; CPU-pinning tests must restore the original affinity
  mask. RSS tests assert positivity only, never a specific value.
- Counting-allocator tests must check exact requested byte counts, peak
  retention after free, and failed-allocation behaviour.
- Process-isolation tests must cover:
  - Protocol JSON round-trips for requests, successful responses, and error
    responses, plus invalid JSON and owned-value cleanup.
  - Registry insertion order, bounded `names`, duplicate/empty-name rejection,
    and allocation-free lookup.
  - Child argument parsing (`--harnessz-list`, `--harnessz-bench=<name>`,
    unknown/empty flags), stdout staying protocol-only, and benchmark callback
    failures surfacing through `error_name`/`error_message`.
  - Parent typed errors for spawn failure, non-zero child exit, oversized
    output, invalid JSON, and benchmark failure.
  - An integration test that spawns the built child through
    `bench.process.runProcess`, verifies sample counts and the deterministic
    checksum, verifies benchmark-error propagation, and verifies timeout
    termination. Skip the timeout case cleanly when process control is
    unavailable.
  - Bounded stderr capture: a child that writes diagnostics and succeeds, a
    child that writes diagnostics and fails (stderr visible through
    `runProcessCapture`), and a child that writes more than
    `max_stderr_bytes` (truncated without deadlock).
  - Process-tree cleanup: a child benchmark that spawns a sleeping grandchild
    must leave no `/proc/<pid>` entry for the grandchild or the direct child
    after a timeout (Linux-only test, skip elsewhere). Verify the child is its
    own process-group leader.
  - Never assert absolute timings, only structure, counts, checksums, and
    error kinds.
- Baseline tests must cover opt-in fingerprint matching, mismatch, missing
  expected fingerprints, and the unchanged default.
- Baseline report tests must cover mixed regressions/improvements/missing/
  extra rows, deterministic text and JSON snapshots, the empty store, invalid
  regression ratios, and duplicate current names.
- Evidence tests must cover JSON round-trip, missing-path validation, known
  test names, and unknown test-name reporting with entry id and name.
- Golden directory tests must cover create/update/match, missing/extra/changed
  detection, update-mode pruning, deterministic report ordering, and bounds.
- JSON oracle tests must cover reordered keys, array order, numeric tolerance,
  type mismatches, missing/extra keys, length mismatches, and nested
  first-difference paths.
- No failing tests are acceptable. Do not claim unimplemented features.

## API and environment conventions

- Update mode: `Options.update` or `HARNESSZ_UPDATE=1`/`true`.
- Fixture root: `Options.fixtures_root`, then `HARNESSZ_FIXTURES`, then
  `testdata/`.
- Tests receive the runner environment automatically through
  `std.testing.environ`. Applications should pass
  `std.process.Init.minimal.environ` via `Options.environ`.
- `bench` callbacks return `u64` and are kept observable with
  `bench.blackBox`, which wraps `std.mem.doNotOptimizeAway`.
- `bench.Comparison.fromSamples` always computes a Welch p-value; fewer than
  two samples per side yields `p_value = 1` and `significant = false` instead
  of an error. `gateSignificant` combines the ratio gate, the 0.05
  significance flag, and the caller's `max_p_value`.
- `bench.runMeasured` passes a `CountingAllocator` to the callback and reports
  peak RSS (nullable on unsupported platforms) plus peak allocated bytes.
  `bench.runMeasuredRuntime` is the type-erased counterpart used by the
  process-isolated child.
- `bench.Options.batch_size` (default 1) invokes the callback that many times
  per timed sample and stores the per-call average; `Stats.batch_size` records
  it. `protocol.Request.batch_size` defaults to 1 when omitted by older
  parents.
- `bench.pinToCpu`, `bench.currentCpu`, `bench.affinityMask`, and
  `bench.peakRssBytes` are Linux-only. Tests must skip on
  `error.Unsupported`, and pinning tests must restore the original mask.
  Pinning and affinity queries affect the calling thread, not every thread in
  the process.
- `determinism.run` callbacks receive a thread count and own any actual
  threading. `determinism.runThreaded` spawns OS threads itself with worker
  signature `fn (context, thread_index: usize, *std.Io.Writer) anyerror!void`;
  it joins every thread, reports `spawn_fallbacks`, and owns
  `thread_checksums` until `deinit()`.
- Golden normalization is opt-in via `NormalizeOptions`; `json_canonical`
  returns `error.InvalidJson` for invalid input.
- `golden.expectDirectory` update mode prunes extra files; compare mode never
  mutates the tree and reports missing/extra/changed files. Traversal is
  sorted and bounded by `max_files`, `max_total_bytes`, and `max_file_bytes`.
- `oracle.compareJson` ignores object key order, preserves array order, and
  reports the first difference path. Invalid JSON returns `error.InvalidJson`;
  `Report.deinit` releases the path.
- `baseline.Store` owns an arena; call `deinit()`. `compare` requires an
  existing entry, and `update` replaces an entry by name and returns
  `error.MissingBaseline` for unknown names. Fingerprint enforcement is
  opt-in via `Options.require_fingerprint` and `Options.expected_fingerprint`.
  The store lives in `src/baseline/store.zig` and is re-exported from
  `src/baseline.zig`.
- `baseline.report.report(alloc, writer, store, current, options)` writes a
  deterministic text table (rows sorted by name) and returns a `Report` with
  `regressions`, `improvements`, `missing`, `extra`, `ok()`, `toText`/`toJson`
  and `writeText`/`writeJson`. `Report.deinit()` releases the rows. A row is
  `regressed` above `baseline * max_regression_ratio` and `improved` below
  `baseline / max_regression_ratio`; p-values require at least two raw samples
  on both sides.
- `evidence.Manifest.fromJson` owns its arena; call `deinit()`.
  `validateTests` returns a `TestValidationReport` whose slices reference the
  manifest and whose list is released by `deinit()`.
- Directory creation uses `std.Io.Dir.createDirPath` (the Zig 0.16 recursive
  make-path API).
- Process isolation lives in `src/bench/protocol.zig`,
  `src/bench/registry.zig`, `src/bench/child.zig`, and
  `src/bench/process.zig`. `bench.childMain(alloc, io, registry)` is the
  argv-free protocol core. Zig 0.16 supplies argv through
  `std.process.Init`, so executables call `bench.child.mainInit(init, &registry)`
  or `childMainArgs` for `--harnessz-list` and `--harnessz-bench=<name>`.
- Child stdout is protocol-only (one JSON `Response`, or one JSON name array in
  list mode); diagnostics must go to stderr.
- `protocol.Response.checksum` is an optional additive extension carrying the
  callback's last returned `u64`. `peak_rss_bytes` and
  `peak_allocated_bytes` are optional additive child metrics. Required fields
  remain `samples_ns`, `error_name`, and `error_message`.
- `bench.process.runProcess` maps a valid response with `error_name` to
  `error.BenchmarkFailed` and forwards captured stderr to the parent's stderr.
  `runProcessResponse` returns the response so callers can inspect the child's
  error name/message. `runProcessCapture` returns a `ProcessResult` with
  `response`, `stderr`, `stderr_truncated`, `timed_out`, and `exit_code`; call
  `deinit(alloc)`, and use `takeResponse()` to transfer the response.
  Capture-thread allocations are serialized with the main task, so `alloc`
  does not need to be thread-safe.
- Timeout zero disables the watchdog; otherwise a dedicated `std.Thread`
  watchdog starts after the request is written. It terminates the child's
  whole POSIX process group (`kill(-pid, SIGKILL)`) and the parent reaps the
  direct child. When a thread cannot be started the watchdog falls back to
  `Io.concurrent`; `error.TimeoutUnavailable` means neither mechanism exists.
- Child stderr is a pipe drained concurrently with stdout. At most
  `Options.max_stderr_bytes` (default 64 KiB) is retained; the rest is
  discarded so the child cannot deadlock, and `stderr_truncated` reports the
  loss. Child stdout remains protocol-only.
- Child executables call `bench.child.mainInit`, which runs
  `child.prepareProcess()`: POSIX `setpgid(0, 0)` plus Linux
  `PR_SET_PDEATHSIG=SIGKILL`. The parent also sets `SpawnOptions.pgid = 0`, so
  the group exists before the watchdog can fire. `child.processId()` and
  `child.processGroupId()` are diagnostic helpers (they return `-1` when the
  platform lacks the syscall).
- Process isolation is not OS-level sandboxing. The child shares the parent's
  user, environment, filesystem, and network; only address space, threads, and
  allocator state are isolated. Process-group cleanup is POSIX-only: on
  Windows only the direct child is terminated, and descendants that call
  `setsid` escape the group. A successful run does not kill lingering
  descendants.

## Baseline workflow

1. Capture samples with `bench.run`; keep `samples_ns` and `distribution`.
2. Build the initial JSON store (construct `baseline.Store` or use
   `Store.fromJson`) and call `save(io, dir, "bench/baseline.json")`.
3. Commit the baseline file with the benchmark.
4. On later runs, `Store.load`, then `compare(name, current_samples, .{
   .max_regression_ratio = 1.05 })` and fail when `regressed` is true.
5. Record `environmentFingerprint` in entries so different machines or build
   modes are visible. Pass `require_fingerprint = true` plus
   `expected_fingerprint` when a mismatch must fail with
   `error.EnvironmentMismatch`; enforcement is off by default.
6. Refresh intentional changes with `update(entry)` followed by `save`.
   `update` only replaces an existing name; unknown names return
   `error.MissingBaseline`.
7. For multi-entry reports, call `baseline.report.report(...)` with the loaded
   store and the current entries. It writes the deterministic text table and
   returns counts (`regressions`, `improvements`, `missing`, `extra`) plus a
   JSON writer; fail the gate when `report.ok()` is false or
   `report.regressions != 0`.

## Build metadata

- Package name: `.harnessz`
- Version: `0.0.1`
- Minimum Zig: `0.16.0`
- No external dependencies.
- Integration-test child executable: `bench/child_main.zig`, installed as
  `harnessz-bench-child`. `build.zig` passes its emitted path to
  `test/integration.zig` through the `bench_child` options module.

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
  - `zig build check-cross` after platform-conditional or packaging changes
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
  boundaries, normal and Student-t confidence-interval margins, and trimmed
  means.
- Welch tests must cover a known statistic/degrees-of-freedom pair with its
  exact Student-t p-value, reference critical values, symmetry, identical
  distributions, zero variance, the two-sample minimum, and invalid degrees of
  freedom/NaN/infinite inputs.
- Mann-Whitney tests must cover complete separation, symmetry, identical
  distributions, ties, the two-sample minimum, and an outlier case where Welch
  is not significant but the rank test is.
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
  - Process-isolated suites must aggregate multiple names, record per-entry
    benchmark failures without stopping, continue after a timeout, and render
    deterministic text/JSON plus `toEntries` for successful samples.
  - Name discovery must match `--harnessz-list`, preserve registration order,
    and feed the isolated suite runner.
  - Never assert absolute timings, only structure, counts, checksums, and
    error kinds.
- Baseline tests must cover opt-in fingerprint matching, mismatch, missing
  expected fingerprints, and the unchanged default.
- Baseline report tests must cover mixed regressions/improvements/missing/
  extra rows, deterministic text, JSON, and Markdown snapshots, the empty
  store, invalid regression ratios, and duplicate current names.
- Evidence tests must cover JSON round-trip, missing-path validation, known
  test names, and unknown test-name reporting with entry id and name.
- Provenance tests must cover known SHA-256 vectors, file/byte hash agreement,
  deterministic and content-sensitive tree hashes, skipped cache directories,
  traversal bounds, symlink policy, verified-file loading (relative/empty/
  oversized/symlink/changed-during-read cases), and fingerprint stability plus
  caller fields.
- Multi-comparison tests must cover rotating call order, per-runner sample
  counts, synthetic summaries and pairwise p-values, flipped pair lookups,
  gate errors, duplicate/empty names, deterministic text/JSON, and
  `toEntries` borrowing.
- Suite tests must cover registry order, per-benchmark sample counts, callback
  call counts and last results, `max_benchmarks` bounds, the empty registry,
  invalid options, partial-result cleanup on callback failure, deterministic
  text/JSON, `toEntries` borrowing, and `measure_memory` (peak bytes, positive
  allocation/free counts, nullable RSS, and the no-memory JSON null).
- The package integration suite must include a downstream adoption workflow
  test composing suite -> baseline save/load/compare/report -> provenance
  fingerprint and tree hash -> golden -> evidence validation in one temporary
  workspace.
- Artifact tests must cover strict JSON round-trip (unknown/duplicate/missing
  fields, invalid paths/digests, duplicate paths), verification of matching,
  mismatched, missing, and extra files, save/load, the empty manifest, and
  `Manifest.fromTree` generation plus a post-generation mismatch.
- Policy tests must cover a valid configuration, build-mode mismatch and the
  empty-mode opt-out, each sample-count bound, inconsistent policy bounds, the
  deterministic first violation, and descriptions for every violation.
- After public API or packaging changes, run the external consumer example
  (`cd examples/consumer && zig build run`). It must build and run using only
  the path dependency and the public `harnessz` module.
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
- `stats.confidenceIntervalMean` takes a caller-supplied critical value;
  `stats.confidenceIntervalMeanT(values, confidence)` uses the exact Student-t
  critical value with `n - 1` degrees of freedom and requires at least two
  values. `stats.studentTCritical(df, confidence)` is public.
- `bench` callbacks return `u64` and are kept observable with
  `bench.blackBox`, which wraps `std.mem.doNotOptimizeAway`.
- `bench.Comparison.fromSamples` always computes a Welch p-value (exact
  Student-t tail) and a tie-corrected Mann-Whitney U p-value (normal
  approximation); fewer than two samples per side yields
  `p_value = robust_p_value = 1` and both significance flags false instead of
  an error. `gateSignificant` combines the ratio gate, Welch significance, and
  the caller's `max_p_value`; `gateRobust` is the outlier-tolerant counterpart
  using the rank-sum p-value.
- `bench.runMeasured` passes a `CountingAllocator` to the callback and reports
  peak RSS (nullable on unsupported platforms), peak allocated bytes, and
  allocation/free counts from the measured phase. Warmup resets peaks and
  counts. `bench.runMeasuredRuntime` is the type-erased counterpart used by
  the process-isolated child.
- `bench.Options.batch_size` (default 1) invokes the callback that many times
  per timed sample and stores the per-call average; `Stats.batch_size` records
  it. `protocol.Request.batch_size` defaults to 1 when omitted by older
  parents.
- `bench.compareMany` interleaves N named `bench.Runner` values and rotates the
  starting point each round. `MultiComparison` owns names/samples in an arena;
  call `deinit()`. `pairs` are stored `i < j`; `comparisonOf(a, b)` returns the
  pair with `a` as numerator (flipping when needed); `gatePair` and
  `gateRobustPair` return `error.UnknownName`/`error.InvalidPair`. Text and
  JSON reports are
  deterministic in registration order. `MultiComparison.fromSamples` supports
  synthetic tests, and `toEntries` borrows the owned names/samples as
  `baseline.Entry` values.
- `bench.runSuite(alloc, io, registry, options)` runs a
  `bench.registry.Registry` in registration order (bounded by
  `max_benchmarks`) and returns a `SuiteResult` that owns names and `Stats`
  until `deinit()`. A callback error aborts the suite and releases partial
  results; an empty registry yields an empty result. `find(name)` returns a
  benchmark's stats, and `toEntries` borrows names/samples for baseline
  reporting. With `measure_memory = true`, `SuiteResult.memory` records
  `peak_rss_bytes` (nullable), `peak_allocated_bytes`, `allocation_count`, and
  `free_count` per benchmark; text/JSON include the same fields and JSON emits
  `memory: null` when not measured.
- `bench.validatePolicy(build_mode, options, policy)` rejects a build-mode
  mismatch and out-of-bounds warmup/iterations/batch size with typed errors;
  `bench.policy.check` returns the first `PolicyViolation` and
  `bench.policy.describe` renders it. Empty `required_build_mode` disables the
  build check; inconsistent bounds return `error.InvalidPolicy`.
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
  and `writeText`/`writeJson`, plus `toMarkdown`/`writeMarkdown` for committed
  history documents. `Report.deinit()` releases the rows. A row is
  `regressed` above `baseline * max_regression_ratio` and `improved` below
  `baseline / max_regression_ratio`; p-values require at least two raw samples
  on both sides.
- `provenance.hashTree`/`hashTreeHex` accept an ordinary `std.Io.Dir` (they
  open their own iterable handle), sort paths, skip VCS/cache/output
  directories by default, and return `error.ProvenanceTooLarge` past
  `max_files`/`max_total_bytes`. Symlinked files are hashed only with
  `follow_symlinks = true`; symlinked directories are never traversed.
  `provenance.loadVerifiedFile` reads an absolute path as a stable,
  non-symlinked regular file, rejects empty/oversized/changed-during-read
  inputs, and returns owned bytes plus a SHA-256 digest; call `deinit()`.
  `provenance.fingerprint` is the richer alternative to
  `baseline.environmentFingerprint`; its format is opaque (equality only) and
  Linux CPU probes degrade to `unknown`.
- `artifact.Manifest.fromJson` is strict JSON (unknown/duplicate/missing
  fields, invalid paths or digests, and duplicate paths are rejected). It owns
  its arena; call `deinit()`. `Manifest.init` borrows caller-owned entries;
  `Manifest.fromTree` hashes a tree with the provenance traversal rules and
  owns the resulting entries. `verify` returns a `VerifyReport` that owns its
  strings via an arena; call
  `deinit()`, and use `ok()` plus `missing`/`mismatched`/`extra`/`present`.
- `evidence.Manifest.fromJson` owns its arena; call `deinit()`.
  `validateTests` returns a `TestValidationReport` whose slices reference the
  manifest and whose list is released by `deinit()`.
- Directory creation uses `std.Io.Dir.createDirPath` (the Zig 0.16 recursive
  make-path API).
- Process isolation lives in `src/bench/protocol.zig`,
  `src/bench/registry.zig`, `src/bench/child.zig`, `src/bench/process.zig`, and
  `src/bench/process_suite.zig`. `bench.childMain(alloc, io, registry)` is the
  argv-free protocol core. Zig 0.16 supplies argv through
  `std.process.Init`, so executables call `bench.child.mainInit(init, &registry)`
  or `childMainArgs` for `--harnessz-list` and `--harnessz-bench=<name>`.
- `bench.process_suite.run(alloc, io, options)` spawns the child once per name,
  records benchmark failures/timeouts/parent errors on each `Entry`, and
  continues with the remaining names. The `Suite` owns entries in an arena;
  call `deinit()`. `ok()` requires every entry to pass; `toEntries` borrows the
  successful samples for baseline reporting. `bench.process.listNames` discovers
  the child's registered names through `--harnessz-list`; the caller frees each
  name and the outer slice.
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

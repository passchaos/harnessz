# Architecture

`harnessz` is a std-only Zig 0.16 package. It owns the shared test, benchmark,
and oracle infrastructure for Project-Z so downstream repositories do not
reimplement golden checks, timing loops, baseline storage, or evidence
validation.

## Layers

The modules form a dependency layering rather than a strict stack. Higher
layers may use lower layers; lower layers never import higher ones.

| Layer | Modules | Responsibility |
| --- | --- | --- |
| Foundation | `paths`, `env`, `num`, `json_canon`, `diff` | Path validation, environment lookup, numeric policies, canonical JSON, unified diffs |
| Assertions | `golden`, `snapshot`, `oracle` | Compare actual output with expected bytes, structures, or trees |
| Measurement | `stats`, `determinism`, `bench` | Summaries, significance tests, repeated/threaded runs, sampling, gates, suites |
| Evidence | `baseline`, `provenance`, `artifact`, `evidence`, `fixture` | Regression storage/reporting, hashing, artifact verification, evidence manifests, fixture resolution |

`bench` is itself a facade over focused submodules:

| Submodule | Responsibility |
| --- | --- |
| `bench/run.zig` | Warmup, timed sampling, batch sizes, min-time sampling, memory measurement |
| `bench/comparison.zig` | `Comparison`, Welch/rank p-values, gate logic |
| `bench/measure.zig` | Internal clock helpers shared by run and multi |
| `bench/multi.zig` | Rotating N-way comparison |
| `bench/suite.zig` | In-process registry suites |
| `bench/policy.zig` | Build-mode and sample-count policy checks |
| `bench/system.zig` | CPU affinity, peak RSS, counting allocator |
| `bench/protocol.zig` | JSON request/response wire types |
| `bench/registry.zig` | Ordered benchmark registry |
| `bench/child.zig` | Child entrypoint and process preparation |
| `bench/process.zig` | Parent spawn/capture/watchdog runner |
| `bench/stderr_capture.zig` | Bounded concurrent stderr capture |
| `bench/watchdog.zig` | Timeout and process-group termination |
| `bench/process_suite.zig` | One child per benchmark, failures recorded per entry |

`provenance` follows the same pattern:

| Submodule | Responsibility |
| --- | --- |
| `provenance/hash.zig` | SHA-256 of bytes, files, and verified snapshots |
| `provenance/tree.zig` | Deterministic bounded tree traversal and hashing |
| `provenance/fingerprint.zig` | Environment fingerprints and Linux CPU probes |

## Public API

`src/root.zig` is the only public entry point. It re-exports the stable modules:

```zig
const harnessz = @import("harnessz");

harnessz.golden;
harnessz.snapshot;
harnessz.oracle;
harnessz.determinism;
harnessz.stats;
harnessz.bench;
harnessz.baseline;
harnessz.fixture;
harnessz.evidence;
harnessz.provenance;
harnessz.artifact;
```

It also exports the small shared helpers `diff`, `env`, `json_canon`, and
`paths`. Internal helpers such as `num` are not part of the public API.

Public names are re-exported from parent modules so callers never import a
submodule directly. For example, `bench.run` is defined in `bench/run.zig` but
exported as `harnessz.bench.run`; `provenance.hashTree` is defined in
`provenance/tree.zig` but exported as `harnessz.provenance.hashTree`.

## Ownership conventions

- **Owned values** are documented and provide `deinit()`. They usually own an
  arena or a slice allocated with the allocator passed to the constructor.
- **Borrowed values** are explicitly documented as borrowed. For example,
  `SuiteResult.toEntries` borrows the suite's names and samples, and
  `artifact.Manifest.init` borrows caller-owned entries.
- **Arena-backed parsers** (`baseline.Store.fromJson`,
  `artifact.Manifest.fromJson`, `evidence.Manifest.fromJson`) keep all parsed
  strings in one arena and release them in `deinit()`.
- **Transfer** helpers exist where a result is commonly moved:
  `ProcessResult.takeResponse()`.
- **Allocator choice:** public entry points take an allocator rather than using
  a global. A few statistics helpers allocate temporary sorted copies with
  `std.heap.page_allocator` because their inputs are const slices; this is
  documented on the functions.

## Error conventions

- Invalid caller input returns `error.InvalidOptions`, `error.InvalidName`,
  `error.DuplicateName`, `error.InvalidPath`, or a module-specific typed error.
- Missing expected data returns a typed error such as `error.GoldenMissing`,
  `error.MissingBaseline`, or `error.FileNotFound` (propagated from `std.Io`).
- Mismatches return `error.GoldenMismatch`, `error.EnvironmentMismatch`, or a
  report value with `ok()`; the choice is documented per API.
- Process failures are typed: `error.SpawnFailed`, `error.ChildExitFailure`,
  `error.Timeout`, `error.OutputTooLarge`, `error.InvalidJson`, and so on.
- The package does not use `unreachable` for recoverable input validation.

## Zig 0.16 conventions

- All file and directory operations take an explicit `io: std.Io`.
- File APIs come from `std.Io.Dir` / `std.Io.File`; `std.fs` file APIs are not
  used. `std.fs.path` remains in use for pure path manipulation.
- Recursive directory creation uses `std.Io.Dir.createDirPath`.
- Benchmark callbacks return `u64`; `bench.blackBox` wraps
  `std.mem.doNotOptimizeAway` so results stay observable.
- Threaded tests and the process watchdog use `std.Thread` directly; the
  fallback path uses `Io.concurrent`.

## File layout

```text
src/
  root.zig              public module surface
  golden.zig            facade over golden/dir.zig and golden/normalize.zig
  oracle.zig            facade over oracle/*.zig
  stats.zig             batch statistics plus stats/*.zig
  bench.zig             facade over bench/*.zig
  baseline.zig          facade over baseline/store.zig and baseline/report.zig
  provenance.zig        facade over provenance/*.zig
  provenance/           hash, tree, and fingerprint submodules
  <module>/             focused submodules, re-exported from the parent
test/
  integration.zig       wires the integration test groups into the test binary
  core.zig              assertions, stats, baselines, evidence, fixtures
  process.zig           process-isolated benchmark integration tests
  workflow.zig          downstream adoption workflow test
  support.zig           shared integration-test helpers
bench/
  child_main.zig        installable benchmark child executable
tools/
  adoption_bench.zig    host-dependent adoption evidence tool
examples/consumer/      external package that imports only the public module
docs/                   these guides
```

Implementation files stay under roughly 500 lines; larger suites move to a
sibling `*_test.zig` file imported from a small `test` block. The same pattern
is used for `bench/multi_test.zig`, `bench/suite_test.zig`, and
`baseline/report_test.zig`.

## Adding a module

1. Put the implementation in `src/<name>.zig` or `src/<name>/<part>.zig`.
2. Re-export the public names from the parent and from `src/root.zig`.
3. Add a `test` block in the parent that imports the sibling test file and
   calls `refAllDecls` for submodules.
4. Document ownership, errors, and platform limitations on the public names.
5. Add the relevant validation gate to [testing.md](testing.md) if the module
   introduces a new failure mode.

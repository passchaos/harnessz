# AGENTS.md — harnessz

## Mission

`harnessz` is the shared test, benchmark, and oracle infrastructure for
Project-Z. It replaces per-repository golden/bench gates and evidence
conventions in imx, iris, pdfz, zev, and spectra with one std-only Zig 0.16
package.

## Boundaries

- This repository owns only `/home/passchaos/project-z/harnessz`.
- Do not modify sibling repositories from this workspace.
- Public API lives in `src/root.zig`; modules are re-exported from there.
- Keep modules focused. Split by stable responsibility before a file grows past
  roughly 500 lines.
- Tests live beside implementation. Package-level integration tests live in
  `test/`.
- Use `std.Io.Dir` / `std.Io.File` with an explicit `io: std.Io`; do not add
  `std.fs` file APIs. `std.fs.path` is acceptable for pure path manipulation.

## Validation rules

- Run the smallest relevant test first, then the full gate:
  - `zig build test`
  - `zig build test -Doptimize=ReleaseSafe`
- Never assert absolute timings, speedups, or scheduler behaviour in unit
  tests. They are flaky.
- Test `bench` structurally (iteration counts, sample lengths, callback call
  counts) and test gate logic with `bench.Comparison.fromSamples` and synthetic
  samples.
- Golden tests must cover first-run creation, matching, mismatch diagnostics,
  and update rewriting.
- Oracle tests must cover exact matches, first-mismatch offsets, NaN/infinity,
  signed zero, and absolute/relative tolerance boundaries.
- Determinism tests must cover stable output and an unstable producer whose
  first divergence is reported.
- Evidence tests must cover JSON round-trip and missing-path validation.
- No failing tests are acceptable. Do not claim unimplemented features.

## API and environment conventions

- Update mode: `Options.update` or `HARNESSZ_UPDATE=1`/`true`.
- Fixture root: `Options.fixtures_root`, then `HARNESSZ_FIXTURES`, then
  `testdata/`.
- Tests receive the runner environment automatically through
  `std.testing.environ`. Applications should pass
  `std.process.Init.minimal.environ` via `Options.environ`.
- `bench` callbacks return `u64` and are kept observable with
  `std.mem.doNotOptimizeAway`.
- `determinism` callbacks receive a thread count and own any actual threading.
- `evidence.Manifest.fromJson` owns its arena; call `deinit()`.
- Directory creation uses `std.Io.Dir.createDirPath` (the Zig 0.16 recursive
  make-path API).

## Build metadata

- Package name: `.harnessz`
- Version: `0.0.1`
- Minimum Zig: `0.16.0`
- No external dependencies.

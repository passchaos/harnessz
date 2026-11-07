# Migration guide

`harnessz` replaces per-repository golden/bench gates and evidence conventions
in `imx`, `iris`, `pdfz`, `zev`, and `spectra` with one std-only package. This
guide covers dependency wiring, the adoption sequence, and what each
repository should keep versus replace.

Measured methodology and results live in
[evidence/adoption-comparison.md](evidence/adoption-comparison.md).

## Dependency wiring

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

The wiring is exercised by [`examples/consumer/`](../examples/consumer), a
standalone package that imports only the public module:

```sh
cd examples/consumer && zig build run
```

## Adoption sequence

1. Add `harnessz` as a path dependency and import it in the benchmark module.
2. Wrap each implementation in `bench.NamedRunner` (a `bench.Runner` is a
   context pointer plus `fn (*anyopaque, Allocator, std.Io) anyerror!u64`).
3. Replace per-file executables with `bench.runSuite` over a registry, or use
   `bench.run` for a single workload and `bench.compareMany` for matrices.
4. Gate with `gateRobust` (noisy hosts) or `gateSignificant` (clean hosts), and
   call `bench.validatePolicy` before measuring.
5. Record samples in `baseline.Store` and gate on `compare`/`baseline.report`.
6. Fill `Entry.environment_fingerprint` with `provenance.fingerprint`, using
   `provenance.hashTreeHex` for source hashes and `loadVerifiedFile` for
   artifacts or dependency closures.
7. Keep golden and evidence checks in the same package instead of per-repo
   helpers.

The sequence is exercised end-to-end by the package integration test
`integration: downstream adoption workflow` in `test/workflow.zig`: it runs a
registry through `runSuite`, saves and reloads a baseline, compares with
fingerprint enforcement, renders a report, checks a golden file, validates an
evidence manifest, and hashes the workspace tree.

## Migration map

| Repository | Keep | Replace |
| --- | --- | --- |
| `zev` | SIMD/scalar kernels and the Highway baseline | `BenchmarkResult`, `nsPerIter`, `printResultChecked`, and the `min_ratio` loop with `compareMany`, `gateRobust`, and `baseline.report` (including Markdown history); use `process_suite` to keep one-process-per-kernel isolation |
| `spectra` | Per-format benchmark kernels and checksums | Per-file `main` argv parsing/timing/output with a registry plus `runSuite` (or `process_suite` when each kernel must keep its own process); use `measure_memory = true` for allocation/RSS numbers instead of per-file tracking allocators |
| `iris` | Renderer/scene setup | The single `Clock.awake.now` block with `bench.runMeasured` or `compareMany` across renderer configurations |
| `imx` | Codec kernels and reference-library oracles | Ad-hoc byte comparisons with `oracle.compareBytes`/`compareJson`; golden writes with `golden.expectFile`/`expectDirectory`; benchmark mains with `runSuite` |
| `pdfz` | Corpus cases and performance thresholds | Closure file loading with `provenance.loadVerifiedFile`; artifact descriptors with `artifact.Manifest.fromTree`/`verify`; ReleaseFast/sample checks with `bench.validatePolicy`; threshold history with `baseline.Store`/`baseline.report` |

The kernels and corpus definitions stay in the downstream repository. The
shared package owns sampling, statistics, gates, isolation, provenance, and
reporting, so migration does not move domain code out of its repository.

## Per-repository checklist

- [ ] Add the path dependency and module import.
- [ ] Replace ad-hoc timing with `bench.run` or `runSuite`.
- [ ] Add a `bench.validatePolicy` call for release-build and sample bounds.
- [ ] Replace ratio-only gates with `gateSignificant` or `gateRobust`.
- [ ] Commit a baseline JSON file and a report history document.
- [ ] Record `provenance.fingerprint` in baseline entries.
- [ ] Move golden files and evidence manifests under the shared APIs.
- [ ] Run the downstream build and the `examples/consumer` smoke test.

## Boundaries

- No sibling repository is modified from this workspace; adoption is a
  downstream change.
- Process isolation is not a sandbox. The child shares the parent's user,
  environment, filesystem, and network. It isolates address space, threads,
  allocator state, and process-group lifetime. See
  [Process isolation](process-isolation.md#boundaries).
- Absolute benchmark numbers are host-dependent; migrate methodology and
  gates, not recorded timings.

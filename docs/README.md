# harnessz documentation

`harnessz` is the shared test, benchmark, and oracle infrastructure for
Project-Z. Start with the [README](../README.md) for installation and a quick
tour, then use the guides below for subsystem details.

## Guides

| Guide | Covers |
| --- | --- |
| [Architecture](architecture.md) | Module layers, ownership rules, public API, file layout |
| [Testing](testing.md) | Validation gates, test taxonomy, determinism rules |
| [Environment](environment.md) | Zig 0.16 `std.Io` conventions, environment variables, fixtures |
| [Golden files](golden.md) | File and directory goldens, normalization, snapshots |
| [Oracles](oracles.md) | Byte, integer, float, ULP, complex, and JSON comparisons |
| [Determinism](determinism.md) | Repeated runs, first divergence, threaded runs |
| [Statistics](statistics.md) | Summaries, streaming stats, confidence intervals, Welch, Mann-Whitney |
| [Benchmarks](benchmarks.md) | Sampling, gates, multi-runner comparisons, suites, policy, memory |
| [Process isolation](process-isolation.md) | Child protocol, registry, parent runner, isolated suites, boundaries |
| [Baselines](baselines.md) | JSON storage, fingerprints, regression reports, Markdown history |
| [Fixtures](fixtures.md) | `HARNESSZ_FIXTURES` / `testdata` resolution |
| [Evidence](evidence.md) | Evidence manifests, path validation, test-name validation |
| [Provenance](provenance.md) | SHA-256 hashing, verified files, tree hashes, environment fingerprints |
| [Artifacts](artifacts.md) | Strict artifact manifests and verification |
| [Migration](migration.md) | Replacing per-repository harness code in downstream projects |
| [Adoption evidence](evidence/adoption-comparison.md) | Measured comparison against downstream ad-hoc harnesses |

## Reading paths

- **Downstream adopter:** [README](../README.md) → [Migration](migration.md) →
  [Benchmarks](benchmarks.md) → [Baselines](baselines.md) →
  [Provenance](provenance.md).
- **Contributor:** [Architecture](architecture.md) → [Testing](testing.md) →
  the guide for the module you are changing.
- **Debugging a flaky benchmark:** [Statistics](statistics.md) →
  [Benchmarks](benchmarks.md) → [Process isolation](process-isolation.md).

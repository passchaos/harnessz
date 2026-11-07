# Environment and Zig 0.16 conventions

## Toolchain

- Zig `0.16.0` minimum.
- No external dependencies.
- Package name `.harnessz`, version `0.0.1`.

## `std.Io`

All file and directory operations take an explicit `io: std.Io`. The package
uses `std.Io.Dir` / `std.Io.File`; it does not use `std.fs` file APIs.
`std.fs.path` is acceptable for pure path manipulation.

Recursive directory creation uses `std.Io.Dir.createDirPath` (the Zig 0.16
recursive make-path API).

Benchmark callbacks have the shape:

```zig
fn work(context: *Ctx, alloc: std.mem.Allocator, io: std.Io) anyerror!u64
```

The returned `u64` stays observable through `bench.blackBox`, which wraps
`std.mem.doNotOptimizeAway`.

## Environment variables

| Variable | Values | Effect |
| --- | --- | --- |
| `HARNESSZ_UPDATE` | `1` or `true` (ASCII case-insensitive) | Enables golden and snapshot update mode |
| `HARNESSZ_FIXTURES` | directory path | Fixture root when `Options.fixtures_root` is absent |

## Environment blocks

Tests receive the runner environment automatically through
`std.testing.environ`. Applications should pass
`std.process.Init.minimal.environ` via the relevant `Options.environ` field.

Zig 0.16 exposes the environment at `init.minimal.environ`;
`std.process.Environ` has platform-specific getters and `createMap`.
`harnessz` uses `createMap` for portable lookups.

An explicitly supplied environment always wins. In tests, an omitted
environment falls back to the runner environment; in non-test builds an omitted
environment means "no environment", so environment-driven behaviour is off
unless the application passes one.

## Fixture root

Resolution order for `fixture.resolve`:

1. `Options.fixtures_root`, when supplied.
2. `HARNESSZ_FIXTURES`, when set and non-empty.
3. `Options.testdata_dir` (default `testdata`).

Relative paths are checked against `Options.base_dir` (default cwd).
`workspace`, `workspaceJoin`, and `workspaceDir` help tests locate the workspace
root.

## Platform availability

- `bench.pinToCpu`, `bench.currentCpu`, `bench.affinityMask`, and
  `bench.peakRssBytes` are Linux-only and return `error.Unsupported` elsewhere.
- Pinning and affinity queries affect the calling thread, not every thread in
  the process. Save the original mask and restore it when the benchmark
  finishes.
- Process-group cleanup is POSIX-only. On Windows only the direct child is
  terminated; descendants that call `setsid` escape the group.
- The process watchdog starts a dedicated `std.Thread` and falls back to
  `Io.concurrent`. `error.TimeoutUnavailable` means neither mechanism exists.

# Fixtures

`fixture` resolves test data paths from a caller root, the environment, or a
conventional `testdata/` directory.

```zig
var resolved = try harnessz.fixture.resolve(gpa, io, "images/basic.png", .{
    .environ = init.minimal.environ, // optional in tests
});
defer resolved.deinit(gpa);
```

## Resolution order

1. `Options.fixtures_root`, when supplied.
2. `HARNESSZ_FIXTURES`, when set and non-empty.
3. `Options.testdata_dir` (default `testdata`).

Relative paths are checked against `Options.base_dir` (default cwd).
`Resolved.path` is the resolved relative or absolute path and
`Resolved.source` reports which rule matched.

## Workspace helpers

`workspace`, `workspaceJoin`, and `workspaceDir` help tests locate the workspace
root without hard-coding a checkout path. They are convenience wrappers around
the same resolution and path-validation rules.

## Environment

In tests, the runner environment is used automatically. Applications should
pass `std.process.Init.minimal.environ` via `Options.environ`. See
[Environment](environment.md) for the full environment contract.

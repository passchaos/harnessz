# Evidence manifests

`evidence` validates committed evidence documents that list implementation
paths, test names, and evidence paths. It is the machine-readable replacement
for hand-maintained `docs/*evidence*` conventions.

```zig
var manifest = try harnessz.evidence.Manifest.fromJson(gpa, json_bytes);
defer manifest.deinit();

const summary = manifest.summary();
var report = try manifest.validatePaths(io, repo_dir);
defer report.deinit();
if (!report.valid()) {
    for (report.missing) |missing| {
        std.debug.print("{s}: missing {s} ({s})\n", .{
            missing.entry_id, missing.path, @tagName(missing.kind),
        });
    }
}
```

Entries carry `id`, `status` (`implemented`, `partial`, `planned`, `deferred`),
`implementation_paths`, `test_names`, `evidence_paths`, and `notes`.
`toJson` emits only the manifest schema, not allocator bookkeeping.

`Manifest.fromJson` owns its arena; call `deinit()`. `validatePaths` checks
implementation and evidence paths relative to the supplied directory and
reports every missing path with its entry id and kind.

## Test-name validation

Test names can be checked against a list of tests known to the build:

```zig
var test_report = try manifest.validateTests(&known_test_names);
defer test_report.deinit();
if (!test_report.valid()) {
    for (test_report.unknown) |unknown| {
        // unknown.entry_id, unknown.name
    }
}
```

`TestValidationReport` references manifest-owned strings and counts every
declared test name, including duplicates. Its list is released by `deinit()`.

## Test coverage

Evidence tests cover JSON round-trip, missing-path validation, known test
names, and unknown test-name reporting with entry id and name. The package
integration suite composes evidence validation with golden, baseline,
provenance, and artifact checks in the downstream adoption workflow.

# Artifact manifests

`artifact.Manifest` records relative paths and SHA-256 digests for build
artifacts and verifies them against a directory tree. Generate one from a tree,
or construct it from known hashes.

```zig
var generated = try harnessz.artifact.Manifest.fromTree(gpa, io, repo_dir, .{});
defer generated.deinit();
try generated.save(io, repo_dir, "bench/artifacts.json");

const entries = [_]harnessz.artifact.Entry{
    .{ .path = "zig-out/bin/render", .sha256 = binary_hash },
    .{ .path = "bench/corpus.json", .sha256 = corpus_hash },
};
const manifest = harnessz.artifact.Manifest.init(gpa, &entries);
try manifest.save(io, repo_dir, "bench/artifacts.json");

var loaded = try harnessz.artifact.Manifest.load(
    gpa, io, repo_dir, "bench/artifacts.json",
);
defer loaded.deinit();

var report = try loaded.verify(io, repo_dir, .{ .reject_extra = false });
defer report.deinit();
if (!report.ok()) {
    // report.missing, report.mismatched, report.extra, report.present
}
```

## Strict JSON

`Manifest.fromJson` is strict:

- unknown fields are rejected,
- duplicate fields are rejected,
- missing `path`/`sha256` fields are rejected,
- paths must be relative and must not contain `..`,
- digests must be 64 lowercase hex characters,
- duplicate paths return `error.DuplicateEntry`.

All other parse and validation failures return `error.InvalidManifest`.
`Manifest.fromJson` owns its arena; call `deinit()`.

`Manifest.init` borrows caller-owned entries; `Manifest.fromTree` hashes a tree
with the provenance traversal rules and owns the resulting entries.

## Verification

`verify` reports:

- `missing`: manifest paths that do not exist on disk,
- `mismatched`: files whose actual digest differs from the manifest, with both
  digests,
- `extra`: files under the tree that the manifest does not list, when
  `reject_extra = true`,
- `present`: artifacts that exist (matched or mismatched),
- `total`: artifacts in the manifest.

`VerifyReport` owns its strings via an arena; call `deinit()`. Use `ok()` to
require no missing, mismatched, or extra entries.

## Save and load

`save` creates parent directories and writes deterministic indented JSON.
`load` validates the path, bounds the file read, and parses with the same strict
rules. A missing file propagates `error.FileNotFound`; oversized files return
`error.ManifestTooLarge`.

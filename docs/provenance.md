# Provenance and environment fingerprints

`provenance` hashes benchmark inputs and builds the environment tag stored in
`baseline.Entry.environment_fingerprint`. The module is split into
`provenance/hash.zig`, `provenance/tree.zig`, and
`provenance/fingerprint.zig`, re-exported from `provenance.zig`.

## Hashing bytes and files

```zig
const digest = harnessz.provenance.hashBytes(bytes);       // [32]u8
const hex = try harnessz.provenance.hashBytesHex(gpa, bytes);
defer gpa.free(hex);

const file_digest = try harnessz.provenance.hashFile(io, dir, "zig-out/bin/render");
const file_hex = try harnessz.provenance.hashFileHex(
    gpa, io, repo_dir, "zig-out/bin/render",
);
defer gpa.free(file_hex);
```

`hashFile` accepts a path relative to `dir` or an absolute path. All digests
are SHA-256; `hexAlloc` renders a digest as lowercase hex.

## Verified file loading

```zig
var loaded = try harnessz.provenance.loadVerifiedFile(io, gpa, absolute_path, .{
    .max_bytes = 64 * 1024 * 1024,
    .allow_empty = false,
});
defer loaded.deinit();
// loaded.bytes, loaded.digest, loaded.digestHex(gpa)
```

`loadVerifiedFile` reads an absolute path as a stable, non-symlinked regular
file and returns the bytes plus their digest. It rejects:

- symlinked path components and symlinked final files
  (`error.SymlinkRejected`),
- directories and other non-regular files (`error.NotRegularFile`),
- empty files when `allow_empty = false` (`error.FileEmpty`),
- files larger than `max_bytes` (`error.FileTooLarge`),
- files whose metadata or canonical path changes during the read
  (`error.ChangedDuringRead`),
- relative paths (`error.PathNotAbsolute`) and NUL-containing paths.

Use it for benchmark artifacts and dependency closures before trusting their
hash.

## Tree hashing

```zig
const source_hash = try harnessz.provenance.hashTreeHex(gpa, io, repo_dir, .{
    .skip_dirs = &.{ ".git", ".zig-cache", "zig-out" }, // default
    .max_files = 100_000,
    .max_total_bytes = 4 * 1024 * 1024 * 1024,
});
defer gpa.free(source_hash);
```

`hashTree`/`hashTreeHex` accept an ordinary `std.Io.Dir` (they open their own
iterable handle), sort paths, and skip VCS/cache/output directories by default.
Each file contributes its path length, path bytes, and content digest.
Traversal returns `error.ProvenanceTooLarge` past `max_files` or
`max_total_bytes`.

- Symlinked files are skipped unless `TreeOptions.follow_symlinks` is true;
  symlinked directories are never traversed.
- `listTree` returns the same sorted file set for callers that need paths
  rather than a combined digest.
- `Manifest.fromTree` in [Artifacts](artifacts.md) uses the same traversal
  rules.

## Environment fingerprints

```zig
const fingerprint = try harnessz.provenance.fingerprint(gpa, io, .{
    .build_mode = "ReleaseSafe",
    .source_hash = source_hash,
    .binary_hash = binary_hash,
    .commit = commit,
    .dirty = true,
    .extra = "machine-a",
});
defer gpa.free(fingerprint);
```

`fingerprint` combines architecture, OS, CPU count, Linux CPU model and
scaling-governor probes, build mode, source/binary hashes, commit, dirty state,
and a caller tag. Unavailable probes degrade to `unknown` instead of failing;
the string format is opaque and only equality is supported.

`baseline.environmentFingerprint(alloc, io, tag)` is the smaller historical
alternative. `provenance.fingerprint` is the richer choice for new code.

Use the result as `baseline.Entry.environment_fingerprint` together with
`Options.require_fingerprint = true` and `expected_fingerprint`, so a baseline
recorded on a different machine, build mode, or source revision fails loudly
with `error.EnvironmentMismatch` instead of producing a false regression.

# Golden files, directories, and snapshots

Golden checks compare actual output with committed expected bytes. Missing
files, mismatches, and update mode are explicit outcomes rather than implicit
behaviour.

## File goldens

```zig
const harnessz = @import("harnessz");

try harnessz.golden.expectFile(io, dir, "render/basic.txt", actual, .{
    .allocator = gpa,
    .update = false, // or set HARNESSZ_UPDATE=1
    .mode = .text,
});
```

Behaviour:

- Missing file without update returns `error.GoldenMissing`.
- Equal bytes return `.matched`.
- Mismatch without update prints a unified diff and returns
  `error.GoldenMismatch`.
- Update mode creates parent directories and returns `.created` or `.updated`.
- Text mode compares exact bytes by default; the mode only changes mismatch
  diagnostics (line diff versus hex dump).
- `expectString(expected, actual, .{})` performs the same comparison in memory.

`Options.report = false` suppresses diagnostics. `Options.max_bytes` bounds the
golden file read. `Options.max_diff_lines` and `Options.context_lines` control
the diagnostic diff.

## Normalization

Text comparisons can opt into normalization:

```zig
try harnessz.golden.expectFile(io, dir, "render/basic.txt", actual, .{
    .allocator = gpa,
    .normalize = .{
        .line_endings = true,        // CRLF and lone CR become LF
        .trailing_whitespace = true, // strip spaces/tabs at line ends
        .json_canonical = true,      // parse JSON and compare canonical forms
    },
});
```

`json_canonical` recursively sorts object keys, preserves array order, and
returns `error.InvalidJson` for invalid input. Normalization applies only to
text mode. Update mode always writes the original `actual` bytes, never the
normalized form; normalized-equal comparisons return `.matched` without
rewriting the file. Binary mode ignores normalization.

## Directory goldens

```zig
const expected = [_]harnessz.golden.DirEntry{
    .{ .relative_path = "a.txt", .bytes = "alpha" },
    .{ .relative_path = "nested/b.bin", .bytes = &blob },
};

var report = try harnessz.golden.expectDirectory(io, dir, "golden/render", &expected, .{
    .allocator = gpa,
    .update = false, // or set HARNESSZ_UPDATE=1
    .max_files = 4096,
    .max_total_bytes = 256 * 1024 * 1024,
    .max_file_bytes = 64 * 1024 * 1024,
});
defer report.deinit();
if (!report.ok()) {
    for (report.changes) |change| {
        // change.kind: missing, extra, changed, or created
        // change.relative_path
    }
}
```

Traversal is deterministic: files are collected recursively and sorted by
relative path. Compare mode reports `missing`, `extra`, and `changed` files
without mutating the tree, and a missing root is reported as every expected
file missing. Update mode creates missing files, rewrites changed files, and
deletes extra files. Both modes enforce `max_files`, `max_total_bytes`, and
`max_file_bytes`; duplicate expected paths return `error.DuplicateEntry`.

## Snapshots

```zig
var registry = try harnessz.snapshot.Registry.init(gpa, io, .{
    .dir = snapshots_dir, // omit for an in-memory registry
    .prefix = "snapshots",
    .update = false,
});
defer registry.deinit();

try registry.check("render/basic", bytes);
try registry.checkFmt("hash/{x}", "{x}", .{checksum});
```

An in-memory registry accepts the first value for a name and compares later
values. A file-backed registry requires update mode to create a missing file.
`HARNESSZ_UPDATE=1` (or `true`) enables update mode in both modes.

## Errors

| Error | Meaning |
| --- | --- |
| `error.GoldenMissing` | Expected file is absent and update mode is off |
| `error.GoldenMismatch` | Bytes differ and update mode is off |
| `error.GoldenTooLarge` | File exceeds `max_bytes` |
| `error.InvalidPath` | Empty, absolute, NUL-containing, or `..`-traversing path |
| `error.InvalidJson` | `json_canonical` received invalid JSON |
| `error.DuplicateEntry` | Directory expectations contain the same path twice |

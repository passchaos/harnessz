# Oracles

Oracles compare actual values with expected values and report the first
difference. They do not write files or manage update mode; use `golden` for
committed expectations.

## Byte, integer, and float slices

```zig
const bytes_report = harnessz.oracle.compareBytes(expected, actual);
const floats_report = harnessz.oracle.compareFloatSlices(f64, expected_f, actual_f, .{
    .abs_tolerance = 1e-9,
    .rel_tolerance = 1e-6,
    .nan_equal = true,
    .max_mismatches = 8,
});
const ints_report = harnessz.oracle.compareIntSlices(i32, expected_i, actual_i);
const hash = harnessz.oracle.checksum(bytes);
```

Float tolerance passes when:

```text
|a - b| <= abs_tolerance + rel_tolerance * max(|a|, |b|)
```

NaN is unequal by default (`nan_equal = true` changes this). Same-sign
infinities are equal. `+0.0` and `-0.0` are equal by default; set
`signed_zero_equal = false` to require identical signs.

`compareBytes` reports the first mismatch offset. Slice comparisons stop after
`max_mismatches` entries and expose the total mismatch count.

## ULP distance

```zig
const ulp_report = harnessz.oracle.compareUlp(f64, expected_f, actual_f, 2);
```

`compareUlp` compares f32/f64 values by representable-step distance. `+0.0`
and `-0.0` are equal (`UlpReason.signed_zero`), NaN never compares equal, and
same-sign infinities are equal. `ulp_distance` is `maxInt(u64)` when the values
are not comparable.

## Complex values

```zig
const complex_report = harnessz.oracle.compareComplexSlices(
    f64,
    expected_complex,
    actual_complex,
    .{ .abs_tolerance = 1e-9 },
);
```

`compareComplexSlices` applies the `FloatOptions` policy to both the real and
imaginary parts; one complex element counts as one mismatch when either part
differs.

## Structural JSON

```zig
var json_report = try harnessz.oracle.compareJson(
    "{\"b\":[1,2],\"a\":2}",
    "{\"a\":2,\"b\":[1,2]}",
    .{ .abs_tolerance = 1e-9, .rel_tolerance = 1e-6 },
);
defer json_report.deinit();
if (!json_report.ok()) {
    // json_report.first_difference.?.path, e.g. "a.b[2].c"
    // json_report.first_difference.?.kind
}
```

`compareJson` parses both documents with `std.json` and compares them
structurally. Object key order is ignored, array order is significant, and
integer/float values compare numerically. `abs_tolerance` and `rel_tolerance`
use the same formula as float slices. The first difference is reported as a
path (`a.b[2].c`), and invalid JSON returns `error.InvalidJson`.
`Report.deinit` releases the path.

## Checksums

`oracle.checksum` is a Wyhash checksum suitable for deterministic test output
and child protocol checksums. It is not a cryptographic hash; use
`provenance.hashBytes` for SHA-256.

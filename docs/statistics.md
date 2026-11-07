# Statistics

`stats` provides batch summaries, streaming accumulation, histograms,
confidence intervals, Welch's t-test, and the Mann-Whitney U rank-sum test.
Inputs may be integer or floating-point slices; statistics are computed as
`f64`.

## Batch summaries

```zig
const median = harnessz.stats.median(u64, samples);
const p99 = harnessz.stats.percentile(u64, samples, 99);
const summary = harnessz.stats.summarize(u64, samples);
const robust = harnessz.stats.compare(u64, baseline, candidate);
```

`percentile` uses linear interpolation (R-7 / NumPy default). `summarize`
returns count, min, max, mean, population stddev, median, p90, and p99.
Statistics make temporary copies through `std.heap.page_allocator` because the
input slices are const. Direct statistic functions require non-empty slices.

## Streaming accumulation

```zig
var accumulator: harnessz.stats.Accumulator = .init();
accumulator.add(120);
accumulator.add(130);
const mean = accumulator.mean();
const variance = accumulator.variance(); // population variance (Welford)
const summary = accumulator.summary();   // median/p90/p99 remain 0
```

`Accumulator` uses Welford's single-pass algorithm for mean and variance.
`summary()` fills count/min/max/mean/stddev but cannot produce order statistics
without storing samples.

## Histograms

```zig
var histogram = try harnessz.stats.Histogram.build(gpa, values, 8);
defer histogram.deinit();
const json = try histogram.toJson(gpa);
defer gpa.free(json);
```

`Histogram` uses linear buckets from min to max; the last bucket includes the
maximum and all-equal values collapse to a zero-width first bucket.

## Confidence intervals

```zig
const interval = harnessz.stats.confidenceIntervalMean(values, 1.96);
const t_interval = try harnessz.stats.confidenceIntervalMeanT(values, 0.95);
const robust_mean = harnessz.stats.trimmedMean(values, 0.1);
```

`confidenceIntervalMean` uses the caller-supplied critical value in
`mean +/- z * stddev / sqrt(n)`; pass a Student-t critical value (for example
from `stats.studentTCritical`) when samples are few.

`confidenceIntervalMeanT(values, confidence)` computes the exact Student-t
critical value with `n - 1` degrees of freedom and requires at least two
values. `stats.studentTCritical(df, confidence)` is public.

`trimmedMean` discards `floor(len * trim_fraction)` values from each end, with
`trim_fraction` in `[0, 0.5)`.

## Welch's unequal-variance t-test

```zig
const result = try harnessz.stats.welchTTest(u64, baseline_samples, candidate_samples);
// result.t, result.degrees_of_freedom, result.p_value
```

Both inputs need at least two samples. The p-value is two-sided and uses the
exact Student-t tail via the regularized incomplete beta function with
Welch-Satterthwaite degrees of freedom. `stats.twoSidedNormalPValue` remains
available for callers that explicitly want the normal approximation.
`stats.studentTTwoSidedPValue` exposes the Student-t tail directly.

## Mann-Whitney U

```zig
const rank = try harnessz.stats.mannWhitneyU(u64, baseline_samples, candidate_samples);
// rank.u, rank.z, rank.p_approx, rank.tie_groups
```

`mannWhitneyU` is the two-sample rank-sum test with a tie-corrected normal
approximation. It is less sensitive to timing outliers than Welch's test, at
the cost of some power on small samples. Both sides need at least two samples.

## Choosing a gate

- Use Welch (`Comparison.gateSignificant`) on clean hosts where the mean is the
  quantity of interest.
- Use the rank test (`Comparison.gateRobust`) on noisy hosts or when a single
  scheduler hiccup can inflate the variance.
- Fewer than two samples per side yields `p_value = robust_p_value = 1` and
  both significance flags false instead of an error.

//! Benchmark baseline storage, regression detection, and comparison reports.
//!
//! `Store` and its supporting types live in `baseline/store.zig`; the
//! deterministic text/JSON comparison report lives in `baseline/report.zig`.
//! Both are re-exported here so `harnessz.baseline.Store`,
//! `harnessz.baseline.Entry`, and `harnessz.baseline.report.report` remain the
//! public entry points.
//!
//! A baseline file is JSON with a top-level `entries` array. Each entry stores
//! a name, an environment fingerprint, raw nanosecond samples, and a summary.
//! The environment fingerprint keeps baselines from different machines or
//! build configurations from being compared silently.

const std = @import("std");

pub const store = @import("baseline/store.zig");
pub const report = @import("baseline/report.zig");

pub const Entry = store.Entry;
pub const Store = store.Store;
pub const Options = store.Options;
pub const Regression = store.Regression;
pub const environmentFingerprint = store.environmentFingerprint;

test {
    // Force analysis of both submodules so their tests run with the package
    // test suite.
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(report);
}

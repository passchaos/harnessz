//! Benchmark harness with warmup, minimum-time sampling, interleaved A/B
//! comparison, gate logic, suites, and process isolation.
//!
//! The module is a facade over focused submodules:
//!
//! - `bench/run.zig` — sampling, batch sizes, memory measurement, A/B runs
//! - `bench/comparison.zig` — `Comparison` and gate logic
//! - `bench/multi.zig` — rotating N-way comparison
//! - `bench/suite.zig` — in-process registry suites
//! - `bench/policy.zig` — build-mode and sample-count policy checks
//! - `bench/system.zig` — CPU affinity, RSS, counting allocator
//! - `bench/protocol.zig` through `bench/process_suite.zig` — isolated child
//!   processes
//!
//! Timing values are intentionally not asserted by unit tests. Gate logic is
//! tested through `Comparison.fromSamples`, which works on synthetic samples.

const std = @import("std");

const execution = @import("bench/run.zig");
const comparison_mod = @import("bench/comparison.zig");
const measure_lib = @import("bench/measure.zig");

/// Host environment controls: CPU pinning, peak RSS, and a counting
/// allocator.
pub const system = @import("bench/system.zig");

/// Process-isolated benchmark support: JSON protocol, child registry,
/// child entrypoint, and parent process runner.
pub const protocol = @import("bench/protocol.zig");
pub const registry = @import("bench/registry.zig");
pub const child = @import("bench/child.zig");
pub const process = @import("bench/process.zig");
pub const stderr_capture = @import("bench/stderr_capture.zig");
pub const watchdog = @import("bench/watchdog.zig");
pub const process_suite = @import("bench/process_suite.zig");
pub const ProcessSuiteOptions = process_suite.Options;
pub const ProcessSuiteResult = process_suite.Suite;
pub const runProcessSuite = process_suite.run;

/// Interleaved multi-implementation comparison.
pub const multi = @import("bench/multi.zig");
pub const NamedRunner = multi.NamedRunner;
pub const MultiComparison = multi.MultiComparison;
pub const compareMany = multi.compareMany;

/// In-process suites over a benchmark registry.
pub const suite = @import("bench/suite.zig");
pub const SuiteOptions = suite.SuiteOptions;
pub const SuiteResult = suite.SuiteResult;
pub const runSuite = suite.runSuite;

/// Benchmark configuration policy checks.
pub const policy = @import("bench/policy.zig");
pub const Policy = policy.Policy;
pub const PolicyViolation = policy.Violation;
pub const validatePolicy = policy.validate;

/// Type-erased benchmark callback used by `runRuntime` and the child
/// registry.
pub const Runner = execution.Runner;

pub const Options = execution.Options;
pub const Stats = execution.Stats;
pub const MeasuredStats = execution.MeasuredStats;
pub const GateResult = comparison_mod.GateResult;
pub const Comparison = comparison_mod.Comparison;

pub const run = execution.run;
pub const runRuntime = execution.runRuntime;
pub const runMeasured = execution.runMeasured;
pub const runMeasuredRuntime = execution.runMeasuredRuntime;
pub const compare = execution.compare;

pub const CpuMask = system.CpuMask;
pub const CountingAllocator = system.CountingAllocator;
pub const affinityMask = system.affinityMask;
pub const pinToCpu = system.pinToCpu;
pub const currentCpu = system.currentCpu;
pub const peakRssBytes = system.peakRssBytes;

/// Keep `value` observable to the optimizer. Zig 0.16 exposes this through
/// `std.mem.doNotOptimizeAway`, which emits an empty volatile asm block (or a
/// volatile store on backends without asm support).
pub const blackBox = measure_lib.blackBox;

test {
    _ = @import("bench_test.zig");
    // Force analysis of the submodules so their tests are included in the
    // package test run.
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(registry);
    std.testing.refAllDecls(child);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(stderr_capture);
    std.testing.refAllDecls(watchdog);
    std.testing.refAllDecls(multi);
    std.testing.refAllDecls(suite);
    std.testing.refAllDecls(policy);
    std.testing.refAllDecls(process_suite);
    std.testing.refAllDecls(measure_lib);
    std.testing.refAllDecls(execution);
    std.testing.refAllDecls(comparison_mod);
}

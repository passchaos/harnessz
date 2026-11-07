//! Benchmark configuration policy checks.
//!
//! Downstream benchmark gates often require a release build and a minimum
//! number of samples. `validate` turns those conventions into typed errors so
//! a misconfigured benchmark fails before it produces misleading numbers.

const std = @import("std");
const bench = @import("../bench.zig");

pub const Policy = struct {
    /// Required build-mode tag, for example `"ReleaseFast"`. Empty disables
    /// the check.
    required_build_mode: []const u8 = "ReleaseFast",
    min_warmup_iterations: usize = 1,
    min_iterations: usize = 5,
    max_iterations: usize = 100_000,
    min_batch_size: usize = 1,
    max_batch_size: usize = 1_000_000,

    /// True when the bounds are internally consistent.
    pub fn valid(self: Policy) bool {
        return self.min_iterations >= 1 and
            self.min_iterations <= self.max_iterations and
            self.min_batch_size >= 1 and
            self.min_batch_size <= self.max_batch_size;
    }
};

pub const Violation = enum {
    BuildModeMismatch,
    WarmupTooLow,
    IterationsTooLow,
    IterationsTooHigh,
    BatchSizeTooLow,
    BatchSizeTooHigh,
};

pub const Error = error{
    InvalidPolicy,
    BuildModeMismatch,
    WarmupTooLow,
    IterationsTooLow,
    IterationsTooHigh,
    BatchSizeTooLow,
    BatchSizeTooHigh,
};

/// First violation in a fixed order, or null when the configuration passes.
pub fn check(
    build_mode: []const u8,
    options: bench.Options,
    policy: Policy,
) ?Violation {
    if (policy.required_build_mode.len != 0 and
        !std.mem.eql(u8, build_mode, policy.required_build_mode))
    {
        return .BuildModeMismatch;
    }
    if (options.warmup_iterations < policy.min_warmup_iterations) {
        return .WarmupTooLow;
    }
    if (options.iterations < policy.min_iterations) return .IterationsTooLow;
    if (options.iterations > policy.max_iterations) return .IterationsTooHigh;
    if (options.batch_size < policy.min_batch_size) return .BatchSizeTooLow;
    if (options.batch_size > policy.max_batch_size) return .BatchSizeTooHigh;
    return null;
}

pub fn validate(
    build_mode: []const u8,
    options: bench.Options,
    policy: Policy,
) Error!void {
    if (!policy.valid()) return error.InvalidPolicy;
    const violation = check(build_mode, options, policy) orelse return;
    return switch (violation) {
        .BuildModeMismatch => error.BuildModeMismatch,
        .WarmupTooLow => error.WarmupTooLow,
        .IterationsTooLow => error.IterationsTooLow,
        .IterationsTooHigh => error.IterationsTooHigh,
        .BatchSizeTooLow => error.BatchSizeTooLow,
        .BatchSizeTooHigh => error.BatchSizeTooHigh,
    };
}

pub fn describe(violation: Violation) []const u8 {
    return switch (violation) {
        .BuildModeMismatch => "benchmark build mode does not match the policy",
        .WarmupTooLow => "warmup iterations are below the policy minimum",
        .IterationsTooLow => "iterations are below the policy minimum",
        .IterationsTooHigh => "iterations are above the policy maximum",
        .BatchSizeTooLow => "batch size is below the policy minimum",
        .BatchSizeTooHigh => "batch size is above the policy maximum",
    };
}

test "bench policy: valid configuration passes" {
    const options: bench.Options = .{
        .warmup_iterations = 2,
        .iterations = 20,
        .batch_size = 4,
    };
    try validate("ReleaseFast", options, .{});
    try std.testing.expect(check("ReleaseFast", options, .{}) == null);
}

test "bench policy: build mode is required unless disabled" {
    const options: bench.Options = .{ .iterations = 10 };
    try std.testing.expectError(
        error.BuildModeMismatch,
        validate("Debug", options, .{}),
    );
    try validate("Debug", options, .{ .required_build_mode = "" });
    try std.testing.expectEqual(
        Violation.BuildModeMismatch,
        check("Debug", options, .{}).?,
    );
}

test "bench policy: sample-count bounds" {
    const low_warmup: bench.Options = .{ .warmup_iterations = 0, .iterations = 10 };
    try std.testing.expectError(
        error.WarmupTooLow,
        validate("ReleaseFast", low_warmup, .{}),
    );

    const low_iterations: bench.Options = .{ .iterations = 2 };
    try std.testing.expectError(
        error.IterationsTooLow,
        validate("ReleaseFast", low_iterations, .{}),
    );

    const high_iterations: bench.Options = .{ .iterations = 100 };
    try std.testing.expectError(
        error.IterationsTooHigh,
        validate("ReleaseFast", high_iterations, .{ .max_iterations = 50 }),
    );

    const low_batch: bench.Options = .{ .iterations = 10, .batch_size = 0 };
    try std.testing.expectError(
        error.BatchSizeTooLow,
        validate("ReleaseFast", low_batch, .{}),
    );

    const high_batch: bench.Options = .{ .iterations = 10, .batch_size = 9 };
    try std.testing.expectError(
        error.BatchSizeTooHigh,
        validate("ReleaseFast", high_batch, .{ .max_batch_size = 8 }),
    );
}

test "bench policy: invalid bounds and deterministic first violation" {
    try std.testing.expectError(
        error.InvalidPolicy,
        validate("ReleaseFast", .{ .iterations = 10 }, .{
            .min_iterations = 20,
            .max_iterations = 10,
        }),
    );
    try std.testing.expectError(
        error.InvalidPolicy,
        validate("ReleaseFast", .{ .iterations = 10 }, .{
            .min_iterations = 0,
        }),
    );

    const broken: bench.Options = .{
        .warmup_iterations = 0,
        .iterations = 1,
        .batch_size = 0,
    };
    // Build mode is checked first, then warmup, then iterations, then batch.
    try std.testing.expectEqual(
        Violation.BuildModeMismatch,
        check("Debug", broken, .{}).?,
    );
    try std.testing.expectEqual(
        Violation.WarmupTooLow,
        check("ReleaseFast", broken, .{}).?,
    );
}

test "bench policy: every violation has a description" {
    inline for (std.meta.tags(Violation)) |violation| {
        try std.testing.expect(describe(violation).len > 0);
    }
}

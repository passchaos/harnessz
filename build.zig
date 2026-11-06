const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const harnessz_mod = b.addModule("harnessz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .name = "harnessz-unit",
        .root_module = harnessz_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Process-isolated benchmark child used by the integration tests.
    const bench_child = b.addExecutable(.{
        .name = "harnessz-bench-child",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/child_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "harnessz", .module = harnessz_mod }},
        }),
    });
    b.installArtifact(bench_child);

    const bench_child_options = b.addOptions();
    bench_child_options.addOptionPath("child_exe", bench_child.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "harnessz", .module = harnessz_mod },
            .{ .name = "bench_child", .module = bench_child_options.createModule() },
        },
    });
    const integration_tests = b.addTest(.{
        .name = "harnessz-integration",
        .root_module = integration_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run harnessz unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}

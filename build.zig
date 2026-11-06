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

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harnessz", .module = harnessz_mod }},
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

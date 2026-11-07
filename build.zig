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

    // Adoption evidence tool. Not part of `test`: it reports host-dependent
    // wall-clock numbers and writes an optional JSON artifact.
    const adoption_bench = b.addExecutable(.{
        .name = "harnessz-adoption-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/adoption_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "harnessz", .module = harnessz_mod }},
        }),
    });
    const run_adoption_bench = b.addRunArtifact(adoption_bench);
    if (b.args) |args| run_adoption_bench.addArgs(args);
    const adoption_step = b.step(
        "adoption-bench",
        "Compare harnessz sampling with downstream ad-hoc timing styles",
    );
    adoption_step.dependOn(&run_adoption_bench.step);

    // Compile the public module and child executable for non-native targets.
    // Runtime coverage is still Linux-first; this gate catches compile-time
    // platform regressions.
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    const cross_step = b.step("check-cross", "Compile for non-native targets");
    for (cross_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = optimize,
        });
        const cross_child = b.addExecutable(.{
            .name = b.fmt("harnessz-bench-child-{s}-{s}", .{
                @tagName(query.cpu_arch.?),
                @tagName(query.os_tag.?),
            }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/child_main.zig"),
                .target = resolved,
                .optimize = optimize,
                .imports = &.{.{ .name = "harnessz", .module = cross_mod }},
            }),
        });
        cross_step.dependOn(&cross_child.step);
    }
}

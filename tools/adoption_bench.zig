//! Adoption evidence: compares the ad-hoc benchmark style used by downstream
//! Project-Z repositories with harnessz's sampled comparisons.
//!
//! The tool is deliberately outside `zig build test`: it reports wall-clock
//! numbers, which are host- and load-dependent. Unit tests cover the
//! structural and statistical logic instead.
//!
//! Scenarios:
//! - `false_positive`: baseline and candidate do identical work, with
//!   deterministic per-call jitter. A good method should rarely flag a
//!   regression.
//! - `detect_10pct`: the candidate does 10% more work. A good method should
//!   flag it reliably.
//! - `ordering`: three implementations measured while the machine drifts
//!   (cost grows with cumulative call count). Compares sequential measurement
//!   with harnessz's rotating interleaved measurement.
//! - `overhead`: per-call cost of an empty and a small workload measured with
//!   both styles.
//!
//! The "internal" style mirrors the timing loops in zev/bench/compare.zig,
//! spectra/bench/*.zig, and iris/examples/bench.zig: warmup followed by one
//! timed block (or repeated blocks), a ratio gate, and no significance test.
//!
//! Implementation is split under `tools/adoption/`: configuration, workloads,
//! scenarios, and text/JSON rendering.

const std = @import("std");
const Config = @import("adoption/config.zig").Config;
const scenario = @import("adoption/scenario.zig");
const report = @import("adoption/report.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var config: Config = .{};
    var json_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--trials")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.trials = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.samples = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.iterations = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.warmup = try std.fmt.parseUnsigned(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--jitter")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.jitter_percent = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.seed = try std.fmt.parseUnsigned(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            json_path = args[index];
        } else {
            return error.InvalidArguments;
        }
    }

    if (config.trials == 0 or config.samples < 2 or config.iterations == 0) {
        return error.InvalidArguments;
    }

    const false_positive = try scenario.runScenario(alloc, io, config, "false_positive", 100);
    const detect_10pct = try scenario.runScenario(alloc, io, config, "detect_10pct", 110);
    const detect_20pct = try scenario.runScenario(alloc, io, config, "detect_20pct", 120);
    const ordering = try scenario.runOrdering(alloc, io, config);
    const overhead = try scenario.runOverhead(alloc, io, config);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try report.writeTextReport(
        out,
        config,
        false_positive,
        detect_10pct,
        detect_20pct,
        ordering,
        overhead,
    );
    try out.flush();

    if (json_path) |path| {
        const json = try report.writeJsonReport(
            alloc,
            config,
            false_positive,
            detect_10pct,
            detect_20pct,
            ordering,
            overhead,
        );
        defer alloc.free(json);
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }
}

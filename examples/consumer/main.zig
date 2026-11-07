//! Minimal external consumer of the harnessz package.
//!
//! Run from this directory:
//!
//!     zig build run
//!
//! It exercises the public module through a path dependency, so it catches
//! packaging and module-wiring regressions that in-package tests cannot.

const std = @import("std");
const harnessz = @import("harnessz");

const Work = struct {
    calls: u64 = 0,

    fn run(context: *anyopaque, _: std.mem.Allocator, _: std.Io) anyerror!u64 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        var value = self.calls;
        var index: u64 = 0;
        while (index < 64) : (index += 1) {
            value ^= value << 13;
            value ^= value >> 7;
            value ^= value << 17;
        }
        return value;
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var first: Work = .{};
    var second: Work = .{};

    var stats = try harnessz.bench.run(alloc, io, .{
        .warmup_iterations = 1,
        .iterations = 3,
    }, &first, Work.run);
    defer stats.deinit(alloc);
    if (stats.samples_ns.len != 3) return error.SmokeFailed;

    const runners = [_]harnessz.bench.NamedRunner{
        .{ .name = "first", .runner = .{ .context = &first, .run = Work.run } },
        .{ .name = "second", .runner = .{ .context = &second, .run = Work.run } },
    };
    var multi = try harnessz.bench.compareMany(alloc, io, .{
        .warmup_iterations = 1,
        .iterations = 3,
    }, &runners);
    defer multi.deinit();
    if (multi.pairs.len != 1) return error.SmokeFailed;

    var registry = harnessz.bench.registry.Registry.init(alloc);
    defer registry.deinit();
    try registry.add("first", .{ .context = &first, .run = Work.run });
    try registry.add("second", .{ .context = &second, .run = Work.run });
    var suite = try harnessz.bench.runSuite(alloc, io, &registry, .{
        .run = .{ .warmup_iterations = 0, .iterations = 2 },
    });
    defer suite.deinit();
    if (suite.count() != 2) return error.SmokeFailed;

    try harnessz.bench.validatePolicy("ReleaseFast", .{
        .iterations = 10,
    }, .{ .required_build_mode = "" });

    const fingerprint = try harnessz.provenance.fingerprint(alloc, io, .{
        .build_mode = "consumer-smoke",
    });
    defer alloc.free(fingerprint);

    const source_hash = try harnessz.provenance.hashFileHex(
        alloc,
        io,
        std.Io.Dir.cwd(),
        "main.zig",
    );
    defer alloc.free(source_hash);

    const entries = [_]harnessz.artifact.Entry{
        .{ .path = "main.zig", .sha256 = source_hash },
    };
    var manifest = harnessz.artifact.Manifest.init(alloc, &entries);
    defer manifest.deinit();
    var verify = try manifest.verify(io, std.Io.Dir.cwd(), .{});
    defer verify.deinit();
    if (!verify.ok()) return error.SmokeFailed;

    _ = try harnessz.golden.expectFile(
        io,
        std.Io.Dir.cwd(),
        ".zig-cache/consumer-smoke/out.txt",
        "ok\n",
        .{ .update = true, .allocator = alloc, .report = false },
    );

    var report_out: std.Io.Writer.Allocating = .init(alloc);
    defer report_out.deinit();
    var store = harnessz.baseline.Store.init(alloc);
    defer store.deinit();
    var report = try harnessz.baseline.report.report(
        alloc,
        &report_out.writer,
        &store,
        &.{},
        .{},
    );
    defer report.deinit();
    if (!report.ok()) return error.SmokeFailed;

    std.debug.print("consumer smoke ok: suite={d} pairs={d} fp={s}\n", .{
        suite.count(),
        multi.pairs.len,
        fingerprint,
    });
}

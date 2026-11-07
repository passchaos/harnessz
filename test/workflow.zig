//! Downstream adoption workflow: suite -> baseline -> provenance -> golden
//! -> evidence in one temporary workspace.

const std = @import("std");
const harnessz = @import("harnessz");

test "integration: downstream adoption workflow" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Work = struct {
        value: u64,
        calls: u64 = 0,

        fn run(context: *anyopaque, _: std.mem.Allocator, _: std.Io) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            var hash = self.value;
            var index: u64 = 0;
            while (index < 64) : (index += 1) {
                hash ^= (index *% 0x9e3779b97f4a7c15) >> 7;
                hash *%= 0x100000001b3;
            }
            return hash + self.calls;
        }
    };

    var decode_context: Work = .{ .value = 1 };
    var encode_context: Work = .{ .value = 2 };

    var registry = harnessz.bench.registry.Registry.init(alloc);
    defer registry.deinit();
    try registry.add("decode", .{ .context = &decode_context, .run = Work.run });
    try registry.add("encode", .{ .context = &encode_context, .run = Work.run });

    var suite = try harnessz.bench.runSuite(alloc, io, &registry, .{
        .run = .{ .warmup_iterations = 1, .iterations = 5 },
    });
    defer suite.deinit();

    try std.testing.expectEqual(@as(usize, 2), suite.count());
    try std.testing.expectEqual(@as(usize, 5), suite.find("decode").?.samples_ns.len);

    const fingerprint = try harnessz.provenance.fingerprint(alloc, io, .{
        .build_mode = "test",
        .extra = "adoption-workflow",
    });
    defer alloc.free(fingerprint);

    const entries = try suite.toEntries(alloc, fingerprint);
    defer alloc.free(entries);

    var store = harnessz.baseline.Store.init(alloc);
    defer store.deinit();
    store.entries = entries;
    try store.save(io, tmp.dir, "bench/baseline.json");
    try store.load(io, tmp.dir, "bench/baseline.json");

    const regression = try store.compare("decode", suite.find("decode").?.samples_ns, .{
        .max_regression_ratio = 1.05,
        .require_fingerprint = true,
        .expected_fingerprint = fingerprint,
    });
    try std.testing.expect(!regression.regressed);
    try std.testing.expectError(
        error.EnvironmentMismatch,
        store.compare("decode", suite.find("decode").?.samples_ns, .{
            .require_fingerprint = true,
            .expected_fingerprint = "other",
        }),
    );

    var report_out: std.Io.Writer.Allocating = .init(alloc);
    defer report_out.deinit();
    var comparison = try harnessz.baseline.report.report(
        alloc,
        &report_out.writer,
        &store,
        entries,
        .{},
    );
    defer comparison.deinit();
    try std.testing.expect(comparison.ok());
    try std.testing.expectEqual(@as(usize, 2), comparison.rows.len);
    try std.testing.expect(std.mem.find(u8, report_out.written(), "decode") != null);

    const golden_created = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/decode.txt",
        "decode-ok\n",
        .{ .update = true, .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(
        harnessz.golden.Outcome.created,
        golden_created.outcome,
    );
    const golden_matched = try harnessz.golden.expectFile(
        io,
        tmp.dir,
        "golden/decode.txt",
        "decode-ok\n",
        .{ .allocator = alloc, .report = false },
    );
    try std.testing.expectEqual(
        harnessz.golden.Outcome.matched,
        golden_matched.outcome,
    );

    const manifest_json =
        \\{"entries":[{"id":"decode","status":"implemented","implementation_paths":["golden/decode.txt"],"test_names":["decode bench"],"evidence_paths":["golden/decode.txt"]}]}
    ;
    var manifest = try harnessz.evidence.Manifest.fromJson(alloc, manifest_json);
    defer manifest.deinit();
    var paths = try manifest.validatePaths(io, tmp.dir);
    defer paths.deinit();
    try std.testing.expect(paths.valid());

    const known = [_][]const u8{"decode bench"};
    var tests = try manifest.validateTests(&known);
    defer tests.deinit();
    try std.testing.expect(tests.valid());

    const first_hash = try harnessz.provenance.hashTreeHex(alloc, io, tmp.dir, .{});
    defer alloc.free(first_hash);
    const second_hash = try harnessz.provenance.hashTreeHex(alloc, io, tmp.dir, .{});
    defer alloc.free(second_hash);
    try std.testing.expectEqualStrings(first_hash, second_hash);
}

//! Process-isolated benchmark suites: one child process per benchmark.
//!
//! `bench.runSuite` runs every registered benchmark in one process. That is
//! convenient but a crash, hang, or allocator corruption in one benchmark can
//! stop the whole run. `process_suite.run` spawns the benchmark child once per
//! name instead, records per-benchmark failures, and continues with the next
//! name. The child protocol and timeout/cleanup behavior come from
//! `bench.process`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bench = @import("../bench.zig");
const process_mod = @import("process.zig");
const stats = @import("../stats.zig");
const baseline = @import("../baseline.zig");

pub const Options = struct {
    /// Full argv for the child executable, including the executable path at
    /// index zero.
    argv: []const []const u8,
    /// Benchmark names to run, in order. Names must be registered in the
    /// child's registry.
    names: []const []const u8,
    run: bench.Options = .{},
    /// Zero disables the per-benchmark watchdog.
    timeout_ns: u64 = 0,
    max_output_bytes: usize = 16 * 1024 * 1024,
    max_stderr_bytes: usize = 64 * 1024,
    /// Run at most this many names. Zero means all.
    max_benchmarks: usize = 0,
};

pub const Entry = struct {
    name: []const u8,
    samples_ns: []const u64 = &.{},
    summary: stats.Summary = .{},
    peak_rss_bytes: ?u64 = null,
    peak_allocated_bytes: ?u64 = null,
    checksum: ?u64 = null,
    /// Empty for a successful run. Benchmark failures carry the child's
    /// `error_name`; parent-side failures carry the Zig error name.
    error_name: []const u8 = "",
    error_message: []const u8 = "",
    timed_out: bool = false,
    exit_code: ?u8 = null,
    /// Bounded child stderr, retained for diagnostics. Not emitted in JSON.
    stderr: []const u8 = &.{},
    stderr_truncated: bool = false,

    pub fn ok(self: Entry) bool {
        return self.error_name.len == 0 and !self.timed_out;
    }
};

pub const Suite = struct {
    allocator: Allocator = std.heap.page_allocator,
    arena: ?*std.heap.ArenaAllocator = null,
    entries: []Entry = &.{},

    pub fn deinit(self: *Suite) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
        }
        self.* = undefined;
    }

    pub fn count(self: *const Suite) usize {
        return self.entries.len;
    }

    pub fn find(self: *const Suite, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn ok(self: Suite) bool {
        for (self.entries) |entry| {
            if (!entry.ok()) return false;
        }
        return true;
    }

    /// Borrow the suite's names and samples as baseline entries. Entries
    /// without samples are skipped.
    pub fn toEntries(
        self: *const Suite,
        alloc: Allocator,
        environment_fingerprint: []const u8,
    ) ![]baseline.Entry {
        var entry_count: usize = 0;
        for (self.entries) |entry| {
            if (entry.samples_ns.len != 0) entry_count += 1;
        }
        const entries = try alloc.alloc(baseline.Entry, entry_count);
        var index: usize = 0;
        for (self.entries) |entry| {
            if (entry.samples_ns.len == 0) continue;
            entries[index] = .{
                .name = entry.name,
                .environment_fingerprint = environment_fingerprint,
                .samples_ns = entry.samples_ns,
                .summary = entry.summary,
            };
            index += 1;
        }
        return entries;
    }

    /// Deterministic text table in the requested name order.
    pub fn writeText(self: *const Suite, writer: *std.Io.Writer) !void {
        try writer.writeAll(
            "benchmark\titerations\tmin_ns\tmedian_ns\tp90_ns\tpeak_rss_bytes\tpeak_allocated_bytes\tstatus\n",
        );
        for (self.entries) |entry| {
            if (entry.samples_ns.len == 0) {
                try writer.print(
                    "{s}\t0\t-\t-\t-\t-\t-\t{s}\n",
                    .{ entry.name, statusName(entry) },
                );
                continue;
            }
            const summary = entry.summary;
            try writer.print("{s}\t{d}\t{d:.2}\t{d:.2}\t{d:.2}\t", .{
                entry.name,
                entry.samples_ns.len,
                summary.min,
                summary.median,
                summary.p90,
            });
            if (entry.peak_rss_bytes) |rss| {
                try writer.print("{d}\t", .{rss});
            } else {
                try writer.writeAll("-\t");
            }
            if (entry.peak_allocated_bytes) |allocated| {
                try writer.print("{d}\t", .{allocated});
            } else {
                try writer.writeAll("-\t");
            }
            try writer.print("{s}\n", .{statusName(entry)});
        }
    }

    pub fn toText(self: *const Suite, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeText(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn writeJson(self: *const Suite, writer: *std.Io.Writer) !void {
        const EntryWire = struct {
            name: []const u8,
            iterations: usize,
            summary: stats.Summary,
            peak_rss_bytes: ?u64,
            peak_allocated_bytes: ?u64,
            checksum: ?u64,
            error_name: []const u8,
            error_message: []const u8,
            timed_out: bool,
            exit_code: ?u8,
            stderr_truncated: bool,
        };
        const Wire = struct {
            benchmarks: []const EntryWire,
        };

        const alloc = std.heap.page_allocator;
        const wires = try alloc.alloc(EntryWire, self.entries.len);
        defer alloc.free(wires);
        for (wires, 0..) |*wire, index| {
            const entry = self.entries[index];
            wire.* = .{
                .name = entry.name,
                .iterations = entry.samples_ns.len,
                .summary = entry.summary,
                .peak_rss_bytes = entry.peak_rss_bytes,
                .peak_allocated_bytes = entry.peak_allocated_bytes,
                .checksum = entry.checksum,
                .error_name = entry.error_name,
                .error_message = entry.error_message,
                .timed_out = entry.timed_out,
                .exit_code = entry.exit_code,
                .stderr_truncated = entry.stderr_truncated,
            };
        }

        try std.json.Stringify.value(Wire{ .benchmarks = wires }, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
        }, writer);
    }

    pub fn toJson(self: *const Suite, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        return out.toOwnedSlice();
    }
};

/// Run one child process per benchmark name. Benchmark failures, timeouts, and
/// parent-side process errors are recorded on the entry and do not stop the
/// remaining names.
pub fn run(alloc: Allocator, io: std.Io, options: Options) !Suite {
    if (options.argv.len == 0 or
        options.names.len == 0 or
        options.run.iterations == 0 or
        options.run.batch_size == 0)
    {
        return error.InvalidOptions;
    }

    const count = if (options.max_benchmarks == 0)
        options.names.len
    else
        @min(options.max_benchmarks, options.names.len);

    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const entries = try arena_alloc.alloc(Entry, count);

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const name = options.names[index];
        var entry: Entry = .{ .name = try arena_alloc.dupe(u8, name) };

        var result = process_mod.runProcessCapture(arena_alloc, io, .{
            .argv = options.argv,
            .benchmark = name,
            .warmup_iterations = options.run.warmup_iterations,
            .iterations = options.run.iterations,
            .batch_size = options.run.batch_size,
            .min_time_ns = options.run.min_time_ns,
            .timeout_ns = options.timeout_ns,
            .max_output_bytes = options.max_output_bytes,
            .max_stderr_bytes = options.max_stderr_bytes,
        }) catch |err| {
            entry.error_name = try arena_alloc.dupe(u8, @errorName(err));
            entries[index] = entry;
            continue;
        };

        // `result` and all of its slices live in the suite arena. Transfer
        // the slices into the entry and let `deinit` release the whole arena.
        entry.stderr = result.stderr;
        entry.stderr_truncated = result.stderr_truncated;
        entry.timed_out = result.timed_out;
        entry.exit_code = result.exit_code;

        if (result.timed_out) {
            entry.error_name = "Timeout";
        } else {
            const response = result.takeResponse();
            entry.samples_ns = response.samples_ns;
            entry.summary = stats.summarize(u64, response.samples_ns);
            entry.peak_rss_bytes = response.peak_rss_bytes;
            entry.peak_allocated_bytes = response.peak_allocated_bytes;
            entry.checksum = response.checksum;
            if (response.error_name) |error_name| {
                entry.error_name = error_name;
            } else if (response.samples_ns.len == 0) {
                entry.error_name = "EmptyResponse";
            }
            if (response.error_message) |message| {
                entry.error_message = message;
            }
        }

        entries[index] = entry;
    }

    return .{
        .allocator = alloc,
        .arena = arena,
        .entries = entries,
    };
}

fn statusName(entry: Entry) []const u8 {
    if (entry.timed_out) return "TIMEOUT";
    if (entry.error_name.len != 0) return entry.error_name;
    return "OK";
}

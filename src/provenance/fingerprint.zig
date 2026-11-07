//! Stable environment fingerprints for baseline entries.
//!
//! The fingerprint combines the target, CPU identity, build mode, source and
//! binary hashes, commit, dirty state, and a caller-supplied tag. Its string
//! format is opaque; callers should compare fingerprints for equality rather
//! than parse them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const FingerprintOptions = struct {
    build_mode: []const u8 = "",
    source_hash: []const u8 = "",
    binary_hash: []const u8 = "",
    commit: []const u8 = "",
    dirty: bool = false,
    extra: []const u8 = "",
};

/// Build a stable environment fingerprint for `baseline.Entry`.
///
/// Linux probes for the CPU model and scaling governor; unsupported or
/// unreadable probes become `unknown` instead of failing the fingerprint.
pub fn fingerprint(
    alloc: Allocator,
    io: std.Io,
    options: FingerprintOptions,
) ![]u8 {
    const model = cpuModel(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (model) |value| alloc.free(value);

    const governor = cpuGovernor(alloc, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (governor) |value| alloc.free(value);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    return std.fmt.allocPrint(
        alloc,
        "{s}/{s}/cpu{d}/{s}/gov={s}/mode={s}/src={s}/bin={s}/commit={s}{s}/extra={s}",
        .{
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            cpu_count,
            model orelse "unknown",
            governor orelse "unknown",
            options.build_mode,
            options.source_hash,
            options.binary_hash,
            options.commit,
            if (options.dirty) "+dirty" else "",
            options.extra,
        },
    );
}

/// CPU model name from `/proc/cpuinfo`. Linux only; other platforms return
/// `error.Unsupported`.
pub fn cpuModel(alloc: Allocator, io: std.Io) ![]u8 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;

    const bytes = try readAbsolute(alloc, io, "/proc/cpuinfo", 1024 * 1024);
    defer alloc.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (value.len == 0) continue;
        return alloc.dupe(u8, value);
    }
    return error.Unsupported;
}

/// CPU scaling governor for CPU 0. Linux only; other platforms or missing
/// cpufreq data return `error.Unsupported`.
pub fn cpuGovernor(alloc: Allocator, io: std.Io) ![]u8 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;

    const bytes = readAbsolute(
        alloc,
        io,
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
        4096,
    ) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        => return error.Unsupported,
        else => return err,
    };
    defer alloc.free(bytes);

    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return error.Unsupported;
    return alloc.dupe(u8, value);
}

fn readAbsolute(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    return reader.interface.allocRemaining(alloc, .limited(limit));
}

test "provenance fingerprint: stable and includes caller fields" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const options: FingerprintOptions = .{
        .build_mode = "ReleaseFast",
        .source_hash = "source123",
        .binary_hash = "binary456",
        .commit = "deadbeef",
        .dirty = true,
        .extra = "local",
    };

    const first = try fingerprint(alloc, io, options);
    defer alloc.free(first);
    const second = try fingerprint(alloc, io, options);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);

    try std.testing.expect(std.mem.find(u8, first, "mode=ReleaseFast") != null);
    try std.testing.expect(std.mem.find(u8, first, "src=source123") != null);
    try std.testing.expect(std.mem.find(u8, first, "bin=binary456") != null);
    try std.testing.expect(std.mem.find(u8, first, "commit=deadbeef+dirty") != null);
    try std.testing.expect(std.mem.find(u8, first, "extra=local") != null);

    const other = try fingerprint(alloc, io, .{
        .build_mode = "ReleaseFast",
        .source_hash = "source123",
        .binary_hash = "binary456",
        .commit = "deadbeef",
        .dirty = true,
        .extra = "other",
    });
    defer alloc.free(other);
    try std.testing.expect(!std.mem.eql(u8, first, other));
}

test "provenance fingerprint: Linux CPU probes or unsupported" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const model = cpuModel(alloc, io) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(model);
    try std.testing.expect(model.len > 0);

    const governor = cpuGovernor(alloc, io) catch |err| switch (err) {
        error.Unsupported => return,
        else => return err,
    };
    defer alloc.free(governor);
    try std.testing.expect(governor.len > 0);
}

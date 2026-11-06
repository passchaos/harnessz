//! Timeout watchdog and process-tree termination for isolated benchmarks.
//!
//! The watchdog runs on a dedicated `std.Thread` so timeouts do not depend on
//! `Io.concurrent`. When a thread cannot be started, the parent runner falls
//! back to `Io.concurrent`; only when both mechanisms are unavailable does the
//! runner return `error.TimeoutUnavailable`.
//!
//! On POSIX the child is placed in its own process group, so the watchdog
//! terminates the whole group (`kill(-pid, SIGKILL)`) instead of only the
//! direct child. This prevents sleeping or helper grandchildren from being
//! leaked by a timeout. Windows terminates the direct child only; the
//! process-tree guarantee is POSIX-only.

const std = @import("std");
const builtin = @import("builtin");

/// True on platforms with POSIX process groups and signal delivery. `std.c`
/// declares POSIX-looking functions on Windows, so `@hasDecl` alone is not a
/// reliable gate.
pub const posix_process_control = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding, .other, .plan9, .psp => false,
    else => true,
};

/// Poll granularity while waiting for the timeout or an early `finish`.
/// Zig 0.16's `std.Io.Condition` has no timed wait, so the watchdog polls an
/// atomic flag in short OS-level sleeps. Join latency is bounded by this value.
const poll_slice_ns: u64 = 2 * std.time.ns_per_ms;

pub const Watchdog = struct {
    /// Direct child id copied from `std.process.Child.id`. The watchdog never
    /// touches the `Child` value itself, which stays owned by the main task.
    child_id: std.process.Child.Id,
    timeout_ns: u64,
    /// Set when the watchdog runs through `Io.concurrent`; in that case sleeps
    /// go through `io.sleep` instead of blocking an OS thread.
    use_io_sleep: bool = false,
    io: std.Io = undefined,

    finished: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    /// Watchdog body. Safe to run on a `std.Thread` or through
    /// `Io.concurrent`.
    pub fn run(self: *Watchdog) void {
        var remaining = self.timeout_ns;
        while (remaining > 0) {
            if (self.finished.load(.acquire)) return;
            const step = @min(remaining, poll_slice_ns);
            if (self.use_io_sleep) {
                self.io.sleep(std.Io.Duration.fromNanoseconds(@intCast(step)), .awake) catch return;
            } else {
                sleepNs(step);
            }
            if (self.finished.load(.acquire)) return;
            remaining -= step;
        }
        self.fired.store(true, .release);
        terminateProcessGroup(self.child_id);
    }

    /// Ask the watchdog to stop without firing. The caller still joins the
    /// watchdog task.
    pub fn finish(self: *Watchdog) void {
        self.finished.store(true, .release);
    }
};

/// Kill the whole process group rooted at `child_id` on POSIX. Falls back to
/// the direct child when the group is already gone. On Windows only the direct
/// process is terminated because Zig 0.16 does not expose job-object helpers.
pub fn terminateProcessGroup(child_id: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(child_id, @enumFromInt(1));
    } else if (comptime posix_process_control) {
        const pid: std.posix.pid_t = child_id;
        std.posix.kill(-pid, .KILL) catch {
            std.posix.kill(pid, .KILL) catch {};
        };
    }
}

fn sleepNs(ns: u64) void {
    if (comptime builtin.os.tag == .windows) {
        const Sleep = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        const rounded = @max(@as(u64, 1), (ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        Sleep.Sleep(@intCast(@min(rounded, std.math.maxInt(u32))));
        return;
    }
    if (comptime @hasDecl(std.posix.system, "nanosleep")) {
        var request: std.posix.timespec = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.posix.system.nanosleep(&request, null);
    }
}

test "watchdog: finish prevents a long timeout from firing" {
    if (comptime posix_process_control) {
        const child_id: std.process.Child.Id = if (comptime builtin.os.tag == .linux)
            std.os.linux.getpid()
        else if (comptime @hasDecl(std.posix.system, "getpid"))
            std.posix.system.getpid()
        else
            undefined; // The watchdog is finished before it can fire.
        var watchdog: Watchdog = .{
            .child_id = child_id,
            .timeout_ns = 60 * std.time.ns_per_s,
        };
        const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
        watchdog.finish();
        thread.join();
        try std.testing.expect(!watchdog.fired.load(.acquire));
    } else {
        return error.SkipZigTest;
    }
}

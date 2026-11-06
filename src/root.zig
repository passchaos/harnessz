//! harnessz: shared golden, snapshot, oracle, determinism, and benchmark
//! infrastructure for Project-Z.

pub const golden = @import("golden.zig");
pub const snapshot = @import("snapshot.zig");
pub const oracle = @import("oracle.zig");
pub const determinism = @import("determinism.zig");
pub const stats = @import("stats.zig");
pub const bench = @import("bench.zig");
pub const fixture = @import("fixture.zig");
pub const evidence = @import("evidence.zig");

pub const diff = @import("diff.zig");
pub const env = @import("env.zig");
pub const paths = @import("paths.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

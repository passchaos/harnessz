//! harnessz: shared golden, snapshot, oracle, determinism, benchmark,
//! baseline, and evidence infrastructure for Project-Z.

pub const golden = @import("golden.zig");
pub const snapshot = @import("snapshot.zig");
pub const oracle = @import("oracle.zig");
pub const determinism = @import("determinism.zig");
pub const stats = @import("stats.zig");
pub const bench = @import("bench.zig");
pub const baseline = @import("baseline.zig");
pub const fixture = @import("fixture.zig");
pub const evidence = @import("evidence.zig");

pub const diff = @import("diff.zig");
pub const env = @import("env.zig");
pub const json_canon = @import("json_canon.zig");
pub const paths = @import("paths.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

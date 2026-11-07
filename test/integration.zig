//! Package-level integration tests for the public `harnessz` module.
//!
//! Tests are grouped by subsystem; this root only wires the files into the
//! package test binary.

test {
    _ = @import("core.zig");
    _ = @import("process.zig");
    _ = @import("workflow.zig");
}

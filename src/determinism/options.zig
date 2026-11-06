//! Shared options for sequential and threaded determinism runs.

pub const Options = struct {
    /// Number of baseline executions at thread count 1. Must be at least 1.
    /// `runThreaded` does not use this field.
    runs: usize = 3,
    /// Maximum accepted output size per execution.
    max_bytes: usize = 16 * 1024 * 1024,
    /// Additional thread counts to exercise. Empty disables the matrix for
    /// `run`; `runThreaded` requires at least one entry.
    thread_counts: []const usize = &.{},
    /// Executions per thread count in the matrix, or per thread-count case
    /// for `runThreaded`.
    thread_runs: usize = 1,
};

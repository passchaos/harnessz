//! Shared summary shape used by batch statistics and streaming accumulators.

pub const Summary = struct {
    count: usize = 0,
    min: f64 = 0,
    max: f64 = 0,
    mean: f64 = 0,
    stddev: f64 = 0,
    median: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
};

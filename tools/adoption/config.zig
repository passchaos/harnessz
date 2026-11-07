//! Shared configuration for the adoption evidence tool.

pub const Config = struct {
    trials: usize = 40,
    samples: usize = 15,
    iterations: usize = 20,
    warmup: usize = 3,
    jitter_percent: u64 = 20,
    seed: u64 = 1,
};

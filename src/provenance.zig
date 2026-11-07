//! Benchmark provenance: source/artifact hashing and a stable fingerprint for
//! baseline storage.
//!
//! The module is split into three focused submodules:
//!
//! - `provenance/hash.zig` — SHA-256 of bytes, files, and verified snapshots
//! - `provenance/tree.zig` — deterministic bounded directory traversal
//! - `provenance/fingerprint.zig` — environment fingerprints and Linux probes
//!
//! The fingerprint is an opaque tag intended for
//! `baseline.Entry.environment_fingerprint`. It combines the target, CPU
//! identity, build mode, source/binary hashes, commit, dirty state, and a
//! caller-supplied extra tag. Equality is the only supported operation; the
//! exact string format is not a stable API.

const std = @import("std");

const hash = @import("provenance/hash.zig");
const tree = @import("provenance/tree.zig");
const fingerprint_mod = @import("provenance/fingerprint.zig");

pub const Hash = hash.Hash;
pub const hashBytes = hash.hashBytes;
pub const hashBytesHex = hash.hashBytesHex;
pub const hashFile = hash.hashFile;
pub const hashFileHex = hash.hashFileHex;
pub const hexAlloc = hash.hexAlloc;
pub const LoadOptions = hash.LoadOptions;
pub const VerifiedFile = hash.VerifiedFile;
pub const loadVerifiedFile = hash.loadVerifiedFile;

pub const TreeOptions = tree.TreeOptions;
pub const hashTree = tree.hashTree;
pub const hashTreeHex = tree.hashTreeHex;
pub const listTree = tree.listTree;

pub const FingerprintOptions = fingerprint_mod.FingerprintOptions;
pub const fingerprint = fingerprint_mod.fingerprint;
pub const cpuModel = fingerprint_mod.cpuModel;
pub const cpuGovernor = fingerprint_mod.cpuGovernor;

test {
    // Force analysis of the submodules so their tests run with the package
    // test suite.
    std.testing.refAllDecls(hash);
    std.testing.refAllDecls(tree);
    std.testing.refAllDecls(fingerprint_mod);
}

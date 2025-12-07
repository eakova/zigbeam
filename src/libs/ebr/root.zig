//! EBR (Epoch-Based Reclamation) - High-Throughput Memory Reclamation for Zig
//!
//! A production-ready, lock-free memory reclamation library targeting:
//! - >1 Gops/sec throughput per thread
//! - <5ns p99 latency for pin/unpin operations
//! - <32 bytes memory overhead per protected pointer
//!
//! ## Quick Start
//!
//! ```zig
//! const ebr = @import("ebr");
//!
//! var collector = try ebr.Collector.init(allocator);
//! defer collector.deinit();
//!
//! const handle = try collector.registerThread();
//! defer collector.unregisterThread(handle);
//!
//! // Critical section
//! const guard = collector.pin();
//! defer guard.unpin();
//!
//! // Safe to access protected data here
//! ```

const std = @import("std");
const helpers = @import("helpers");

// Core modules (using module imports)
pub const epoch = @import("epoch");
pub const guard = @import("guard");
pub const thread_local = @import("thread_local");
pub const reclaim = @import("reclaim");

// Re-export main types
const ebr_mod = @import("ebr");
pub const Collector = ebr_mod.Collector;
pub const CollectorType = ebr_mod.CollectorType;
pub const CollectorConfig = ebr_mod.CollectorConfig;
pub const makeDtor = ebr_mod.makeDtor;
pub const Guard = guard.Guard;
pub const FastGuard = guard.FastGuard;
pub const ThreadHandle = thread_local.ThreadHandle;
pub const DtorFn = reclaim.DtorFn;

// Advanced types (for inspection/customization)
pub const GlobalState = epoch.GlobalState;
pub const ThreadLocalState = thread_local.ThreadLocalState;
pub const DeferredSimple = reclaim.DeferredSimple;
pub const EpochBucketedBag = reclaim.EpochBucketedBag;

// Utility constants (for building cache-aligned structures)
pub const cache_line = helpers.cache_line;
pub const CacheLinePadding = helpers.CacheLinePadding;

// Tests
test {
    std.testing.refAllDecls(@This());
}

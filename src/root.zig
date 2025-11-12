//! Root wrapper that re-exports every public module in the utils library.
//! By importing this file, consumers (and internal tools like benchmarks)
//! gain access to the entire surface area via a single namespace.

const tagged_pointer = @import("tagged_pointer");
const thread_local_cache = @import("thread_local_cache");
const arc = @import("arc_core");
const arc_pool = @import("arc_pool");
const arc_cycle_detector = @import("arc_cycle_detector");

// Public entry under a single namespace. Consumers use:
// const beam = @import("zig_beam");
// const ArcU64 = beam.Utils.Arc(u64);
pub const Utils = struct {
    pub const TaggedPointer = tagged_pointer.TaggedPointer;
    pub const ThreadLocalCache = thread_local_cache.ThreadLocalCache;
    pub const ThreadLocalCacheWithCapacity = thread_local_cache.ThreadLocalCacheWithCapacity;
    pub const ThreadLocalCacheWithOptions = thread_local_cache.ThreadLocalCacheWithOptions;
    pub const Arc = arc.Arc;
    pub const ArcWeak = arc.ArcWeak;
    pub const ArcPool = arc_pool.ArcPool;
    // ArcPoolWithCapacity was removed in favor of ArcPool + Options
    pub const ArcCycleDetector = arc_cycle_detector.ArcCycleDetector;
};

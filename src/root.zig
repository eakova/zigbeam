//! Root wrapper that re-exports every public module in the libs library.
//! By importing this file, consumers (and internal tools like benchmarks)
//! gain access to the entire surface area via a single namespace.

const loom = @import("loom");
const tagged_pointer = @import("tagged-pointer");
const thread_local_cache = @import("thread-local-cache");
const arc = @import("arc");
const arc_pool = @import("arc-pool");
const arc_cycle_detector = @import("arc-cycle");
const backoff = @import("backoff");
const dvyukov_mpmc_queue = @import("dvyukov-mpmc");
const sharded_dvyukov_mpmc_queue = @import("sharded-dvyukov-mpmc");
const deque = @import("deque");
const deque_channel = @import("deque-channel");
const spsc_queue = @import("spsc-queue");
const segmented_queue = @import("segmented-queue");
const task = @import("task");
const cache_padded = @import("cache-padded");
const ebr = @import("ebr");

// Loom - High-Performance Work-Stealing Thread Pool with Parallel Iterators
// Framework that orchestrates primitives (not a primitive itself)
pub const Loom = loom;

// Public entry under a single namespace. Consumers use:
// const beam = @import("zigbeam");
// const ArcU64 = beam.Libs.Arc(u64);
pub const Libs = struct {
    pub const TaggedPointer = tagged_pointer.TaggedPointer;
    pub const ThreadLocalCache = thread_local_cache.ThreadLocalCache;
    pub const ThreadLocalCacheWithCapacity = thread_local_cache.ThreadLocalCacheWithCapacity;
    pub const ThreadLocalCacheWithOptions = thread_local_cache.ThreadLocalCacheWithOptions;
    pub const Arc = arc.Arc;
    pub const ArcWeak = arc.ArcWeak;
    pub const ArcPool = arc_pool.ArcPool;
    // ArcPoolWithCapacity was removed in favor of ArcPool + Options
    pub const ArcCycleDetector = arc_cycle_detector.ArcCycleDetector;

    // Backoff
    pub const Backoff = backoff.Backoff;

    // DVyukov MPMC Queues
    pub const DVyukovMPMCQueue = dvyukov_mpmc_queue.DVyukovMPMCQueue;
    pub const ShardedDVyukovMPMCQueue = sharded_dvyukov_mpmc_queue.ShardedDVyukovMPMCQueue;

    // Deque - High-Performance Work-Stealing
    pub const Deque = deque.Deque;
    pub const DequeChannel = deque_channel.DequeChannel;

    // Bounded SPSC Queue - Lock-Free Point-to-Point Communication
    pub const BoundedSPSCQueue = spsc_queue.BoundedSPSCQueue;

    // Segmented Queue - Unbounded MPMC Queue with Dynamic Growth
    pub const SegmentedQueue = segmented_queue.SegmentedQueue;

    // Task - Cancellable OS-thread task abstraction
    pub const Task = task.Task;

    // CachePadded - Cache-line aware padding helpers
    pub const CachePadded = cache_padded.CachePadded;

    // EBR - Epoch-Based Reclamation
    pub const Ebr = ebr;
};

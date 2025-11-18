//! Root wrapper that re-exports every public module in the libs library.
//! By importing this file, consumers (and internal tools like benchmarks)
//! gain access to the entire surface area via a single namespace.

const tagged_pointer = @import("tagged_pointer");
const thread_local_cache = @import("thread_local_cache");
const arc = @import("arc_core");
const arc_pool = @import("arc_pool");
const arc_cycle_detector = @import("arc_cycle_detector");
const ebr = @import("epoch_based_reclamation");
const backoff = @import("backoff");
const dvyukov_mpmc_queue = @import("dvyukov_mpmc");
const sharded_dvyukov_mpmc_queue = @import("sharded_dvyukov_mpmc");
const beam_deque = @import("beam_deque");
const beam_deque_channel = @import("beam_deque_channel");
const deque = @import("deque");
const deque_pool = @import("deque_pool");
const task = @import("task");

// Public entry under a single namespace. Consumers use:
// const beam = @import("zig_beam");
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

    // Beam Deque - High-Performance Work-Stealing
    pub const BeamDeque = beam_deque.BeamDeque;
    pub const BeamDequeChannel = beam_deque_channel.BeamDequeChannel;
};

pub const Protos = struct {
    // Epoch-Based Reclamation (Prototype)
    pub const EBR = ebr.EBR;
    pub const ThreadState = ebr.ThreadState;
    pub const Guard = ebr.Guard;
    pub const pin = ebr.pin;
    pub const AtomicPtr = ebr.AtomicPtr;
    pub const RetiredNode = ebr.RetiredNode;
    pub const RetiredList = ebr.RetiredList;

    // Work-Stealing Deque & Thread Pool (Legacy Prototypes)
    pub const WorkStealingDeque = deque.WorkStealingDeque;
    pub const WorkStealingPool = deque_pool.WorkStealingPool;
    pub const Task = task.Task;
};

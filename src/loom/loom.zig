// ZigParallel - Rayon-like Data Parallelism Library for Zig
//
// A high-performance work-stealing thread pool with structured concurrency.
// Built on the mpmc library primitives (Deque, BoundedMpmcQueue, DequeChannel, Backoff).
//
// Architecture:
// - Layer 1: mpmc primitives (Deque, BoundedMpmcQueue, DequeChannel, Backoff)
// - Layer 2: ThreadPool, Worker, Task (this layer)
// - Layer 3: Fork-Join primitives (join, scope, spawn)
// - Layer 4: Parallel Iterators (par_iter, map, reduce, filter, for_each)
//
// Usage:
// ```zig
// const zigparallel = @import("loom");
//
// // Binary fork-join
// const left, const right = zigparallel.join(taskA, .{}, taskB, .{});
//
// // Scoped spawning
// zigparallel.scope(struct {
//     fn body(s: *zigparallel.Scope) void {
//         s.spawn(process, .{item1});
//         s.spawn(process, .{item2});
//     }
// }.body);
//
// // Parallel iteration
// items.par_iter().for_each(process);
// ```

const std = @import("std");

// ============================================================================
// Layer 1: mpmc primitives (re-exported for convenience)
// ============================================================================

// Re-export beam libs for convenience
pub const backoff = @import("backoff");
pub const deque_channel = @import("deque-channel");

// ============================================================================
// Layer 2: Thread Pool
// ============================================================================

pub const thread_pool = @import("pool/thread_pool.zig");
pub const Task = thread_pool.Task;
pub const ThreadPoolFn = thread_pool.ThreadPoolFn;
pub const ThreadPool = thread_pool.ThreadPool;
pub const Config = thread_pool.Config;
pub const InitConfig = thread_pool.InitConfig;
pub const BackoffMode = thread_pool.BackoffMode;
pub const PoolState = thread_pool.PoolState;
pub const WorkerStats = thread_pool.WorkerStats;
pub const getGlobalPool = thread_pool.getGlobalPool;
pub const getCurrentWorkerId = thread_pool.getCurrentWorkerId;
pub const getCurrentPool = thread_pool.getCurrentPool;

// ============================================================================
// Layer 3: Fork-Join Primitives
// ============================================================================

pub const join_module = @import("util/join.zig");
pub const join = join_module.join;
pub const joinOnPool = join_module.joinOnPool;
pub const JoinHandle = join_module.JoinHandle;

pub const scope_module = @import("pool/scope.zig");
pub const scope = scope_module.scope;
pub const scopeOnPool = scope_module.scopeOnPool;
pub const Scope = scope_module.Scope;
pub const SpawnHandle = scope_module.SpawnHandle;
pub const getCurrentScope = scope_module.getCurrentScope;

// ============================================================================
// Layer 4: Parallel Iterators
// ============================================================================

pub const splitter_mod = @import("util/splitter.zig");
pub const Splitter = splitter_mod.Splitter;
pub const SplitMode = splitter_mod.SplitMode;
pub const ChunkIterator = splitter_mod.ChunkIterator;

pub const reducer_mod = @import("util/reducer.zig");
pub const Reducer = reducer_mod.Reducer;
pub const BoolReducer = reducer_mod.BoolReducer;

pub const parallel_iter_mod = @import("iter/par_iter.zig");
pub const ParallelIterator = parallel_iter_mod.ParallelIterator;
pub const SteppedIterator = parallel_iter_mod.SteppedIterator;
pub const ContextParallelIterator = parallel_iter_mod.ContextParallelIterator;
pub const RangeParallelIterator = parallel_iter_mod.RangeParallelIterator;
pub const ContextRangeParallelIterator = parallel_iter_mod.ContextRangeParallelIterator;
pub const par_iter = parallel_iter_mod.par_iter;
pub const par_iter_const = parallel_iter_mod.par_iter_const;
pub const par_range = parallel_iter_mod.par_range;

// ============================================================================
// Tests
// ============================================================================

test {
    _ = thread_pool;
    _ = join_module;
    _ = scope_module;
    _ = splitter_mod;
    _ = reducer_mod;
    _ = parallel_iter_mod;
}

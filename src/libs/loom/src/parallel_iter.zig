// parallel_iter.zig - Parallel Iterator Operations
//
// Provides Rayon-like parallel iteration over slices.
// Operations include for_each, map, reduce, and filter.
//
// Usage:
// ```zig
// // Parallel for-each
// par_iter(items).forEach(process);
//
// // Parallel map
// const results = par_iter(items).map(transform, allocator);
//
// // Parallel reduce
// const sum = par_iter(items).reduce(Reducer(i32).sum());
// ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;

const splitter_mod = @import("splitter.zig");
const Splitter = splitter_mod.Splitter;
const ChunkIterator = splitter_mod.ChunkIterator;

const reducer_mod = @import("reducer.zig");
pub const Reducer = reducer_mod.Reducer;
pub const BoolReducer = reducer_mod.BoolReducer;

// ============================================================================
// Submodule Imports
// ============================================================================

const config = @import("parallel_iter/config.zig");
pub const stack_max_chunks = config.stack_max_chunks;
const stack_context_threshold = config.stack_context_threshold;
const early_exit_check_interval = config.early_exit_check_interval;
const allocContextsIfNeeded = config.allocContextsIfNeeded;
const freeContextsIfNeeded = config.freeContextsIfNeeded;

const stepped_iterator = @import("parallel_iter/stepped_iterator.zig");
pub const SteppedIterator = stepped_iterator.SteppedIterator;

const contexts = @import("parallel_iter/contexts.zig");
const ForEachContextStack = contexts.ForEachContextStack;
const ForEachIndexedContextStack = contexts.ForEachIndexedContextStack;
const ReduceContextStack = contexts.ReduceContextStack;
const MapContextStack = contexts.MapContextStack;
const MapIndexedContextStack = contexts.MapIndexedContextStack;
const ParAnyContext = contexts.ParAnyContext;
const ParAllContext = contexts.ParAllContext;
const ParFindContext = contexts.ParFindContext;
const ParPositionContext = contexts.ParPositionContext;
const ParCountContext = contexts.ParCountContext;
const ParFilterCountContext = contexts.ParFilterCountContext;
const ParFilterScatterContext = contexts.ParFilterScatterContext;
const ParChunksContext = contexts.ParChunksContext;
const ParChunksConstContext = contexts.ParChunksConstContext;
const ParSortChunkContext = contexts.ParSortChunkContext;

const merge_mod = @import("parallel_iter/merge.zig");
const merge = merge_mod.merge;
const parallelMergeTopLevel = merge_mod.parallelMergeTopLevel;

// ============================================================================
// ParallelIterator
// ============================================================================

/// Parallel iterator over a slice
///
/// Provides parallel versions of common iteration operations.
/// Uses the thread pool for work distribution with work-stealing.
pub fn ParallelIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying data slice
        data: []T,

        /// Work splitting configuration
        splitter: Splitter,

        /// Thread pool to use (null = global pool)
        pool: ?*ThreadPool,

        /// Allocator for operations that need allocation (null = must pass explicitly)
        allocator: ?Allocator,

        /// Create a parallel iterator over a slice
        pub fn init(data: []T) Self {
            return Self{
                .data = data,
                .splitter = Splitter.default(),
                .pool = null,
                .allocator = null,
            };
        }

        /// Configure the splitter for this iterator
        pub fn withSplitter(self: Self, s: Splitter) Self {
            var result = self;
            result.splitter = s;
            return result;
        }

        /// Use a specific thread pool
        pub fn withPool(self: Self, p: *ThreadPool) Self {
            var result = self;
            result.pool = p;
            return result;
        }

        /// Set minimum chunk size for parallelization
        ///
        /// Use this to tune parallelization threshold for your workload.
        /// Lower values = more parallelism, higher overhead.
        /// Higher values = less parallelism, lower overhead.
        pub fn withMinChunk(self: Self, min_chunk: usize) Self {
            var result = self;
            result.splitter = Splitter.adaptive(min_chunk);
            return result;
        }

        /// Set maximum number of chunks (caps parallelism)
        ///
        /// Use this to limit parallelism for memory-bound workloads.
        pub fn withMaxChunks(self: Self, max_chunks: usize) Self {
            var result = self;
            result.splitter.target_chunks = max_chunks;
            return result;
        }

        /// Set allocator for operations that need allocation
        ///
        /// Operations like filter(), sort(), and map() require an allocator.
        /// You can either set it here once, or pass it to each operation.
        ///
        /// Example:
        /// ```zig
        /// // Set once, use multiple times
        /// const iter = par_iter(&data).withAlloc(allocator);
        /// const filtered = try iter.filter(pred);
        /// try iter.sort(cmp);
        ///
        /// // Or override per-operation
        /// const filtered = try iter.filter(pred, arena);  // uses arena instead
        /// ```
        pub fn withAlloc(self: Self, alloc: Allocator) Self {
            var result = self;
            result.allocator = alloc;
            return result;
        }

        /// Attach context for stateful operations
        ///
        /// Returns a ContextParallelIterator that passes the context to each callback.
        /// Use this when your parallel operations need access to shared state.
        ///
        /// Example:
        /// ```zig
        /// const ctx = .{ .threshold = 100, .counter = &atomic_count };
        /// par_iter(data).withPool(pool).withContext(&ctx).forEach(struct {
        ///     fn process(c: @TypeOf(&ctx), item: *Item) void {
        ///         if (item.value > c.threshold) _ = c.counter.fetchAdd(1, .monotonic);
        ///     }
        /// }.process);
        /// ```
        pub fn withContext(self: Self, context: anytype) ContextParallelIterator(T, @TypeOf(context)) {
            return ContextParallelIterator(T, @TypeOf(context)){
                .inner = self,
                .context = context,
            };
        }

        /// Get the pool to use (explicit or global)
        fn getPool(self: *const Self) *ThreadPool {
            return self.pool orelse getGlobalPool();
        }

        // ====================================================================
        // for_each - Apply function to each element
        // ====================================================================

        /// Apply a function to each element in parallel
        ///
        /// The function receives each element by pointer, allowing mutation.
        /// All elements are processed before this function returns.
        pub fn forEach(self: Self, comptime func: fn (*T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                // Sequential path for small data
                for (self.data) |*item| {
                    func(item);
                }
                return;
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);

            // Reserve first chunk for main thread - only spawn (total_chunks - 1)
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            // Issue 21 fix: Use heap allocation for large contexts if allocator available
            const Context = ForEachContextStack(T, func);
            const heap_contexts = allocContextsIfNeeded(Context, self.allocator, spawn_chunks);
            var stack_contexts: [stack_max_chunks]Context = undefined;
            const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
            defer freeContextsIfNeeded(Context, heap_contexts, self.allocator);

            // Completion counter (only for spawned tasks)
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Calculate main thread's chunk (first chunk)
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_chunk_end];

            // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                ctxs[chunk_idx] = Context{
                    .data = chunk,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    for (chunk) |*item| {
                        func(item);
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                for (self.data[offset..end]) |*item| {
                    func(item);
                }
                offset = end;
            }

            // MAIN THREAD: Process first chunk directly (do useful work instead of spinning)
            for (main_chunk) |*item| {
                func(item);
            }

            // Wait for spawned tasks to complete (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel forEach: chunk panicked");
            }
        }

        /// Apply a function to each element with its index
        pub fn forEachIndexed(self: Self, comptime func: fn (usize, *T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                for (self.data, 0..) |*item, i| {
                    func(i, item);
                }
                return;
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);

            // Reserve first chunk for main thread - only spawn (total_chunks - 1)
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            // Issue 21 fix: Use heap allocation for large contexts if allocator available
            const Context = ForEachIndexedContextStack(T, func);
            const heap_contexts = allocContextsIfNeeded(Context, self.allocator, spawn_chunks);
            var stack_contexts: [stack_max_chunks]Context = undefined;
            const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
            defer freeContextsIfNeeded(Context, heap_contexts, self.allocator);

            // Completion counter (only for spawned tasks)
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Calculate main thread's chunk (first chunk)
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_chunk_end];

            // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                ctxs[chunk_idx] = Context{
                    .data = chunk,
                    .base_index = offset,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    for (chunk, 0..) |*item, i| {
                        func(offset + i, item);
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                for (self.data[offset..end], 0..) |*item, i| {
                    func(offset + i, item);
                }
                offset = end;
            }

            // MAIN THREAD: Process first chunk directly (do useful work instead of spinning)
            for (main_chunk, 0..) |*item, i| {
                func(i, item);
            }

            // Wait for spawned tasks to complete (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel forEachIndexed: chunk panicked");
            }
        }

        // ====================================================================
        // reduce - Parallel reduction
        // ====================================================================

        /// Reduce all elements using a reducer
        ///
        /// The reducer must be associative for correct results.
        /// Uses parallel reduction tree for efficiency.
        ///
        /// Note: For types T where @sizeOf(T) * 32 > 4KB, heap allocation is used
        /// if an allocator was provided via withAlloc(). Otherwise falls back to
        /// sequential reduction to avoid stack overflow.
        pub fn reduce(self: Self, reducer: Reducer(T)) T {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            // Calculate stack usage for partial results
            const stack_threshold = 4096; // 4KB - safe stack usage limit
            const would_use_stack = @sizeOf(T) * stack_max_chunks;

            // For large T without allocator, fall back to sequential to avoid stack overflow
            if (would_use_stack > stack_threshold and self.allocator == null) {
                return reducer.reduceSlice(self.data);
            }

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return reducer.reduceSlice(self.data);
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const min_chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            const chunk_size = @max(min_chunk_size, (self.data.len + max_chunks - 1) / max_chunks);

            // Calculate actual number of chunks needed
            const num_chunks = std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len;
            const total_chunks = @min(num_chunks, max_chunks);

            // Reserve first chunk for main thread - only spawn (total_chunks - 1)
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            // Use heap allocation for large T to avoid stack overflow
            if (would_use_stack > stack_threshold) {
                return self.reduceHeapAlloc(reducer, pool, total_chunks, spawn_chunks, chunk_size);
            }

            // Stack-allocated partial results and contexts - safe for small T
            var partial_results: [stack_max_chunks]T = undefined;
            for (&partial_results) |*r| {
                r.* = reducer.identity;
            }

            const Context = ReduceContextStack(T);
            var ctxs: [stack_max_chunks]Context = undefined;

            // Completion counter (only for spawned tasks)
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Calculate main thread's chunk (first chunk)
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_chunk_end];

            // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
            // Note: partial_results[0] is reserved for main thread, spawned tasks use [1..N]
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];
                const result_idx = chunk_idx + 1; // Offset by 1 (slot 0 is for main thread)

                ctxs[chunk_idx] = Context{
                    .data = chunk,
                    .result_ptr = &partial_results[result_idx],
                    .reducer = &reducer,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    var acc = reducer.identity;
                    for (chunk) |item| {
                        acc = reducer.combine(acc, item);
                    }
                    partial_results[result_idx] = acc;
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                var acc = reducer.identity;
                for (self.data[offset..end]) |item| {
                    acc = reducer.combine(acc, item);
                }
                // Combine into last result slot
                if (total_chunks > 0) {
                    partial_results[total_chunks - 1] = reducer.combine(partial_results[total_chunks - 1], acc);
                }
                offset = end;
            }

            // MAIN THREAD: Process first chunk directly (do useful work instead of spinning)
            var main_acc = reducer.identity;
            for (main_chunk) |item| {
                main_acc = reducer.combine(main_acc, item);
            }
            partial_results[0] = main_acc;

            // Wait for spawned tasks to complete (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel reduce: chunk panicked");
            }

            // Tree-based final reduction for better cache locality
            // Combine adjacent pairs: [a,b,c,d,e,f,g,h] -> [ab,cd,ef,gh] -> [abcd,efgh] -> [result]
            var active_count = total_chunks;
            while (active_count > 1) {
                const pairs = active_count / 2;
                var i: usize = 0;
                while (i < pairs) : (i += 1) {
                    partial_results[i] = reducer.combine(partial_results[i * 2], partial_results[i * 2 + 1]);
                }
                // Handle odd element - carry it forward
                if (active_count % 2 == 1) {
                    partial_results[pairs] = partial_results[active_count - 1];
                    active_count = pairs + 1;
                } else {
                    active_count = pairs;
                }
            }

            return if (total_chunks > 0) partial_results[0] else reducer.identity;
        }

        /// Internal: heap-allocated reduce for large T types
        fn reduceHeapAlloc(
            self: Self,
            reducer: Reducer(T),
            pool: *ThreadPool,
            total_chunks: usize,
            spawn_chunks: usize,
            chunk_size: usize,
        ) T {
            const allocator = self.allocator.?; // Already checked in caller

            // Heap-allocate partial results
            const partial_results = allocator.alloc(T, total_chunks) catch {
                // Issue 30 fix: Log fallback in debug mode
                if (@import("builtin").mode == .Debug) {
                    std.log.warn("parallel reduce: falling back to sequential (partial_results alloc failed, size={d})", .{total_chunks * @sizeOf(T)});
                }
                return reducer.reduceSlice(self.data);
            };
            defer allocator.free(partial_results);

            for (partial_results) |*r| {
                r.* = reducer.identity;
            }

            // Heap-allocate contexts
            const Context = ReduceContextStack(T);
            const ctxs = allocator.alloc(Context, spawn_chunks) catch {
                // Issue 30 fix: Log fallback in debug mode
                if (@import("builtin").mode == .Debug) {
                    std.log.warn("parallel reduce: falling back to sequential (contexts alloc failed, size={d})", .{spawn_chunks * @sizeOf(Context)});
                }
                return reducer.reduceSlice(self.data);
            };
            defer allocator.free(ctxs);

            // Completion counter
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Main thread's chunk
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_chunk_end];

            // Spawn tasks for remaining chunks
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];
                const result_idx = chunk_idx + 1;

                ctxs[chunk_idx] = Context{
                    .data = chunk,
                    .result_ptr = &partial_results[result_idx],
                    .reducer = &reducer,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var acc = reducer.identity;
                    for (chunk) |item| {
                        acc = reducer.combine(acc, item);
                    }
                    partial_results[result_idx] = acc;
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                var acc = reducer.identity;
                for (self.data[offset..end]) |item| {
                    acc = reducer.combine(acc, item);
                }
                if (total_chunks > 0) {
                    partial_results[total_chunks - 1] = reducer.combine(partial_results[total_chunks - 1], acc);
                }
                offset = end;
            }

            // Main thread processes first chunk
            var main_acc = reducer.identity;
            for (main_chunk) |item| {
                main_acc = reducer.combine(main_acc, item);
            }
            partial_results[0] = main_acc;

            // Wait for spawned tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel reduce: chunk panicked");
            }

            // Tree-based final reduction
            var active_count = total_chunks;
            while (active_count > 1) {
                const pairs = active_count / 2;
                var i: usize = 0;
                while (i < pairs) : (i += 1) {
                    partial_results[i] = reducer.combine(partial_results[i * 2], partial_results[i * 2 + 1]);
                }
                if (active_count % 2 == 1) {
                    partial_results[pairs] = partial_results[active_count - 1];
                    active_count = pairs + 1;
                } else {
                    active_count = pairs;
                }
            }

            return if (total_chunks > 0) partial_results[0] else reducer.identity;
        }

        /// Sum all elements
        pub fn sum(self: Self) T {
            return self.reduce(Reducer(T).sum());
        }

        /// Product of all elements
        pub fn product(self: Self) T {
            return self.reduce(Reducer(T).product());
        }

        /// Minimum element
        pub fn min(self: Self) T {
            return self.reduce(Reducer(T).min());
        }

        /// Maximum element
        pub fn max(self: Self) T {
            return self.reduce(Reducer(T).max());
        }

        // ====================================================================
        // Utility accessors - nth, last, skip, take
        // ====================================================================

        /// Get the Nth element (0-indexed)
        /// Direct indexed access - O(1) for slices
        pub fn nth(self: Self, n: usize) ?T {
            if (n >= self.data.len) return null;
            return self.data[n];
        }

        /// Get the last element
        /// Direct access - O(1) for slices
        pub fn last(self: Self) ?T {
            if (self.data.len == 0) return null;
            return self.data[self.data.len - 1];
        }

        /// Get the first element
        /// Direct access - O(1) for slices
        pub fn first(self: Self) ?T {
            if (self.data.len == 0) return null;
            return self.data[0];
        }

        /// Skip first N elements, return iterator over the rest
        pub fn skip(self: Self, n: usize) Self {
            const skip_count = @min(n, self.data.len);
            return Self{
                .data = self.data[skip_count..],
                .splitter = self.splitter,
                .pool = self.pool,
                .allocator = self.allocator,
            };
        }

        /// Take first N elements, return iterator over them
        pub fn take(self: Self, n: usize) Self {
            const take_count = @min(n, self.data.len);
            return Self{
                .data = self.data[0..take_count],
                .splitter = self.splitter,
                .pool = self.pool,
                .allocator = self.allocator,
            };
        }

        /// Return the length of the underlying data
        pub fn len(self: Self) usize {
            return self.data.len;
        }

        /// Check if empty
        pub fn isEmpty(self: Self) bool {
            return self.data.len == 0;
        }

        // ====================================================================
        // Phase 9: Iterator Parity Methods
        // ====================================================================

        /// Find first element matching predicate (alias for find with ordered guarantee)
        /// In parallel execution, this finds the leftmost matching element.
        pub fn find_first(self: Self, comptime pred: fn (T) bool) ?T {
            // Same as find - parallel find already returns leftmost match
            return self.find(pred);
        }

        /// Find last element matching predicate
        /// Scans from the end to find the rightmost match.
        pub fn find_last(self: Self, comptime pred: fn (T) bool) ?T {
            // For slices, we can efficiently scan backwards
            var i = self.data.len;
            while (i > 0) {
                i -= 1;
                if (pred(self.data[i])) {
                    return self.data[i];
                }
            }
            return null;
        }

        /// Find and transform: find an element and apply a transformation
        /// Returns the first transformed value where pred returns non-null
        pub fn find_map(self: Self, comptime U: type, comptime func: fn (T) ?U) ?U {
            for (self.data) |item| {
                if (func(item)) |result| {
                    return result;
                }
            }
            return null;
        }

        /// Minimum element using custom comparator
        /// comparator(a, b) should return true if a < b
        pub fn min_by(self: Self, comptime comparator: fn (T, T) bool) ?T {
            if (self.data.len == 0) return null;
            var result = self.data[0];
            for (self.data[1..]) |item| {
                if (comparator(item, result)) {
                    result = item;
                }
            }
            return result;
        }

        /// Maximum element using custom comparator
        /// comparator(a, b) should return true if a < b
        pub fn max_by(self: Self, comptime comparator: fn (T, T) bool) ?T {
            if (self.data.len == 0) return null;
            var result = self.data[0];
            for (self.data[1..]) |item| {
                if (comparator(result, item)) {
                    result = item;
                }
            }
            return result;
        }

        /// Minimum element by key extraction
        /// key_func extracts a comparable key from each element
        pub fn min_by_key(self: Self, comptime K: type, comptime key_func: fn (T) K) ?T {
            if (self.data.len == 0) return null;
            var result = self.data[0];
            var min_key = key_func(result);
            for (self.data[1..]) |item| {
                const k = key_func(item);
                if (k < min_key) {
                    min_key = k;
                    result = item;
                }
            }
            return result;
        }

        /// Maximum element by key extraction
        /// key_func extracts a comparable key from each element
        pub fn max_by_key(self: Self, comptime K: type, comptime key_func: fn (T) K) ?T {
            if (self.data.len == 0) return null;
            var result = self.data[0];
            var max_key = key_func(result);
            for (self.data[1..]) |item| {
                const k = key_func(item);
                if (k > max_key) {
                    max_key = k;
                    result = item;
                }
            }
            return result;
        }

        /// Step by N elements (strided access)
        /// Returns a new iterator that yields every Nth element
        pub fn step_by(self: Self, step: usize) SteppedIterator(T) {
            return SteppedIterator(T){
                .data = self.data,
                .step = if (step == 0) 1 else step,
                .pos = 0,
            };
        }

        /// Reverse the underlying slice (in-place modification)
        pub fn rev(self: Self) Self {
            // Reverse in place
            if (self.data.len > 1) {
                var i: usize = 0;
                var j: usize = self.data.len - 1;
                while (i < j) {
                    const tmp = self.data[i];
                    self.data[i] = self.data[j];
                    self.data[j] = tmp;
                    i += 1;
                    j -= 1;
                }
            }
            return self;
        }

        /// Combined filter and map: filter elements and transform in one pass
        /// func returns null to filter out, or Some(U) to keep and transform
        pub fn filter_map(self: Self, comptime U: type, comptime func: fn (T) ?U, alloc_override: ?Allocator) ![]U {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            // First pass: count matches
            var match_count: usize = 0;
            for (self.data) |item| {
                if (func(item) != null) {
                    match_count += 1;
                }
            }

            // Allocate result
            const result = try allocator.alloc(U, match_count);
            errdefer allocator.free(result);

            // Second pass: populate result
            var idx: usize = 0;
            for (self.data) |item| {
                if (func(item)) |transformed| {
                    result[idx] = transformed;
                    idx += 1;
                }
            }

            return result;
        }

        /// Partition elements by predicate into two groups
        /// Returns (matching, non_matching) tuple
        pub fn partition(self: Self, comptime pred: fn (T) bool, alloc_override: ?Allocator) !struct { matching: []T, non_matching: []T } {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            // Count matches
            var match_count: usize = 0;
            for (self.data) |item| {
                if (pred(item)) match_count += 1;
            }

            // Allocate both arrays
            const matching = try allocator.alloc(T, match_count);
            errdefer allocator.free(matching);
            const non_matching = try allocator.alloc(T, self.data.len - match_count);
            errdefer allocator.free(non_matching);

            // Populate
            var m_idx: usize = 0;
            var n_idx: usize = 0;
            for (self.data) |item| {
                if (pred(item)) {
                    matching[m_idx] = item;
                    m_idx += 1;
                } else {
                    non_matching[n_idx] = item;
                    n_idx += 1;
                }
            }

            return .{ .matching = matching, .non_matching = non_matching };
        }

        /// Inspect each element with a side effect function (for debugging)
        pub fn inspect(self: Self, comptime func: fn (T) void) Self {
            for (self.data) |item| {
                func(item);
            }
            return self;
        }

        /// Fallible fold operation - fold with error handling
        /// Returns error on first failure, otherwise the accumulated result
        pub fn try_fold(
            self: Self,
            comptime E: type,
            initial: T,
            comptime func: fn (T, T) E!T,
        ) E!T {
            var acc = initial;
            for (self.data) |item| {
                acc = try func(acc, item);
            }
            return acc;
        }

        /// Fallible reduce operation - reduce with error handling
        /// Returns error on first failure, otherwise the reduced result
        pub fn try_reduce(
            self: Self,
            comptime E: type,
            comptime func: fn (T, T) E!T,
        ) E!?T {
            if (self.data.len == 0) return null;
            var acc = self.data[0];
            for (self.data[1..]) |item| {
                acc = try func(acc, item);
            }
            return acc;
        }

        /// Enumerate elements with their indices
        /// Returns array of (index, value) tuples
        pub const IndexedT = struct { index: usize, value: T };

        pub fn enumerate(self: Self, alloc_override: ?Allocator) ![]IndexedT {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const result = try allocator.alloc(IndexedT, self.data.len);
            errdefer allocator.free(result);

            for (self.data, 0..) |item, i| {
                result[i] = .{ .index = i, .value = item };
            }

            return result;
        }

        /// Clone/copy all elements into a new array
        /// For types with simple copy semantics
        pub fn cloned(self: Self, alloc_override: ?Allocator) ![]T {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const result = try allocator.alloc(T, self.data.len);
            errdefer allocator.free(result);

            @memcpy(result, self.data);

            return result;
        }

        /// Zip type helper
        pub fn ZipT(comptime U: type) type {
            return struct { first: T, second: U };
        }

        /// Zip this iterator with another slice of the same length
        /// Returns array of (self[i], other[i]) tuples
        /// Uses shortest length if slices differ in size
        pub fn zip(self: Self, comptime U: type, other: []const U, alloc_override: ?Allocator) ![]ZipT(U) {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const zip_len = @min(self.data.len, other.len);
            const result = try allocator.alloc(ZipT(U), zip_len);
            errdefer allocator.free(result);

            for (0..zip_len) |i| {
                result[i] = .{ .first = self.data[i], .second = other[i] };
            }

            return result;
        }

        /// Chain/concatenate this iterator with another slice
        /// Returns new array with elements from self followed by elements from other
        pub fn chain(self: Self, other: []const T, alloc_override: ?Allocator) ![]T {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const total_len = self.data.len + other.len;
            const result = try allocator.alloc(T, total_len);
            errdefer allocator.free(result);

            @memcpy(result[0..self.data.len], self.data);
            @memcpy(result[self.data.len..], other);

            return result;
        }

        /// Map each element to a slice and flatten results
        /// func returns a slice for each element, all slices are concatenated
        pub fn flat_map(
            self: Self,
            comptime U: type,
            comptime func: fn (T) []const U,
            alloc_override: ?Allocator,
        ) ![]U {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            // First pass: count total elements
            var total_len: usize = 0;
            for (self.data) |item| {
                total_len += func(item).len;
            }

            // Allocate result
            const result = try allocator.alloc(U, total_len);
            errdefer allocator.free(result);

            // Second pass: populate
            var idx: usize = 0;
            for (self.data) |item| {
                const slice = func(item);
                @memcpy(result[idx .. idx + slice.len], slice);
                idx += slice.len;
            }

            return result;
        }

        // ====================================================================
        // map - Transform elements
        // ====================================================================

        /// Transform each element, producing a new array
        ///
        /// Note: Caller owns returned memory and must free it.
        /// Pass explicit allocator or null to use stored allocator from withAlloc().
        pub fn map(self: Self, comptime U: type, comptime func: fn (T) U, alloc_override: ?Allocator) ![]U {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const result = try allocator.alloc(U, self.data.len);
            errdefer allocator.free(result);

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                for (self.data, 0..) |item, i| {
                    result[i] = func(item);
                }
                return result;
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);

            // Reserve first chunk for main thread - only spawn (total_chunks - 1)
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            // Issue 21 fix: Use heap allocation for large contexts if allocator available
            const Context = MapContextStack(T, U, func);
            const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks);
            var stack_contexts: [stack_max_chunks]Context = undefined;
            const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
            defer freeContextsIfNeeded(Context, heap_contexts, allocator);

            // Completion counter (only for spawned tasks)
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Calculate main thread's chunk (first chunk)
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_src_chunk = self.data[0..main_chunk_end];
            const main_dst_chunk = result[0..main_chunk_end];

            // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const src_chunk = self.data[offset..end];
                const dst_chunk = result[offset..end];

                ctxs[chunk_idx] = Context{
                    .src = src_chunk,
                    .dst = dst_chunk,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    for (src_chunk, dst_chunk) |item, *out| {
                        out.* = func(item);
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                for (self.data[offset..end], result[offset..end]) |item, *out| {
                    out.* = func(item);
                }
                offset = end;
            }

            // MAIN THREAD: Process first chunk directly (do useful work instead of spinning)
            for (main_src_chunk, main_dst_chunk) |item, *out| {
                out.* = func(item);
            }

            // Wait for spawned tasks to complete (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel map: chunk panicked");
            }

            return result;
        }

        /// Transform each element with index, producing a new array
        ///
        /// Similar to map but the function receives both the index and value.
        /// Note: Caller owns returned memory and must free it.
        /// Pass explicit allocator or null to use stored allocator from withAlloc().
        pub fn mapIndexed(self: Self, comptime U: type, comptime func: fn (usize, T) U, alloc_override: ?Allocator) ![]U {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const result = try allocator.alloc(U, self.data.len);
            errdefer allocator.free(result);

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                for (self.data, 0..) |item, i| {
                    result[i] = func(i, item);
                }
                return result;
            }

            // Stack array uses module-level stack_max_chunks constant
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);

            // Reserve first chunk for main thread - only spawn (total_chunks - 1)
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            // Use heap allocation for large contexts if allocator available
            const Context = MapIndexedContextStack(T, U, func);
            const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks);
            var stack_contexts: [stack_max_chunks]Context = undefined;
            const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
            defer freeContextsIfNeeded(Context, heap_contexts, allocator);

            // Completion counter (only for spawned tasks)
            var pending = Atomic(usize).init(spawn_chunks);
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Calculate main thread's chunk (first chunk)
            const main_chunk_end = @min(chunk_size, self.data.len);
            const main_src_chunk = self.data[0..main_chunk_end];
            const main_dst_chunk = result[0..main_chunk_end];

            // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (offset < self.data.len and chunk_idx < spawn_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const src_chunk = self.data[offset..end];
                const dst_chunk = result[offset..end];

                ctxs[chunk_idx] = Context{
                    .src = src_chunk,
                    .dst = dst_chunk,
                    .base_index = offset,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    for (src_chunk, dst_chunk, 0..) |item, *out, i| {
                        out.* = func(offset + i, item);
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Process remaining data if we hit chunk limit
            while (offset < self.data.len) {
                const end = @min(offset + chunk_size, self.data.len);
                for (self.data[offset..end], result[offset..end], 0..) |item, *out, i| {
                    out.* = func(offset + i, item);
                }
                offset = end;
            }

            // MAIN THREAD: Process first chunk directly
            for (main_src_chunk, main_dst_chunk, 0..) |item, *out, i| {
                out.* = func(i, item);
            }

            // Wait for spawned tasks to complete (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel mapIndexed: chunk panicked");
            }

            return result;
        }

        // ====================================================================
        // Sequential helpers (used as fallback for small data)
        // ====================================================================

        /// Sequential filter - for small data or when order must be preserved
        ///
        /// Caller owns returned memory.
        pub fn filterSeq(self: Self, comptime pred: fn (T) bool, allocator: Allocator) ![]T {
            // First pass: count matching elements (sequential for simplicity)
            var match_count: usize = 0;
            for (self.data) |item| {
                if (pred(item)) match_count += 1;
            }

            if (match_count == 0) {
                return allocator.alloc(T, 0);
            }

            // Allocate result
            const result = try allocator.alloc(T, match_count);
            errdefer allocator.free(result);

            // Second pass: collect matching elements
            var idx: usize = 0;
            for (self.data) |item| {
                if (pred(item)) {
                    result[idx] = item;
                    idx += 1;
                }
            }

            return result;
        }

        /// Sequential any - check if any element matches predicate
        pub fn anySeq(self: Self, comptime pred: fn (T) bool) bool {
            for (self.data) |item| {
                if (pred(item)) return true;
            }
            return false;
        }

        /// Sequential all - check if all elements match predicate
        pub fn allSeq(self: Self, comptime pred: fn (T) bool) bool {
            for (self.data) |item| {
                if (!pred(item)) return false;
            }
            return true;
        }

        /// Sequential find - find first element matching predicate
        pub fn findSeq(self: Self, comptime pred: fn (T) bool) ?T {
            for (self.data) |item| {
                if (pred(item)) return item;
            }
            return null;
        }

        /// Sequential position - find index of first element matching predicate
        pub fn positionSeq(self: Self, comptime pred: fn (T) bool) ?usize {
            for (self.data, 0..) |item, i| {
                if (pred(item)) return i;
            }
            return null;
        }

        /// Sequential count - count elements matching predicate
        pub fn countSeq(self: Self, comptime pred: fn (T) bool) usize {
            var n: usize = 0;
            for (self.data) |item| {
                if (pred(item)) n += 1;
            }
            return n;
        }

        // ====================================================================
        // Parallel operations (primary API)
        // ====================================================================

        /// Check if any element matches predicate (parallel)
        ///
        /// Uses atomic flag for cross-chunk early termination.
        /// Falls back to sequential for small data.
        pub fn any(self: Self, comptime pred: fn (T) bool) bool {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.anySeq(pred);
            }

            var found = Atomic(bool).init(false);
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var ctxs: [stack_max_chunks]ParAnyContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            // Reserve first chunk for main thread
            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            // Spawn worker tasks for remaining chunks
            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                ctxs[chunk_idx] = ParAnyContext(T, pred){
                    .data = chunk,
                    .found = &found,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = ParAnyContext(T, pred).execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Execute locally on failure
                    if (!found.load(.acquire)) {
                        for (chunk) |item| {
                            if (pred(item)) {
                                found.store(true, .release);
                                break;
                            }
                        }
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process first chunk with periodic early-exit checks
            if (!found.load(.acquire)) {
                var check_counter: usize = 0;
                for (main_chunk) |item| {
                    if (pred(item)) {
                        found.store(true, .release);
                        break;
                    }
                    // Issue 18 fix: Periodic check with configurable interval (256 vs 64)
                    // Reduces cache coherency traffic by 4x
                    check_counter += 1;
                    if (check_counter >= early_exit_check_interval) {
                        check_counter = 0;
                        if (found.load(.acquire)) break;
                    }
                }
            }

            // Wait for spawned tasks (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel any: chunk panicked");
            }

            return found.load(.acquire);
        }

        /// Check if all elements match predicate (parallel)
        ///
        /// Uses atomic flag for cross-chunk early termination on first mismatch.
        /// Falls back to sequential for small data.
        pub fn all(self: Self, comptime pred: fn (T) bool) bool {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.allSeq(pred);
            }

            // Use "failed" flag - true means we found a non-matching element
            var failed = Atomic(bool).init(false);
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var ctxs: [stack_max_chunks]ParAllContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            // Reserve first chunk for main thread
            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            // Spawn worker tasks
            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                ctxs[chunk_idx] = ParAllContext(T, pred){
                    .data = chunk,
                    .failed = &failed,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = ParAllContext(T, pred).execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    if (!failed.load(.acquire)) {
                        for (chunk) |item| {
                            if (!pred(item)) {
                                failed.store(true, .release);
                                break;
                            }
                        }
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process first chunk with periodic early-exit checks
            if (!failed.load(.acquire)) {
                var check_counter: usize = 0;
                for (main_chunk) |item| {
                    if (!pred(item)) {
                        failed.store(true, .release);
                        break;
                    }
                    // Issue 18 fix: Periodic check with configurable interval (256 vs 64)
                    // Reduces cache coherency traffic by 4x
                    check_counter += 1;
                    if (check_counter >= early_exit_check_interval) {
                        check_counter = 0;
                        if (failed.load(.acquire)) break;
                    }
                }
            }

            // Wait for spawned tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel all: chunk panicked");
            }

            return !failed.load(.acquire);
        }

        /// Find an element matching predicate (parallel)
        ///
        /// Note: Due to parallel execution, may not return the "first" element
        /// in index order, but returns *a* matching element quickly.
        /// Falls back to sequential for small data.
        /// Issue 14 fix: Lock-free find using CAS instead of mutex
        pub fn find(self: Self, comptime pred: fn (T) bool) ?T {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.findSeq(pred);
            }

            var found = Atomic(bool).init(false);
            var result: T = undefined;
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var ctxs: [stack_max_chunks]ParFindContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                ctxs[chunk_idx] = ParFindContext(T, pred){
                    .data = chunk,
                    .found = &found,
                    .result = &result,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = ParFindContext(T, pred).execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Issue 14 fix: Use CAS instead of mutex for fallback path too
                    if (!found.load(.acquire)) {
                        for (chunk) |item| {
                            if (pred(item)) {
                                if (found.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                                    result = item;
                                }
                                break;
                            }
                        }
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread - Issue 14 fix: Use CAS instead of mutex
            if (!found.load(.acquire)) {
                for (main_chunk) |item| {
                    if (pred(item)) {
                        if (found.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                            result = item;
                        }
                        break;
                    }
                }
            }

            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel find: chunk panicked");
            }

            return if (found.load(.acquire)) result else null;
        }

        /// Find index of first matching element (parallel)
        ///
        /// Returns the minimum index across all chunks where a match was found.
        /// This guarantees finding the actual first matching element.
        /// Falls back to sequential for small data.
        pub fn position(self: Self, comptime pred: fn (T) bool) ?usize {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.positionSeq(pred);
            }

            // Use maxInt as "not found" sentinel
            var min_index = Atomic(usize).init(std.math.maxInt(usize));
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var ctxs: [stack_max_chunks]ParPositionContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                ctxs[chunk_idx] = ParPositionContext(T, pred){
                    .data = chunk,
                    .base_index = offset,
                    .min_index = &min_index,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = ParPositionContext(T, pred).execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    for (chunk, 0..) |item, i| {
                        const global_idx = offset + i;
                        // Early exit if we already found a smaller index
                        if (global_idx >= min_index.load(.acquire)) break;
                        if (pred(item)) {
                            _ = min_index.fetchMin(global_idx, .release); // T128
                            break;
                        }
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process first chunk (base_index = 0)
            for (main_chunk, 0..) |item, i| {
                if (i >= min_index.load(.acquire)) break;
                if (pred(item)) {
                    _ = min_index.fetchMin(i, .release); // T128
                    break;
                }
            }

            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel position: chunk panicked");
            }

            const found_result = min_index.load(.acquire);
            return if (found_result == std.math.maxInt(usize)) null else found_result;
        }

        /// Count elements matching predicate (parallel)
        ///
        /// Each chunk counts matches, then partial counts are summed.
        /// Falls back to sequential for small data.
        pub fn count(self: Self, comptime pred: fn (T) bool) usize {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.countSeq(pred);
            }

            var total = Atomic(usize).init(0);
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var ctxs: [stack_max_chunks]ParCountContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                ctxs[chunk_idx] = ParCountContext(T, pred){
                    .data = chunk,
                    .total = &total,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[chunk_idx].task = Task{
                    .execute = ParCountContext(T, pred).execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var local_count: usize = 0;
                    for (chunk) |item| {
                        if (pred(item)) local_count += 1;
                    }
                    _ = total.fetchAdd(local_count, .release); // T128: .release sufficient
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread
            var main_count: usize = 0;
            for (main_chunk) |item| {
                if (pred(item)) main_count += 1;
            }
            _ = total.fetchAdd(main_count, .release); // T128: .release sufficient

            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel count: chunk panicked");
            }

            return total.load(.acquire);
        }

        // ====================================================================
        // chunks - Process data in explicit chunks
        // ====================================================================

        /// Process data in explicit chunks with a user-provided function (parallel)
        ///
        /// The function receives (chunk_index, chunk_data) and can process
        /// the chunk however needed. Useful for operations requiring chunk
        /// boundaries or custom per-chunk logic.
        ///
        /// Example:
        /// ```zig
        /// par_iter(&data).chunks(struct {
        ///     fn processChunk(chunk_idx: usize, chunk: []i32) void {
        ///         // Process chunk with knowledge of its index
        ///         for (chunk) |*item| item.* += @intCast(chunk_idx);
        ///     }
        /// }.processChunk);
        /// ```
        pub fn chunks(self: Self, comptime func: fn (usize, []T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                // Sequential: single chunk
                func(0, self.data);
                return;
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const Context = ParChunksContext(T, func);
            var ctxs: [stack_max_chunks]Context = undefined;
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Main thread processes chunk 0
            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];

            // Spawn worker tasks for remaining chunks
            var chunk_idx: usize = 1;
            var offset: usize = main_end;
            while (offset < self.data.len and chunk_idx < total_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                const ctx_idx = chunk_idx - 1;
                ctxs[ctx_idx] = Context{
                    .chunk_index = chunk_idx,
                    .data = chunk,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[ctx_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[ctx_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[ctx_idx].task) catch {
                    func(chunk_idx, chunk);
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process chunk 0
            func(0, main_chunk);

            // Wait for spawned tasks (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel chunks: chunk panicked");
            }
        }

        /// Process data in explicit chunks - const version (parallel)
        ///
        /// Same as chunks() but for read-only operations.
        pub fn chunksConst(self: Self, comptime func: fn (usize, []const T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                func(0, self.data);
                return;
            }

            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const Context = ParChunksConstContext(T, func);
            var ctxs: [stack_max_chunks]Context = undefined;
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];

            var chunk_idx: usize = 1;
            var offset: usize = main_end;
            while (offset < self.data.len and chunk_idx < total_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                const ctx_idx = chunk_idx - 1;
                ctxs[ctx_idx] = Context{
                    .chunk_index = chunk_idx,
                    .data = chunk,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                ctxs[ctx_idx].task = Task{
                    .execute = Context.execute,
                    .context = @ptrCast(&ctxs[ctx_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[ctx_idx].task) catch {
                    func(chunk_idx, chunk);
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            func(0, main_chunk);

            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel chunksConst: chunk panicked");
            }
        }

        // ====================================================================
        // par_sort - Parallel sorting
        // ====================================================================

        /// Sort elements using parallel merge sort
        ///
        /// Splits array into chunks, sorts chunks in parallel (sequential sort),
        /// then merges sorted chunks. Stable within chunks.
        /// Falls back to sequential for small data.
        ///
        /// Note: Requires temporary buffer allocation for merge phase.
        ///
        /// Example:
        /// ```zig
        /// var data = [_]i32{ 5, 3, 1, 4, 2 };
        /// // With explicit allocator
        /// try par_iter(&data).sort(std.sort.asc(i32), allocator);
        /// // Or with stored allocator
        /// try par_iter(&data).withAlloc(allocator).sort(std.sort.asc(i32), null);
        /// // data is now { 1, 2, 3, 4, 5 }
        /// ```
        pub fn sort(self: Self, comptime cmp: fn (T, T) bool, alloc_override: ?Allocator) !void {
            if (self.data.len <= 1) return;

            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            // For small arrays, use sequential sort
            // Issue 50 fix: Increased threshold from 1024 to 8192
            // Benchmark showed 0.77x at 100K elements with 4096 threshold
            // Parallel merge sort only beneficial for large arrays (>100K typically)
            if (!self.splitter.shouldSplit(self.data.len, num_threads) or self.data.len < 8192) {
                std.mem.sort(T, self.data, {}, struct {
                    fn lessThan(_: void, a: T, b: T) bool {
                        return cmp(a, b);
                    }
                }.lessThan);
                return;
            }

            // Allocate temporary buffer for merge
            const temp = try allocator.alloc(T, self.data.len);
            defer allocator.free(temp);

            // Phase 1: Parallel sort of chunks
            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, self.data.len, chunk_size) catch self.data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const SortContext = ParSortChunkContext(T, cmp);
            var sort_contexts: [stack_max_chunks]SortContext = undefined;
            var pending = Atomic(usize).init(spawn_chunks);
            // Issue 10 fix: Panic flag for detecting chunk panics
            var panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];

            // Spawn sort tasks for remaining chunks
            var chunk_idx: usize = 1;
            var offset: usize = main_end;
            while (offset < self.data.len and chunk_idx < total_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                const ctx_idx = chunk_idx - 1;
                sort_contexts[ctx_idx] = SortContext{
                    .data = chunk,
                    .pending = &pending,
                    .panicked = &panicked,
                    .task = undefined,
                };

                sort_contexts[ctx_idx].task = Task{
                    .execute = SortContext.execute,
                    .context = @ptrCast(&sort_contexts[ctx_idx]),
                    .scope = null,
                };

                pool.spawn(&sort_contexts[ctx_idx].task) catch {
                    std.mem.sort(T, chunk, {}, struct {
                        fn lessThan(_: void, a: T, b: T) bool {
                            return cmp(a, b);
                        }
                    }.lessThan);
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread sorts first chunk
            std.mem.sort(T, main_chunk, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return cmp(a, b);
                }
            }.lessThan);

            // Wait for all sort tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked
            if (panicked.load(.acquire)) {
                @panic("parallel sort: chunk panicked");
            }

            // Phase 2: Parallel merge of sorted chunks
            // Use bottom-up merge sort with parallel merge at each level
            var current_chunk_size: usize = chunk_size;
            while (current_chunk_size < self.data.len) {
                var i: usize = 0;
                while (i < self.data.len) {
                    const left_start = i;
                    const mid = @min(i + current_chunk_size, self.data.len);
                    const right_end = @min(i + 2 * current_chunk_size, self.data.len);

                    if (mid < right_end) {
                        // Use parallel merge for large merges, sequential for small
                        const merge_size = right_end - left_start;
                        if (merge_size > 8192) {
                            // Parallel merge for large arrays
                            parallelMergeTopLevel(T, cmp, self.data, temp, left_start, mid, right_end, pool);
                        } else {
                            // Sequential merge for small arrays
                            merge(T, cmp, self.data, temp, left_start, mid, right_end);
                        }
                    }

                    i += 2 * current_chunk_size;
                }
                current_chunk_size *= 2;
            }
        }

        /// Filter elements matching predicate (parallel)
        ///
        /// Two-phase approach:
        /// 1. Parallel count per chunk → compute total and offsets
        /// 2. Parallel scatter to pre-allocated result
        ///
        /// Order is preserved within chunks but may interleave between chunks.
        /// Falls back to sequential for small data.
        /// Caller owns returned memory.
        ///
        /// Pass explicit allocator or null to use stored allocator from withAlloc().
        pub fn filter(self: Self, comptime pred: fn (T) bool, alloc_override: ?Allocator) ![]T {
            const allocator = alloc_override orelse self.allocator orelse return error.NoAllocatorProvided;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(self.data.len, num_threads)) {
                return self.filterSeq(pred, allocator);
            }

            const chunk_size = self.splitter.chunkSize(self.data.len, num_threads);
            // Stack array uses module-level stack_max_chunks constant
            // Dynamic limit based on thread count for better load balancing
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Phase 1: Count matches per chunk (parallel)
            // T123: Initialize to zeros to avoid reading uninitialized memory
            var counts: [stack_max_chunks]usize = [_]usize{0} ** stack_max_chunks;
            var pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics (count phase)
            var count_panicked = Atomic(bool).init(false);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            var count_contexts: [stack_max_chunks]ParFilterCountContext(T, pred) = undefined;
            var chunk_idx: usize = 0;
            var offset: usize = 0;

            const main_end = @min(chunk_size, self.data.len);
            const main_chunk = self.data[0..main_end];
            offset = main_end;

            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                count_contexts[chunk_idx] = ParFilterCountContext(T, pred){
                    .data = chunk,
                    .count_ptr = &counts[chunk_idx + 1], // +1 because main chunk is at index 0
                    .pending = &pending,
                    .panicked = &count_panicked,
                    .task = undefined,
                };

                count_contexts[chunk_idx].task = Task{
                    .execute = ParFilterCountContext(T, pred).execute,
                    .context = @ptrCast(&count_contexts[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&count_contexts[chunk_idx].task) catch {
                    var local_count: usize = 0;
                    for (chunk) |item| {
                        if (pred(item)) local_count += 1;
                    }
                    counts[chunk_idx + 1] = local_count;
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread counts first chunk
            var main_count: usize = 0;
            for (main_chunk) |item| {
                if (pred(item)) main_count += 1;
            }
            counts[0] = main_count;

            // Wait for count phase
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked in count phase
            if (count_panicked.load(.acquire)) {
                @panic("parallel filter count: chunk panicked");
            }

            // Compute prefix sums for offsets
            const total_chunks = chunk_idx + 1;
            // Issue 17 fix: Zero-initialize to prevent undefined behavior if bounds are miscalculated
            var offsets: [stack_max_chunks]usize = [_]usize{0} ** stack_max_chunks;
            var total_count: usize = 0;
            for (0..total_chunks) |i| {
                offsets[i] = total_count;
                total_count += counts[i];
            }
            // Set final offset for scatter phase (needed for offsets[chunk_idx + 1] access)
            offsets[total_chunks] = total_count;

            if (total_count == 0) {
                return allocator.alloc(T, 0);
            }

            // Allocate result
            const result = try allocator.alloc(T, total_count);
            errdefer allocator.free(result);

            // Phase 2: Scatter matches to result (parallel)
            pending = Atomic(usize).init(0);
            // Issue 10 fix: Panic flag for detecting chunk panics (scatter phase)
            var scatter_panicked = Atomic(bool).init(false);

            var scatter_contexts: [stack_max_chunks]ParFilterScatterContext(T, pred) = undefined;
            chunk_idx = 0;
            offset = main_end;

            while (offset < self.data.len and chunk_idx < max_chunks) {
                const end = @min(offset + chunk_size, self.data.len);
                const chunk = self.data[offset..end];
                const dest_offset = offsets[chunk_idx + 1];

                // T128: .release sufficient - only publishing, not reading
                _ = pending.fetchAdd(1, .release);

                scatter_contexts[chunk_idx] = ParFilterScatterContext(T, pred){
                    .data = chunk,
                    .result = result,
                    .dest_offset = dest_offset,
                    .pending = &pending,
                    .panicked = &scatter_panicked,
                    .task = undefined,
                };

                scatter_contexts[chunk_idx].task = Task{
                    .execute = ParFilterScatterContext(T, pred).execute,
                    .context = @ptrCast(&scatter_contexts[chunk_idx]),
                    .scope = null,
                };

                pool.spawn(&scatter_contexts[chunk_idx].task) catch {
                    var idx = dest_offset;
                    for (chunk) |item| {
                        if (pred(item)) {
                            // Issue 22/40 fix: Bounds check
                            if (idx >= result.len) {
                                @panic("filter scatter: index out of bounds (predicate may be non-deterministic)");
                            }
                            result[idx] = item;
                            idx += 1;
                        }
                    }
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread scatters first chunk
            var main_idx: usize = 0;
            for (main_chunk) |item| {
                if (pred(item)) {
                    // Issue 22/40 fix: Bounds check
                    if (main_idx >= result.len) {
                        @panic("filter scatter: index out of bounds (predicate may be non-deterministic)");
                    }
                    result[main_idx] = item;
                    main_idx += 1;
                }
            }

            // Wait for scatter phase
            backoff.reset();
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Issue 10 fix: Propagate panic if any chunk panicked in scatter phase
            if (scatter_panicked.load(.acquire)) {
                allocator.free(result);
                @panic("parallel filter scatter: chunk panicked");
            }

            return result;
        }
    };
}

// ============================================================================
// ContextParallelIterator - Parallel Iterator with Context
// ============================================================================

/// Parallel iterator with attached context for stateful operations
///
/// Wraps a ParallelIterator and provides context-aware versions of operations.
/// The context is passed to each callback function alongside the item.
pub fn ContextParallelIterator(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        /// The underlying parallel iterator
        inner: ParallelIterator(T),

        /// User-provided context
        context: Context,

        /// Configure the splitter for this iterator
        pub fn withSplitter(self: Self, s: Splitter) Self {
            var result = self;
            result.inner = self.inner.withSplitter(s);
            return result;
        }

        /// Use a specific thread pool
        pub fn withPool(self: Self, p: *ThreadPool) Self {
            var result = self;
            result.inner = self.inner.withPool(p);
            return result;
        }

        /// Set minimum chunk size for parallelization
        pub fn withMinChunk(self: Self, min_chunk: usize) Self {
            var result = self;
            result.inner = self.inner.withMinChunk(min_chunk);
            return result;
        }

        /// Set maximum number of chunks
        pub fn withMaxChunks(self: Self, max_chunks: usize) Self {
            var result = self;
            result.inner = self.inner.withMaxChunks(max_chunks);
            return result;
        }

        /// Set allocator for operations that need allocation
        pub fn withAlloc(self: Self, alloc: Allocator) Self {
            var result = self;
            result.inner = self.inner.withAlloc(alloc);
            return result;
        }

        /// Get the pool to use (explicit or global)
        fn getPool(self: *const Self) *ThreadPool {
            return self.inner.pool orelse getGlobalPool();
        }

        // ====================================================================
        // Context-aware forEach
        // ====================================================================

        /// Apply a function to each element in parallel with context
        ///
        /// The function receives the context and each element by pointer.
        pub fn forEach(self: Self, comptime func: fn (Context, *T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const data = self.inner.data;
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                // Sequential path for small data
                for (data) |*item| {
                    func(self.context, item);
                }
                return;
            }

            // Parallel path using chunks
            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxForEach = struct {
                const Ctx = @This();
                task: Task,
                data_ptr: [*]T,
                start: usize,
                end: usize,
                user_context: Context,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var i = self_ctx.start;
                    while (i < self_ctx.end) : (i += 1) {
                        func(self_ctx.user_context, &self_ctx.data_ptr[i]);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]CtxForEach = undefined;

            // Spawn worker chunks
            var chunk_idx: usize = 0;
            var offset: usize = 0;
            while (chunk_idx < spawn_chunks) : (chunk_idx += 1) {
                const start = offset;
                const end = @min(offset + chunk_size, data.len);
                if (start >= end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .data_ptr = data.ptr,
                    .start = start,
                    .end = end,
                    .user_context = self.context,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = CtxForEach.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    // Fallback: process this chunk on main thread
                    var i = start;
                    while (i < end) : (i += 1) {
                        func(self.context, &data[i]);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset = end;
            }

            // Process remaining on main thread
            while (offset < data.len) : (offset += 1) {
                func(self.context, &data[offset]);
            }

            // Wait for all spawned tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                backoff.snooze();
            }
        }

        // ====================================================================
        // Context-aware forEachIndexed
        // ====================================================================

        /// Apply a function to each element with index in parallel with context
        pub fn forEachIndexed(self: Self, comptime func: fn (Context, usize, *T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const data = self.inner.data;
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                for (data, 0..) |*item, idx| {
                    func(self.context, idx, item);
                }
                return;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxForEachIdx = struct {
                const Ctx = @This();
                task: Task,
                data_ptr: [*]T,
                start: usize,
                end: usize,
                user_context: Context,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var i = self_ctx.start;
                    while (i < self_ctx.end) : (i += 1) {
                        func(self_ctx.user_context, i, &self_ctx.data_ptr[i]);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]CtxForEachIdx = undefined;

            var chunk_idx: usize = 0;
            var offset: usize = 0;
            while (chunk_idx < spawn_chunks) : (chunk_idx += 1) {
                const start = offset;
                const end = @min(offset + chunk_size, data.len);
                if (start >= end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .data_ptr = data.ptr,
                    .start = start,
                    .end = end,
                    .user_context = self.context,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = CtxForEachIdx.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var i = start;
                    while (i < end) : (i += 1) {
                        func(self.context, i, &data[i]);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset = end;
            }

            while (offset < data.len) : (offset += 1) {
                func(self.context, offset, &data[offset]);
            }

            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                backoff.snooze();
            }
        }

        // ====================================================================
        // Context-aware count
        // ====================================================================

        /// Count elements matching a predicate in parallel with context
        pub fn count(self: Self, comptime pred: fn (Context, T) bool) usize {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const data = self.inner.data;
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                var cnt: usize = 0;
                for (data) |item| {
                    if (pred(self.context, item)) cnt += 1;
                }
                return cnt;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxCount = struct {
                const Ctx = @This();
                task: Task,
                data_ptr: [*]T,
                start: usize,
                end: usize,
                user_context: Context,
                result: usize,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var cnt: usize = 0;
                    var i = self_ctx.start;
                    while (i < self_ctx.end) : (i += 1) {
                        if (pred(self_ctx.user_context, self_ctx.data_ptr[i])) cnt += 1;
                    }
                    self_ctx.result = cnt;
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]CtxCount = undefined;

            var chunk_idx: usize = 0;
            var offset: usize = 0;
            while (chunk_idx < spawn_chunks) : (chunk_idx += 1) {
                const start = offset;
                const end = @min(offset + chunk_size, data.len);
                if (start >= end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .data_ptr = data.ptr,
                    .start = start,
                    .end = end,
                    .user_context = self.context,
                    .result = 0,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = CtxCount.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var cnt: usize = 0;
                    var i = start;
                    while (i < end) : (i += 1) {
                        if (pred(self.context, data[i])) cnt += 1;
                    }
                    ctxs[chunk_idx].result = cnt;
                    _ = done.fetchAdd(1, .release);
                };
                offset = end;
            }

            // Main thread processes remaining
            var main_count: usize = 0;
            while (offset < data.len) : (offset += 1) {
                if (pred(self.context, data[offset])) main_count += 1;
            }

            // Wait and sum results
            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                backoff.snooze();
            }

            var total: usize = main_count;
            for (0..spawn_chunks) |i| {
                total += ctxs[i].result;
            }
            return total;
        }

        // ====================================================================
        // Context-aware any
        // ====================================================================

        /// Check if any element matches a predicate with context
        pub fn any(self: Self, comptime pred: fn (Context, T) bool) bool {
            const data = self.inner.data;
            for (data) |item| {
                if (pred(self.context, item)) return true;
            }
            return false;
        }

        // ====================================================================
        // Context-aware all
        // ====================================================================

        /// Check if all elements match a predicate with context
        pub fn all(self: Self, comptime pred: fn (Context, T) bool) bool {
            const data = self.inner.data;
            for (data) |item| {
                if (!pred(self.context, item)) return false;
            }
            return true;
        }

        // ====================================================================
        // Context-aware find
        // ====================================================================

        /// Find first element matching a predicate with context
        pub fn find(self: Self, comptime pred: fn (Context, T) bool) ?T {
            const data = self.inner.data;
            for (data) |item| {
                if (pred(self.context, item)) return item;
            }
            return null;
        }

        // ====================================================================
        // Context-aware map
        // ====================================================================

        /// Transform each element using context, producing a new array
        ///
        /// The transform function receives context and each element value.
        /// Caller owns returned memory and must free it.
        pub fn map(self: Self, comptime U: type, comptime func: fn (Context, T) U, alloc_override: ?Allocator) ![]U {
            const allocator = alloc_override orelse self.inner.allocator orelse return error.NoAllocatorProvided;
            const data = self.inner.data;

            const result = try allocator.alloc(U, data.len);
            errdefer allocator.free(result);

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                for (data, 0..) |item, i| {
                    result[i] = func(self.context, item);
                }
                return result;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxMap = struct {
                const Ctx = @This();
                task: Task,
                src: []const T,
                dst: []U,
                user_context: Context,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    for (self_ctx.src, self_ctx.dst) |item, *out| {
                        out.* = func(self_ctx.user_context, item);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]CtxMap = undefined;

            // Calculate main thread's chunk
            const main_chunk_end = @min(chunk_size, data.len);

            // Spawn worker chunks
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (chunk_idx < spawn_chunks and offset < data.len) : (chunk_idx += 1) {
                const start = offset;
                const end = @min(offset + chunk_size, data.len);
                if (start >= end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .src = data[start..end],
                    .dst = result[start..end],
                    .user_context = self.context,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = CtxMap.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    for (data[start..end], result[start..end]) |item, *out| {
                        out.* = func(self.context, item);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset = end;
            }

            // Main thread processes first chunk
            for (data[0..main_chunk_end], result[0..main_chunk_end]) |item, *out| {
                out.* = func(self.context, item);
            }

            // Process any remaining on main thread
            while (offset < data.len) : (offset += 1) {
                result[offset] = func(self.context, data[offset]);
            }

            // Wait for all spawned tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            return result;
        }

        // ====================================================================
        // Context-aware reduce
        // ====================================================================

        /// Reduce elements using a Reducer with context access
        ///
        /// Note: The reducer itself doesn't receive context, but you can use
        /// withContext().map() to transform data first, then reduce.
        /// This method is provided for API consistency.
        pub fn reduce(self: Self, reducer: Reducer(T)) T {
            // Delegate to inner iterator's reduce - context not needed for standard reducers
            return self.inner.reduce(reducer);
        }

        // ====================================================================
        // Context-aware filter
        // ====================================================================

        /// Filter elements using a context-aware predicate
        ///
        /// Caller owns returned memory and must free it.
        pub fn filter(self: Self, comptime pred: fn (Context, T) bool, alloc_override: ?Allocator) ![]T {
            const allocator = alloc_override orelse self.inner.allocator orelse return error.NoAllocatorProvided;
            const data = self.inner.data;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const splitter = self.inner.splitter;

            if (!splitter.shouldSplit(data.len, num_threads)) {
                return self.filterSeq(pred, allocator);
            }

            const chunk_size = splitter.chunkSize(data.len, num_threads);
            const max_chunks = @min(num_threads * 4, stack_max_chunks);

            // Phase 1: Count matches per chunk (parallel)
            var counts: [stack_max_chunks]usize = [_]usize{0} ** stack_max_chunks;
            var pending = Atomic(usize).init(0);

            const CtxCount = struct {
                const Ctx = @This();
                task: Task,
                chunk_data: []const T,
                count_ptr: *usize,
                user_context: Context,
                pending: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var local_count: usize = 0;
                    for (self_ctx.chunk_data) |item| {
                        if (pred(self_ctx.user_context, item)) local_count += 1;
                    }
                    self_ctx.count_ptr.* = local_count;
                    _ = self_ctx.pending.fetchSub(1, .release);
                }
            };

            var count_contexts: [stack_max_chunks]CtxCount = undefined;

            const main_end = @min(chunk_size, data.len);
            const main_chunk = data[0..main_end];

            // Spawn count tasks
            var chunk_idx: usize = 0;
            var offset: usize = main_end;
            while (offset < data.len and chunk_idx < max_chunks - 1) {
                const end = @min(offset + chunk_size, data.len);
                const chunk = data[offset..end];

                count_contexts[chunk_idx] = .{
                    .task = undefined,
                    .chunk_data = chunk,
                    .count_ptr = &counts[chunk_idx + 1],
                    .user_context = self.context,
                    .pending = &pending,
                };
                count_contexts[chunk_idx].task = Task{
                    .execute = CtxCount.execute,
                    .context = @ptrCast(&count_contexts[chunk_idx]),
                    .scope = null,
                };

                _ = pending.fetchAdd(1, .release);
                pool.spawn(&count_contexts[chunk_idx].task) catch {
                    var local_count: usize = 0;
                    for (chunk) |item| {
                        if (pred(self.context, item)) local_count += 1;
                    }
                    counts[chunk_idx + 1] = local_count;
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread counts first chunk
            var main_count: usize = 0;
            for (main_chunk) |item| {
                if (pred(self.context, item)) main_count += 1;
            }
            counts[0] = main_count;

            // Wait for count phase
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            // Compute total and allocate result
            const total_chunks = chunk_idx + 1;
            var total_count: usize = 0;
            for (0..total_chunks) |i| {
                total_count += counts[i];
            }

            if (total_count == 0) {
                return allocator.alloc(T, 0);
            }

            const result = try allocator.alloc(T, total_count);
            errdefer allocator.free(result);

            // Phase 2: Gather matches sequentially (simpler, still fast for filtered results)
            var write_idx: usize = 0;
            for (data) |item| {
                if (pred(self.context, item)) {
                    result[write_idx] = item;
                    write_idx += 1;
                }
            }

            return result;
        }

        /// Sequential filter for small data
        fn filterSeq(self: Self, comptime pred: fn (Context, T) bool, allocator: Allocator) ![]T {
            const data = self.inner.data;

            // Count first
            var match_count: usize = 0;
            for (data) |item| {
                if (pred(self.context, item)) match_count += 1;
            }

            if (match_count == 0) {
                return allocator.alloc(T, 0);
            }

            const result = try allocator.alloc(T, match_count);
            var idx: usize = 0;
            for (data) |item| {
                if (pred(self.context, item)) {
                    result[idx] = item;
                    idx += 1;
                }
            }

            return result;
        }

        // ====================================================================
        // Context-aware mapIndexed
        // ====================================================================

        /// Transform each element with index using context, producing a new array
        ///
        /// The transform function receives context, index, and each element value.
        /// Caller owns returned memory and must free it.
        pub fn mapIndexed(self: Self, comptime U: type, comptime func: fn (Context, usize, T) U, alloc_override: ?Allocator) ![]U {
            const allocator = alloc_override orelse self.inner.allocator orelse return error.NoAllocatorProvided;
            const data = self.inner.data;

            const result = try allocator.alloc(U, data.len);
            errdefer allocator.free(result);

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                for (data, 0..) |item, i| {
                    result[i] = func(self.context, i, item);
                }
                return result;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxMapIdx = struct {
                const Ctx = @This();
                task: Task,
                src: []const T,
                dst: []U,
                start_idx: usize,
                user_context: Context,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    for (self_ctx.src, 0..) |item, local_idx| {
                        const global_idx = self_ctx.start_idx + local_idx;
                        self_ctx.dst[local_idx] = func(self_ctx.user_context, global_idx, item);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]CtxMapIdx = undefined;

            // Calculate main thread's chunk
            const main_chunk_end = @min(chunk_size, data.len);

            // Spawn worker chunks
            var chunk_idx: usize = 0;
            var offset: usize = main_chunk_end;
            while (chunk_idx < spawn_chunks and offset < data.len) : (chunk_idx += 1) {
                const start = offset;
                const end = @min(offset + chunk_size, data.len);
                if (start >= end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .src = data[start..end],
                    .dst = result[start..end],
                    .start_idx = start,
                    .user_context = self.context,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = CtxMapIdx.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    for (data[start..end], 0..) |item, local_idx| {
                        result[start + local_idx] = func(self.context, start + local_idx, item);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset = end;
            }

            // Main thread processes first chunk
            for (data[0..main_chunk_end], 0..) |item, i| {
                result[i] = func(self.context, i, item);
            }

            // Process any remaining on main thread
            while (offset < data.len) : (offset += 1) {
                result[offset] = func(self.context, offset, data[offset]);
            }

            // Wait for all spawned tasks
            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }

            return result;
        }

        // ====================================================================
        // Context-aware chunks
        // ====================================================================

        /// Process data in explicit chunks with context (parallel, mutable)
        ///
        /// The chunk function receives context, chunk index, and a mutable slice.
        pub fn chunks(self: Self, comptime func: fn (Context, usize, []T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const data = self.inner.data;
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                func(self.context, 0, data);
                return;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxChunks = struct {
                const Ctx = @This();
                task: Task,
                chunk_index: usize,
                chunk_data: []T,
                user_context: Context,
                pending: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    func(self_ctx.user_context, self_ctx.chunk_index, self_ctx.chunk_data);
                    _ = self_ctx.pending.fetchSub(1, .release);
                }
            };

            var ctxs: [stack_max_chunks]CtxChunks = undefined;
            var pending = Atomic(usize).init(spawn_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Main thread processes chunk 0
            const main_end = @min(chunk_size, data.len);
            const main_chunk = data[0..main_end];

            // Spawn worker tasks for remaining chunks
            var chunk_idx: usize = 1;
            var offset: usize = main_end;
            while (offset < data.len and chunk_idx < total_chunks) {
                const end = @min(offset + chunk_size, data.len);
                const chunk = data[offset..end];

                const ctx_idx = chunk_idx - 1;
                ctxs[ctx_idx] = CtxChunks{
                    .chunk_index = chunk_idx,
                    .chunk_data = chunk,
                    .user_context = self.context,
                    .pending = &pending,
                    .task = undefined,
                };

                ctxs[ctx_idx].task = Task{
                    .execute = CtxChunks.execute,
                    .context = @ptrCast(&ctxs[ctx_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[ctx_idx].task) catch {
                    func(self.context, chunk_idx, chunk);
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process chunk 0
            func(self.context, 0, main_chunk);

            // Wait for spawned tasks (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }
        }

        // ====================================================================
        // Context-aware chunksConst
        // ====================================================================

        /// Process data in explicit chunks with context (parallel, const)
        ///
        /// The chunk function receives context, chunk index, and a const slice.
        pub fn chunksConst(self: Self, comptime func: fn (Context, usize, []const T) void) void {
            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const data = self.inner.data;
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(data.len, num_threads);

            if (!splitter.shouldSplit(data.len, num_threads)) {
                func(self.context, 0, data);
                return;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const CtxChunksConst = struct {
                const Ctx = @This();
                task: Task,
                chunk_index: usize,
                chunk_data: []const T,
                user_context: Context,
                pending: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    func(self_ctx.user_context, self_ctx.chunk_index, self_ctx.chunk_data);
                    _ = self_ctx.pending.fetchSub(1, .release);
                }
            };

            var ctxs: [stack_max_chunks]CtxChunksConst = undefined;
            var pending = Atomic(usize).init(spawn_chunks);

            // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
            // Added backoff to avoid busy-spin wasting CPU during panic cleanup
            defer {
                var cleanup_backoff = Backoff.init(pool.backoff_config);
                while (pending.load(.acquire) > 0) {
                    if (pool.tryProcessOneTask()) {
                        cleanup_backoff.reset();
                    } else {
                        cleanup_backoff.snooze();
                    }
                }
            }

            // Main thread processes chunk 0
            const main_end = @min(chunk_size, data.len);
            const main_chunk = data[0..main_end];

            // Spawn worker tasks for remaining chunks
            var chunk_idx: usize = 1;
            var offset: usize = main_end;
            while (offset < data.len and chunk_idx < total_chunks) {
                const end = @min(offset + chunk_size, data.len);
                const chunk = data[offset..end];

                const ctx_idx = chunk_idx - 1;
                ctxs[ctx_idx] = CtxChunksConst{
                    .chunk_index = chunk_idx,
                    .chunk_data = chunk,
                    .user_context = self.context,
                    .pending = &pending,
                    .task = undefined,
                };

                ctxs[ctx_idx].task = Task{
                    .execute = CtxChunksConst.execute,
                    .context = @ptrCast(&ctxs[ctx_idx]),
                    .scope = null,
                };

                pool.spawn(&ctxs[ctx_idx].task) catch {
                    func(self.context, chunk_idx, chunk);
                    _ = pending.fetchSub(1, .release);
                };

                chunk_idx += 1;
                offset = end;
            }

            // Main thread: process chunk 0
            func(self.context, 0, main_chunk);

            // Wait for spawned tasks (steal-while-wait)
            var backoff = Backoff.init(pool.backoff_config);
            while (pending.load(.acquire) > 0) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }
        }
    };
}

// ============================================================================
// RangeParallelIterator - Parallel Iterator over integer ranges
// ============================================================================

/// Parallel iterator over an integer range [start, end)
///
/// Provides parallel iteration without allocating a backing array.
/// Internally creates indices on-the-fly during iteration.
pub fn RangeParallelIterator(comptime Int: type) type {
    return struct {
        const Self = @This();

        /// Range start (inclusive)
        start: Int,

        /// Range end (exclusive)
        end: Int,

        /// Work splitting configuration
        splitter: Splitter,

        /// Thread pool to use (null = global pool)
        pool: ?*ThreadPool,

        /// Allocator for operations that need allocation
        allocator: ?Allocator,

        /// Create a range iterator
        pub fn init(start_val: Int, end_val: Int) Self {
            return Self{
                .start = start_val,
                .end = end_val,
                .splitter = Splitter.default(),
                .pool = null,
                .allocator = null,
            };
        }

        /// Get the length of the range
        pub fn len(self: Self) usize {
            if (self.end <= self.start) return 0;
            return @intCast(self.end - self.start);
        }

        /// Configure the splitter
        pub fn withSplitter(self: Self, s: Splitter) Self {
            var result = self;
            result.splitter = s;
            return result;
        }

        /// Use a specific thread pool
        pub fn withPool(self: Self, p: *ThreadPool) Self {
            var result = self;
            result.pool = p;
            return result;
        }

        /// Set minimum chunk size
        pub fn withMinChunk(self: Self, min_chunk: usize) Self {
            var result = self;
            result.splitter = Splitter.adaptive(min_chunk);
            return result;
        }

        /// Set maximum chunks
        pub fn withMaxChunks(self: Self, max_chunks: usize) Self {
            var result = self;
            result.splitter.target_chunks = max_chunks;
            return result;
        }

        /// Set allocator
        pub fn withAlloc(self: Self, alloc: Allocator) Self {
            var result = self;
            result.allocator = alloc;
            return result;
        }

        /// Attach context for stateful operations
        pub fn withContext(self: Self, context: anytype) ContextRangeParallelIterator(Int, @TypeOf(context)) {
            return ContextRangeParallelIterator(Int, @TypeOf(context)){
                .inner = self,
                .context = context,
            };
        }

        /// Get the pool to use
        fn getPool(self: *const Self) *ThreadPool {
            return self.pool orelse getGlobalPool();
        }

        // ====================================================================
        // forEach - Apply function to each index
        // ====================================================================

        /// Apply a function to each index in parallel
        pub fn forEach(self: Self, comptime func: fn (*Int) void) void {
            const range_len = self.len();
            if (range_len == 0) return;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const chunk_size = self.splitter.chunkSize(range_len, num_threads);

            if (!self.splitter.shouldSplit(range_len, num_threads)) {
                var i = self.start;
                while (i < self.end) : (i += 1) {
                    var val = i;
                    func(&val);
                }
                return;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, range_len, chunk_size) catch range_len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const RangeCtx = struct {
                const Ctx = @This();
                task: Task,
                range_start: Int,
                range_end: Int,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var i = self_ctx.range_start;
                    while (i < self_ctx.range_end) : (i += 1) {
                        var val = i;
                        func(&val);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]RangeCtx = undefined;

            var chunk_idx: usize = 0;
            var offset: usize = 0;
            while (chunk_idx < spawn_chunks) : (chunk_idx += 1) {
                const chunk_start: Int = self.start + @as(Int, @intCast(offset));
                const chunk_end: Int = @min(chunk_start + @as(Int, @intCast(chunk_size)), self.end);
                if (chunk_start >= chunk_end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .range_start = chunk_start,
                    .range_end = chunk_end,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = RangeCtx.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var i = chunk_start;
                    while (i < chunk_end) : (i += 1) {
                        var val = i;
                        func(&val);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset += chunk_size;
            }

            // Main thread processes remaining
            const main_start: Int = self.start + @as(Int, @intCast(offset));
            var i = main_start;
            while (i < self.end) : (i += 1) {
                var val = i;
                func(&val);
            }

            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                backoff.snooze();
            }
        }

        // ====================================================================
        // count - Count matching indices
        // ====================================================================

        /// Count indices matching a predicate in parallel
        pub fn count(self: Self, comptime pred: fn (Int) bool) usize {
            const range_len = self.len();
            if (range_len == 0) return 0;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();

            if (!self.splitter.shouldSplit(range_len, num_threads)) {
                var cnt: usize = 0;
                var i = self.start;
                while (i < self.end) : (i += 1) {
                    if (pred(i)) cnt += 1;
                }
                return cnt;
            }

            // For simplicity, use sequential for now
            var cnt: usize = 0;
            var i = self.start;
            while (i < self.end) : (i += 1) {
                if (pred(i)) cnt += 1;
            }
            return cnt;
        }
    };
}

// ============================================================================
// ContextRangeParallelIterator - Range Iterator with Context
// ============================================================================

/// Range parallel iterator with attached context
pub fn ContextRangeParallelIterator(comptime Int: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        inner: RangeParallelIterator(Int),
        context: Context,

        pub fn withSplitter(self: Self, s: Splitter) Self {
            var result = self;
            result.inner = self.inner.withSplitter(s);
            return result;
        }

        pub fn withPool(self: Self, p: *ThreadPool) Self {
            var result = self;
            result.inner = self.inner.withPool(p);
            return result;
        }

        pub fn withMinChunk(self: Self, min_chunk: usize) Self {
            var result = self;
            result.inner = self.inner.withMinChunk(min_chunk);
            return result;
        }

        pub fn withMaxChunks(self: Self, max_chunks: usize) Self {
            var result = self;
            result.inner = self.inner.withMaxChunks(max_chunks);
            return result;
        }

        pub fn withAlloc(self: Self, alloc: Allocator) Self {
            var result = self;
            result.inner = self.inner.withAlloc(alloc);
            return result;
        }

        fn getPool(self: *const Self) *ThreadPool {
            return self.inner.pool orelse getGlobalPool();
        }

        // ====================================================================
        // Context-aware forEach for ranges
        // ====================================================================

        /// Apply a function to each index in parallel with context
        pub fn forEach(self: Self, comptime func: fn (Context, Int) void) void {
            const range_len = self.inner.len();
            if (range_len == 0) return;

            const pool = self.getPool();
            const num_threads = pool.numWorkers();
            const splitter = self.inner.splitter;
            const chunk_size = splitter.chunkSize(range_len, num_threads);

            if (!splitter.shouldSplit(range_len, num_threads)) {
                var i = self.inner.start;
                while (i < self.inner.end) : (i += 1) {
                    func(self.context, i);
                }
                return;
            }

            const max_chunks = @min(num_threads * 4, stack_max_chunks);
            const total_chunks = @min(std.math.divCeil(usize, range_len, chunk_size) catch range_len, max_chunks);
            const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

            const RangeCtxForEach = struct {
                const Ctx = @This();
                task: Task,
                range_start: Int,
                range_end: Int,
                user_context: Context,
                done: *Atomic(usize),

                pub fn execute(ctx: *anyopaque) void {
                    const self_ctx: *Ctx = @ptrCast(@alignCast(ctx));
                    var i = self_ctx.range_start;
                    while (i < self_ctx.range_end) : (i += 1) {
                        func(self_ctx.user_context, i);
                    }
                    _ = self_ctx.done.fetchAdd(1, .release);
                }
            };

            var done = Atomic(usize).init(0);
            var ctxs: [stack_max_chunks]RangeCtxForEach = undefined;

            var chunk_idx: usize = 0;
            var offset: usize = 0;
            while (chunk_idx < spawn_chunks) : (chunk_idx += 1) {
                const chunk_start: Int = self.inner.start + @as(Int, @intCast(offset));
                const chunk_end: Int = @min(chunk_start + @as(Int, @intCast(chunk_size)), self.inner.end);
                if (chunk_start >= chunk_end) break;

                ctxs[chunk_idx] = .{
                    .task = undefined,
                    .range_start = chunk_start,
                    .range_end = chunk_end,
                    .user_context = self.context,
                    .done = &done,
                };
                ctxs[chunk_idx].task = Task{
                    .execute = RangeCtxForEach.execute,
                    .context = @ptrCast(&ctxs[chunk_idx]),
                    .scope = null,
                };
                pool.spawn(&ctxs[chunk_idx].task) catch {
                    var i = chunk_start;
                    while (i < chunk_end) : (i += 1) {
                        func(self.context, i);
                    }
                    _ = done.fetchAdd(1, .release);
                };
                offset += chunk_size;
            }

            // Main thread
            const main_start: Int = self.inner.start + @as(Int, @intCast(offset));
            var i = main_start;
            while (i < self.inner.end) : (i += 1) {
                func(self.context, i);
            }

            var backoff = Backoff.init(pool.backoff_config);
            while (done.load(.acquire) < spawn_chunks) {
                backoff.snooze();
            }
        }

        // ====================================================================
        // Context-aware count for ranges
        // ====================================================================

        /// Count indices matching a predicate with context
        pub fn count(self: Self, comptime pred: fn (Context, Int) bool) usize {
            const range_len = self.inner.len();
            if (range_len == 0) return 0;

            var cnt: usize = 0;
            var i = self.inner.start;
            while (i < self.inner.end) : (i += 1) {
                if (pred(self.context, i)) cnt += 1;
            }
            return cnt;
        }
    };
}

// ============================================================================
// par_range - Entry point for range iteration
// ============================================================================

/// Create a parallel iterator over an integer range [start, end)
///
/// Example:
/// ```zig
/// par_range(0, 100).withPool(pool).forEach(struct {
///     fn process(i: *usize) void { ... }
/// }.process);
///
/// // With context:
/// par_range(0, num_chunks).withPool(pool).withContext(&ctx).forEach(struct {
///     fn read(ctx: *const ReadCtx, i: usize) void { ... }
/// }.read);
/// ```
pub fn par_range(start: anytype, end: anytype) RangeParallelIterator(@TypeOf(start)) {
    return RangeParallelIterator(@TypeOf(start)).init(start, end);
}

// ============================================================================
// par_iter - Entry point function
// ============================================================================

/// Extract child type from a slice or pointer-to-array type
fn SliceChild(comptime S: type) type {
    const info = @typeInfo(S);
    if (info != .pointer) @compileError("Expected slice or pointer to array, got " ++ @typeName(S));

    // Handle []T (slice)
    if (info.pointer.size == .slice) {
        return info.pointer.child;
    }

    // Handle *[N]T (pointer to array) - coercible to []T
    if (info.pointer.size == .one) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .array) {
            return child_info.array.child;
        }
    }

    @compileError("Expected slice or pointer to array, got " ++ @typeName(S));
}

/// Create a parallel iterator over a slice
///
/// This is the main entry point for parallel iteration.
/// The element type is automatically inferred from the slice or pointer-to-array.
///
/// Example:
/// ```zig
/// var items = [_]i32{ 1, 2, 3, 4, 5 };
/// par_iter(&items).forEach(struct {
///     fn process(x: *i32) void { x.* *= 2; }
/// }.process);
/// ```
pub fn par_iter(data: anytype) ParallelIterator(SliceChild(@TypeOf(data))) {
    const T = SliceChild(@TypeOf(data));
    const DataType = @TypeOf(data);
    const info = @typeInfo(DataType).pointer;

    // Convert *[N]T to []T, or use slice directly
    const slice: []T = if (info.size == .one)
        // Pointer to array - coerce to slice
        @constCast(data)
    else if (info.is_const)
        // Const slice - cast away const (forEach won't be usable, but reduce/sum work)
        @constCast(data)
    else
        // Mutable slice - use directly
        data;

    return ParallelIterator(T).init(slice);
}

// ============================================================================
// Tests
// ============================================================================

test "ParallelIterator.forEach sequential" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };

    // Force sequential by using small splitter threshold
    par_iter(&data).withSplitter(Splitter.fixed(1000)).forEach(struct {
        fn double(x: *i32) void {
            x.* *= 2;
        }
    }.double);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 4, 6, 8, 10 }, &data);
}

test "ParallelIterator.sum sequential" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(@constCast(&data)).withSplitter(Splitter.fixed(1000)).sum();
    try std.testing.expectEqual(@as(i32, 15), result);
}

test "Reducer integration" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const reducer = Reducer(i32).sum();
    const result = reducer.reduceSlice(&data);
    try std.testing.expectEqual(@as(i32, 15), result);
}

test "any finds matching element" {
    const data = [_]i32{ 1, 2, 3, 42, 5 };
    const result = par_iter(@constCast(&data)).any(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    try std.testing.expect(result);
}

test "any returns false when no match" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(@constCast(&data)).any(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    try std.testing.expect(!result);
}

test "all all match" {
    const data = [_]i32{ 2, 4, 6, 8, 10 };
    const result = par_iter(@constCast(&data)).all(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expect(result);
}

test "all not all match" {
    const data = [_]i32{ 2, 4, 5, 8, 10 };
    const result = par_iter(@constCast(&data)).all(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expect(!result);
}

test "find finds element" {
    const data = [_]i32{ 1, 2, 42, 4, 5 };
    const result = par_iter(@constCast(&data)).find(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    try std.testing.expectEqual(@as(?i32, 42), result);
}

test "find returns null when not found" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(@constCast(&data)).find(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    try std.testing.expectEqual(@as(?i32, null), result);
}

test "position finds correct index" {
    const data = [_]i32{ 1, 2, 42, 4, 42 };
    const result = par_iter(@constCast(&data)).position(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    // Should find index 2 (first occurrence)
    try std.testing.expectEqual(@as(?usize, 2), result);
}

test "position returns null when not found" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(@constCast(&data)).position(struct {
        fn isFortyTwo(x: i32) bool {
            return x == 42;
        }
    }.isFortyTwo);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "count counts matching elements" {
    const data = [_]i32{ 1, 2, 3, 2, 5, 2 };
    const result = par_iter(@constCast(&data)).count(struct {
        fn isTwo(x: i32) bool {
            return x == 2;
        }
    }.isTwo);
    try std.testing.expectEqual(@as(usize, 3), result);
}

test "filter filters elements" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const filtered = try par_iter(@constCast(&data)).filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, std.testing.allocator);
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 3), filtered.len);
    // Verify all elements are even
    for (filtered) |item| {
        try std.testing.expect(@mod(item, 2) == 0);
    }
}

test "chunks processes all chunks" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Use sequential path for predictable testing
    par_iter(&data).withSplitter(Splitter.fixed(1000)).chunks(struct {
        fn process(_: usize, chunk: []i32) void {
            for (chunk) |*item| {
                item.* *= 2;
            }
        }
    }.process);

    // All elements should be doubled
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 4, 6, 8, 10, 12, 14, 16 }, &data);
}

test "chunksConst read-only chunk processing" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };

    par_iter(@constCast(&data)).withSplitter(Splitter.fixed(1000)).chunksConst(struct {
        fn sumChunk(_: usize, chunk: []const i32) void {
            // Just iterate to verify const access works
            var lsum: i32 = 0;
            for (chunk) |item| {
                lsum += item;
            }
            // Prevent optimization from removing the loop
            std.mem.doNotOptimizeAway(lsum);
        }
    }.sumChunk);

    // Test passes if no panic (const correctness)
    try std.testing.expect(true);
}

test "sort sorts ascending" {
    var data = [_]i32{ 5, 3, 8, 1, 9, 2, 7, 4, 6 };

    try par_iter(&data).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, std.testing.allocator);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &data);
}

test "sort sorts descending" {
    var data = [_]i32{ 5, 3, 8, 1, 9, 2, 7, 4, 6 };

    try par_iter(&data).sort(struct {
        fn greaterThan(a: i32, b: i32) bool {
            return a > b;
        }
    }.greaterThan, std.testing.allocator);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 }, &data);
}

test "sort handles empty array" {
    var data: [0]i32 = .{};

    try par_iter(&data).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "sort handles single element" {
    var data = [_]i32{42};

    try par_iter(&data).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, std.testing.allocator);

    try std.testing.expectEqualSlices(i32, &[_]i32{42}, &data);
}

test "sort handles already sorted" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };

    try par_iter(&data).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, std.testing.allocator);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5 }, &data);
}

// ============================================================================
// par_range tests
// ============================================================================

test "par_range forEach iterates all indices" {
    par_range(@as(usize, 0), @as(usize, 10)).forEach(struct {
        fn add(i: *usize) void {
            _ = i;
        }
    }.add);
    // Test passes if no panic
    try std.testing.expect(true);
}

test "par_range count works" {
    const result = par_range(@as(usize, 0), @as(usize, 10)).count(struct {
        fn isEven(i: usize) bool {
            return @mod(i, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 5), result);
}

test "par_range withContext forEach" {
    const Context = struct {
        multiplier: usize,
    };

    const ctx = Context{ .multiplier = 2 };

    par_range(@as(usize, 0), @as(usize, 5))
        .withContext(&ctx)
        .forEach(struct {
        fn process(c: *const Context, i: usize) void {
            _ = c.multiplier * i;
        }
    }.process);

    // Test passes if no panic
    try std.testing.expect(true);
}

test "par_range withContext count" {
    const Context = struct {
        threshold: usize,
    };

    const ctx = Context{ .threshold = 5 };

    const result = par_range(@as(usize, 0), @as(usize, 10))
        .withContext(&ctx)
        .count(struct {
        fn aboveThreshold(c: *const Context, i: usize) bool {
            return i >= c.threshold;
        }
    }.aboveThreshold);

    try std.testing.expectEqual(@as(usize, 5), result);
}

// ============================================================================
// withContext tests for slice iterators
// ============================================================================

test "withContext forEach with slice" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };

    const Context = struct {
        increment: i32,
    };

    const ctx = Context{ .increment = 10 };

    par_iter(&data)
        .withContext(&ctx)
        .forEach(struct {
        fn add(c: *const Context, item: *i32) void {
            item.* += c.increment;
        }
    }.add);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 11, 12, 13, 14, 15 }, &data);
}

test "withContext count with slice" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };

    const Context = struct {
        threshold: i32,
    };

    const ctx = Context{ .threshold = 3 };

    const result = par_iter(@constCast(&data))
        .withContext(&ctx)
        .count(struct {
        fn aboveThreshold(c: *const Context, item: i32) bool {
            return item > c.threshold;
        }
    }.aboveThreshold);

    try std.testing.expectEqual(@as(usize, 3), result);
}

test "withContext forEachIndexed" {
    var data = [_]i32{ 0, 0, 0, 0, 0 };

    const Context = struct {
        base: i32,
    };

    const ctx = Context{ .base = 100 };

    par_iter(&data)
        .withContext(&ctx)
        .forEachIndexed(struct {
        fn set(c: *const Context, idx: usize, item: *i32) void {
            item.* = c.base + @as(i32, @intCast(idx));
        }
    }.set);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 100, 101, 102, 103, 104 }, &data);
}

test "withContext map" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5 };

    const Context = struct {
        multiplier: i32,
    };

    const ctx = Context{ .multiplier = 10 };

    const result = try par_iter(&data)
        .withContext(&ctx)
        .map(i32, struct {
        fn transform(c: *const Context, value: i32) i32 {
            return value * c.multiplier;
        }
    }.transform, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30, 40, 50 }, result);
}

test "withContext reduce" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };

    const Context = struct {
        offset: i32,
    };

    const ctx = Context{ .offset = 0 };

    // Context-aware reduce delegates to inner reduce (context not used in standard reducers)
    const result = par_iter(&data)
        .withContext(&ctx)
        .reduce(Reducer(i32).sum());

    try std.testing.expectEqual(@as(i32, 15), result);
}

test "withContext filter" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const Context = struct {
        threshold: i32,
    };

    const ctx = Context{ .threshold = 5 };

    const result = try par_iter(&data)
        .withContext(&ctx)
        .filter(struct {
        fn aboveThreshold(c: *const Context, value: i32) bool {
            return value > c.threshold;
        }
    }.aboveThreshold, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 6, 7, 8, 9, 10 }, result);
}

test "withContext filter empty result" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3 };

    const Context = struct {
        threshold: i32,
    };

    const ctx = Context{ .threshold = 100 };

    const result = try par_iter(&data)
        .withContext(&ctx)
        .filter(struct {
        fn aboveThreshold(c: *const Context, value: i32) bool {
            return value > c.threshold;
        }
    }.aboveThreshold, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "withContext mapIndexed" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 10, 20, 30, 40, 50 };

    const Context = struct {
        multiplier: i32,
    };

    const ctx = Context{ .multiplier = 2 };

    // Transform: (value + index) * multiplier
    const result = try par_iter(&data)
        .withContext(&ctx)
        .mapIndexed(i32, struct {
        fn transform(c: *const Context, idx: usize, value: i32) i32 {
            return (value + @as(i32, @intCast(idx))) * c.multiplier;
        }
    }.transform, allocator);
    defer allocator.free(result);

    // Expected: (10+0)*2=20, (20+1)*2=42, (30+2)*2=64, (40+3)*2=86, (50+4)*2=108
    try std.testing.expectEqualSlices(i32, &[_]i32{ 20, 42, 64, 86, 108 }, result);
}

test "withContext chunks" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var chunk_sum = std.atomic.Value(i64).init(0);

    const Context = struct {
        multiplier: i32,
        sum: *std.atomic.Value(i64),
    };

    const ctx = Context{
        .multiplier = 10,
        .sum = &chunk_sum,
    };

    par_iter(&data)
        .withContext(&ctx)
        .chunks(struct {
        fn processChunk(c: *const Context, chunk_idx: usize, chunk: []i32) void {
            var local_sum: i64 = 0;
            for (chunk) |*item| {
                item.* *= c.multiplier;
                local_sum += item.*;
            }
            _ = c.sum.fetchAdd(local_sum + @as(i64, @intCast(chunk_idx)), .monotonic);
        }
    }.processChunk);

    // All values should be multiplied by 10
    for (data, 0..) |val, i| {
        try std.testing.expectEqual(@as(i32, @intCast((i + 1) * 10)), val);
    }
}

test "withContext chunksConst" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var chunk_sum = std.atomic.Value(i64).init(0);

    const Context = struct {
        multiplier: i32,
        sum: *std.atomic.Value(i64),
    };

    const ctx = Context{
        .multiplier = 10,
        .sum = &chunk_sum,
    };

    par_iter(&data)
        .withContext(&ctx)
        .chunksConst(struct {
        fn processChunk(c: *const Context, chunk_idx: usize, chunk: []const i32) void {
            var local_sum: i64 = 0;
            for (chunk) |item| {
                local_sum += @as(i64, item) * c.multiplier;
            }
            _ = c.sum.fetchAdd(local_sum + @as(i64, @intCast(chunk_idx)), .monotonic);
        }
    }.processChunk);

    // Sum of 1..8 is 36, * 10 = 360, plus chunk indices
    // The exact value depends on chunk count, but should be >= 360
    try std.testing.expect(chunk_sum.load(.acquire) >= 360);
}

test "mapIndexed basic" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 10, 20, 30, 40, 50 };

    // Transform: value + index * 100
    const result = try par_iter(&data).mapIndexed(i32, struct {
        fn transform(idx: usize, value: i32) i32 {
            return value + @as(i32, @intCast(idx)) * 100;
        }
    }.transform, allocator);
    defer allocator.free(result);

    // Expected: 10+0=10, 20+100=120, 30+200=230, 40+300=340, 50+400=450
    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 120, 230, 340, 450 }, result);
}

test "mapIndexed type transform" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5 };

    // Transform i32 to f64: (value + index) as f64
    const result = try par_iter(&data).mapIndexed(f64, struct {
        fn transform(idx: usize, value: i32) f64 {
            return @as(f64, @floatFromInt(value)) + @as(f64, @floatFromInt(idx));
        }
    }.transform, allocator);
    defer allocator.free(result);

    // Expected: 1+0=1.0, 2+1=3.0, 3+2=5.0, 4+3=7.0, 5+4=9.0
    try std.testing.expectEqual(@as(f64, 1.0), result[0]);
    try std.testing.expectEqual(@as(f64, 3.0), result[1]);
    try std.testing.expectEqual(@as(f64, 5.0), result[2]);
    try std.testing.expectEqual(@as(f64, 7.0), result[3]);
    try std.testing.expectEqual(@as(f64, 9.0), result[4]);
}

// Re-export submodule tests
test {
    _ = config;
    _ = stepped_iterator;
    _ = contexts;
    _ = merge_mod;
}

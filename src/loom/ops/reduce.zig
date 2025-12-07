// reduce.zig - Parallel Reduce Operations
//
// Tree-based parallel reduction with work-stealing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("../pool/thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;

const reducer_mod = @import("../util/reducer.zig");
pub const Reducer = reducer_mod.Reducer;

const config = @import("../iter/config.zig");
const stack_max_chunks = config.stack_max_chunks;
const heap_max_chunks = config.heap_max_chunks;

const contexts = @import("../iter/contexts.zig");
const ReduceContextStack = contexts.ReduceContextStack;

// ============================================================================
// Constants
// ============================================================================

/// Stack usage threshold for partial results array
const stack_threshold = 4096; // 4KB - safe stack usage limit

// ============================================================================
// reduce Implementation
// ============================================================================

/// Parallel reduce with tree-based final combination
pub fn reduce(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?Allocator,
    reducer: Reducer(T),
) T {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    // Calculate stack usage for partial results
    const would_use_stack = @sizeOf(T) * stack_max_chunks;

    // For large T without allocator, fall back to sequential to avoid stack overflow
    if (would_use_stack > stack_threshold and allocator == null) {
        return reducer.reduceSlice(data);
    }

    if (!splitter.shouldSplit(data.len, num_threads)) {
        return reducer.reduceSlice(data);
    }

    // Issue 55 fix: Use heap_max_chunks when allocator available
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);
    const min_chunk_size = splitter.chunkSize(data.len, num_threads);
    const chunk_size = @max(min_chunk_size, (data.len + max_chunks - 1) / max_chunks);

    // Calculate actual number of chunks needed
    const num_chunks = std.math.divCeil(usize, data.len, chunk_size) catch data.len;
    const total_chunks = @min(num_chunks, max_chunks);

    // Reserve first chunk for main thread
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    // Use heap allocation for large T to avoid stack overflow
    if (would_use_stack > stack_threshold) {
        return reduceHeapAlloc(T, data, pool, allocator.?, total_chunks, spawn_chunks, chunk_size, reducer);
    }

    // Stack-allocated partial results and contexts - safe for small T
    var partial_results: [stack_max_chunks]T = undefined;
    for (&partial_results) |*r| {
        r.* = reducer.identity;
    }

    const Context = ReduceContextStack(T);
    var ctxs: [stack_max_chunks]Context = undefined;

    // Completion counter
    var pending = Atomic(usize).init(spawn_chunks);
    var panicked = Atomic(bool).init(false);

    // Issue 27/48/54 fix: Cleanup defer
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
    const main_chunk_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_chunk_end];

    // Spawn tasks for remaining chunks
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];
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
            // Issue 64 fix
            defer _ = pending.fetchSub(1, .release);
            var acc = reducer.identity;
            for (chunk) |item| {
                acc = reducer.combine(acc, item);
            }
            partial_results[result_idx] = acc;
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process remaining data if we hit chunk limit
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        var acc = reducer.identity;
        for (data[offset..end]) |item| {
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

    if (panicked.load(.acquire)) {
        @panic("parallel reduce: chunk panicked");
    }

    // Tree-based final reduction
    return treeReduce(T, partial_results[0..total_chunks], reducer);
}

/// Internal: heap-allocated reduce for large T types
fn reduceHeapAlloc(
    comptime T: type,
    data: []const T,
    pool: *ThreadPool,
    allocator: Allocator,
    total_chunks: usize,
    spawn_chunks: usize,
    chunk_size: usize,
    reducer: Reducer(T),
) T {
    // Heap-allocate partial results
    const partial_results = allocator.alloc(T, total_chunks) catch {
        if (@import("builtin").mode == .Debug) {
            std.log.warn("parallel reduce: falling back to sequential (partial_results alloc failed)", .{});
        }
        return reducer.reduceSlice(data);
    };
    defer allocator.free(partial_results);

    for (partial_results) |*r| {
        r.* = reducer.identity;
    }

    // Heap-allocate contexts
    const Context = ReduceContextStack(T);
    const ctxs = allocator.alloc(Context, spawn_chunks) catch {
        if (@import("builtin").mode == .Debug) {
            std.log.warn("parallel reduce: falling back to sequential (contexts alloc failed)", .{});
        }
        return reducer.reduceSlice(data);
    };
    defer allocator.free(ctxs);

    var pending = Atomic(usize).init(spawn_chunks);
    var panicked = Atomic(bool).init(false);

    // Cleanup defer
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
    const main_chunk_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_chunk_end];

    // Spawn tasks
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];
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
            defer _ = pending.fetchSub(1, .release);
            var acc = reducer.identity;
            for (chunk) |item| {
                acc = reducer.combine(acc, item);
            }
            partial_results[result_idx] = acc;
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process remaining data
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        var acc = reducer.identity;
        for (data[offset..end]) |item| {
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

    // Wait for completion
    var backoff = Backoff.init(pool.backoff_config);
    while (pending.load(.acquire) > 0) {
        if (pool.tryProcessOneTask()) {
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }

    if (panicked.load(.acquire)) {
        @panic("parallel reduce: chunk panicked");
    }

    return treeReduce(T, partial_results, reducer);
}

/// Tree-based final reduction for better cache locality
/// Combine adjacent pairs: [a,b,c,d,e,f,g,h] -> [ab,cd,ef,gh] -> [abcd,efgh] -> [result]
fn treeReduce(comptime T: type, partial_results: []T, reducer: Reducer(T)) T {
    if (partial_results.len == 0) return reducer.identity;

    var active_count = partial_results.len;
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

    return partial_results[0];
}

// ============================================================================
// Tests
// ============================================================================

test "reduce sum" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = reduce(i32, &data, splitter, null, null, Reducer(i32).sum());
    try std.testing.expectEqual(@as(i32, 15), result);
}

test "reduce product" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = reduce(i32, &data, splitter, null, null, Reducer(i32).product());
    try std.testing.expectEqual(@as(i32, 120), result);
}

test "treeReduce correctness" {
    var results = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const sum = treeReduce(i32, &results, Reducer(i32).sum());
    try std.testing.expectEqual(@as(i32, 36), sum);
}

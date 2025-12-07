// for_each.zig - forEach and forEachIndexed Operations
//
// Parallel for-each operations that apply a function to each element.

const std = @import("std");
const Atomic = std.atomic.Value;

const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("../pool/thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;

const config = @import("../iter/config.zig");
const stack_max_chunks = config.stack_max_chunks;
const heap_max_chunks = config.heap_max_chunks;
const allocContextsIfNeeded = config.allocContextsIfNeeded;
const freeContextsIfNeeded = config.freeContextsIfNeeded;

const contexts = @import("../iter/contexts.zig");
const ForEachContextStack = contexts.ForEachContextStack;
const ForEachIndexedContextStack = contexts.ForEachIndexedContextStack;

// ============================================================================
// forEach Implementation
// ============================================================================

/// Apply a function to each element in parallel
///
/// Parameters:
/// - T: Element type
/// - data: The slice to iterate over
/// - splitter: Work splitting configuration
/// - pool_opt: Thread pool to use (null = global pool)
/// - allocator: Optional allocator for heap context allocation
/// - func: Function to apply to each element
pub fn forEach(
    comptime T: type,
    data: []T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime func: fn (*T) void,
) void {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path for small data
        for (data) |*item| {
            func(item);
        }
        return;
    }

    // Issue 55 fix: Use heap_max_chunks when allocator available for better many-core scaling
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);

    // Reserve first chunk for main thread - only spawn (total_chunks - 1)
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    // Issue 21 fix: Use heap allocation for large contexts if allocator available
    // Issue 60 fix: Fall back to sequential if heap allocation is required but fails
    const Context = ForEachContextStack(T, func);
    const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks) catch {
        // Heap allocation required but failed - fall back to sequential
        for (data) |*item| {
            func(item);
        }
        return;
    };
    var stack_contexts: [stack_max_chunks]Context = undefined;
    const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
    defer freeContextsIfNeeded(Context, heap_contexts, allocator);

    // Completion counter (only for spawned tasks)
    var pending = Atomic(usize).init(spawn_chunks);
    // Issue 10 fix: Panic flag for detecting chunk panics
    var panicked = Atomic(bool).init(false);

    // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds on panic
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
    const main_chunk_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_chunk_end];

    // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

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
            // Issue 64 fix: Use defer to ensure counter is updated even on panic
            defer _ = pending.fetchSub(1, .release);
            // Execute locally on failure
            for (chunk) |*item| {
                func(item);
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process remaining data if we hit chunk limit
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        for (data[offset..end]) |*item| {
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

// ============================================================================
// forEachIndexed Implementation
// ============================================================================

/// Apply a function to each element with its index in parallel
pub fn forEachIndexed(
    comptime T: type,
    data: []T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime func: fn (usize, *T) void,
) void {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path for small data
        for (data, 0..) |*item, i| {
            func(i, item);
        }
        return;
    }

    // Issue 55 fix: Use heap_max_chunks when allocator available
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);

    // Reserve first chunk for main thread
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    // Issue 21/60 fix: Heap allocation with fallback
    const Context = ForEachIndexedContextStack(T, func);
    const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks) catch {
        // Fall back to sequential
        for (data, 0..) |*item, i| {
            func(i, item);
        }
        return;
    };
    var stack_contexts: [stack_max_chunks]Context = undefined;
    const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
    defer freeContextsIfNeeded(Context, heap_contexts, allocator);

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

    // Main chunk
    const main_chunk_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_chunk_end];

    // Spawn worker tasks
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

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
            // Issue 64 fix
            defer _ = pending.fetchSub(1, .release);
            for (chunk, 0..) |*item, i| {
                func(offset + i, item);
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process overflow chunks
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        for (data[offset..end], 0..) |*item, i| {
            func(offset + i, item);
        }
        offset = end;
    }

    // Main thread processes first chunk
    for (main_chunk, 0..) |*item, i| {
        func(i, item);
    }

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
        @panic("parallel forEachIndexed: chunk panicked");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "forEach basic" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    forEach(i32, &data, splitter, null, null, struct {
        fn double(x: *i32) void {
            x.* *= 2;
        }
    }.double);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 4, 6, 8, 10 }, &data);
}

test "forEachIndexed basic" {
    var data = [_]i32{ 10, 20, 30, 40, 50 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    forEachIndexed(i32, &data, splitter, null, null, struct {
        fn addIndex(idx: usize, x: *i32) void {
            x.* += @intCast(idx);
        }
    }.addIndex);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 21, 32, 43, 54 }, &data);
}

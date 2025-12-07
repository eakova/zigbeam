// map.zig - Parallel Map Operations
//
// Transform elements in parallel, producing new arrays:
// - map: Transform each element
// - mapIndexed: Transform each element with its index

const std = @import("std");
const Allocator = std.mem.Allocator;
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
const MapContextStack = contexts.MapContextStack;
const MapIndexedContextStack = contexts.MapIndexedContextStack;

// ============================================================================
// map Implementation
// ============================================================================

/// Transform each element in parallel, producing a new array
///
/// Parameters:
/// - T: Source element type
/// - U: Destination element type
/// - data: Source slice to transform
/// - splitter: Work splitting configuration
/// - pool_opt: Thread pool to use (null = global pool)
/// - allocator: Allocator for result array (required)
/// - func: Transformation function
///
/// Returns: Newly allocated array of transformed elements
/// Note: Caller owns returned memory and must free it.
pub fn map(
    comptime T: type,
    comptime U: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: Allocator,
    comptime func: fn (T) U,
) ![]U {
    const result = try allocator.alloc(U, data.len);
    errdefer allocator.free(result);

    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        for (data, 0..) |item, i| {
            result[i] = func(item);
        }
        return result;
    }

    // Issue 55 fix: Use heap_max_chunks for better many-core scaling
    const max_chunks = @min(num_threads * 4, heap_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);

    // Reserve first chunk for main thread - only spawn (total_chunks - 1)
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    // Issue 21 fix: Use heap allocation for large contexts if allocator available
    // Issue 60 fix: Fall back to sequential if heap allocation is required but fails
    const Context = MapContextStack(T, U, func);
    const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks) catch {
        // Heap allocation required but failed - fall back to sequential
        for (data, 0..) |item, i| {
            result[i] = func(item);
        }
        return result;
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
    const main_src_chunk = data[0..main_chunk_end];
    const main_dst_chunk = result[0..main_chunk_end];

    // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const src_chunk = data[offset..end];
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
            // Issue 64 fix: Use defer to ensure counter is updated even on panic
            defer _ = pending.fetchSub(1, .release);
            // Execute locally on failure
            for (src_chunk, dst_chunk) |item, *out| {
                out.* = func(item);
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process remaining data if we hit chunk limit
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        for (data[offset..end], result[offset..end]) |item, *out| {
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

// ============================================================================
// mapIndexed Implementation
// ============================================================================

/// Transform each element with index in parallel, producing a new array
///
/// Similar to map but the function receives both the index and value.
/// Note: Caller owns returned memory and must free it.
pub fn mapIndexed(
    comptime T: type,
    comptime U: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: Allocator,
    comptime func: fn (usize, T) U,
) ![]U {
    const result = try allocator.alloc(U, data.len);
    errdefer allocator.free(result);

    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        for (data, 0..) |item, i| {
            result[i] = func(i, item);
        }
        return result;
    }

    // Stack array uses module-level stack_max_chunks constant
    const max_chunks = @min(num_threads * 4, stack_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);

    // Reserve first chunk for main thread - only spawn (total_chunks - 1)
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    // Use heap allocation for large contexts if allocator available
    // Issue 60 fix: Fall back to sequential if heap allocation is required but fails
    const Context = MapIndexedContextStack(T, U, func);
    const heap_contexts = allocContextsIfNeeded(Context, allocator, spawn_chunks) catch {
        // Heap allocation required but failed - fall back to sequential
        for (data, 0..) |item, i| {
            result[i] = func(i, item);
        }
        return result;
    };
    var stack_contexts: [stack_max_chunks]Context = undefined;
    const ctxs: []Context = if (heap_contexts) |hc| hc else stack_contexts[0..spawn_chunks];
    defer freeContextsIfNeeded(Context, heap_contexts, allocator);

    // Completion counter (only for spawned tasks)
    var pending = Atomic(usize).init(spawn_chunks);
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
    const main_src_chunk = data[0..main_chunk_end];
    const main_dst_chunk = result[0..main_chunk_end];

    // Spawn tasks for remaining chunks (skip first chunk - main thread will do it)
    var chunk_idx: usize = 0;
    var offset: usize = main_chunk_end;
    while (offset < data.len and chunk_idx < spawn_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const src_chunk = data[offset..end];
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
            // Issue 64 fix: Use defer to ensure counter is updated even on panic
            defer _ = pending.fetchSub(1, .release);
            // Execute locally on failure
            for (src_chunk, dst_chunk, 0..) |item, *out, i| {
                out.* = func(offset + i, item);
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Process remaining data if we hit chunk limit
    while (offset < data.len) {
        const end = @min(offset + chunk_size, data.len);
        for (data[offset..end], result[offset..end], 0..) |item, *out, i| {
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

// ============================================================================
// Tests
// ============================================================================

test "map basic" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try map(i32, i64, &data, splitter, null, allocator, struct {
        fn double(x: i32) i64 {
            return @as(i64, x) * 2;
        }
    }.double);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(i64, &[_]i64{ 2, 4, 6, 8, 10 }, result);
}

test "mapIndexed basic" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 10, 20, 30, 40, 50 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try mapIndexed(i32, i64, &data, splitter, null, allocator, struct {
        fn addIndex(idx: usize, x: i32) i64 {
            return @as(i64, x) + @as(i64, @intCast(idx));
        }
    }.addIndex);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(i64, &[_]i64{ 10, 21, 32, 43, 54 }, result);
}

test "map empty slice" {
    const allocator = std.testing.allocator;
    const data = [_]i32{};
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try map(i32, i64, &data, splitter, null, allocator, struct {
        fn double(x: i32) i64 {
            return @as(i64, x) * 2;
        }
    }.double);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// chunks.zig - Parallel Chunk Processing Operations
//
// Process data in explicit chunks with user-provided functions:
// - chunks: Mutable chunk processing
// - chunksConst: Read-only chunk processing

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

const contexts = @import("../iter/contexts.zig");
const ParChunksContext = contexts.ParChunksContext;
const ParChunksConstContext = contexts.ParChunksConstContext;

// ============================================================================
// chunks Implementation
// ============================================================================

/// Process data in explicit chunks with a user-provided function (parallel)
///
/// The function receives (chunk_index, chunk_data) and can process
/// the chunk however needed. Useful for operations requiring chunk
/// boundaries or custom per-chunk logic.
///
/// Parameters:
/// - T: Element type
/// - data: Mutable slice to process
/// - splitter: Work splitting configuration
/// - pool_opt: Thread pool to use (null = global pool)
/// - allocator_hint: Optional allocator for max_chunks calculation
/// - func: Function to apply to each chunk
pub fn chunks(
    comptime T: type,
    data: []T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator_hint: ?std.mem.Allocator,
    comptime func: fn (usize, []T) void,
) void {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential: single chunk
        func(0, data);
        return;
    }

    // Issue 55 fix: Use heap_max_chunks when allocator available
    const max_chunks = if (allocator_hint != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    const Context = ParChunksContext(T, func);
    var ctxs: [stack_max_chunks]Context = undefined;
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
            defer _ = pending.fetchSub(1, .release);
            func(chunk_idx, chunk);
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

    if (panicked.load(.acquire)) {
        @panic("parallel chunks: chunk panicked");
    }
}

// ============================================================================
// chunksConst Implementation
// ============================================================================

/// Process data in explicit chunks - const version (parallel)
///
/// Same as chunks() but for read-only operations.
pub fn chunksConst(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator_hint: ?std.mem.Allocator,
    comptime func: fn (usize, []const T) void,
) void {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();
    const chunk_size = splitter.chunkSize(data.len, num_threads);

    if (!splitter.shouldSplit(data.len, num_threads)) {
        func(0, data);
        return;
    }

    // Issue 55 fix: Use heap_max_chunks when allocator available
    const max_chunks = if (allocator_hint != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    const Context = ParChunksConstContext(T, func);
    var ctxs: [stack_max_chunks]Context = undefined;
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

    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];

    var chunk_idx: usize = 1;
    var offset: usize = main_end;
    while (offset < data.len and chunk_idx < total_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

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
            defer _ = pending.fetchSub(1, .release);
            func(chunk_idx, chunk);
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

    if (panicked.load(.acquire)) {
        @panic("parallel chunksConst: chunk panicked");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "chunks basic" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    // Each chunk doubles its elements
    chunks(i32, &data, splitter, null, null, struct {
        fn processChunk(_: usize, chunk: []i32) void {
            for (chunk) |*item| {
                item.* *= 2;
            }
        }
    }.processChunk);

    // All elements should be doubled
    for (data) |item| {
        std.testing.expect(@mod(item, 2) == 0) catch unreachable;
    }
}

test "chunksConst basic" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    // Just verify chunksConst runs without error (read-only iteration)
    chunksConst(i32, &data, splitter, null, null, struct {
        fn processChunk(_: usize, chunk: []const i32) void {
            // Read-only access to verify no crash
            for (chunk) |_| {}
        }
    }.processChunk);
}

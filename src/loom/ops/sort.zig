// sort.zig - Parallel Sort Operation
//
// Parallel merge sort implementation:
// 1. Parallel sort of chunks (each chunk sorted sequentially)
// 2. Bottom-up merge of sorted chunks

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

const merge_mod = @import("../iter/merge.zig");
const parallelMergeTopLevel = merge_mod.parallelMergeTopLevel;
const merge = merge_mod.merge;

const contexts = @import("../iter/contexts.zig");
const ParSortChunkContext = contexts.ParSortChunkContext;

// ============================================================================
// sort Implementation
// ============================================================================

/// Sort elements using parallel merge sort
///
/// Splits array into chunks, sorts chunks in parallel (sequential sort),
/// then merges sorted chunks. Stable within chunks.
/// Falls back to sequential for small data.
///
/// Parameters:
/// - T: Element type
/// - data: Mutable slice to sort in-place
/// - splitter: Work splitting configuration
/// - pool_opt: Thread pool to use (null = global pool)
/// - allocator: Required for temporary buffer allocation
/// - cmp: Comparator function (less-than)
///
/// Note: Requires temporary buffer allocation for merge phase.
pub fn sort(
    comptime T: type,
    data: []T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: Allocator,
    comptime cmp: fn (T, T) bool,
) !void {
    if (data.len <= 1) return;

    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    // For small arrays, use sequential sort
    // Issue 50 fix: Increased threshold to 8192
    // Parallel merge sort only beneficial for large arrays (>100K typically)
    if (!splitter.shouldSplit(data.len, num_threads) or data.len < 8192) {
        std.mem.sort(T, data, {}, struct {
            fn lessThan(_: void, a: T, b: T) bool {
                return cmp(a, b);
            }
        }.lessThan);
        return;
    }

    // Allocate temporary buffer for merge
    const temp = try allocator.alloc(T, data.len);
    defer allocator.free(temp);

    // Phase 1: Parallel sort of chunks
    const chunk_size = splitter.chunkSize(data.len, num_threads);
    // Issue 55 fix: Use heap_max_chunks for better many-core scaling
    const max_chunks = @min(num_threads * 4, heap_max_chunks);
    const total_chunks = @min(std.math.divCeil(usize, data.len, chunk_size) catch data.len, max_chunks);
    const spawn_chunks = if (total_chunks > 1) total_chunks - 1 else 0;

    const SortContext = ParSortChunkContext(T, cmp);
    var sort_contexts: [stack_max_chunks]SortContext = undefined;
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

    // Spawn sort tasks for remaining chunks
    var chunk_idx: usize = 1;
    var offset: usize = main_end;
    while (offset < data.len and chunk_idx < total_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

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
            defer _ = pending.fetchSub(1, .release);
            std.mem.sort(T, chunk, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return cmp(a, b);
                }
            }.lessThan);
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

    if (panicked.load(.acquire)) {
        @panic("parallel sort: chunk panicked");
    }

    // Phase 2: Parallel merge of sorted chunks
    // Use bottom-up merge sort with parallel merge at each level
    var current_chunk_size: usize = chunk_size;
    while (current_chunk_size < data.len) {
        var i: usize = 0;
        while (i < data.len) {
            const left_start = i;
            const mid = @min(i + current_chunk_size, data.len);
            const right_end = @min(i + 2 * current_chunk_size, data.len);

            if (mid < right_end) {
                // Use parallel merge for large merges, sequential for small
                const merge_size = right_end - left_start;
                if (merge_size > 8192) {
                    // Parallel merge for large arrays
                    parallelMergeTopLevel(T, cmp, data, temp, left_start, mid, right_end, pool);
                } else {
                    // Sequential merge for small arrays
                    merge(T, cmp, data, temp, left_start, mid, right_end);
                }
            }

            i += 2 * current_chunk_size;
        }
        current_chunk_size *= 2;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "sort basic" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 5, 3, 1, 4, 2 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    try sort(i32, &data, splitter, null, allocator, struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5 }, &data);
}

test "sort descending" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    try sort(i32, &data, splitter, null, allocator, struct {
        fn greaterThan(a: i32, b: i32) bool {
            return a > b;
        }
    }.greaterThan);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 5, 4, 3, 2, 1 }, &data);
}

test "sort empty" {
    const allocator = std.testing.allocator;
    var data = [_]i32{};
    const splitter = @import("../util/splitter.zig").Splitter.default();

    try sort(i32, &data, splitter, null, allocator, struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan);

    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "sort single element" {
    const allocator = std.testing.allocator;
    var data = [_]i32{42};
    const splitter = @import("../util/splitter.zig").Splitter.default();

    try sort(i32, &data, splitter, null, allocator, struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan);

    try std.testing.expectEqualSlices(i32, &[_]i32{42}, &data);
}

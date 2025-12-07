// filter.zig - Parallel Filter Operation
//
// Filter elements matching predicate in parallel using two-phase approach:
// 1. Parallel count per chunk → compute total and offsets
// 2. Parallel scatter to pre-allocated result

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

const contexts = @import("../iter/contexts.zig");
const ParFilterCountContext = contexts.ParFilterCountContext;
const ParFilterScatterContext = contexts.ParFilterScatterContext;

// ============================================================================
// filter Implementation
// ============================================================================

/// Filter elements matching predicate (parallel)
///
/// Two-phase approach:
/// 1. Parallel count per chunk → compute total and offsets
/// 2. Parallel scatter to pre-allocated result
///
/// Order is preserved within chunks but may interleave between chunks.
/// Falls back to sequential for small data.
/// Caller owns returned memory.
pub fn filter(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: Allocator,
    comptime pred: fn (T) bool,
) ![]T {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        return filterSeq(T, data, allocator, pred);
    }

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    // Issue 55 fix: Use heap_max_chunks for better many-core scaling
    const max_chunks = @min(num_threads * 4, heap_max_chunks);

    // Phase 1: Count matches per chunk (parallel)
    // Issue 65 fix: Need +1 because counts[0] is main chunk, counts[1..chunk_idx+1] are worker chunks
    var counts: [stack_max_chunks + 1]usize = [_]usize{0} ** (stack_max_chunks + 1);
    var pending = Atomic(usize).init(0);
    var count_panicked = Atomic(bool).init(false);

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

    const CountContext = ParFilterCountContext(T, pred);
    var count_contexts: [stack_max_chunks]CountContext = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        count_contexts[chunk_idx] = CountContext{
            .data = chunk,
            .count_ptr = &counts[chunk_idx + 1],
            .pending = &pending,
            .panicked = &count_panicked,
            .task = undefined,
        };

        count_contexts[chunk_idx].task = Task{
            .execute = CountContext.execute,
            .context = @ptrCast(&count_contexts[chunk_idx]),
            .scope = null,
        };

        pool.spawn(&count_contexts[chunk_idx].task) catch {
            defer _ = pending.fetchSub(1, .release);
            var local_count: usize = 0;
            for (chunk) |item| {
                if (pred(item)) local_count += 1;
            }
            counts[chunk_idx + 1] = local_count;
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

    if (count_panicked.load(.acquire)) {
        @panic("parallel filter count: chunk panicked");
    }

    // Compute prefix sums for offsets
    const total_chunks = chunk_idx + 1;
    var offsets: [stack_max_chunks + 1]usize = [_]usize{0} ** (stack_max_chunks + 1);
    var total_count: usize = 0;
    for (0..total_chunks) |i| {
        offsets[i] = total_count;
        total_count += counts[i];
    }
    offsets[total_chunks] = total_count;

    if (total_count == 0) {
        return allocator.alloc(T, 0);
    }

    // Allocate result
    const result = try allocator.alloc(T, total_count);
    errdefer allocator.free(result);

    // Phase 2: Scatter matches to result (parallel)
    pending = Atomic(usize).init(0);
    var scatter_panicked = Atomic(bool).init(false);

    const ScatterContext = ParFilterScatterContext(T, pred);
    var scatter_contexts: [stack_max_chunks]ScatterContext = undefined;
    chunk_idx = 0;
    offset = main_end;

    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];
        const dest_offset = offsets[chunk_idx + 1];

        _ = pending.fetchAdd(1, .release);

        scatter_contexts[chunk_idx] = ScatterContext{
            .data = chunk,
            .result = result,
            .dest_offset = dest_offset,
            .pending = &pending,
            .panicked = &scatter_panicked,
            .task = undefined,
        };

        scatter_contexts[chunk_idx].task = Task{
            .execute = ScatterContext.execute,
            .context = @ptrCast(&scatter_contexts[chunk_idx]),
            .scope = null,
        };

        pool.spawn(&scatter_contexts[chunk_idx].task) catch {
            defer _ = pending.fetchSub(1, .release);
            var idx = dest_offset;
            for (chunk) |item| {
                if (pred(item)) {
                    if (idx >= result.len) {
                        @panic("filter scatter: index out of bounds (predicate may be non-deterministic)");
                    }
                    result[idx] = item;
                    idx += 1;
                }
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Main thread scatters first chunk
    var main_idx: usize = 0;
    for (main_chunk) |item| {
        if (pred(item)) {
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

    if (scatter_panicked.load(.acquire)) {
        allocator.free(result);
        @panic("parallel filter scatter: chunk panicked");
    }

    return result;
}

/// Sequential filter - for small data or when order must be preserved
fn filterSeq(
    comptime T: type,
    data: []const T,
    allocator: Allocator,
    comptime pred: fn (T) bool,
) ![]T {
    // First pass: count matching elements
    var match_count: usize = 0;
    for (data) |item| {
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
    for (data) |item| {
        if (pred(item)) {
            result[idx] = item;
            idx += 1;
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "filter basic" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try filter(i32, &data, splitter, null, allocator, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    // Verify all results are even
    for (result) |item| {
        try std.testing.expect(@mod(item, 2) == 0);
    }
}

test "filter no matches" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 1, 3, 5, 7, 9 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try filter(i32, &data, splitter, null, allocator, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "filter all match" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 2, 4, 6, 8, 10 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try filter(i32, &data, splitter, null, allocator, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
}

test "filter empty slice" {
    const allocator = std.testing.allocator;
    const data = [_]i32{};
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const result = try filter(i32, &data, splitter, null, allocator, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

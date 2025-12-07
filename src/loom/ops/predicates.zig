// predicates.zig - Parallel Predicate Operations
//
// Operations that test conditions across elements:
// - any: Check if any element matches predicate
// - all: Check if all elements match predicate
// - find: Find an element matching predicate
// - position: Find index of first matching element
// - count: Count elements matching predicate

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
const early_exit_check_interval = config.early_exit_check_interval;

const contexts = @import("../iter/contexts.zig");
const ParAnyContext = contexts.ParAnyContext;
const ParAllContext = contexts.ParAllContext;
const ParFindContext = contexts.ParFindContext;
const ParPositionContext = contexts.ParPositionContext;
const ParCountContext = contexts.ParCountContext;

// ============================================================================
// any Implementation
// ============================================================================

/// Check if any element matches predicate (parallel)
///
/// Uses atomic flag for cross-chunk early termination.
/// Falls back to sequential for small data.
///
/// Parameters:
/// - T: Element type
/// - data: The slice to check
/// - splitter: Work splitting configuration
/// - pool_opt: Thread pool to use (null = global pool)
/// - allocator: Optional allocator (unused, for API consistency)
/// - pred: Predicate function to test each element
pub fn any(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime pred: fn (T) bool,
) bool {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path
        for (data) |item| {
            if (pred(item)) return true;
        }
        return false;
    }

    var found = Atomic(bool).init(false);
    var pending = Atomic(usize).init(0);
    var panicked = Atomic(bool).init(false);

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    // Issue 55 fix: Use heap_max_chunks when allocator available
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);

    // Issue 27/48/54 fix: Ensure spawned tasks complete before stack unwinds
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

    const Context = ParAnyContext(T, pred);
    var ctxs: [stack_max_chunks]Context = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    // Reserve first chunk for main thread
    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    // Spawn worker tasks for remaining chunks
    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        ctxs[chunk_idx] = Context{
            .data = chunk,
            .found = &found,
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
            if (!found.load(.acquire)) {
                for (chunk) |item| {
                    if (pred(item)) {
                        found.store(true, .release);
                        break;
                    }
                }
            }
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
            // Issue 18 fix: Periodic check with configurable interval
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

// ============================================================================
// all Implementation
// ============================================================================

/// Check if all elements match predicate (parallel)
///
/// Uses atomic flag for cross-chunk early termination on first mismatch.
/// Falls back to sequential for small data.
pub fn all(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime pred: fn (T) bool,
) bool {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path
        for (data) |item| {
            if (!pred(item)) return false;
        }
        return true;
    }

    // Use "failed" flag - true means we found a non-matching element
    var failed = Atomic(bool).init(false);
    var pending = Atomic(usize).init(0);
    var panicked = Atomic(bool).init(false);

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);

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

    const Context = ParAllContext(T, pred);
    var ctxs: [stack_max_chunks]Context = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    // Reserve first chunk for main thread
    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    // Spawn worker tasks
    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        ctxs[chunk_idx] = Context{
            .data = chunk,
            .failed = &failed,
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
            if (!failed.load(.acquire)) {
                for (chunk) |item| {
                    if (!pred(item)) {
                        failed.store(true, .release);
                        break;
                    }
                }
            }
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

    if (panicked.load(.acquire)) {
        @panic("parallel all: chunk panicked");
    }

    return !failed.load(.acquire);
}

// ============================================================================
// find Implementation
// ============================================================================

/// Find an element matching predicate (parallel)
///
/// Note: Due to parallel execution, may not return the "first" element
/// in index order, but returns *a* matching element quickly.
/// Falls back to sequential for small data.
/// Issue 14 fix: Lock-free find using CAS instead of mutex
pub fn find(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime pred: fn (T) bool,
) ?T {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path
        for (data) |item| {
            if (pred(item)) return item;
        }
        return null;
    }

    var found = Atomic(bool).init(false);
    var result: T = undefined;
    var pending = Atomic(usize).init(0);
    var panicked = Atomic(bool).init(false);

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);

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

    const Context = ParFindContext(T, pred);
    var ctxs: [stack_max_chunks]Context = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        ctxs[chunk_idx] = Context{
            .data = chunk,
            .found = &found,
            .result = &result,
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

    if (panicked.load(.acquire)) {
        @panic("parallel find: chunk panicked");
    }

    return if (found.load(.acquire)) result else null;
}

// ============================================================================
// position Implementation
// ============================================================================

/// Find index of first matching element (parallel)
///
/// Returns the minimum index across all chunks where a match was found.
/// This guarantees finding the actual first matching element.
/// Falls back to sequential for small data.
pub fn position(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime pred: fn (T) bool,
) ?usize {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path
        for (data, 0..) |item, i| {
            if (pred(item)) return i;
        }
        return null;
    }

    // Use maxInt as "not found" sentinel
    var min_index = Atomic(usize).init(std.math.maxInt(usize));
    var pending = Atomic(usize).init(0);
    var panicked = Atomic(bool).init(false);

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);

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

    const Context = ParPositionContext(T, pred);
    var ctxs: [stack_max_chunks]Context = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        ctxs[chunk_idx] = Context{
            .data = chunk,
            .base_index = offset,
            .min_index = &min_index,
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
            for (chunk, 0..) |item, i| {
                const global_idx = offset + i;
                // Early exit if we already found a smaller index
                if (global_idx >= min_index.load(.acquire)) break;
                if (pred(item)) {
                    _ = min_index.fetchMin(global_idx, .release);
                    break;
                }
            }
        };

        chunk_idx += 1;
        offset = end;
    }

    // Main thread: process first chunk (base_index = 0)
    for (main_chunk, 0..) |item, i| {
        if (i >= min_index.load(.acquire)) break;
        if (pred(item)) {
            _ = min_index.fetchMin(i, .release);
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

    if (panicked.load(.acquire)) {
        @panic("parallel position: chunk panicked");
    }

    const found_result = min_index.load(.acquire);
    return if (found_result == std.math.maxInt(usize)) null else found_result;
}

// ============================================================================
// count Implementation
// ============================================================================

/// Count elements matching predicate (parallel)
///
/// Each chunk counts matches, then partial counts are summed.
/// Falls back to sequential for small data.
pub fn count(
    comptime T: type,
    data: []const T,
    splitter: anytype,
    pool_opt: ?*ThreadPool,
    allocator: ?std.mem.Allocator,
    comptime pred: fn (T) bool,
) usize {
    const pool = pool_opt orelse getGlobalPool();
    const num_threads = pool.numWorkers();

    if (!splitter.shouldSplit(data.len, num_threads)) {
        // Sequential path
        var cnt: usize = 0;
        for (data) |item| {
            if (pred(item)) cnt += 1;
        }
        return cnt;
    }

    var total = Atomic(usize).init(0);
    var pending = Atomic(usize).init(0);
    var panicked = Atomic(bool).init(false);

    const chunk_size = splitter.chunkSize(data.len, num_threads);
    const max_chunks = if (allocator != null)
        @min(num_threads * 4, heap_max_chunks)
    else
        @min(num_threads * 4, stack_max_chunks);

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

    const Context = ParCountContext(T, pred);
    var ctxs: [stack_max_chunks]Context = undefined;
    var chunk_idx: usize = 0;
    var offset: usize = 0;

    const main_end = @min(chunk_size, data.len);
    const main_chunk = data[0..main_end];
    offset = main_end;

    while (offset < data.len and chunk_idx < max_chunks) {
        const end = @min(offset + chunk_size, data.len);
        const chunk = data[offset..end];

        _ = pending.fetchAdd(1, .release);

        ctxs[chunk_idx] = Context{
            .data = chunk,
            .total = &total,
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
            var local_count: usize = 0;
            for (chunk) |item| {
                if (pred(item)) local_count += 1;
            }
            _ = total.fetchAdd(local_count, .release);
        };

        chunk_idx += 1;
        offset = end;
    }

    // Main thread
    var main_count: usize = 0;
    for (main_chunk) |item| {
        if (pred(item)) main_count += 1;
    }
    _ = total.fetchAdd(main_count, .release);

    var backoff = Backoff.init(pool.backoff_config);
    while (pending.load(.acquire) > 0) {
        if (pool.tryProcessOneTask()) {
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }

    if (panicked.load(.acquire)) {
        @panic("parallel count: chunk panicked");
    }

    return total.load(.acquire);
}

// ============================================================================
// Tests
// ============================================================================

test "any basic" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const has_even = any(i32, &data, splitter, null, null, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expect(has_even);
}

test "any returns false when no match" {
    const data = [_]i32{ 1, 3, 5, 7, 9 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const has_even = any(i32, &data, splitter, null, null, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expect(!has_even);
}

test "all basic" {
    const data = [_]i32{ 2, 4, 6, 8, 10 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const all_even = all(i32, &data, splitter, null, null, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expect(all_even);
}

test "all returns false when one doesn't match" {
    const data = [_]i32{ 2, 4, 5, 8, 10 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const all_even = all(i32, &data, splitter, null, null, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expect(!all_even);
}

test "find basic" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const found = find(i32, &data, splitter, null, null, struct {
        fn greaterThan3(x: i32) bool {
            return x > 3;
        }
    }.greaterThan3);

    try std.testing.expect(found != null);
    try std.testing.expect(found.? > 3);
}

test "find returns null when no match" {
    const data = [_]i32{ 1, 2, 3 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const found = find(i32, &data, splitter, null, null, struct {
        fn greaterThan10(x: i32) bool {
            return x > 10;
        }
    }.greaterThan10);

    try std.testing.expect(found == null);
}

test "position basic" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const pos = position(i32, &data, splitter, null, null, struct {
        fn isThree(x: i32) bool {
            return x == 3;
        }
    }.isThree);

    try std.testing.expectEqual(@as(?usize, 2), pos);
}

test "position returns null when no match" {
    const data = [_]i32{ 1, 2, 3 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const pos = position(i32, &data, splitter, null, null, struct {
        fn isTen(x: i32) bool {
            return x == 10;
        }
    }.isTen);

    try std.testing.expect(pos == null);
}

test "count basic" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const splitter = @import("../util/splitter.zig").Splitter.default();

    const even_count = count(i32, &data, splitter, null, null, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expectEqual(@as(usize, 3), even_count);
}

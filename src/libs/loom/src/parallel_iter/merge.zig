// merge.zig - Parallel Merge Implementation for Sort
//
// Contains:
// - Sequential merge helper
// - Binary search for merge split point
// - Parallel merge implementation using divide-and-conquer
// - ParallelMergeContext for spawned merge tasks

const std = @import("std");
const Atomic = std.atomic.Value;

const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("../thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;

// ============================================================================
// Configuration
// ============================================================================

/// Issue 15 fix: Maximum recursion depth before falling back to sequential merge
pub const max_merge_depth: usize = 24;

// ============================================================================
// Sequential Merge Helpers
// ============================================================================

/// Merge two sorted subarrays [left..mid) and [mid..right)
pub fn merge(comptime T: type, comptime cmp: fn (T, T) bool, data: []T, temp: []T, left: usize, mid: usize, right: usize) void {
    // Copy to temp buffer
    @memcpy(temp[left..right], data[left..right]);

    var i = left;
    var j = mid;
    var k = left;

    while (i < mid and j < right) {
        if (cmp(temp[j], temp[i])) {
            // temp[j] < temp[i], take from right half
            data[k] = temp[j];
            j += 1;
        } else {
            // temp[i] <= temp[j], take from left half (stable)
            data[k] = temp[i];
            i += 1;
        }
        k += 1;
    }

    // Copy remaining elements from left half
    while (i < mid) {
        data[k] = temp[i];
        i += 1;
        k += 1;
    }

    // Copy remaining elements from right half
    while (j < right) {
        data[k] = temp[j];
        j += 1;
        k += 1;
    }
}

/// Sequential merge of two sorted arrays into destination
pub fn sequentialMergeArrays(comptime T: type, comptime cmp: fn (T, T) bool, left: []const T, right: []const T, dest: []T) void {
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;

    while (i < left.len and j < right.len) {
        if (cmp(right[j], left[i])) {
            dest[k] = right[j];
            j += 1;
        } else {
            dest[k] = left[i];
            i += 1;
        }
        k += 1;
    }

    // Copy remaining from left
    while (i < left.len) {
        dest[k] = left[i];
        i += 1;
        k += 1;
    }

    // Copy remaining from right
    while (j < right.len) {
        dest[k] = right[j];
        j += 1;
        k += 1;
    }
}

// ============================================================================
// Binary Search Helper
// ============================================================================

/// Binary search to find insertion point for pivot in sorted array
/// Returns index where pivot would be inserted to maintain sort order
pub fn binarySearchInsertPoint(comptime T: type, comptime cmp: fn (T, T) bool, arr: []const T, pivot: T) usize {
    var low: usize = 0;
    var high: usize = arr.len;

    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cmp(arr[mid], pivot)) {
            // arr[mid] < pivot, search right half
            low = mid + 1;
        } else {
            // arr[mid] >= pivot, search left half
            high = mid;
        }
    }
    return low;
}

// ============================================================================
// Parallel Merge Context and Implementation
// ============================================================================

/// Context for parallel merge task
pub fn ParallelMergeContext(comptime T: type, comptime cmp: fn (T, T) bool) type {
    return struct {
        const Self = @This();

        // Source arrays (from temp buffer)
        left_src: []const T,
        right_src: []const T,

        // Destination slice (in data array)
        dest: []T,

        // Threshold for sequential fallback
        threshold: usize,

        // Issue 15 fix: Current recursion depth
        depth: usize,

        // Synchronization - local done flag for this specific task
        done: *Atomic(bool),
        pool: *ThreadPool,

        // Task struct (must be part of context for stable pointer)
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Ensure done is signaled even on panic
            defer self.done.store(true, .release);

            // Execute the parallel merge with depth tracking
            parallelMergeImpl(T, cmp, self.left_src, self.right_src, self.dest, self.threshold, self.depth, self.pool);
        }
    };
}

/// Parallel merge implementation using divide-and-conquer with binary search
/// Merges two sorted arrays (left_src, right_src) into dest
/// Issue 15 fix: Added depth parameter to prevent stack overflow
pub fn parallelMergeImpl(
    comptime T: type,
    comptime cmp: fn (T, T) bool,
    left_src: []const T,
    right_src: []const T,
    dest: []T,
    threshold: usize,
    depth: usize,
    pool: *ThreadPool,
) void {
    const total = left_src.len + right_src.len;

    // Issue 15 fix: Fall back to sequential merge if recursion is too deep
    if (depth >= max_merge_depth) {
        sequentialMergeArrays(T, cmp, left_src, right_src, dest);
        return;
    }

    // Base case: sequential merge for small arrays
    if (total <= threshold) {
        sequentialMergeArrays(T, cmp, left_src, right_src, dest);
        return;
    }

    // Ensure left is the larger array (for balanced split)
    if (left_src.len < right_src.len) {
        // Swap: recurse with swapped arrays
        parallelMergeImpl(T, cmp, right_src, left_src, dest, threshold, depth, pool);
        return;
    }

    // If right is empty, just copy left
    if (right_src.len == 0) {
        @memcpy(dest, left_src);
        return;
    }

    // Pick pivot from middle of larger (left) array
    const pivot_idx = left_src.len / 2;
    const pivot = left_src[pivot_idx];

    // Binary search for pivot position in right array
    const split_idx = binarySearchInsertPoint(T, cmp, right_src, pivot);

    // Calculate destination positions
    const dest_pivot_idx = pivot_idx + split_idx;

    // Place pivot in destination
    dest[dest_pivot_idx] = pivot;

    // Prepare sub-arrays for parallel merge
    const left_left = left_src[0..pivot_idx];
    const right_left = right_src[0..split_idx];
    const dest_left = dest[0..dest_pivot_idx];

    const left_right = left_src[pivot_idx + 1 ..];
    const right_right = right_src[split_idx..];
    const dest_right = dest[dest_pivot_idx + 1 ..];

    // Spawn right half as task, execute left half locally
    if (dest_right.len > threshold and dest_right.len > 0) {
        // Use local done flag for this specific spawn
        var done = Atomic(bool).init(false);

        // Use stack-allocated context for the spawned task
        var right_ctx: ParallelMergeContext(T, cmp) = .{
            .left_src = left_right,
            .right_src = right_right,
            .dest = dest_right,
            .threshold = threshold,
            .depth = depth + 1,
            .done = &done,
            .pool = pool,
            .task = undefined,
        };

        right_ctx.task = Task{
            .execute = ParallelMergeContext(T, cmp).execute,
            .context = @ptrCast(&right_ctx),
            .scope = null,
        };

        const spawned = if (pool.spawn(&right_ctx.task)) |_| true else |_| false;

        // Issue 37 fix: Ensure spawned task completes before stack unwinds on panic
        // This is the same pattern as Issue 27 fix for other parallel functions.
        // Without this defer, if the left half panics, the right task would access
        // dangling pointers to right_ctx and done on the unwinding stack.
        defer if (spawned) {
            var backoff = Backoff.init(pool.backoff_config);
            while (!done.load(.acquire)) {
                if (pool.tryProcessOneTask()) {
                    backoff.reset();
                } else {
                    backoff.snooze();
                }
            }
        };

        // Execute left half locally
        parallelMergeImpl(T, cmp, left_left, right_left, dest_left, threshold, depth + 1, pool);

        // Normal path: wait for spawned task (defer handles panic path)
        // Note: defer also runs on normal return, so we don't need explicit wait here
    } else {
        // Both halves are small, execute sequentially
        parallelMergeImpl(T, cmp, left_left, right_left, dest_left, threshold, depth + 1, pool);
        parallelMergeImpl(T, cmp, left_right, right_right, dest_right, threshold, depth + 1, pool);
    }
}

/// Top-level parallel merge that handles the full array merge
/// Merges data[left..mid] with data[mid..right] using parallel divide-and-conquer
pub fn parallelMergeTopLevel(
    comptime T: type,
    comptime cmp: fn (T, T) bool,
    data: []T,
    temp: []T,
    left: usize,
    mid: usize,
    right: usize,
    pool: *ThreadPool,
) void {
    const n = right - left;

    // Threshold: below this, use sequential merge
    // Use ~4K elements or n/num_workers, whichever is larger
    const num_workers = pool.numWorkers();
    const threshold = @max(4096, n / (num_workers * 2));

    // Copy source data to temp buffer
    @memcpy(temp[left..right], data[left..right]);

    // Set up source slices from temp
    const left_src = temp[left..mid];
    const right_src = temp[mid..right];
    const dest = data[left..right];

    // Execute parallel merge (uses local done flags per spawn)
    // Issue 15 fix: Start with depth=0
    parallelMergeImpl(T, cmp, left_src, right_src, dest, threshold, 0, pool);
}

// ============================================================================
// Tests
// ============================================================================

test "merge basic" {
    var data = [_]i32{ 1, 3, 5, 2, 4, 6 };
    var temp: [6]i32 = undefined;

    merge(i32, struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, &data, &temp, 0, 3, 6);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6 }, &data);
}

test "sequentialMergeArrays basic" {
    const left = [_]i32{ 1, 3, 5 };
    const right = [_]i32{ 2, 4, 6 };
    var dest: [6]i32 = undefined;

    sequentialMergeArrays(i32, struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, &left, &right, &dest);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6 }, &dest);
}

test "binarySearchInsertPoint" {
    const arr = [_]i32{ 1, 3, 5, 7, 9 };
    const cmp = struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan;

    try std.testing.expectEqual(@as(usize, 0), binarySearchInsertPoint(i32, cmp, &arr, 0));
    try std.testing.expectEqual(@as(usize, 1), binarySearchInsertPoint(i32, cmp, &arr, 2));
    try std.testing.expectEqual(@as(usize, 2), binarySearchInsertPoint(i32, cmp, &arr, 4));
    try std.testing.expectEqual(@as(usize, 5), binarySearchInsertPoint(i32, cmp, &arr, 10));
}

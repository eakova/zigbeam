// contexts.zig - Task Context Types for Parallel Iterator Operations
//
// Contains all the context types used by parallel operations:
// - ForEach contexts (ForEachContextStack, ForEachIndexedContextStack)
// - Reduce context (ReduceContextStack)
// - Map context (MapContextStack)
// - Predicate contexts (ParAnyContext, ParAllContext, ParFindContext, ParPositionContext, ParCountContext)
// - Filter contexts (ParFilterCountContext, ParFilterScatterContext)
// - Chunks contexts (ParChunksContext, ParChunksConstContext)
// - Sort context (ParSortChunkContext)

const std = @import("std");
const Atomic = std.atomic.Value;

const thread_pool = @import("../pool/thread_pool.zig");
const Task = thread_pool.Task;

const reducer_mod = @import("../util/reducer.zig");
const Reducer = reducer_mod.Reducer;

// ============================================================================
// forEach Contexts
// ============================================================================

/// Stack-allocated context for forEach (no heap allocation needed)
pub fn ForEachContextStack(comptime T: type, comptime func: fn (*T) void) type {
    return struct {
        const Self = @This();

        data: []T,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            // Execute the function on this chunk
            for (self.data) |*item| {
                func(item);
            }
            completed_normally = true;
        }
    };
}

/// Stack-allocated context for forEachIndexed (no heap allocation needed)
pub fn ForEachIndexedContextStack(comptime T: type, comptime func: fn (usize, *T) void) type {
    return struct {
        const Self = @This();

        data: []T,
        base_index: usize,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            for (self.data, 0..) |*item, i| {
                func(self.base_index + i, item);
            }
            completed_normally = true;
        }
    };
}

// ============================================================================
// reduce Context
// ============================================================================

/// Stack-allocated context for reduce (no heap allocation needed)
pub fn ReduceContextStack(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []const T,
        result_ptr: *T,
        reducer: *const Reducer(T),
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            // Reduce this chunk
            var acc = self.reducer.identity;
            for (self.data) |item| {
                acc = self.reducer.combine(acc, item);
            }
            self.result_ptr.* = acc;
            completed_normally = true;
        }
    };
}

// ============================================================================
// map Context
// ============================================================================

/// Stack-allocated context for map (no heap allocation needed)
pub fn MapContextStack(comptime T: type, comptime U: type, comptime func: fn (T) U) type {
    return struct {
        const Self = @This();

        src: []const T,
        dst: []U,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            for (self.src, self.dst) |item, *out| {
                out.* = func(item);
            }
            completed_normally = true;
        }
    };
}

/// Stack-allocated context for mapIndexed (no heap allocation needed)
pub fn MapIndexedContextStack(comptime T: type, comptime U: type, comptime func: fn (usize, T) U) type {
    return struct {
        const Self = @This();

        src: []const T,
        dst: []U,
        base_index: usize,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            for (self.src, self.dst, 0..) |item, *out, i| {
                out.* = func(self.base_index + i, item);
            }
            completed_normally = true;
        }
    };
}

// ============================================================================
// Parallel Predicate Contexts
// ============================================================================

/// Context for any() - parallel any with early-exit
pub fn ParAnyContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        found: *Atomic(bool),
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            // Early exit if already found
            if (!self.found.load(.acquire)) {
                for (self.data) |item| {
                    if (pred(item)) {
                        self.found.store(true, .release);
                        break;
                    }
                    // Check periodically for early termination
                    if (self.found.load(.acquire)) break;
                }
            }
            completed_normally = true;
        }
    };
}

/// Context for all() - parallel all with early-exit
pub fn ParAllContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        failed: *Atomic(bool),
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            if (!self.failed.load(.acquire)) {
                for (self.data) |item| {
                    if (!pred(item)) {
                        self.failed.store(true, .release);
                        break;
                    }
                    if (self.failed.load(.acquire)) break;
                }
            }
            completed_normally = true;
        }
    };
}

/// Context for find() - parallel find with early-exit
/// Issue 14 fix: Uses CAS instead of mutex for lock-free result storage
pub fn ParFindContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        found: *Atomic(bool),
        result: *T,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            if (!self.found.load(.acquire)) {
                for (self.data) |item| {
                    if (pred(item)) {
                        // Issue 14 fix: Use CAS instead of mutex
                        // Only the first thread to swap false->true writes the result
                        if (self.found.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                            // We won the race - write the result
                            self.result.* = item;
                        }
                        break;
                    }
                    if (self.found.load(.acquire)) break;
                }
            }
            completed_normally = true;
        }
    };
}

/// Context for position() - parallel position tracking minimum index
pub fn ParPositionContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        base_index: usize,
        min_index: *Atomic(usize),
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            for (self.data, 0..) |item, i| {
                const global_idx = self.base_index + i;
                // Early exit if we already found a smaller index
                if (global_idx >= self.min_index.load(.acquire)) break;
                if (pred(item)) {
                    _ = self.min_index.fetchMin(global_idx, .release); // T128
                    break;
                }
            }
            completed_normally = true;
        }
    };
}

/// Context for count() - parallel count accumulator
pub fn ParCountContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        total: *Atomic(usize),
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            var local_count: usize = 0;
            for (self.data) |item| {
                if (pred(item)) local_count += 1;
            }
            _ = self.total.fetchAdd(local_count, .release); // T128
            completed_normally = true;
        }
    };
}

// ============================================================================
// Filter Contexts
// ============================================================================

/// Context for filter() count phase
pub fn ParFilterCountContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        count_ptr: *usize,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            var local_count: usize = 0;
            for (self.data) |item| {
                if (pred(item)) local_count += 1;
            }
            self.count_ptr.* = local_count;
            completed_normally = true;
        }
    };
}

/// Context for filter() scatter phase
pub fn ParFilterScatterContext(comptime T: type, comptime pred: fn (T) bool) type {
    return struct {
        const Self = @This();

        data: []const T,
        result: []T,
        dest_offset: usize,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            var idx = self.dest_offset;
            for (self.data) |item| {
                if (pred(item)) {
                    // Issue 22/40 fix: Bounds check to guard against prefix sum bugs
                    // or non-deterministic predicates
                    if (idx >= self.result.len) {
                        @panic("filter scatter: index out of bounds (predicate may be non-deterministic)");
                    }
                    self.result[idx] = item;
                    idx += 1;
                }
            }
            completed_normally = true;
        }
    };
}

// ============================================================================
// Chunks Contexts
// ============================================================================

/// Context for chunks() - explicit chunk processing
pub fn ParChunksContext(comptime T: type, comptime func: fn (usize, []T) void) type {
    return struct {
        const Self = @This();

        chunk_index: usize,
        data: []T,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            func(self.chunk_index, self.data);
            completed_normally = true;
        }
    };
}

/// Context for chunksConst() - explicit chunk processing (const)
pub fn ParChunksConstContext(comptime T: type, comptime func: fn (usize, []const T) void) type {
    return struct {
        const Self = @This();

        chunk_index: usize,
        data: []const T,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            func(self.chunk_index, self.data);
            completed_normally = true;
        }
    };
}

// ============================================================================
// Sort Context
// ============================================================================

/// Context for sort() chunk sorting
pub fn ParSortChunkContext(comptime T: type, comptime cmp: fn (T, T) bool) type {
    return struct {
        const Self = @This();

        data: []T,
        pending: *Atomic(usize),
        panicked: *Atomic(bool),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Issue 10 fix: Track normal completion for panic detection
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    self.panicked.store(true, .release);
                }
                _ = self.pending.fetchSub(1, .release);
            }

            std.mem.sort(T, self.data, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return cmp(a, b);
                }
            }.lessThan);
            completed_normally = true;
        }
    };
}

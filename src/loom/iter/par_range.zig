// range.zig - Parallel Range Iterators
//
// Provides parallel iteration over integer ranges without allocating backing arrays:
// - RangeParallelIterator: Iterates over [start, end) range
// - ContextRangeParallelIterator: Range iterator with user context
// - par_range: Entry point function

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("../pool/thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;

const splitter_mod = @import("../util/splitter.zig");
const Splitter = splitter_mod.Splitter;

const config = @import("config.zig");
const stack_max_chunks = config.stack_max_chunks;

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
        pub fn withMaxChunks(self: Self, max_chunks_val: usize) Self {
            var result = self;
            result.splitter.target_chunks = max_chunks_val;
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
                    // Issue 64 fix: Use defer to ensure counter is updated even on panic
                    defer _ = done.fetchAdd(1, .release);
                    var i = chunk_start;
                    while (i < chunk_end) : (i += 1) {
                        var val = i;
                        func(&val);
                    }
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

        pub fn withMaxChunks(self: Self, max_chunks_val: usize) Self {
            var result = self;
            result.inner = self.inner.withMaxChunks(max_chunks_val);
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
                    // Issue 64 fix: Use defer to ensure counter is updated even on panic
                    defer _ = done.fetchAdd(1, .release);
                    var i = chunk_start;
                    while (i < chunk_end) : (i += 1) {
                        func(self.context, i);
                    }
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
// Tests
// ============================================================================

test "par_range basic" {
    par_range(@as(usize, 0), @as(usize, 10)).forEach(struct {
        fn accumulate(val: *usize) void {
            _ = val;
        }
    }.accumulate);
    // Just verify it runs without error
}

test "RangeParallelIterator len" {
    const iter = RangeParallelIterator(i32).init(5, 15);
    try std.testing.expectEqual(@as(usize, 10), iter.len());

    const empty = RangeParallelIterator(i32).init(10, 5);
    try std.testing.expectEqual(@as(usize, 0), empty.len());
}

test "par_range with context" {
    const Ctx = struct {
        multiplier: i32,
    };

    const ctx = Ctx{ .multiplier = 2 };

    par_range(@as(i32, 0), @as(i32, 5)).withContext(ctx).forEach(struct {
        fn process(_: Ctx, _: i32) void {
            // Just verify it compiles and runs
        }
    }.process);
}

test "RangeParallelIterator count" {
    const iter = RangeParallelIterator(i32).init(0, 10);
    const even_count = iter.count(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);

    try std.testing.expectEqual(@as(usize, 5), even_count);
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

// join.zig - Binary Fork-Join Execution
//
// Provides the join() function for executing two tasks in parallel.
// This is the fundamental building block for divide-and-conquer algorithms.
//
// Design:
// - Left task executes locally (no scheduling overhead)
// - Right task spawns to the pool
// - Caller helps by working while waiting (steal-while-wait)
// - Panic propagation from either task
//
// Usage:
// ```zig
// const left, const right = join(
//     computeLeft, .{data[0..mid]},
//     computeRight, .{data[mid..]},
// );
// ```

const std = @import("std");
const Atomic = std.atomic.Value;
const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;

// ============================================================================
// JoinHandle - Result container for async task execution
// ============================================================================

/// Handle for retrieving the result of an async task
///
/// The JoinHandle stores the result of a spawned task and provides
/// synchronization for the join point.
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The result value (valid after completion)
        result: T,

        /// Completion flag (set when task finishes)
        completed: Atomic(bool),

        /// Issue 9 fix: Atomic flag for panic detection (independent of payload)
        panicked: Atomic(bool),

        /// Panic payload if task panicked (may be null even when panicked)
        panic_payload: ?*anyopaque,

        /// Pool reference for steal-while-wait
        pool: *ThreadPool,

        /// Initialize a new JoinHandle
        pub fn init(pool: *ThreadPool) Self {
            return Self{
                .result = undefined,
                .completed = Atomic(bool).init(false),
                .panicked = Atomic(bool).init(false),
                .panic_payload = null,
                .pool = pool,
            };
        }

        /// Block until result is available, then return it
        ///
        /// While waiting, helps by stealing and executing tasks.
        /// If the task panicked, propagates the panic.
        pub fn get(self: *Self) T {
            self.wait();

            // Issue 9 fix: Check panicked flag (not just payload, since payload may be null)
            if (self.panicked.load(.acquire)) {
                @panic("task panicked");
            }

            return self.result;
        }

        /// Check if result is available without blocking
        pub fn isDone(self: *const Self) bool {
            return self.completed.load(.acquire);
        }

        /// Try to get result, return null if not ready
        pub fn tryGet(self: *Self) ?T {
            if (!self.isDone()) {
                return null;
            }

            // Issue 9 fix: Check panicked flag (not just payload)
            if (self.panicked.load(.acquire)) {
                @panic("task panicked");
            }

            return self.result;
        }

        /// Wait for completion, helping with other tasks while waiting
        ///
        /// Implements "steal-while-wait": when waiting for a spawned task,
        /// the caller helps by executing other tasks from the pool.
        /// This prevents deadlock in recursive fork-join patterns.
        fn wait(self: *Self) void {
            // Fast path: already complete
            if (self.completed.load(.acquire)) {
                return;
            }

            var backoff = Backoff.init(self.pool.backoff_config);

            // Steal-while-wait loop
            while (!self.completed.load(.acquire)) {
                // Try to help by executing other tasks
                if (self.pool.tryProcessOneTask()) {
                    // Made progress, reset backoff and check again
                    backoff.reset();
                } else {
                    // No work available, backoff before checking again
                    backoff.snooze();
                }
            }
        }

        /// Store the result and mark as complete
        pub fn complete(self: *Self, value: T) void {
            self.result = value;
            self.completed.store(true, .release);
        }

        /// Store panic and mark as complete
        pub fn completePanic(self: *Self, payload: ?*anyopaque) void {
            self.panic_payload = payload;
            // Issue 9 fix: Always set panicked flag regardless of payload
            self.panicked.store(true, .release);
            self.completed.store(true, .release);
        }
    };
}

// ============================================================================
// Context structure for passing arguments through Task
// ============================================================================

/// Context for right task execution - stores handle and args, uses comptime function
fn RightTaskContext(comptime right_fn: anytype, comptime RightArgs: type) type {
    const RightResult = FnReturnType(@TypeOf(right_fn));

    return struct {
        const Self = @This();

        handle: *JoinHandle(RightResult),
        args: RightArgs,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Track completion to ensure handle is always signaled
            var completed = false;
            defer {
                if (!completed) {
                    // If we get here, right_fn panicked - signal completion with panic
                    self.handle.completePanic(null);
                }
            }

            const result = @call(.auto, right_fn, self.args);
            self.handle.complete(result);
            completed = true;
        }
    };
}

// ============================================================================
// join() - Binary Fork-Join Execution
// ============================================================================

/// Execute two tasks in parallel and return both results
///
/// This is the fundamental building block for divide-and-conquer parallelism.
/// One task executes locally (no scheduling overhead), while the other is
/// spawned to the pool. The caller helps by working while waiting.
///
/// Type Parameters:
///   - left_fn: First function to execute (runs locally)
///   - right_fn: Second function to execute (spawned to pool)
///
/// Returns: Tuple of (left_result, right_result)
///
/// Panics: If either task panics, the panic is propagated to the caller.
///
/// Example:
/// ```zig
/// const left, const right = join(
///     computeLeft, .{data[0..mid]},
///     computeRight, .{data[mid..]},
/// );
/// ```
pub fn join(
    comptime left_fn: anytype,
    left_args: anytype,
    comptime right_fn: anytype,
    right_args: anytype,
) JoinResult(@TypeOf(left_fn), @TypeOf(right_fn)) {
    return joinOnPool(getGlobalPool(), left_fn, left_args, right_fn, right_args);
}

/// Variant of join that uses a specific pool instead of the global pool
pub fn joinOnPool(
    pool: *ThreadPool,
    comptime left_fn: anytype,
    left_args: anytype,
    comptime right_fn: anytype,
    right_args: anytype,
) JoinResult(@TypeOf(left_fn), @TypeOf(right_fn)) {
    const RightArgs = @TypeOf(right_args);
    const RightResult = FnReturnType(@TypeOf(right_fn));
    const Context = RightTaskContext(right_fn, RightArgs);

    // Create handle for right task result
    var right_handle = JoinHandle(RightResult).init(pool);

    // Create context with handle and arguments (function is comptime)
    var context = Context{
        .handle = &right_handle,
        .args = right_args,
    };

    // Create task struct
    var task = Task{
        .execute = Context.execute,
        .context = @ptrCast(&context),
        .scope = null,
    };

    // Spawn right task to pool
    pool.spawn(&task) catch {
        // If spawn fails, execute both tasks locally
        const right_result = @call(.auto, right_fn, right_args);
        const left_result = @call(.auto, left_fn, left_args);
        return .{ left_result, right_result };
    };

    // Issue 13 fix: Track whether we spawned successfully
    // Use defer to ensure right task completes before stack unwinds on panic.
    // This prevents dangling pointers if left_fn panics.
    var left_completed_normally = false;
    defer {
        if (!left_completed_normally) {
            // Left task panicked - we must wait for right task to complete
            // before the stack unwinds and destroys right_handle/context/task.
            // Use a busy-wait loop since backoff may not be safe during panic unwind.
            while (!right_handle.completed.load(.acquire)) {
                // Try to help process tasks to avoid deadlock
                _ = pool.tryProcessOneTask();
            }
            // Note: The panic will propagate after this defer completes
        }
    }

    // Execute left task locally
    const left_result = @call(.auto, left_fn, left_args);
    left_completed_normally = true;

    // Wait for right task to complete
    const right_result = right_handle.get();

    return .{ left_result, right_result };
}

// ============================================================================
// Type Helpers
// ============================================================================

/// Get return type of a function type
fn FnReturnType(comptime Fn: type) type {
    const fn_info = @typeInfo(Fn);
    return switch (fn_info) {
        .@"fn" => |f| f.return_type orelse void,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f.return_type orelse void,
            else => @compileError("Expected function type"),
        },
        else => @compileError("Expected function type"),
    };
}

/// Result type for join operation
fn JoinResult(comptime LeftFn: type, comptime RightFn: type) type {
    const LeftResult = FnReturnType(LeftFn);
    const RightResult = FnReturnType(RightFn);
    return struct { LeftResult, RightResult };
}

// ============================================================================
// Tests
// ============================================================================

test "JoinHandle basic" {
    const pool = try ThreadPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var handle = JoinHandle(i32).init(pool);
    try std.testing.expect(!handle.isDone());

    handle.complete(42);
    try std.testing.expect(handle.isDone());
    try std.testing.expectEqual(@as(i32, 42), handle.get());
}

test "JoinHandle tryGet" {
    const pool = try ThreadPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var handle = JoinHandle(i32).init(pool);
    try std.testing.expectEqual(@as(?i32, null), handle.tryGet());

    handle.complete(123);
    try std.testing.expectEqual(@as(?i32, 123), handle.tryGet());
}

// Task - Type-erased unit of parallel work
//
// Tasks are the fundamental unit of work in the ZigParallel scheduler.
// They consist of a function pointer and a context pointer, enabling
// type-erased execution across worker threads.
//
// Size: 24 bytes (fits in cache line)
// Memory: No allocation - context provided by caller

const std = @import("std");

/// Type-erased task for work-stealing scheduler
///
/// A task represents a unit of parallel work that can be:
/// - Pushed to a worker's local deque
/// - Stolen by idle workers
/// - Executed on any worker thread
///
/// Tasks are small (24 bytes) and do not allocate.
/// The context pointer must remain valid until the task completes.
pub const Task = struct {
    /// Function to execute (receives context pointer)
    /// The function is responsible for casting context to the correct type
    execute: *const fn (context: *anyopaque) void,

    /// Task-specific context (captures, arguments)
    /// Must remain valid for the lifetime of the task
    context: *anyopaque,

    /// Scope this task belongs to (null for fire-and-forget tasks)
    /// Used for structured concurrency guarantees
    /// Type-erased to avoid circular dependency with scope.zig
    scope: ?*anyopaque,

    /// Execute the task
    ///
    /// This is called by worker threads when they pick up the task.
    /// The task's execute function is responsible for:
    /// 1. Casting context to the correct type
    /// 2. Performing the actual work
    /// 3. Handling any errors (panic propagation is done at scope level)
    pub inline fn run(self: Task) void {
        self.execute(self.context);
    }

    /// Create a task from a function and arguments
    ///
    /// This is a helper for creating tasks from comptime-known functions.
    /// The wrapper handles type erasure and argument unpacking.
    ///
    /// Usage:
    /// ```zig
    /// const task = Task.create(myFunction, .{arg1, arg2}, null);
    /// ```
    pub fn create(
        comptime func: anytype,
        args: anytype,
        scope_ptr: ?*anyopaque,
    ) Task {
        const Args = @TypeOf(args);

        const Wrapper = struct {
            fn execute(ctx: *anyopaque) void {
                const args_ptr: *Args = @ptrCast(@alignCast(ctx));
                @call(.auto, func, args_ptr.*);
            }
        };

        return Task{
            .execute = Wrapper.execute,
            .context = @ptrCast(@constCast(&args)),
            .scope = scope_ptr,
        };
    }
};

/// Task with result storage
///
/// Used for tasks that return a value. The result is written to
/// the provided storage location, and a completion flag is set.
pub fn TaskWithResult(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying task
        task: Task,

        /// Result storage (written by task, read after completion)
        result: T align(std.atomic.cache_line) = undefined,

        /// Completion flag (set to true when result is available)
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Check if result is available
        pub fn isDone(self: *const Self) bool {
            return self.completed.load(.acquire);
        }

        /// Get the result (must only be called after isDone() returns true)
        pub fn get(self: *Self) T {
            std.debug.assert(self.isDone());
            return self.result;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Task size fits in cache line" {
    try std.testing.expect(@sizeOf(Task) <= std.atomic.cache_line);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Task));
}

test "Task execution" {
    var counter: usize = 0;

    const Context = struct {
        counter: *usize,
    };

    const wrapper = struct {
        fn execute(ctx: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(ctx));
            context.counter.* += 1;
        }
    };

    var context = Context{ .counter = &counter };

    const task = Task{
        .execute = wrapper.execute,
        .context = @ptrCast(&context),
        .scope = null,
    };

    task.run();

    try std.testing.expectEqual(@as(usize, 1), counter);
}

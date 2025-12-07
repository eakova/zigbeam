const std = @import("std");

pub const Task = struct {
    thread: std.Thread,
    state: *SharedState,
    allocator: std.mem.Allocator,
    /// Internal flag to make wait() idempotent and prevent double-destroy.
    joined: bool = false,

    /// The context object passed to the worker function.
    /// Acts like C# CancellationToken.
    pub const Context = struct {
        _state: *SharedState,

        /// Returns true if cancellation has been requested.
        pub fn cancelled(self: Context) bool {
            // Acquire ensures we see any writes that happened-before cancel().
            return self._state.is_cancelled.load(.acquire);
        }

        /// Smart sleep: waits for `ms` milliseconds OR until cancelled.
        /// Returns `true` if woke up due to cancellation.
        /// Returns `false` if sleep finished normally.
        pub fn sleep(self: Context, ms: u64) bool {
            if (self.cancelled()) return true;

            self._state.mutex.lock();
            defer self._state.mutex.unlock();

            // Check flag again inside lock to avoid races
            if (self._state.is_cancelled.load(.monotonic)) return true;

            // timedWait returns error.Timeout if time expires naturally
            self._state.cond.timedWait(&self._state.mutex, ms * std.time.ns_per_ms) catch {
                return self.cancelled();
            };

            // If we got here (no timeout error), we were signaled (cancelled)
            return true;
        }
    };

    /// Spawns a new thread.
    /// `function`: A function accepting `Task.Context` as its first argument.
    /// `args`: A tuple of additional arguments.
    pub fn spawn(allocator: std.mem.Allocator, comptime function: anytype, args: anytype) !Task {
        const state = try allocator.create(SharedState);
        state.* = .{};

        const ctx = Context{ ._state = state };

        // Prepend 'ctx' to the user's arguments using comptime tuple concatenation
        const thread_args = prependContext(ctx, args);

        const t = try std.Thread.spawn(.{}, function, thread_args);

        return Task{
            .thread = t,
            .state = state,
            .allocator = allocator,
        };
    }

    /// Helper function to prepend Context to args tuple at comptime
    fn prependContext(ctx: Context, args: anytype) TuplePrepend(Context, @TypeOf(args)) {
        const ArgsType = @TypeOf(args);
        const args_fields = @typeInfo(ArgsType).@"struct".fields;
        var result: TuplePrepend(Context, ArgsType) = undefined;
        result[0] = ctx;
        inline for (args_fields, 0..) |_, i| {
            result[i + 1] = args[i];
        }
        return result;
    }

    /// Type function to create a tuple type with T prepended to ArgsType
    fn TuplePrepend(comptime T: type, comptime ArgsType: type) type {
        const args_fields = @typeInfo(ArgsType).@"struct".fields;
        return std.meta.Tuple(&[_]type{T} ++ fieldTypes(args_fields));
    }

    /// Extract field types from struct fields
    fn fieldTypes(comptime fields: []const std.builtin.Type.StructField) []const type {
        var types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| {
            types[i] = field.type;
        }
        return &types;
    }

    /// Signals the thread to cancel.
    /// Wakes up the thread immediately if it is inside `ctx.sleep()`.
    pub fn cancel(self: *Task) void {
        // 1. Set flag
        // Release pairs with the acquire load in Context.cancelled().
        self.state.is_cancelled.store(true, .release);

        // 2. Wake up sleeper
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        self.state.cond.signal();
    }

    /// Waits for the thread to finish and frees internal memory.
    pub fn wait(self: *Task) void {
        if (self.joined) return;
        self.thread.join();
        self.allocator.destroy(self.state);
        self.joined = true;
    }

    // --- Private Internal State ---
    const SharedState = struct {
        is_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
    };
};

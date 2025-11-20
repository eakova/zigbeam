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

        // Prepend 'ctx' to the user's arguments
        const thread_args = try std.tuple.concat(.{ctx}, args);

        const t = try std.Thread.spawn(.{}, function, thread_args);

        return Task{
            .thread = t,
            .state = state,
            .allocator = allocator,
        };
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

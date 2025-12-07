// scope.zig - Scoped Task Spawning with Structured Concurrency
//
// Provides the scope() function for spawning a dynamic number of tasks
// with guaranteed completion before return.
//
// Design:
// - Scope tracks pending task count atomically
// - Tasks can spawn other tasks within the same scope
// - scope() blocks until all tasks complete (steal-while-wait)
// - Panics from any task propagate to scope exit
// - Nested scopes complete inner-first
// - Uses sharded arenas (one per worker + one for external threads)
//   to eliminate mutex contention on concurrent spawn
//
// Usage:
// ```zig
// scope(|s| {
//     for (work_items) |item| {
//         s.spawn(process, .{item});
//     }
// });
// // All work_items processed here
// ```

const std = @import("std");
const Atomic = std.atomic.Value;
const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;

const thread_pool = @import("thread_pool.zig");
const ThreadPool = thread_pool.ThreadPool;
const Task = thread_pool.Task;
const getGlobalPool = thread_pool.getGlobalPool;
const getCurrentWorkerId = thread_pool.getCurrentWorkerId;

// ============================================================================
// Scope - Structured Concurrency Container
// ============================================================================

/// Maximum number of sharded arenas (workers + 1 for external threads)
/// Increased from 64 to 256 to support larger systems (up to 255 workers)
/// without excessive contention on shared shards.
const MAX_SHARDS = 256;

/// A single arena shard with its own mutex
const ArenaShard = struct {
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) ArenaShard {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
        };
    }

    fn deinit(self: *ArenaShard) void {
        self.arena.deinit();
    }

    fn alloc(self: *ArenaShard, comptime T: type) ?*T {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.arena.allocator().create(T) catch null;
    }
};

/// Scope for structured concurrency
///
/// A Scope tracks a group of spawned tasks and ensures they all complete
/// before the scope exits. Tasks can safely reference stack data because
/// the scope guarantees lifetime.
///
/// Uses sharded arena allocators (one per worker thread + one for external
/// threads) to eliminate mutex contention on concurrent spawn operations.
/// All contexts are freed at once when the scope completes.
pub const Scope = struct {
    /// Number of pending (not yet completed) tasks
    pending: Atomic(usize),

    /// Atomic flag: true if any task panicked (used for panic propagation)
    /// Issue 31 fix: Removed panic_payload field - it stored potentially dangling pointers
    /// and was never actually used (taskPanicked was dead code). The panicked flag is
    /// sufficient for panic detection, and we re-panic with a static message.
    panicked: Atomic(bool),

    /// Parent scope (for nested scopes)
    parent: ?*Scope,

    /// Pool this scope uses
    pool: *ThreadPool,

    /// Sharded arenas: one per worker + one for external threads
    /// Index 0..num_workers-1 = worker arenas (keyed by worker ID)
    /// Index num_workers = external thread arena (fallback)
    shards: []ArenaShard,

    /// Number of worker shards (external shard is at index num_workers)
    num_workers: usize,

    /// Backing allocator for shard array
    allocator: std.mem.Allocator,

    /// Initialize a new Scope with sharded arenas
    pub fn init(pool: *ThreadPool, parent: ?*Scope) Scope {
        const num_workers = pool.numWorkers();
        const num_shards = @min(num_workers + 1, MAX_SHARDS);

        // Allocate shard array
        const shards = pool.allocator.alloc(ArenaShard, num_shards) catch {
            // Fallback: single shard if allocation fails
            return initFallback(pool, parent);
        };

        // Initialize each shard
        for (shards) |*shard| {
            shard.* = ArenaShard.init(pool.allocator);
        }

        return Scope{
            .pending = Atomic(usize).init(0),
            .panicked = Atomic(bool).init(false),
            .parent = parent,
            .pool = pool,
            .shards = shards,
            .num_workers = num_workers,
            .allocator = pool.allocator,
        };
    }

    /// Fallback initialization with single shard (if shard array allocation fails)
    fn initFallback(pool: *ThreadPool, parent: ?*Scope) Scope {
        // Use a static single-shard array on stack - this is emergency fallback
        return Scope{
            .pending = Atomic(usize).init(0),
            .panicked = Atomic(bool).init(false),
            .parent = parent,
            .pool = pool,
            .shards = &[_]ArenaShard{},
            .num_workers = 0,
            .allocator = pool.allocator,
        };
    }

    /// Deinitialize scope and free all context allocations
    pub fn deinit(self: *Scope) void {
        for (self.shards) |*shard| {
            shard.deinit();
        }
        if (self.shards.len > 0) {
            self.allocator.free(self.shards);
        }
    }

    /// Get the shard index for the current thread
    /// Workers use their ID (modulo shards), external threads use the last shard
    fn getShardIndex(self: *const Scope) usize {
        if (self.shards.len == 0) return 0;

        if (getCurrentWorkerId()) |worker_id| {
            // Worker thread: use modulo to distribute evenly when workers > shards
            // Reserve last shard for external threads, so use shards.len - 1
            const worker_shards = if (self.shards.len > 1) self.shards.len - 1 else 1;
            return worker_id % worker_shards;
        } else {
            // External thread: use the last shard (external shard)
            return self.shards.len - 1;
        }
    }

    /// Allocate from the appropriate shard (lock-free for different workers)
    fn allocContext(self: *Scope, comptime Context: type) ?*Context {
        if (self.shards.len == 0) {
            // Fallback mode: allocation failed during init
            return null;
        }
        const shard_idx = self.getShardIndex();
        return self.shards[shard_idx].alloc(Context);
    }

    /// Spawn a task within this scope
    ///
    /// The task will be executed by the thread pool. The scope tracks
    /// the task and ensures it completes before scope exit.
    ///
    /// Safe to call from multiple threads concurrently.
    /// Uses arena allocation for reduced overhead - contexts are freed
    /// when scope completes.
    pub fn spawn(
        self: *Scope,
        comptime func: anytype,
        args: anytype,
    ) void {
        const Args = @TypeOf(args);
        const Context = ScopeTaskContext(func, Args);

        // Increment pending count BEFORE spawning
        _ = self.pending.fetchAdd(1, .acq_rel);

        // Allocate context from scope's arena (freed when scope completes)
        const ctx = self.allocContext(Context) orelse {
            // Issue 23 fix: Execute locally on allocation failure instead of silently skipping.
            // This is consistent with pool.spawn failure handling below.
            @call(.auto, func, args);
            _ = self.pending.fetchSub(1, .acq_rel);
            return;
        };

        ctx.* = Context{
            .scope = self,
            .args = args,
            .task = undefined,
        };

        ctx.task = Task{
            .execute = Context.execute,
            .context = @ptrCast(ctx),
            .scope = @ptrCast(self),
        };

        // Spawn task to pool
        self.pool.spawn(&ctx.task) catch {
            // If spawn fails, execute locally (no destroy - arena handles cleanup)
            @call(.auto, func, args);
            _ = self.pending.fetchSub(1, .acq_rel);
        };
    }

    /// Spawn a task and get a handle for its result
    ///
    /// Returns a pointer to a SpawnHandle that can be used to retrieve the result.
    /// The result is valid after scope completes. The handle is arena-allocated
    /// and freed automatically when the scope completes.
    /// Returns null if allocation fails.
    pub fn spawnWithHandle(
        self: *Scope,
        comptime func: anytype,
        args: anytype,
    ) ?*SpawnHandle(FnReturnType(@TypeOf(func))) {
        const ReturnType = FnReturnType(@TypeOf(func));
        const Args = @TypeOf(args);
        const Context = ScopeTaskContextWithResult(func, Args, ReturnType);
        const HandleType = SpawnHandle(ReturnType);

        // Allocate handle from arena (not stack!) to avoid dangling pointer
        const handle = self.allocContext(HandleType) orelse {
            return null;
        };
        handle.* = HandleType{
            .result = undefined,
            .completed = Atomic(bool).init(false),
        };

        // Increment pending count BEFORE spawning
        _ = self.pending.fetchAdd(1, .acq_rel);

        // Allocate context from scope's arena
        const ctx = self.allocContext(Context) orelse {
            // Issue 7/46 fix: Execute locally on allocation failure
            // Mark handle completed AND set result to prevent callers reading undefined
            const local_result = @call(.auto, func, args);
            handle.result = local_result;
            handle.completed.store(true, .release);
            _ = self.pending.fetchSub(1, .acq_rel);
            return handle;
        };

        ctx.* = Context{
            .scope = self,
            .args = args,
            .handle = handle,
            .task = undefined,
        };

        ctx.task = Task{
            .execute = Context.execute,
            .context = @ptrCast(ctx),
            .scope = @ptrCast(self),
        };

        self.pool.spawn(&ctx.task) catch {
            // Execute locally on failure (no destroy - arena handles cleanup)
            const result = @call(.auto, func, args);
            handle.result = result;
            handle.completed.store(true, .release);
            _ = self.pending.fetchSub(1, .acq_rel);
        };

        return handle;
    }

    /// Wait for all spawned tasks to complete
    ///
    /// Uses steal-while-wait to help execute other tasks while waiting.
    /// After this returns, all tasks are guaranteed complete.
    pub fn wait(self: *Scope) void {
        var backoff = Backoff.init(self.pool.backoff_config);

        while (self.pending.load(.acquire) > 0) {
            // Help by executing other tasks
            if (self.pool.tryProcessOneTask()) {
                backoff.reset();
            } else {
                backoff.snooze();
            }
        }
    }

    /// Called when a task completes (internal)
    pub fn taskCompleted(self: *Scope) void {
        _ = self.pending.fetchSub(1, .acq_rel);
    }

    // Issue 31 fix: Removed taskPanicked() - it was dead code that stored potentially
    // dangling pointers. Panic detection now uses panicked: Atomic(bool) exclusively.
};

// ============================================================================
// SpawnHandle - Result handle for spawnWithHandle
// ============================================================================

/// Handle for retrieving spawn result
pub fn SpawnHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        result: T,
        completed: Atomic(bool),

        /// Check if result is available
        pub fn isDone(self: *const Self) bool {
            return self.completed.load(.acquire);
        }

        /// Get the result (must call after scope completes)
        pub fn get(self: *const Self) T {
            return self.result;
        }
    };
}

// ============================================================================
// Task Context Types
// ============================================================================

/// Context for scope task execution
/// Note: Memory is managed by scope's arena - no individual deallocation needed
fn ScopeTaskContext(comptime func: anytype, comptime Args: type) type {
    return struct {
        const Self = @This();

        scope: *Scope,
        args: Args,
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const scope_ptr = self.scope;

            // Track normal completion - if defer runs without this being true, we panicked
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    // Issue 8 fix: Set panicked flag so scope exit can re-panic
                    scope_ptr.panicked.store(true, .release);
                }
                scope_ptr.taskCompleted();
            }

            // Execute the function
            @call(.auto, func, self.args);
            completed_normally = true;
        }
    };
}

/// Context for scope task with result
/// Note: Memory is managed by scope's arena - no individual deallocation needed
fn ScopeTaskContextWithResult(comptime func: anytype, comptime Args: type, comptime ReturnType: type) type {
    return struct {
        const Self = @This();

        scope: *Scope,
        args: Args,
        handle: *SpawnHandle(ReturnType),
        task: Task,

        pub fn execute(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const scope_ptr = self.scope;

            // Track normal completion - if defer runs without this being true, we panicked
            var completed_normally = false;
            defer {
                if (!completed_normally) {
                    // Issue 8 fix: Set panicked flag so scope exit can re-panic
                    scope_ptr.panicked.store(true, .release);
                }
                scope_ptr.taskCompleted();
            }

            // Execute and store result
            const result = @call(.auto, func, self.args);
            self.handle.result = result;
            self.handle.completed.store(true, .release);
            completed_normally = true;
        }
    };
}

// ============================================================================
// scope() - Main API
// ============================================================================

/// Execute a body with a scope for spawning tasks
///
/// All tasks spawned within the body are guaranteed to complete
/// before scope() returns. Tasks can safely reference stack data.
///
/// If any task panics, the panic is propagated after all tasks complete.
///
/// Example:
/// ```zig
/// var results: [N]i32 = undefined;
/// scope(|s| {
///     for (0..N) |i| {
///         s.spawn(compute, .{i, &results[i]});
///     }
/// });
/// // All results[i] are now valid
/// ```
pub fn scope(comptime body: fn (*Scope) void) void {
    scopeOnPool(getGlobalPool(), body);
}

/// Execute a body with a scope using a specific pool
pub fn scopeOnPool(pool: *ThreadPool, comptime body: fn (*Scope) void) void {
    // Get parent scope if nested
    const parent = current_scope;

    // Create scope
    var s = Scope.init(pool, parent);
    defer s.deinit(); // Free all context allocations from arena

    // Set as current scope for nested operations
    current_scope = &s;
    defer current_scope = parent;

    // Execute body
    body(&s);

    // Wait for all tasks to complete
    s.wait();

    // Issue 8/31 fix: Propagate panic if any task panicked (check atomic flag only)
    if (s.panicked.load(.acquire)) {
        @panic("task panicked in scope");
    }
}

// ============================================================================
// Thread-Local State
// ============================================================================

/// Current scope for nested scope support
threadlocal var current_scope: ?*Scope = null;

/// Get current scope (for nested spawn operations)
pub fn getCurrentScope() ?*Scope {
    return current_scope;
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

// ============================================================================
// Tests
// ============================================================================

test "Scope basic" {
    const pool = try ThreadPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    // Basic test just verifies scope completes without deadlock
    scopeOnPool(pool, struct {
        fn body(_: *Scope) void {
            // Empty scope should complete immediately
        }
    }.body);

    try std.testing.expect(true);
}

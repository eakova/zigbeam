//! EBR Collector - Central coordinator for epoch-based reclamation.
//!
//! The Collector manages the global epoch, thread registration,
//! and coordinates safe memory reclamation across all threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

const epoch_mod = @import("epoch");
const guard_mod = @import("guard");
const thread_local = @import("thread_local");
const reclaim = @import("reclaim");

pub const Guard = guard_mod.Guard;
pub const FastGuard = guard_mod.FastGuard;
pub const ThreadHandle = thread_local.ThreadHandle;
pub const GlobalState = epoch_mod.GlobalState;
pub const ThreadLocalState = thread_local.ThreadLocalState;
pub const DtorFn = reclaim.DtorFn;

/// Configuration for EBR Collector behavior.
///
/// Example usage:
/// ```zig
/// // Use default config
/// var collector = try Collector.init(allocator);
///
/// // Use custom config for high-scalability (32+ threads)
/// const MyCollector = CollectorType(.{
///     .epoch_advance_sample_rate = 8,  // 12.5% sampling
///     .batch_threshold = 128,           // larger batches
/// });
/// var collector = try MyCollector.init(allocator);
/// ```
pub const CollectorConfig = struct {
    /// Sampling rate for epoch advancement: 1 in N collections trigger tryAdvanceEpoch.
    /// Higher values reduce mutex contention but delay epoch advancement.
    /// - N=1: 100% - every collection tries to advance (high contention)
    /// - N=4: 25%  - default, good balance for 8-16 threads
    /// - N=8: 12.5% - better for 32+ threads
    /// Trade-off: epoch advancement may be delayed by 0 to (N-1) collections.
    epoch_advance_sample_rate: usize = 4,

    /// Number of deferred objects before triggering collection.
    /// Higher values reduce collection frequency but increase memory usage.
    /// - 32: aggressive collection, lower memory
    /// - 64: default, good balance
    /// - 128+: less frequent collection, higher memory
    batch_threshold: usize = 64,
};

/// Default Collector with standard configuration.
/// For custom configuration, use `CollectorType(.{ ... })`.
pub const Collector = CollectorType(.{});

/// Creates a Collector type with custom configuration.
///
/// Example:
/// ```zig
/// // High-scalability collector for 32+ threads
/// const ScalableCollector = CollectorType(.{ .epoch_advance_sample_rate = 8 });
/// var collector = try ScalableCollector.init(allocator);
/// ```
pub fn CollectorType(comptime config: CollectorConfig) type {
    return struct {
        const Self = @This();

        /// Configuration used by this collector type.
        pub const cfg = config;

        /// Global epoch state (cache-line aligned).
        global_state: GlobalState,

        /// Allocator for internal allocations.
        allocator: Allocator,

        /// List of all registered thread states.
        /// Protected by mutex for registration/unregistration.
        threads: std.ArrayList(*ThreadLocalState),

        /// Mutex protecting the threads list.
        /// Only held during registration/unregistration, not in hot path.
        threads_mutex: Mutex,

        /// Initialize a new collector.
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            return .{
                .global_state = GlobalState.init(),
                .allocator = allocator,
                .threads = .{},
                .threads_mutex = .{},
            };
        }

        /// Destroy the collector and free resources.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.threads.items.len == 0);
            self.threads.deinit(self.allocator);
        }

        /// Get the current global epoch.
        pub fn getCurrentEpoch(self: *const Self) u64 {
            return self.global_state.getCurrentEpoch();
        }

        /// Get count of pending deferred objects across all threads.
        ///
        /// **Performance Warning:** O(N_threads) iteration with mutex held.
        /// Use sparingly (e.g., health checks, metrics endpoints).
        /// Do NOT call in hot paths or per-request handlers.
        pub fn getPendingCount(self: *Self) usize {
            self.threads_mutex.lock();
            defer self.threads_mutex.unlock();

            var total: usize = 0;
            for (self.threads.items) |state| {
                total += state.garbage_bag.count();
            }
            return total;
        }

        /// Get count of currently registered threads.
        ///
        /// **Performance Warning:** Requires mutex acquisition.
        /// Use for debugging/monitoring only.
        pub fn getRegisteredThreadCount(self: *Self) usize {
            self.threads_mutex.lock();
            defer self.threads_mutex.unlock();
            return self.threads.items.len;
        }

        // ====================================================================
        // Thread Registration
        // ====================================================================

        /// Register the calling thread with the collector.
        ///
        /// **Important:** Each registered thread MUST call `unregisterThread()`
        /// before termination, or memory will leak. `Collector.deinit()` will
        /// panic in debug mode if threads remain registered.
        pub fn registerThread(self: *Self) Allocator.Error!ThreadHandle {
            if (thread_local.getLocalState() != null) {
                return ThreadHandle{ .state = thread_local.getLocalState().? };
            }

            const state = try self.allocator.create(ThreadLocalState);
            state.* = ThreadLocalState.init(self.allocator);

            self.threads_mutex.lock();
            defer self.threads_mutex.unlock();
            try self.threads.append(self.allocator, state);

            thread_local.setLocalState(state);
            return ThreadHandle{ .state = state };
        }

        /// Unregister the calling thread from the collector.
        pub fn unregisterThread(self: *Self, handle: ThreadHandle) void {
            const state = handle.state;
            std.debug.assert(!state.isPinned());

            _ = state.garbage_bag.reclaimAll();

            self.threads_mutex.lock();
            defer self.threads_mutex.unlock();

            for (self.threads.items, 0..) |s, i| {
                if (s == state) {
                    _ = self.threads.swapRemove(i);
                    break;
                }
            }

            state.deinit();
            self.allocator.destroy(state);
            thread_local.clearLocalState();
        }

        // ====================================================================
        // Critical Section (Pin/Unpin) - HOT PATH
        // ====================================================================

        /// Enter a critical section (pin the current epoch).
        pub inline fn pin(self: *Self) Guard {
            const state = thread_local.getLocalState().?;

            if (state.pin_count > 0) {
                state.pin_count += 1;
                return Guard{ ._collector = @ptrCast(self) };
            }

            const global_epoch = self.global_state.getCurrentEpoch();
            state.setEpochAndActive(global_epoch);
            state.pin_count = 1;

            return Guard{ ._collector = @ptrCast(self) };
        }

        /// Ultra-fast pin for maximum throughput (no nesting support).
        pub inline fn pinFast(self: *Self) FastGuard {
            const state = thread_local.getLocalState().?;
            const global_epoch = self.global_state.getCurrentEpoch();
            state.setEpochAndActive(global_epoch);
            return FastGuard{ ._state = state };
        }

        /// Exit a critical section (unpin the current epoch).
        pub inline fn unpinGuard(self: *Self, _: Guard) void {
            _ = self;
            const state = thread_local.getLocalState().?;

            std.debug.assert(state.pin_count > 0);
            state.pin_count -= 1;

            if (state.pin_count == 0) {
                state.clearActive();
            }
        }

        pub fn unpin(self: *Self, guard: Guard) void {
            self.unpinGuard(guard);
        }

        // ====================================================================
        // Deferred Reclamation
        // ====================================================================

        /// Defer reclamation of an object until safe.
        pub fn deferReclaim(self: *Self, ptr: *anyopaque, dtor: DtorFn) void {
            const state = thread_local.getLocalState().?;
            const current_epoch = self.global_state.getCurrentEpoch();

            const deferred = reclaim.DeferredSimple{ .ptr = ptr, .dtor = dtor };
            state.garbage_bag.append(deferred, current_epoch) catch {
                dtor(ptr);
                return;
            };

            if (state.garbage_bag.count() >= config.batch_threshold and
                current_epoch > state.last_collect_epoch)
            {
                self.collectInternal(state, current_epoch);
            }
        }

        /// Internal collection for a single thread's garbage.
        fn collectInternal(self: *Self, state: *ThreadLocalState, current_epoch: u64) void {
            state.last_collect_epoch = current_epoch;

            // Probabilistic sampling: only 1 in N collections try to advance epoch
            const hash = (@intFromPtr(state) >> 6) ^ current_epoch;
            if (hash % config.epoch_advance_sample_rate == 0) {
                _ = self.tryAdvanceEpoch();
            }

            const safe_epoch = self.global_state.getSafeEpoch();
            _ = state.garbage_bag.reclaimUpTo(safe_epoch);
        }

        /// Zero-allocation typed defer for types with embedded allocator.
        pub fn deferDestroy(self: *Self, comptime T: type, ptr: *T) void {
            self.deferReclaim(@ptrCast(ptr), makeDtor(T));
        }

        /// Attempt to advance epoch and trigger collection.
        pub fn collect(self: *Self) void {
            _ = self.tryAdvanceEpoch();

            if (thread_local.getLocalState()) |state| {
                const safe_epoch = self.global_state.getSafeEpoch();
                _ = state.garbage_bag.reclaimUpTo(safe_epoch);
            }
        }

        const EpochCheckResult = struct {
            all_caught_up: bool,
            min_epoch: u64,
        };

        fn checkThreadsAndGetMinEpoch(self: *Self) EpochCheckResult {
            const current_epoch = self.global_state.getCurrentEpoch();

            self.threads_mutex.lock();
            defer self.threads_mutex.unlock();

            var min_epoch: u64 = std.math.maxInt(u64);
            var all_caught_up = true;

            for (self.threads.items) |state| {
                if (!state.isPinned()) continue;

                const local = state.getLocalEpoch();
                if (local < min_epoch) min_epoch = local;
                if (local < current_epoch) all_caught_up = false;
            }

            return .{ .all_caught_up = all_caught_up, .min_epoch = min_epoch };
        }

        /// Try to advance the global epoch.
        pub fn tryAdvanceEpoch(self: *Self) bool {
            const check = self.checkThreadsAndGetMinEpoch();
            if (!check.all_caught_up) return false;
            const current = self.global_state.getCurrentEpoch();
            return self.global_state.tryAdvance(current);
        }
    };
}

// ============================================================================
// Comptime Helpers
// ============================================================================

/// Creates a zero-allocation destructor for types with embedded allocator.
pub fn makeDtor(comptime T: type) DtorFn {
    if (!@hasField(T, "allocator")) {
        @compileError("Type '" ++ @typeName(T) ++ "' must have an 'allocator' field for makeDtor. " ++
            "Use deferReclaim with a custom destructor instead.");
    }

    return struct {
        fn destroy(ptr: *anyopaque) void {
            const typed: *T = @ptrCast(@alignCast(ptr));
            const alloc = typed.allocator;
            alloc.destroy(typed);
        }
    }.destroy;
}

// ============================================================================
// Tests
// ============================================================================

test "Collector init and deinit" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());
    try std.testing.expectEqual(@as(usize, 0), collector.getPendingCount());
}

test "Collector thread registration" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    try std.testing.expect(handle.isValid());
    try std.testing.expect(thread_local.getLocalState() != null);

    collector.unregisterThread(handle);
    try std.testing.expect(thread_local.getLocalState() == null);
}

test "Collector pin/unpin" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    const guard = collector.pin();
    try std.testing.expect(guard.isValid());
    try std.testing.expect(thread_local.getLocalState().?.isPinned());

    guard.unpin();
    try std.testing.expect(!thread_local.getLocalState().?.isPinned());
}

test "Collector nested pin/unpin" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    const guard1 = collector.pin();
    const guard2 = collector.pin();
    const guard3 = collector.pin();

    try std.testing.expect(thread_local.getLocalState().?.isPinned());
    try std.testing.expectEqual(@as(u32, 3), thread_local.getLocalState().?.pin_count);

    guard3.unpin();
    try std.testing.expect(thread_local.getLocalState().?.isPinned());

    guard2.unpin();
    try std.testing.expect(thread_local.getLocalState().?.isPinned());

    guard1.unpin();
    try std.testing.expect(!thread_local.getLocalState().?.isPinned());
}

test "Collector epoch advancement" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());

    try std.testing.expect(collector.tryAdvanceEpoch());
    try std.testing.expectEqual(@as(u64, 1), collector.getCurrentEpoch());
}

test "Collector deferDestroy properly reclaims memory" {
    var collector = try Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    const TestNode = struct {
        value: u64,
        allocator: Allocator,
        padding: [56]u8 = undefined,
    };

    {
        const guard = collector.pin();
        defer guard.unpin();

        const node = try std.testing.allocator.create(TestNode);
        node.* = .{ .value = 42, .allocator = std.testing.allocator };

        collector.deferDestroy(TestNode, node);
    }

    try std.testing.expectEqual(@as(usize, 1), collector.getPendingCount());

    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();

    collector.collect();

    try std.testing.expectEqual(@as(usize, 0), collector.getPendingCount());
}

test "CollectorType with custom config" {
    const ScalableCollector = CollectorType(.{ .epoch_advance_sample_rate = 8 });
    var collector = try ScalableCollector.init(std.testing.allocator);
    defer collector.deinit();

    try std.testing.expectEqual(@as(usize, 8), ScalableCollector.cfg.epoch_advance_sample_rate);

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());
}

//! Thread-local state management for EBR.
//!
//! Each thread participating in EBR maintains its own state including:
//! - Local epoch (last observed global epoch)
//! - Active flag (currently in critical section)
//! - Pin count (for nested guards)
//! - Garbage bag (deferred objects)

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers");
const reclaim = @import("reclaim");

/// Per-thread state for EBR - cache-line aligned.
///
/// Each thread has exactly one of these, allocated on registration.
/// The structure is cache-line aligned to prevent false sharing
/// between threads.
pub const ThreadLocalState = struct {
    /// Combined epoch and active flag in single atomic.
    /// Layout: upper 63 bits = epoch, lowest bit = active flag.
    /// This eliminates the need for SeqCst fence between epoch and active stores.
    epoch_and_active: std.atomic.Value(u64) align(helpers.cache_line),

    /// Count of nested pin() calls.
    /// Allows nested critical sections without re-acquiring epoch.
    pin_count: u32,

    /// Last epoch when collection was attempted.
    /// Used to skip redundant collection when epoch hasn't advanced.
    last_collect_epoch: u64,

    /// Thread-local garbage bag for deferred reclamation (epoch-bucketed for O(1) reclaim).
    garbage_bag: reclaim.EpochBucketedBag,

    /// Padding to fill cache line.
    _padding: PaddingType = undefined,

    // Calculate padding size at comptime
    const UsedSize = @sizeOf(std.atomic.Value(u64)) +
        @sizeOf(u32) + // pin_count
        @sizeOf(u64) + // last_collect_epoch
        @sizeOf(reclaim.EpochBucketedBag);
    const PaddingType = if (UsedSize >= helpers.cache_line)
        [0]u8
    else
        [helpers.cache_line - UsedSize]u8;

    /// Active flag is stored in the lowest bit.
    const ACTIVE_BIT: u64 = 1;

    /// Initialize thread-local state.
    pub fn init(allocator: Allocator) ThreadLocalState {
        return .{
            .epoch_and_active = std.atomic.Value(u64).init(0),
            .pin_count = 0,
            .last_collect_epoch = 0,
            .garbage_bag = reclaim.EpochBucketedBag.init(allocator),
        };
    }

    /// Clean up thread-local state.
    /// Must be called with is_active == false.
    pub fn deinit(self: *ThreadLocalState) void {
        std.debug.assert(!self.isPinned());
        self.garbage_bag.deinit();
    }

    /// Check if this thread is currently pinned (in critical section).
    pub fn isPinned(self: *const ThreadLocalState) bool {
        return (self.epoch_and_active.load(.acquire) & ACTIVE_BIT) != 0;
    }

    /// Get the local epoch value (upper 63 bits).
    pub fn getLocalEpoch(self: *const ThreadLocalState) u64 {
        return self.epoch_and_active.load(.acquire) >> 1;
    }

    /// Set epoch and active flag atomically (single store, no fence needed).
    pub inline fn setEpochAndActive(self: *ThreadLocalState, epoch: u64) void {
        // Combine: shift epoch left by 1, set active bit
        const combined = (epoch << 1) | ACTIVE_BIT;
        self.epoch_and_active.store(combined, .release);
    }

    /// Clear active flag (epoch not needed after unpin).
    pub inline fn clearActive(self: *ThreadLocalState) void {
        // Simple store of 0 - no need to preserve epoch since it's only
        // read when active. Eliminates load+store → single store.
        self.epoch_and_active.store(0, .release);
    }
};

/// Opaque handle returned from thread registration.
///
/// Must be held by the thread for its lifetime in the EBR system
/// and passed to unregisterThread() on exit.
pub const ThreadHandle = struct {
    /// Pointer to the thread's local state.
    state: *ThreadLocalState,

    /// Check if this handle is valid.
    pub fn isValid(self: ThreadHandle) bool {
        return @intFromPtr(self.state) != 0;
    }
};

/// Thread-local pointer to this thread's state.
/// Set during registerThread(), cleared during unregisterThread().
pub threadlocal var local_state: ?*ThreadLocalState = null;

/// Get the current thread's local state.
/// Returns null if thread is not registered.
pub inline fn getLocalState() ?*ThreadLocalState {
    return local_state;
}

/// Set the current thread's local state.
/// Called during registration.
pub fn setLocalState(state: *ThreadLocalState) void {
    local_state = state;
}

/// Clear the current thread's local state.
/// Called during unregistration.
pub fn clearLocalState() void {
    local_state = null;
}

// ============================================================================
// Tests
// ============================================================================

test "ThreadLocalState size fits in 2 cache lines" {
    // With last_collect_epoch field, struct may exceed single cache line
    try std.testing.expect(@sizeOf(ThreadLocalState) <= 2 * helpers.cache_line);
}

test "ThreadHandle size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ThreadHandle));
}

test "ThreadLocalState init and deinit" {
    var state = ThreadLocalState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(!state.isPinned());
    try std.testing.expectEqual(@as(u64, 0), state.getLocalEpoch());
    try std.testing.expectEqual(@as(u32, 0), state.pin_count);
}

test "ThreadLocalState setEpochAndActive" {
    var state = ThreadLocalState.init(std.testing.allocator);
    defer state.deinit();

    // Initially not pinned
    try std.testing.expect(!state.isPinned());

    // Set epoch 5 and active
    state.setEpochAndActive(5);
    try std.testing.expect(state.isPinned());
    try std.testing.expectEqual(@as(u64, 5), state.getLocalEpoch());

    // Clear active (epoch cleared too - not needed after unpin)
    state.clearActive();
    try std.testing.expect(!state.isPinned());
    try std.testing.expectEqual(@as(u64, 0), state.getLocalEpoch()); // epoch cleared for perf
}

test "threadlocal state management" {
    try std.testing.expectEqual(@as(?*ThreadLocalState, null), getLocalState());

    var state = ThreadLocalState.init(std.testing.allocator);
    defer state.deinit();

    setLocalState(&state);
    try std.testing.expectEqual(&state, getLocalState().?);

    clearLocalState();
    try std.testing.expectEqual(@as(?*ThreadLocalState, null), getLocalState());
}

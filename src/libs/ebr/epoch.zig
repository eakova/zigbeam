//! Global epoch management for EBR.
//!
//! The epoch is a monotonically increasing counter that tracks the
//! "generation" of the system. Objects retired in epoch N can be
//! safely reclaimed when the global epoch reaches N+2.

const std = @import("std");
const helpers = @import("helpers");

/// Global epoch state - cache-line aligned to prevent false sharing.
///
/// This structure is shared across all threads and contains the
/// global epoch counter that coordinates safe memory reclamation.
pub const GlobalState = struct {
    /// Current global epoch counter.
    /// Monotonically increasing, wraps at u64 max (practically never).
    epoch: std.atomic.Value(u64) align(helpers.cache_line),

    /// Padding to fill cache line and prevent false sharing.
    _padding: helpers.CacheLinePadding(@sizeOf(std.atomic.Value(u64))) = undefined,

    /// Initialize global state with epoch starting at 0.
    pub fn init() GlobalState {
        return .{
            .epoch = std.atomic.Value(u64).init(0),
        };
    }

    /// Get the current global epoch with acquire ordering.
    pub inline fn getCurrentEpoch(self: *const GlobalState) u64 {
        return self.epoch.load(.acquire);
    }

    /// Attempt to advance the epoch by 1.
    /// Returns true if successful, false if another thread beat us.
    pub fn tryAdvance(self: *GlobalState, expected: u64) bool {
        return self.epoch.cmpxchgStrong(
            expected,
            expected +% 1, // Wrapping add (practically never wraps)
            .acq_rel,
            .acquire,
        ) == null;
    }

    /// Force advance the epoch (for testing only).
    /// In production, use tryAdvance with proper quiescence detection.
    pub fn forceAdvance(self: *GlobalState) u64 {
        return self.epoch.fetchAdd(1, .acq_rel);
    }

    /// Calculate the safe reclamation epoch.
    /// Objects retired at or before this epoch can be safely reclaimed.
    ///
    /// The 3-epoch rule: if current epoch is N, objects from epoch N-2
    /// and earlier are safe to reclaim (assuming all threads have
    /// advanced past N-2).
    pub fn getSafeEpoch(self: *const GlobalState) u64 {
        const current = self.getCurrentEpoch();
        // Safe epoch is 2 behind current (with underflow protection)
        return if (current >= 2) current - 2 else 0;
    }
};

// Compile-time verification that GlobalState is exactly cache-line sized
comptime {
    helpers.assertCacheLineAligned(GlobalState);
}

// ============================================================================
// Tests
// ============================================================================

test "GlobalState is cache-line aligned" {
    try std.testing.expectEqual(helpers.cache_line, @sizeOf(GlobalState));
}

test "GlobalState init starts at epoch 0" {
    const state = GlobalState.init();
    try std.testing.expectEqual(@as(u64, 0), state.getCurrentEpoch());
}

test "GlobalState tryAdvance succeeds" {
    var state = GlobalState.init();
    try std.testing.expect(state.tryAdvance(0));
    try std.testing.expectEqual(@as(u64, 1), state.getCurrentEpoch());
}

test "GlobalState tryAdvance fails with wrong expected" {
    var state = GlobalState.init();
    try std.testing.expect(!state.tryAdvance(1)); // Wrong expected
    try std.testing.expectEqual(@as(u64, 0), state.getCurrentEpoch());
}

test "GlobalState forceAdvance increments" {
    var state = GlobalState.init();
    const old = state.forceAdvance();
    try std.testing.expectEqual(@as(u64, 0), old);
    try std.testing.expectEqual(@as(u64, 1), state.getCurrentEpoch());
}

test "GlobalState getSafeEpoch calculation" {
    var state = GlobalState.init();

    // Epoch 0: safe epoch is 0 (underflow protection)
    try std.testing.expectEqual(@as(u64, 0), state.getSafeEpoch());

    _ = state.forceAdvance(); // Epoch 1
    try std.testing.expectEqual(@as(u64, 0), state.getSafeEpoch());

    _ = state.forceAdvance(); // Epoch 2
    try std.testing.expectEqual(@as(u64, 0), state.getSafeEpoch());

    _ = state.forceAdvance(); // Epoch 3
    try std.testing.expectEqual(@as(u64, 1), state.getSafeEpoch());

    _ = state.forceAdvance(); // Epoch 4
    try std.testing.expectEqual(@as(u64, 2), state.getSafeEpoch());
}

//! Guard type for scoped epoch protection.
//!
//! A Guard represents an active critical section where the holding
//! thread may access protected pointers. While a guard is held,
//! no objects visible to this thread will be reclaimed.

const std = @import("std");

/// Forward declaration - actual Collector is in ebr module
const Collector = @import("ebr").Collector;
const ThreadLocalState = @import("thread_local").ThreadLocalState;

/// RAII guard for epoch protection.
///
/// While held, protected pointers are safe to dereference.
/// Must be dropped (unpin called) before thread exits critical section.
///
/// Size: 8 bytes (single pointer)
pub const Guard = struct {
    /// Reference to the collector that created this guard.
    _collector: *Collector,

    /// Explicitly release the guard and exit the critical section.
    ///
    /// This is wait-free: O(1) with bounded operations.
    pub fn unpin(self: Guard) void {
        self._collector.unpinGuard(self);
    }

    /// Check if this guard is valid (non-null collector reference).
    pub fn isValid(self: Guard) bool {
        return @intFromPtr(self._collector) != 0;
    }
};

/// Fast guard that stores ThreadLocalState directly.
/// Eliminates threadlocal read on unpin for maximum throughput.
/// Does NOT support nested guards - use only when nesting not needed.
///
/// Size: 8 bytes (single pointer to state)
pub const FastGuard = struct {
    /// Direct pointer to thread's state (no threadlocal lookup on unpin).
    _state: *ThreadLocalState,

    /// Fast unpin - directly clears active flag, no threadlocal read.
    pub inline fn unpin(self: FastGuard) void {
        self._state.clearActive();
    }
};

// Compile-time size verification
comptime {
    if (@sizeOf(Guard) != 8) {
        @compileError(std.fmt.comptimePrint(
            "Guard must be exactly 8 bytes, got {}",
            .{@sizeOf(Guard)},
        ));
    }
    if (@sizeOf(FastGuard) != 8) {
        @compileError(std.fmt.comptimePrint(
            "FastGuard must be exactly 8 bytes, got {}",
            .{@sizeOf(FastGuard)},
        ));
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Guard size is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Guard));
}

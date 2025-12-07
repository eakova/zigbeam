// Adaptive Backoff for Lock-Free Operations
//
// Four-phase backoff strategy with adaptive sleep to balance latency vs CPU usage:
// - Phase 1 (0 to spin_limit): spinLoopHint - hot path, minimal latency
// - Phase 2 (spin_limit to multi_spin_limit): 4x spinLoopHint - increasing backoff
// - Phase 3 (multi_spin_limit to sleep_limit): Thread.yield - yield to OS scheduler
// - Phase 4 (sleep_limit+): Thread.sleep - power-saving sleep for sustained idleness
//
// THREAD SAFETY WARNING:
// - Backoff is NOT thread-safe (it mutates `count` field without atomics)
// - Each thread must have its own Backoff instance (thread-local)
// - Do NOT share a single Backoff instance between multiple threads

const std = @import("std");

/// Configuration for backoff behavior
pub const Config = struct {
    /// Iterations before switching from spin to multi-spin (default: 64)
    spin_limit: u32 = 64,
    /// Iterations before switching from multi-spin to yield (default: 128)
    multi_spin_limit: u32 = 128,
    /// Iterations before switching from yield to sleep (default: 256)
    sleep_limit: u32 = 256,
    /// Number of spin hints per multi-spin iteration (default: 4)
    multi_spin_count: u32 = 4,
    /// Sleep duration in nanoseconds for phase 4 (default: 1ms)
    sleep_ns: u64 = 1_000_000,
};

/// Adaptive exponential backoff for contention handling
///
/// Usage:
/// ```zig
/// var backoff = Backoff.init(.{});
/// while (!tryAcquire()) {
///     backoff.snooze();
/// }
/// backoff.reset(); // Reset after successful operation
/// ```
pub const Backoff = struct {
    count: u32 = 0,
    config: Config,

    const Self = @This();

    /// Initialize backoff with configuration
    pub fn init(config: Config) Self {
        return Self{
            .count = 0,
            .config = config,
        };
    }

    /// Alias for `init()` for API familiarity
    pub fn new(config: Config) Self {
        return init(config);
    }

    /// Reset the backoff counter (call after successful operation)
    pub fn reset(self: *Self) void {
        self.count = 0;
    }

    /// Perform one spin cycle (phase 1 behavior only)
    ///
    /// Use this for hot-path spinning when you know contention is brief.
    /// For general contention handling, prefer snooze().
    pub fn spin(self: *Self) void {
        std.atomic.spinLoopHint();
        if (self.count < self.config.spin_limit) {
            self.count +|= 1;
        }
    }

    /// Perform one backoff cycle with adaptive phase selection
    ///
    /// Call this when a CAS or other atomic operation fails.
    /// Automatically progresses through phases based on contention level.
    pub fn snooze(self: *Self) void {
        if (self.count < self.config.spin_limit) {
            // Phase 1: Single spin hint (hot path)
            std.atomic.spinLoopHint();
        } else if (self.count < self.config.multi_spin_limit) {
            // Phase 2: Multiple spin hints
            var i: u32 = 0;
            while (i < self.config.multi_spin_count) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        } else if (self.count < self.config.sleep_limit) {
            // Phase 3: Yield to OS scheduler
            std.Thread.yield() catch {};
        } else {
            // Phase 4: Power-saving sleep for sustained idleness
            std.Thread.sleep(self.config.sleep_ns);
        }
        self.count +|= 1; // Saturating add to prevent overflow
    }

    /// Check if backoff has completed all phases (in sleep phase)
    ///
    /// Returns true when it's advisable to switch to a blocking primitive.
    pub fn isCompleted(self: *const Self) bool {
        return self.count >= self.config.sleep_limit;
    }

    /// Check if we're in the yield phase (high contention indicator)
    pub fn isYielding(self: *const Self) bool {
        return self.count >= self.config.multi_spin_limit and
            self.count < self.config.sleep_limit;
    }

    /// Check if we're in the sleep phase (sustained idleness)
    pub fn isSleeping(self: *const Self) bool {
        return self.count >= self.config.sleep_limit;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "backoff phases" {
    var backoff = Backoff.init(.{});

    // Phase 1: spin (count 0-63)
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        backoff.snooze();
    }
    // After 64 snoozes, count = 64, now in phase 2 (multi-spin)
    try std.testing.expect(!backoff.isYielding());
    try std.testing.expect(!backoff.isSleeping());
    try std.testing.expectEqual(@as(u32, 64), backoff.count);

    // Phase 2: multi-spin (count 64-127)
    while (i < 128) : (i += 1) {
        backoff.snooze();
    }
    // After 128 snoozes, count = 128, now in phase 3 (yield)
    try std.testing.expect(backoff.isYielding());
    try std.testing.expect(!backoff.isSleeping());
    try std.testing.expectEqual(@as(u32, 128), backoff.count);

    // Phase 3: yield (count 128-255)
    while (i < 256) : (i += 1) {
        backoff.snooze();
    }
    // After 256 snoozes, count = 256, now in phase 4 (sleep)
    try std.testing.expect(!backoff.isYielding());
    try std.testing.expect(backoff.isSleeping());
    try std.testing.expect(backoff.isCompleted());
    try std.testing.expectEqual(@as(u32, 256), backoff.count);

    // Reset
    backoff.reset();
    try std.testing.expectEqual(@as(u32, 0), backoff.count);
    try std.testing.expect(!backoff.isYielding());
    try std.testing.expect(!backoff.isSleeping());
}

test "spin method" {
    var backoff = Backoff.init(.{});
    try std.testing.expect(!backoff.isCompleted());

    // Exercise spin
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        backoff.spin();
    }
    try std.testing.expectEqual(@as(u32, 16), backoff.count);

    backoff.reset();
    try std.testing.expectEqual(@as(u32, 0), backoff.count);
}

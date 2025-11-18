const std = @import("std");

/// Backoff helper for lock-free / spin-based algorithms.
///
/// This mirrors the behavior of crossbeam-utils' Backoff:
/// - `spin()` performs exponential spinning using CPU pause/hint instructions.
/// - `snooze()` spins first, then yields the OS timeslice after enough steps.
/// - `isCompleted()` tells you when it's advisable to park / block instead of spinning.
///
/// THREAD SAFETY WARNING:
/// - Backoff is NOT thread-safe (it mutates `step` field without atomics)
/// - Each thread must have its own Backoff instance (thread-local)
/// - Do NOT share a single Backoff instance between multiple threads
pub const Backoff = struct {
    step: u32 = 0,
    spin_limit: u32,
    yield_limit: u32,

    /// Configuration options for Backoff behavior.
    pub const Options = struct {
        /// Maximum step for spin-only phase (default: 6, meaning up to 2^6 = 64 spins).
        spin_limit: u32 = 6,
        /// Maximum step before backoff is considered complete (default: 10).
        yield_limit: u32 = 10,
    };

    /// Create a new backoff instance with optional configuration.
    pub inline fn init(opts: Options) Backoff {
        return .{
            .step = 0,
            .spin_limit = opts.spin_limit,
            .yield_limit = opts.yield_limit,
        };
    }

    /// Alias for `init()` for API familiarity.
    pub inline fn new(opts: Options) Backoff {
        return init(opts);
    }

    /// Reset the backoff to its initial state.
    pub inline fn reset(self: *Backoff) void {
        self.step = 0;
    }

    /// Back off in a lock-free loop when another thread made progress.
    ///
    /// Executes an exponential number of spin-loop hints:
    ///   1, 2, 4, 8, ... capped at `1 << spin_limit`.
    pub inline fn spin(self: *Backoff) void {
        const capped = if (self.step > self.spin_limit) self.spin_limit else self.step;
        const spins: u32 = @as(u32, 1) << @intCast(capped);
        var i: u32 = 0;
        while (i < spins) : (i += 1) {
            std.atomic.spinLoopHint();
        }

        if (self.step <= self.spin_limit) {
            self.step += 1;
        }
    }

    /// Back off in a blocking/waiting loop while waiting for other threads.
    ///
    /// Initially behaves like `spin()`, then starts yielding the current
    /// thread to the OS scheduler after enough steps.
    pub inline fn snooze(self: *Backoff) void {
        if (self.step <= self.spin_limit) {
            // Spin-only phase.
            const spins: u32 = @as(u32, 1) << @intCast(self.step);
            var i: u32 = 0;
            while (i < spins) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        } else {
            // Yield phase: give up the timeslice to the OS scheduler.
            // On failure to yield, just spin once as a fallback.
            std.Thread.yield() catch {
                std.atomic.spinLoopHint();
            };
        }

        if (self.step <= self.yield_limit) {
            self.step += 1;
        }
    }

    /// Returns true if exponential backoff has completed and it is advisable
    /// to switch to a blocking/parking synchronization primitive.
    pub inline fn isCompleted(self: *const Backoff) bool {
        return self.step > self.yield_limit;
    }
};

// Basic self-checks.
test "Backoff basic progression" {
    var b = Backoff.init(.{});
    try std.testing.expect(!b.isCompleted());

    // Exercise a few spins and snoozes to ensure the API is wired.
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        b.spin();
    }
    b.reset();
    i = 0;
    while (i < 16) : (i += 1) {
        b.snooze();
    }
}

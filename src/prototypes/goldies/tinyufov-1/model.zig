/// Core data models for TinyUFO v3
/// Uses: atomic counter with cap of 3
/// Location: tracks if item is in small FIFO or main FIFO
/// Bucket: container for cached item with metadata

const std = @import("std");
const Atomic = std.atomic.Value;

/// Location constants
pub const LOCATION_SMALL: bool = false;
pub const LOCATION_MAIN: bool = true;

/// Uses counter - tracks how many times accessed (0-3)
/// Used to avoid evicting hot items from small FIFO
pub const Uses = struct {
    counter: Atomic(u8),

    pub fn init() Uses {
        return .{
            .counter = Atomic(u8).init(0),
        };
    }

    /// Increment uses (capped at 3) - Rust: lib.rs Uses::inc_uses (uses Acquire/Relaxed)
    pub fn inc_uses(self: *Uses) u8 {
        while (true) {
            const current = self.counter.load(.monotonic);  // Rust: uses()

            if (current >= 3) {
                return current;  // Already at cap
            }

            const result = self.counter.cmpxchgWeak(
                current,
                current + 1,
                .acquire,    // Rust: Acquire (match exactly)
                .monotonic,  // Rust: Relaxed (match exactly)
            );

            if (result == null) {
                return current + 1;  // Success: return value AFTER increment
            }
            // else: retry loop
        }
    }

    /// Decrement uses and return previous value (Rust: lib.rs Uses::decr_uses - Acquire/Relaxed)
    pub fn decr_uses(self: *Uses) u8 {
        while (true) {
            const current = self.counter.load(.monotonic);  // Rust: uses()

            if (current == 0) {
                return 0;  // Already at zero
            }

            const result = self.counter.cmpxchgWeak(
                current,
                current - 1,
                .acquire,    // Rust: Acquire (match exactly)
                .monotonic,  // Rust: Relaxed (match exactly)
            );

            if (result == null) {
                return current;  // Success: return value BEFORE decrement
            }
            // else: retry loop
        }
    }

    /// Get current uses count (Rust: lib.rs Uses::uses - uses Relaxed)
    pub fn uses(self: *const Uses) u8 {
        return self.counter.load(.monotonic);  // Rust: Relaxed
    }

    /// Reset to zero
    pub fn reset(self: *Uses) void {
        self.counter.store(0, .monotonic);
    }
};

/// Location - tracks whether item is in small or main FIFO (Rust: lib.rs Location - uses Relaxed)
pub const Location = struct {
    in_main_fifo: Atomic(bool),

    pub fn init() Location {
        return .{
            .in_main_fifo = Atomic(bool).init(LOCATION_SMALL),
        };
    }

    /// Create new in small FIFO
    pub fn new_small() Location {
        return .{
            .in_main_fifo = Atomic(bool).init(LOCATION_SMALL),
        };
    }

    /// Check if in main FIFO (Rust: Location::is_main - uses Relaxed)
    pub fn is_main(self: *const Location) bool {
        return self.in_main_fifo.load(.monotonic);  // Rust: Relaxed
    }

    /// Move to main FIFO (Rust: Location::move_to_main - uses Relaxed)
    pub fn move_to_main(self: *Location) void {
        self.in_main_fifo.store(LOCATION_MAIN, .monotonic);  // Rust: Relaxed
    }

    /// Reset to small
    pub fn reset_to_small(self: *Location) void {
        self.in_main_fifo.store(LOCATION_SMALL, .monotonic);  // Rust: Relaxed
    }
};

/// Bucket - container for cached data with metadata
pub fn Bucket(comptime T: type) type {
    return struct {
        uses: Uses,
        location: Location,
        weight: u16,              // Weight/cost of item (for weighted capacity)
        data: T,
        queue_index: u64,         // Index in SegQueue for tracking

        const Self = @This();

        pub fn init(data: T, weight: u16) Self {
            return .{
                .uses = Uses.init(),
                .location = Location.new_small(),
                .weight = weight,
                .data = data,
                .queue_index = 0,
            };
        }

        /// Access the item (increment uses)
        pub fn access(self: *Self) void {
            _ = self.uses.inc_uses();  // Discard return value
        }

        /// Check if hot (uses >= 2)
        pub fn is_hot(self: *const Self) bool {
            return self.uses.uses() >= 2;
        }

        /// Check if in main FIFO
        pub fn in_main(self: *const Self) bool {
            return self.location.is_main();
        }

        /// Promote to main FIFO
        pub fn promote_to_main(self: *Self) void {
            self.location.move_to_main();
        }

        /// Reset state (but keep data)
        pub fn reset_state(self: *Self) void {
            self.uses.reset();
            self.location.reset_to_small();
        }
    };
}

/// ============================================================================
/// TESTS
/// ============================================================================

const std_testing = std.testing;

test "Uses: init" {
    var uses = Uses.init();
    try std_testing.expect(uses.uses() == 0);
}

test "Uses: inc_uses" {
    var uses = Uses.init();

    _ = uses.inc_uses();
    try std_testing.expect(uses.uses() == 1);

    _ = uses.inc_uses();
    try std_testing.expect(uses.uses() == 2);
}

test "Uses: cap at 3" {
    var uses = Uses.init();

    for (0..10) |_| {
        _ = uses.inc_uses();
    }

    try std_testing.expect(uses.uses() == 3);
}

test "Uses: decr_uses" {
    var uses = Uses.init();

    _ = uses.inc_uses();
    _ = uses.inc_uses();
    _ = uses.inc_uses();

    try std_testing.expect(uses.uses() == 3);

    _ = uses.decr_uses();
    try std_testing.expect(uses.uses() == 2);
}

test "Uses: reset" {
    var uses = Uses.init();

    _ = uses.inc_uses();
    _ = uses.inc_uses();

    uses.reset();
    try std_testing.expect(uses.uses() == 0);
}

test "Location: init" {
    const loc = Location.init();
    try std_testing.expect(!loc.is_main());
}

test "Location: new_small" {
    const loc = Location.new_small();
    try std_testing.expect(!loc.is_main());
}

test "Location: move_to_main" {
    var loc = Location.new_small();
    try std_testing.expect(!loc.is_main());

    loc.move_to_main();
    try std_testing.expect(loc.is_main());
}

test "Location: reset_to_small" {
    var loc = Location.new_small();
    loc.move_to_main();
    try std_testing.expect(loc.is_main());

    loc.reset_to_small();
    try std_testing.expect(!loc.is_main());
}

test "Bucket: init" {
    const data = @as(u64, 12345);
    var bucket = Bucket(u64).init(data, 100);

    try std_testing.expect(bucket.data == 12345);
    try std_testing.expect(bucket.weight == 100);
    try std_testing.expect(bucket.uses.uses() == 0);
    try std_testing.expect(!bucket.in_main());
}

test "Bucket: access and hot" {
    var bucket = Bucket(u32).init(42, 50);

    try std_testing.expect(!bucket.is_hot());

    bucket.access();
    bucket.access();

    try std_testing.expect(bucket.is_hot());
}

test "Bucket: promote_to_main" {
    var bucket = Bucket(u64).init(999, 20);

    try std_testing.expect(!bucket.in_main());

    bucket.promote_to_main();
    try std_testing.expect(bucket.in_main());
}

test "Bucket: reset_state" {
    var bucket = Bucket(u32).init(100, 75);

    bucket.access();
    bucket.access();
    bucket.promote_to_main();

    try std_testing.expect(bucket.is_hot());
    try std_testing.expect(bucket.in_main());

    bucket.reset_state();

    try std_testing.expect(!bucket.is_hot());
    try std_testing.expect(!bucket.in_main());
    try std_testing.expect(bucket.data == 100); // Data unchanged
}

test "Bucket: generic with pointer data" {
    const data = @as(*u32, @ptrFromInt(0xdeadbeef));
    const bucket = Bucket(*u32).init(data, 200);

    try std_testing.expect(bucket.data == data);
    try std_testing.expect(bucket.weight == 200);
}

test "Bucket: sequential access pattern" {
    var bucket = Bucket(u64).init(555, 10);

    for (0..5) |_| {
        bucket.access();
    }

    try std_testing.expect(bucket.uses.uses() == 3); // Capped at 3
    try std_testing.expect(bucket.is_hot());
}

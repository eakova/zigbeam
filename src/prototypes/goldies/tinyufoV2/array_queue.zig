const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

/// Bounded MPMC queue with fixed capacity
/// Similar to crossbeam's ArrayQueue
pub fn ArrayQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            value: T,
            /// Epoch/version number to detect ABA problems
            epoch: u64,
        };

        capacity: u64,
        slots: []Slot,
        /// Atomic head position (includes epoch in upper bits)
        head: atomic.Value(u64),
        /// Atomic tail position (includes epoch in upper bits)
        tail: atomic.Value(u64),
        allocator: Allocator,

        const EPOCH_BITS = 32;
        const INDEX_MASK = (1 << EPOCH_BITS) - 1;

        pub fn init(allocator: Allocator, capacity: u64) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            if (capacity > INDEX_MASK) return error.CapacityTooLarge;

            const slots = try allocator.alloc(Slot, capacity);
            errdefer allocator.free(slots);

            for (slots) |*slot| {
                slot.epoch = 0;
            }

            return Self{
                .capacity = capacity,
                .slots = slots,
                .head = atomic.Value(u64).init(0),
                .tail = atomic.Value(u64).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
        }

        /// Encode position and epoch into single atomic value
        inline fn encode(index: u64, epoch: u64) u64 {
            return (epoch << EPOCH_BITS) | (index & INDEX_MASK);
        }

        /// Decode position and epoch from atomic value
        inline fn decode(encoded: u64) struct { index: u64, epoch: u64 } {
            return .{
                .index = encoded & INDEX_MASK,
                .epoch = encoded >> EPOCH_BITS,
            };
        }

        /// Push an element to the back
        /// Returns error if queue is full
        pub fn push(self: *Self, value: T) error{QueueFull}!void {
            while (true) {
                const tail_encoded = self.tail.load(.acquire);
                const tail_pos = self.decode(tail_encoded);
                const slot_index = tail_pos.index;

                const head_encoded = self.head.load(.acquire);
                const head_pos = self.decode(head_encoded);

                // Check if queue is full
                const next_index = (slot_index + 1) % self.capacity;
                if (next_index == head_pos.index and tail_pos.epoch == head_pos.epoch) {
                    return error.QueueFull;
                }

                const next_epoch = if (next_index == 0)
                    tail_pos.epoch +% 1
                else
                    tail_pos.epoch;

                const next_tail = encode(next_index, next_epoch);

                // Try to advance tail
                const cmpxchg_result = self.tail.cmpxchgStrong(
                    tail_encoded,
                    next_tail,
                    .release,
                    .acquire,
                );

                if (cmpxchg_result == null) {
                    // Successfully advanced tail, now write value
                    self.slots[slot_index] = .{
                        .value = value,
                        .epoch = tail_pos.epoch,
                    };
                    return;
                }
                // CAS failed, retry
            }
        }

        /// Pop an element from the front
        /// Returns null if queue is empty
        pub fn pop(self: *Self) ?T {
            while (true) {
                const head_encoded = self.head.load(.acquire);
                const head_pos = self.decode(head_encoded);
                const slot_index = head_pos.index;

                const tail_encoded = self.tail.load(.acquire);
                const tail_pos = self.decode(tail_encoded);

                // Check if queue is empty
                if (slot_index == tail_pos.index and head_pos.epoch == tail_pos.epoch) {
                    return null;
                }

                const slot = &self.slots[slot_index];

                // Check if slot has the value we expect
                if (slot.epoch != head_pos.epoch) {
                    return null;
                }

                const value = slot.value;

                const next_index = (slot_index + 1) % self.capacity;
                const next_epoch = if (next_index == 0)
                    head_pos.epoch +% 1
                else
                    head_pos.epoch;

                const next_head = encode(next_index, next_epoch);

                // Try to advance head
                const cmpxchg_result = self.head.cmpxchgStrong(
                    head_encoded,
                    next_head,
                    .release,
                    .acquire,
                );

                if (cmpxchg_result == null) {
                    return value;
                }
                // CAS failed, retry
            }
        }

        /// Try to push with timeout (simplified - uses busy spin)
        pub fn pushTimeout(self: *Self, value: T, timeout_ns: u64) !void {
            const start = std.time.nanoTimestamp();
            while (true) {
                if (self.push(value)) {
                    return;
                } else |err| {
                    if (err == error.QueueFull) {
                        if (std.time.nanoTimestamp() - start > timeout_ns) {
                            return err;
                        }
                        std.time.sleep(100); // Sleep briefly before retry
                    }
                }
            }
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *Self) bool {
            const head_encoded = self.head.load(.acquire);
            const tail_encoded = self.tail.load(.acquire);
            return head_encoded == tail_encoded;
        }

        /// Check if queue is full
        pub fn isFull(self: *Self) bool {
            const tail_encoded = self.tail.load(.acquire);
            const tail_pos = self.decode(tail_encoded);
            const next_index = (tail_pos.index + 1) % self.capacity;

            const head_encoded = self.head.load(.acquire);
            const head_pos = self.decode(head_encoded);

            return next_index == head_pos.index and tail_pos.epoch == head_pos.epoch;
        }

        /// Get approximate length
        pub fn len(self: *Self) u64 {
            const head_encoded = self.head.load(.acquire);
            const tail_encoded = self.tail.load(.acquire);

            const head_pos = self.decode(head_encoded);
            const tail_pos = self.decode(tail_encoded);

            if (tail_pos.index >= head_pos.index) {
                return tail_pos.index - head_pos.index;
            } else {
                return self.capacity - head_pos.index + tail_pos.index;
            }
        }

        /// Get capacity
        pub fn getCapacity(self: *Self) u64 {
            return self.capacity;
        }
    };
}

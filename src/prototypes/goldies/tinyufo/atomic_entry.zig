// Atomic Entry for Lock-Free TinyUFO Cache
// All fields are atomic for lock-free concurrent access

const std = @import("std");

/// Queue identifier for S3-FIFO architecture
pub const QueueId = enum(u8) {
    None,
    Window,
    Main,
    Protected,
};

/// Atomic cache entry with frequency tracking
pub fn AtomicEntry(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Key (atomic for pool reuse - only works for integer types)
        key: std.atomic.Value(K),

        /// Value (atomic for lock-free updates)
        value: std.atomic.Value(V),

        /// Frequency counter (for TinyLFU admission)
        frequency: std.atomic.Value(u8),

        /// Queue membership
        queue: std.atomic.Value(QueueId),

        /// Reference count (for safe memory management)
        ref_count: std.atomic.Value(usize),

        /// Timestamp (for LRU within queues)
        timestamp: std.atomic.Value(i128),

        /// Create new entry
        pub fn init(allocator: std.mem.Allocator, key: K, value: V) !*Self {
            const entry = try allocator.create(Self);
            entry.* = Self{
                .key = std.atomic.Value(K).init(key),
                .value = std.atomic.Value(V).init(value),
                .frequency = std.atomic.Value(u8).init(0),
                .queue = std.atomic.Value(QueueId).init(.None),
                .ref_count = std.atomic.Value(usize).init(1),
                .timestamp = std.atomic.Value(i128).init(std.time.nanoTimestamp()),
            };
            return entry;
        }

        /// Get key (atomic load)
        pub fn getKey(self: *const Self) K {
            return self.key.load(.acquire);
        }

        /// Get value (atomic load)
        pub fn getValue(self: *const Self) V {
            return self.value.load(.acquire);
        }

        /// Set value (atomic store)
        pub fn setValue(self: *Self, value: V) void {
            self.value.store(value, .release);
        }

        /// Increment frequency counter (atomic, saturating)
        pub fn incrementFrequency(self: *Self) void {
            const current = self.frequency.load(.acquire);
            if (current < 255) {
                _ = self.frequency.fetchAdd(1, .monotonic);
            }
        }

        /// Get frequency (atomic load)
        pub fn getFrequency(self: *const Self) u8 {
            return self.frequency.load(.acquire);
        }

        /// Set frequency (atomic store)
        pub fn setFrequency(self: *Self, freq: u8) void {
            self.frequency.store(freq, .release);
        }

        /// Get queue membership
        pub fn getQueue(self: *const Self) QueueId {
            return self.queue.load(.acquire);
        }

        /// Set queue membership
        pub fn setQueue(self: *Self, q: QueueId) void {
            self.queue.store(q, .release);
        }

        /// Compare-and-swap queue (for atomic transitions)
        pub fn casQueue(self: *Self, expected: QueueId, new: QueueId) bool {
            return self.queue.cmpxchgStrong(
                expected,
                new,
                .acq_rel,
                .acquire,
            ) == null;
        }

        /// Increment reference count
        pub fn acquire(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .monotonic);
        }

        /// Decrement reference count and return true if should be freed
        pub fn release(self: *Self) bool {
            const prev = self.ref_count.fetchSub(1, .acq_rel);
            return prev == 1;
        }

        /// Get reference count
        pub fn getRefCount(self: *const Self) usize {
            return self.ref_count.load(.acquire);
        }

        /// Update timestamp (atomic)
        pub fn touch(self: *Self) void {
            self.timestamp.store(std.time.nanoTimestamp(), .release);
        }

        /// Get timestamp
        pub fn getTimestamp(self: *const Self) i128 {
            return self.timestamp.load(.acquire);
        }

        /// Reinitialize entry for reuse from pool (reset all fields including key)
        /// This is used by Entry Pool to recycle entries
        pub fn reinit(self: *Self, key: K, value: V) void {
            // Update key (atomic store for thread-safety)
            self.key.store(key, .release);

            // Reset all atomic fields
            self.value.store(value, .release);
            self.frequency.store(0, .release);
            self.queue.store(.None, .release);
            self.ref_count.store(1, .release);
            self.timestamp.store(std.time.nanoTimestamp(), .release);
        }

        /// Destroy entry (must have ref_count == 0)
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }
    };
}

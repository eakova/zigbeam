const std = @import("std");

/// Cache entry with 2-bit frequency counter for lock-free TinyUFO
pub fn Entry(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        // Core data
        key: K,
        value: V,
        hash: u64,

        // 2-bit frequency counter (0-3) with atomic operations
        // Packed into atomic u8 for thread-safe updates
        frequency: std.atomic.Value(u8),

        // Reference counter for safe lock-free memory management
        ref_count: std.atomic.Value(u32),

        /// Initialize a new entry
        pub fn init(key: K, value: V, hash: u64) Self {
            return Self{
                .key = key,
                .value = value,
                .hash = hash,
                .frequency = std.atomic.Value(u8).init(0),
                .ref_count = std.atomic.Value(u32).init(1),
            };
        }

        /// Get current frequency (0-3)
        pub fn getFrequency(self: *Self) u8 {
            const freq = self.frequency.load(.acquire);
            return @min(freq, 3); // Cap at 3 (2-bit max)
        }

        /// Increment frequency (saturates at 3)
        pub fn incrementFrequency(self: *Self) void {
            while (true) {
                const current = self.frequency.load(.acquire);
                if (current >= 3) return; // Already at max

                const new_freq = current + 1;
                const result = self.frequency.cmpxchgWeak(
                    current,
                    new_freq,
                    .release,
                    .acquire,
                );

                if (result == null) return; // Success
                // CAS failed, retry
            }
        }

        /// Decrement frequency (saturates at 0)
        pub fn decrementFrequency(self: *Self) void {
            while (true) {
                const current = self.frequency.load(.acquire);
                if (current == 0) return; // Already at min

                const new_freq = current - 1;
                const result = self.frequency.cmpxchgWeak(
                    current,
                    new_freq,
                    .release,
                    .acquire,
                );

                if (result == null) return; // Success
                // CAS failed, retry
            }
        }

        /// Reset frequency to 0 (for Count-Min Sketch reset)
        pub fn resetFrequency(self: *Self) void {
            self.frequency.store(0, .release);
        }

        /// Acquire reference (increment ref count)
        pub fn acquire(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .acquire);
        }

        /// Release reference (decrement ref count)
        /// Returns true if this was the last reference
        pub fn release(self: *Self) bool {
            const prev = self.ref_count.fetchSub(1, .release);
            return prev == 1;
        }

        /// Get current reference count
        pub fn getRefCount(self: *Self) u32 {
            return self.ref_count.load(.acquire);
        }
    };
}

/// Entry pool for efficient allocation/deallocation
pub fn EntryPool(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const EntryType = Entry(K, V);

        allocator: std.mem.Allocator,
        free_list: std.atomic.Value(?*EntryType),

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .free_list = std.atomic.Value(?*EntryType).init(null),
            };
        }

        pub fn deinit(self: *Self) void {
            // Drain free list
            var current = self.free_list.swap(null, .acquire);
            while (current) |entry| {
                const next = @as(?*EntryType, @ptrFromInt(@intFromPtr(entry) & ~@as(usize, 1)));
                self.allocator.destroy(entry);
                current = next;
            }
        }

        /// Allocate entry from pool or create new
        pub fn create(self: *Self, key: K, value: V, hash: u64) !*EntryType {
            // Try to pop from free list
            while (true) {
                const current = self.free_list.load(.acquire);
                if (current == null) break;

                const result = self.free_list.cmpxchgWeak(
                    current,
                    null,
                    .release,
                    .acquire,
                );

                if (result == null) {
                    // Successfully popped from free list
                    const entry = current.?;
                    entry.* = EntryType.init(key, value, hash);
                    return entry;
                }
            }

            // Free list empty, allocate new
            const entry = try self.allocator.create(EntryType);
            entry.* = EntryType.init(key, value, hash);
            return entry;
        }

        /// Return entry to pool or destroy
        pub fn destroy(self: *Self, entry: *EntryType) void {
            // Push to free list
            while (true) {
                const current = self.free_list.load(.acquire);
                // Store next pointer in unused bits (not safe, simplified)

                const result = self.free_list.cmpxchgWeak(
                    current,
                    entry,
                    .release,
                    .acquire,
                );

                if (result == null) return; // Success
            }
        }
    };
}

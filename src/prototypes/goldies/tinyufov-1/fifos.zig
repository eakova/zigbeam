/// FIFOs for TinyUFO - dual queue structure with weight accounting
/// Manages small and main FIFOs with TinyLFU admission and weight-based eviction

const std = @import("std");
const Atomic = std.atomic.Value;

const seg_queue = @import("seg_queue.zig");
const SegQueue = seg_queue.SegQueue;
const estimator_mod = @import("estimator.zig");
const TinyLFU = estimator_mod.TinyLFU;
const model = @import("model.zig");

/// Key type used in FIFOs (u64 hash)
pub const Key = u64;

/// Represents an item in FIFO queue
pub const QueueEntry = struct {
    key: Key,
    weight: u16,
};

/// FIFOs - dual queue structure with weight accounting
pub const FIFOs = struct {
    allocator: std.mem.Allocator,

    // Two separate queues
    small_queue: *SegQueue,
    main_queue: *SegQueue,

    // Weight tracking (atomic counters)
    small_weight: Atomic(u64),
    main_weight: Atomic(u64),
    total_weight_limit: u64,

    // Frequency estimator for admission
    estimator: *TinyLFU,

    /// Initialize FIFOs with weight limit and capacity
    pub fn init(
        allocator: std.mem.Allocator,
        total_weight_limit: u64,
        cache_capacity: u64,
    ) !*FIFOs {
        const fifos = try allocator.create(FIFOs);

        const small_q = try SegQueue.init(allocator);
        const main_q = try SegQueue.init(allocator);
        const est = try TinyLFU.new(allocator, cache_capacity);

        fifos.* = .{
            .allocator = allocator,
            .small_queue = small_q,
            .main_queue = main_q,
            .small_weight = Atomic(u64).init(0),
            .main_weight = Atomic(u64).init(0),
            .total_weight_limit = total_weight_limit,
            .estimator = est,
        };

        return fifos;
    }

    pub fn deinit(self: *FIFOs) void {
        // Clear both queues, properly deallocating entries (Rust: lib.rs Cache::drop)
        self.clear();
        self.small_queue.deinit();
        self.main_queue.deinit();
        self.estimator.deinit();
        self.allocator.destroy(self);
    }

    /// Get total weight across both queues
    pub fn total_weight(self: *const FIFOs) u64 {
        const small = self.small_weight.load(.seq_cst);
        const main = self.main_weight.load(.seq_cst);
        return small + main;
    }

    /// Check if over capacity
    pub fn is_over_capacity(self: *const FIFOs) bool {
        return self.total_weight() > self.total_weight_limit;
    }

    /// Check if over capacity with extra weight (Rust: lib.rs line 248-249)
    pub fn is_over_capacity_with_weight(self: *const FIFOs, extra_weight: u16) bool {
        const total = self.small_weight.load(.seq_cst) + self.main_weight.load(.seq_cst);
        return self.total_weight_limit < total + extra_weight;
    }

    /// Get small queue weight limit (Rust: lib.rs lines 281-283)
    /// Returns 20% of total capacity + 1
    pub fn small_weight_limit(self: *const FIFOs) u64 {
        const limit = @as(f32, @floatFromInt(self.total_weight_limit)) * 0.2;
        return @as(u64, @intFromFloat(@floor(limit))) + 1;
    }

    /// Admit new key with weight and optional data
    pub fn admit(
        self: *FIFOs,
        key: Key,
        weight: u16,
        _ignore_lfu: bool,
    ) !void {
        _ = _ignore_lfu;
        // Record frequency for this new item
        self.estimator.incr(key);

        // Create entry to queue (HEAP-ALLOCATED to prevent dangling pointers)
        const entry = try self.allocator.create(QueueEntry);
        entry.* = QueueEntry{
            .key = key,
            .weight = weight,
        };

        // Always add to small queue first
        try self.small_queue.push(@ptrFromInt(@intFromPtr(entry)));

        // Update weight
        _ = self.small_weight.fetchAdd(weight, .seq_cst);

        // Note: Eviction is handled by TinyUFO after insertion, not here
        // This ensures consistency between queue state and cache state
    }

    /// Evict items until under capacity
    pub fn evict_to_limit(self: *FIFOs, _weight_needed: u16) !void {
        _ = _weight_needed;
        while (self.is_over_capacity()) {
            // Try to pop from small queue first
            if (self.small_queue.pop()) |entry_ptr| {
                const entry: *QueueEntry = @ptrCast(@alignCast(entry_ptr));

                // Update weight
                const prev_weight = self.small_weight.fetchSub(entry.weight, .seq_cst);

                if (prev_weight <= entry.weight) {
                    self.small_weight.store(0, .seq_cst);
                }

                // Deallocate the heap-allocated QueueEntry
                self.allocator.destroy(entry);
            } else if (self.main_queue.pop()) |entry_ptr| {
                const entry: *QueueEntry = @ptrCast(@alignCast(entry_ptr));

                // Update weight
                const prev_weight = self.main_weight.fetchSub(entry.weight, .seq_cst);

                if (prev_weight <= entry.weight) {
                    self.main_weight.store(0, .seq_cst);
                }

                // Deallocate the heap-allocated QueueEntry
                self.allocator.destroy(entry);
            } else {
                // No more items to evict
                break;
            }
        }
    }

    /// Push to small queue with weight update (Rust: lib.rs lines 221-222)
    pub fn small_queue_push(self: *FIFOs, key: Key, weight: u16) !void {
        const entry = try self.allocator.create(QueueEntry);
        entry.* = QueueEntry{
            .key = key,
            .weight = weight,
        };
        try self.small_queue.push(@ptrFromInt(@intFromPtr(entry)));
        _ = self.small_weight.fetchAdd(weight, .seq_cst);
    }

    /// Promote key from small to main queue (Rust: lib.rs lines 299-301)
    pub fn promote_to_main(self: *FIFOs, key: Key, weight: u16) !void {
        // Add to main queue (HEAP-ALLOCATED to prevent dangling pointers)
        const entry = try self.allocator.create(QueueEntry);
        entry.* = QueueEntry{
            .key = key,
            .weight = weight,
        };

        try self.main_queue.push(@ptrFromInt(@intFromPtr(entry)));
        _ = self.main_weight.fetchAdd(weight, .seq_cst);
    }

    /// Get small queue length
    pub fn small_len(self: *const FIFOs) usize {
        return self.small_queue.len();
    }

    /// Get main queue length
    pub fn main_len(self: *const FIFOs) usize {
        return self.main_queue.len();
    }

    /// Get combined queue length
    pub fn total_len(self: *const FIFOs) usize {
        return self.small_len() + self.main_len();
    }

    /// Clear all queues
    pub fn clear(self: *FIFOs) void {
        // Drain both queues and deallocate entries
        while (self.small_queue.pop()) |entry_ptr| {
            const entry: *QueueEntry = @ptrCast(@alignCast(entry_ptr));
            self.allocator.destroy(entry);
        }
        while (self.main_queue.pop()) |entry_ptr| {
            const entry: *QueueEntry = @ptrCast(@alignCast(entry_ptr));
            self.allocator.destroy(entry);
        }

        self.small_weight.store(0, .monotonic);
        self.main_weight.store(0, .monotonic);
    }
};

/// ============================================================================
/// TESTS
/// ============================================================================

const testing = std.testing;
const test_alloc = testing.allocator;

test "FIFOs: init and deinit" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    try testing.expect(fifos.total_weight_limit == 1000);
    try testing.expect(fifos.total_weight() == 0);
}

test "FIFOs: admit basic" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    try fifos.admit(123, 100, false);

    try testing.expect(fifos.small_weight.load(.relaxed) > 0);
    try testing.expect(fifos.total_len() > 0);
}

test "FIFOs: total weight" {
    const fifos = try FIFOs.init(test_alloc, 5000, 100);
    defer fifos.deinit();

    try fifos.admit(111, 100, false);
    try fifos.admit(222, 200, false);

    const total = fifos.total_weight();
    try testing.expect(total >= 300);
}

test "FIFOs: over capacity check" {
    const fifos = try FIFOs.init(test_alloc, 100, 100);
    defer fifos.deinit();

    try fifos.admit(999, 150, false);

    try testing.expect(fifos.is_over_capacity());
}

test "FIFOs: eviction on overflow" {
    const fifos = try FIFOs.init(test_alloc, 200, 100);
    defer fifos.deinit();

    try fifos.admit(111, 150, false);

    // This should trigger eviction
    try fifos.admit(222, 150, false);

    // Total weight should be under limit (one evicted)
    try testing.expect(fifos.total_weight() <= fifos.total_weight_limit);
}

test "FIFOs: clear all" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    try fifos.admit(100, 50, false);
    try fifos.admit(200, 50, false);

    try testing.expect(fifos.total_len() > 0);

    fifos.clear();

    try testing.expect(fifos.total_weight() == 0);
}

test "FIFOs: small and main separation" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    try fifos.admit(111, 100, false);

    const small_before = fifos.small_len();
    try testing.expect(small_before > 0);

    try fifos.promote_to_main(111, 100);

    // Weight should shift from small to main
    try testing.expect(fifos.main_weight.load(.relaxed) > 0);
}

test "FIFOs: length calculations" {
    const fifos = try FIFOs.init(test_alloc, 5000, 100);
    defer fifos.deinit();

    try testing.expect(fifos.total_len() == 0);

    try fifos.admit(111, 100, false);
    try fifos.admit(222, 100, false);

    const total = fifos.total_len();
    try testing.expect(total >= 2);
}

test "FIFOs: weight limit enforcement" {
    const fifos = try FIFOs.init(test_alloc, 300, 100);
    defer fifos.deinit();

    // Add items that exceed limit
    for (0..10) |i| {
        try fifos.admit(@intCast(i), 50, false);
    }

    // Should still be under limit (some evicted)
    try testing.expect(fifos.total_weight() <= fifos.total_weight_limit);
}

test "FIFOs: multiple admissions" {
    const fifos = try FIFOs.init(test_alloc, 2000, 100);
    defer fifos.deinit();

    for (0..5) |i| {
        try fifos.admit(@intCast(i + 100), 100, false);
    }

    try testing.expect(fifos.total_len() >= 5);
}

test "FIFOs: zero weight items" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    try fifos.admit(111, 0, false);

    // Should be admitted without weight
    try testing.expect(fifos.total_weight() == 0);
}

test "FIFOs: estimator integration" {
    const fifos = try FIFOs.init(test_alloc, 1000, 100);
    defer fifos.deinit();

    const key = 555;

    try fifos.admit(key, 100, false);

    // Estimator should have frequency for key
    const freq = fifos.estimator.get(key);
    try testing.expect(freq > 0);
}

//! Deferred reclamation types for epoch-based memory management.
//!
//! This module provides the core data structures for tracking objects
//! that need to be reclaimed once they are safe to free.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Function signature for object destructors.
/// Called when an object is safe to reclaim.
pub const DtorFn = *const fn (ptr: *anyopaque) void;

/// Simplified deferred object for epoch-bucketed storage.
/// Epoch is implicit (determined by bucket index), reducing size to 16 bytes.
pub const DeferredSimple = struct {
    /// Pointer to the object to be reclaimed.
    ptr: *anyopaque,

    /// Destructor function to call when reclaiming.
    dtor: DtorFn,

    /// Execute the destructor and reclaim the object.
    pub inline fn reclaim(self: DeferredSimple) void {
        self.dtor(self.ptr);
    }
};

// Verify DeferredSimple is 16 bytes
comptime {
    if (@sizeOf(DeferredSimple) != 16) {
        @compileError(std.fmt.comptimePrint(
            "DeferredSimple struct must be exactly 16 bytes, got {}",
            .{@sizeOf(DeferredSimple)},
        ));
    }
}

/// Epoch-bucketed garbage bag for O(1) reclamation.
///
/// Uses 3 buckets (epoch % 3) to eliminate linear scanning.
/// When an epoch becomes safe, the entire bucket is cleared at once.
pub const EpochBucketedBag = struct {
    /// Three buckets for epochs 0, 1, 2 (mod 3).
    bags: [3]std.ArrayList(DeferredSimple),

    /// Allocator for managing the bucket arrays.
    allocator: Allocator,

    /// Track the last epoch we reclaimed up to.
    /// Used to avoid redundant reclamation of already-cleared epochs.
    last_reclaimed_epoch: ?u64,

    /// Running count of items across all buckets.
    /// O(1) count access without iterating bags.
    total_count: usize,

    /// Default initial capacity per bucket.
    pub const DEFAULT_CAPACITY: usize = 512;

    /// Number of epoch buckets (3-epoch safety window).
    pub const NUM_BUCKETS: usize = 3;

    /// Initialize with pre-allocated capacity per bucket.
    pub fn init(allocator: Allocator) EpochBucketedBag {
        var bag = EpochBucketedBag{
            .bags = .{ .{}, .{}, .{} },
            .allocator = allocator,
            .last_reclaimed_epoch = null,
            .total_count = 0,
        };
        // Pre-allocate each bucket
        inline for (0..NUM_BUCKETS) |i| {
            bag.bags[i].ensureTotalCapacity(allocator, DEFAULT_CAPACITY) catch {};
        }
        return bag;
    }

    /// Release all resources.
    pub fn deinit(self: *EpochBucketedBag) void {
        inline for (0..NUM_BUCKETS) |i| {
            self.bags[i].deinit(self.allocator);
        }
    }

    /// Append an object to the appropriate epoch bucket.
    pub fn append(self: *EpochBucketedBag, deferred: DeferredSimple, epoch: u64) Allocator.Error!void {
        const bucket = @as(usize, @intCast(epoch % NUM_BUCKETS));
        try self.bags[bucket].append(self.allocator, deferred);
        self.total_count += 1;
    }

    /// Get total count across all buckets. O(1).
    pub fn count(self: *const EpochBucketedBag) usize {
        return self.total_count;
    }

    /// Check if all buckets are empty.
    pub fn isEmpty(self: *const EpochBucketedBag) bool {
        return self.count() == 0;
    }

    /// O(1) reclaim - clear the entire bucket for the given epoch.
    /// Returns the number of objects reclaimed.
    pub fn reclaimBucket(self: *EpochBucketedBag, epoch: u64) usize {
        const bucket = @as(usize, @intCast(epoch % NUM_BUCKETS));
        const items = self.bags[bucket].items;
        const reclaimed = items.len;

        // Call all destructors
        for (items) |item| {
            item.reclaim();
        }

        // Clear bucket, retaining capacity
        self.bags[bucket].clearRetainingCapacity();
        self.total_count -= reclaimed;
        return reclaimed;
    }

    /// Reclaim all epochs from (last_reclaimed + 1) up to safe_epoch.
    /// Tracks progress to avoid redundant work on subsequent calls.
    /// Returns the number of objects reclaimed.
    ///
    /// Bucket-limited: O(NUM_BUCKETS) constant iterations instead of O(safe_epoch - start).
    /// Since there are only 3 buckets, iterating more than 3 times is wasteful -
    /// subsequent epochs map to already-cleared buckets.
    pub fn reclaimUpTo(self: *EpochBucketedBag, safe_epoch: u64) usize {
        const start = if (self.last_reclaimed_epoch) |last| last + 1 else 0;
        if (start > safe_epoch) return 0;

        var total: usize = 0;
        var e = start;
        var iterations: usize = 0;
        // Limit to NUM_BUCKETS iterations - beyond that, buckets repeat
        while (e <= safe_epoch and iterations < NUM_BUCKETS) : ({
            e += 1;
            iterations += 1;
        }) {
            total += self.reclaimBucket(e);
        }
        self.last_reclaimed_epoch = safe_epoch;
        return total;
    }

    /// Reclaim all objects in all buckets.
    /// Use only during shutdown.
    pub fn reclaimAll(self: *EpochBucketedBag) usize {
        var total: usize = 0;
        inline for (0..NUM_BUCKETS) |i| {
            for (self.bags[i].items) |item| {
                item.reclaim();
            }
            total += self.bags[i].items.len;
            self.bags[i].clearRetainingCapacity();
        }
        self.total_count = 0;
        return total;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DeferredSimple size is exactly 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DeferredSimple));
}

test "EpochBucketedBag init and deinit" {
    var bag = EpochBucketedBag.init(std.testing.allocator);
    defer bag.deinit();

    try std.testing.expect(bag.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), bag.count());
}

test "EpochBucketedBag append and count" {
    var bag = EpochBucketedBag.init(std.testing.allocator);
    defer bag.deinit();

    var call_count: u32 = 0;
    const counting_dtor = struct {
        fn count(ptr: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ptr));
            counter.* += 1;
        }
    }.count;

    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 0);
    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 1);
    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 2);

    try std.testing.expectEqual(@as(usize, 3), bag.count());
    try std.testing.expect(!bag.isEmpty());
}

test "EpochBucketedBag reclaimUpTo" {
    var bag = EpochBucketedBag.init(std.testing.allocator);
    defer bag.deinit();

    var call_count: u32 = 0;
    const counting_dtor = struct {
        fn count(ptr: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ptr));
            counter.* += 1;
        }
    }.count;

    // Add items at epochs 0, 1, 2
    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 0);
    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 1);
    try bag.append(.{ .ptr = @ptrCast(&call_count), .dtor = counting_dtor }, 2);

    // Reclaim up to epoch 1
    const reclaimed = bag.reclaimUpTo(1);
    try std.testing.expectEqual(@as(usize, 2), reclaimed);
    try std.testing.expectEqual(@as(u32, 2), call_count);
    try std.testing.expectEqual(@as(usize, 1), bag.count());

    // Reclaim remaining
    const reclaimed2 = bag.reclaimUpTo(2);
    try std.testing.expectEqual(@as(usize, 1), reclaimed2);
    try std.testing.expectEqual(@as(u32, 3), call_count);
    try std.testing.expect(bag.isEmpty());
}

// Thread ID Management - Port of seize's thread_id.rs
// Reference: refs/seize_rust/src/raw/tls/thread_id.rs

const std = @import("std");

/// Maximum number of bucket levels (supports thread IDs up to 2^BUCKETS)
/// Set to 32 to support thread IDs up to 4 billion (covers all realistic OS thread IDs)
pub const BUCKETS: usize = 32;

/// Thread identifier with bucket/entry indexing
pub const Thread = struct {
    id: usize,
    bucket: usize,  // Which bucket level (0..BUCKETS-1)
    entry: usize,   // Index within bucket

    /// Get current thread ID (uses std.Thread.getCurrentId())
    pub fn current() Thread {
        const tid = std.Thread.getCurrentId();
        return fromId(tid);
    }

    /// Create a new unique thread ID (for OwnedGuard)
    pub fn create() Thread {
        const id = thread_id_manager.alloc();
        return fromId(id);
    }

    /// Free a thread ID back to the pool
    pub fn free(id: usize) void {
        thread_id_manager.free(id);
    }

    /// Convert thread ID to Thread struct
    pub fn fromId(id: usize) Thread {
        // Formula from seize:
        //   If id == 0: bucket=0, entry=0
        //   Else: bucket = log2(id+1), entry = id - (2^bucket - 1)

        if (id == 0) {
            return .{ .id = 0, .bucket = 0, .entry = 0 };
        }

        // Calculate bucket level (log2 of id+1)
        const bucket = std.math.log2_int(usize, id + 1);

        // Calculate entry within bucket
        const bucket_start = (@as(usize, 1) << @intCast(bucket)) - 1;
        const entry = id - bucket_start;

        return .{
            .id = id,
            .bucket = bucket,
            .entry = entry,
        };
    }

    /// Get capacity of a bucket level
    pub fn bucket_capacity(bucket: usize) usize {
        if (bucket == 0) return 1;
        return @as(usize, 1) << @intCast(bucket);  // 2^bucket
    }
};

/// Thread ID Manager for allocating and reusing thread IDs
const ThreadIdManager = struct {
    mutex: std.Thread.Mutex = .{},
    free_from: usize = 0,  // Next ID to allocate if free list is empty
    free_list: std.ArrayListUnmanaged(usize) = .{},  // Reusable IDs from freed threads
    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Allocate a new thread ID, preferring to reuse from free list
    fn alloc(self: *ThreadIdManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse from free list (prefer smallest IDs)
        if (self.free_list.items.len > 0) {
            const id = self.free_list.items[self.free_list.items.len - 1];
            self.free_list.items.len -= 1;  // Manual pop
            return id;
        }

        // Allocate new ID
        const id = self.free_from;
        self.free_from += 1;
        return id;
    }

    /// Free a thread ID for reuse
    fn free(self: *ThreadIdManager, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Add to free list for reuse
        // Note: Rust uses a min-heap to always reuse smallest IDs first
        // For simplicity, we just append (could sort later if needed)
        self.free_list.append(self.allocator, id) catch {
            // If append fails, just lose the ID (rare case)
            return;
        };
    }
};

/// Global thread ID manager
var thread_id_manager: ThreadIdManager = .{};

// ============================================================================
// TESTS
// ============================================================================

test "thread id calculation" {
    // Test cases from seize
    {
        const t = Thread.fromId(0);
        try std.testing.expectEqual(@as(usize, 0), t.bucket);
        try std.testing.expectEqual(@as(usize, 0), t.entry);
    }
    {
        const t = Thread.fromId(1);
        try std.testing.expectEqual(@as(usize, 1), t.bucket);
        try std.testing.expectEqual(@as(usize, 0), t.entry);
    }
    {
        const t = Thread.fromId(2);
        try std.testing.expectEqual(@as(usize, 1), t.bucket);
        try std.testing.expectEqual(@as(usize, 1), t.entry);
    }
    {
        const t = Thread.fromId(5);
        try std.testing.expectEqual(@as(usize, 2), t.bucket);
        try std.testing.expectEqual(@as(usize, 2), t.entry);
    }
}

test "bucket capacity" {
    try std.testing.expectEqual(@as(usize, 1), Thread.bucket_capacity(0));
    try std.testing.expectEqual(@as(usize, 2), Thread.bucket_capacity(1));
    try std.testing.expectEqual(@as(usize, 4), Thread.bucket_capacity(2));
    try std.testing.expectEqual(@as(usize, 8), Thread.bucket_capacity(3));
}

test "thread create/free" {
    const t1 = Thread.create();
    const t2 = Thread.create();
    try std.testing.expect(t2.id > t1.id);

    // Free and reallocate
    Thread.free(t1.id);
    const t3 = Thread.create();
    try std.testing.expectEqual(t1.id, t3.id); // Should reuse t1's ID
}

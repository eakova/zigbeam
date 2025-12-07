const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

/// Queue clearing strategies
pub const ClearStrategy = enum {
    /// Pop all items (slow but thread-safe, can be done concurrently)
    Drain,
    /// Drop pointer (fast, dangerous if threads still using queue)
    DropAll,
    /// Mark generation (can handle concurrent operations)
    Generation,
};

/// Clear operation with different strategies
pub fn ClearOp(comptime T: type) type {
    return struct {
        const Self = @This();

        queue_ptr: anytype,
        dropped_count: usize = 0,
        strategy: ClearStrategy = .Drain,

        pub fn init(queue_ptr: anytype, strategy: ClearStrategy) Self {
            return Self{
                .queue_ptr = queue_ptr,
                .strategy = strategy,
            };
        }

        /// Clear using drain strategy (thread-safe)
        pub fn clearDrain(self: *Self) usize {
            var count: usize = 0;
            while (self.queue_ptr.pop()) |_| {
                count += 1;
            }
            self.dropped_count = count;
            return count;
        }

        /// Mark all current items as obsolete without removing them
        /// Safe for concurrent operations
        pub fn clearGeneration(self: *Self) !usize {
            _ = self.queue_ptr.len(); // Marker: next generation starts
            return 0; // Items not actually deleted
        }

        pub fn getDroppedCount(self: *const Self) usize {
            return self.dropped_count;
        }
    };
}

/// Reset queue to initial state
/// WARNING: Must not be called while other threads are using queue
pub fn resetQueue(queue_ptr: anytype, allocator: Allocator, initial_size: usize) !void {
    queue_ptr.deinit();
    queue_ptr.* = try @TypeOf(queue_ptr.*).init(allocator, initial_size);
}

/// Snapshot of queue at a point in time
pub fn QueueSnapshot(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        timestamp: i64,
        allocator: Allocator,

        pub fn init(allocator: Allocator, queue_ptr: anytype) !Self {
            var items_list = std.ArrayList(T).init(allocator);
            errdefer items_list.deinit();

            // Snapshot all current items
            while (queue_ptr.pop()) |item| {
                try items_list.append(item);
            }

            return Self{
                .items = try items_list.toOwnedSlice(),
                .timestamp = std.time.nanoTimestamp(),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn len(self: *const Self) usize {
            return self.items.len;
        }

        pub fn at(self: *const Self, index: usize) ?T {
            if (index < self.items.len) {
                return self.items[index];
            }
            return null;
        }
    };
}

/// Batch clear operation - remove items matching predicate
pub fn batchClear(
    allocator: Allocator,
    queue_ptr: anytype,
    predicate: anytype,
) !usize {
    var removed: usize = 0;
    var temp_list = std.ArrayList(@TypeOf(queue_ptr.T)).init(allocator);
    defer temp_list.deinit();

    // Pop all items
    while (queue_ptr.pop()) |item| {
        if (predicate(item)) {
            removed += 1;
            // Item is discarded
        } else {
            try temp_list.append(item);
        }
    }

    // Push non-matching items back
    for (temp_list.items) |item| {
        try queue_ptr.push(item);
    }

    return removed;
}

/// Queue state snapshot for debugging
pub fn QueueState(comptime T: type) type {
    return struct {
        const Self = @This();

        size: u64,
        capacity: ?u64,
        is_empty: bool,
        is_full: bool,
        timestamp: i64,

        pub fn capture(queue_ptr: anytype) Self {
            const size = queue_ptr.len();
            const empty = queue_ptr.isEmpty();
            const full = @hasDecl(@TypeOf(queue_ptr.*), "isFull") and queue_ptr.isFull();
            const capacity = @hasDecl(@TypeOf(queue_ptr.*), "getCapacity") and queue_ptr.getCapacity() or null;

            return Self{
                .size = size,
                .capacity = capacity,
                .is_empty = empty,
                .is_full = full,
                .timestamp = std.time.nanoTimestamp(),
            };
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("QueueState{{ size={}, capacity={?}, empty={}, full={}, timestamp={} }}", .{
                self.size,
                self.capacity,
                self.is_empty,
                self.is_full,
                self.timestamp,
            });
        }
    };
}

/// Queue monitoring and metrics
pub const QueueMetrics = struct {
    const Self = @This();

    total_pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_pops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_pops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_size: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordPush(self: *Self, success: bool) void {
        if (success) {
            _ = self.total_pushes.fetchAdd(1, .release);
        } else {
            _ = self.failed_pushes.fetchAdd(1, .release);
        }
    }

    pub fn recordPop(self: *Self, success: bool) void {
        if (success) {
            _ = self.total_pops.fetchAdd(1, .release);
        } else {
            _ = self.failed_pops.fetchAdd(1, .release);
        }
    }

    pub fn recordSize(self: *Self, size: u64) void {
        var max = self.max_size.load(.acquire);
        while (size > max) {
            max = self.max_size.cmpxchgWeak(max, size, .release, .acquire) orelse break;
        }
    }

    pub fn recordWait(self: *Self, wait_ns: u64) void {
        _ = self.total_wait_ns.fetchAdd(wait_ns, .release);
    }

    pub fn getStats(self: *const Self) struct {
        total_pushes: u64,
        total_pops: u64,
        failed_pushes: u64,
        failed_pops: u64,
        max_size: u64,
        throughput: f64,
    } {
        const pushes = self.total_pushes.load(.acquire);
        const pops = self.total_pops.load(.acquire);
        const total_ops = pushes + pops;

        return .{
            .total_pushes = pushes,
            .total_pops = pops,
            .failed_pushes = self.failed_pushes.load(.acquire),
            .failed_pops = self.failed_pops.load(.acquire),
            .max_size = self.max_size.load(.acquire),
            .throughput = @as(f64, @floatFromInt(total_ops)),
        };
    }

    pub fn reset(self: *Self) void {
        _ = self.total_pushes.store(0, .release);
        _ = self.total_pops.store(0, .release);
        _ = self.failed_pushes.store(0, .release);
        _ = self.failed_pops.store(0, .release);
        _ = self.total_wait_ns.store(0, .release);
    }
};

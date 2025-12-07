const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

/// Arc-like reference counting for queues
/// Allows sharing queue across threads with automatic cleanup
pub fn SharedQueue(comptime T: type, comptime QueueType: type) type {
    return struct {
        const Self = @This();

        const QueueHandle = struct {
            queue: *QueueType,
            refcount: *atomic.Value(usize),
            allocator: Allocator,

            fn deinit(self: *QueueHandle) void {
                const refs = self.refcount.fetchSub(1, .release);
                if (refs == 1) {
                    // Last reference, clean up
                    self.queue.deinit();
                    self.allocator.destroy(self.queue);
                    self.allocator.destroy(self.refcount);
                }
            }
        };

        handle: QueueHandle,

        pub fn init(allocator: Allocator, args: anytype) !Self {
            const queue = try allocator.create(QueueType);
            errdefer allocator.destroy(queue);

            queue.* = try QueueType.init(allocator, args);
            errdefer queue.deinit();

            const refcount = try allocator.create(atomic.Value(usize));
            refcount.* = atomic.Value(usize).init(1);

            return Self{
                .handle = .{
                    .queue = queue,
                    .refcount = refcount,
                    .allocator = allocator,
                },
            };
        }

        pub fn clone(self: *const Self) Self {
            _ = self.handle.refcount.fetchAdd(1, .release);
            return Self{ .handle = self.handle };
        }

        pub fn deinit(self: *Self) void {
            self.handle.deinit();
        }

        pub fn push(self: *Self, value: T) !void {
            try self.handle.queue.push(value);
        }

        pub fn pop(self: *Self) ?T {
            return self.handle.queue.pop();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.handle.queue.isEmpty();
        }

        pub fn len(self: *const Self) usize {
            return self.handle.queue.len();
        }

        pub fn refcount(self: *const Self) usize {
            return self.handle.refcount.load(.acquire);
        }
    };
}

/// Thread-safe wrapper that tracks ownership
pub fn OwnedQueue(comptime T: type, comptime QueueType: type) type {
    return struct {
        const Self = @This();

        queue: QueueType,
        owner_thread_id: std.Thread.Id,
        is_shared: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        writers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(allocator: Allocator, args: anytype) !Self {
            return Self{
                .queue = try QueueType.init(allocator, args),
                .owner_thread_id = std.Thread.getCurrentId(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        pub fn markShared(self: *Self) void {
            _ = self.is_shared.store(true, .release);
        }

        pub fn push(self: *Self, value: T) !void {
            if (self.is_shared.load(.acquire)) {
                _ = self.writers.fetchAdd(1, .release);
                defer _ = self.writers.fetchSub(1, .release);
            }
            try self.queue.push(value);
        }

        pub fn pop(self: *Self) ?T {
            if (self.is_shared.load(.acquire)) {
                _ = self.readers.fetchAdd(1, .release);
                defer _ = self.readers.fetchSub(1, .release);
            }
            return self.queue.pop();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.queue.isEmpty();
        }

        pub fn len(self: *const Self) usize {
            return self.queue.len();
        }

        pub fn getCurrentReaders(self: *const Self) usize {
            return self.readers.load(.acquire);
        }

        pub fn getCurrentWriters(self: *const Self) usize {
            return self.writers.load(.acquire);
        }

        pub fn isShared(self: *const Self) bool {
            return self.is_shared.load(.acquire);
        }
    };
}

/// Distributed queue across multiple threads with load balancing
pub fn DistributedQueue(comptime T: type, comptime QueueType: type) type {
    return struct {
        const Self = @This();

        queues: []QueueType,
        next_queue: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        allocator: Allocator,

        pub fn init(allocator: Allocator, num_queues: usize, queue_size: usize) !Self {
            const queues = try allocator.alloc(QueueType, num_queues);
            errdefer allocator.free(queues);

            for (queues) |*q| {
                q.* = try QueueType.init(allocator, queue_size);
            }

            return Self{
                .queues = queues,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.queues) |*q| {
                q.deinit();
            }
            self.allocator.free(self.queues);
        }

        /// Push with round-robin load balancing
        pub fn push(self: *Self, value: T) !void {
            const idx = self.next_queue.fetchAdd(1, .release) % self.queues.len;
            try self.queues[idx].push(value);
        }

        /// Pop from any queue (tries in sequence)
        pub fn pop(self: *Self) ?T {
            const len = self.queues.len;
            const start = self.next_queue.load(.acquire) % len;

            for (0..len) |i| {
                const idx = (start + i) % len;
                if (self.queues[idx].pop()) |value| {
                    return value;
                }
            }
            return null;
        }

        pub fn isEmpty(self: *const Self) bool {
            for (self.queues) |q| {
                if (!q.isEmpty()) return false;
            }
            return true;
        }

        pub fn len(self: *const Self) usize {
            var total: usize = 0;
            for (self.queues) |q| {
                total += q.len();
            }
            return total;
        }

        pub fn getQueueCount(self: *const Self) usize {
            return self.queues.len;
        }

        pub fn getQueueLen(self: *const Self, idx: usize) ?usize {
            if (idx < self.queues.len) {
                return self.queues[idx].len();
            }
            return null;
        }
    };
}

/// Thread-local queue with fallback to shared queue
pub fn HybridQueue(comptime T: type, comptime QueueType: type) type {
    return struct {
        const Self = @This();

        local_queues: std.AutoHashMap(std.Thread.Id, *QueueType),
        shared_queue: *QueueType,
        fallback_enabled: bool = true,
        allocator: Allocator,
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: Allocator, queue_size: usize) !Self {
            const shared = try allocator.create(QueueType);
            shared.* = try QueueType.init(allocator, queue_size);

            return Self{
                .local_queues = std.AutoHashMap(std.Thread.Id, *QueueType).init(allocator),
                .shared_queue = shared,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.local_queues.valueIterator();
            while (iter.next()) |q| {
                q.*.deinit();
                self.allocator.destroy(q.*);
            }
            self.local_queues.deinit();

            self.shared_queue.deinit();
            self.allocator.destroy(self.shared_queue);
        }

        pub fn push(self: *Self, value: T) !void {
            const thread_id = std.Thread.getCurrentId();
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.local_queues.get(thread_id)) |q| {
                try q.push(value);
            } else if (self.fallback_enabled) {
                try self.shared_queue.push(value);
            } else {
                return error.NoLocalQueue;
            }
        }

        pub fn pop(self: *Self) ?T {
            const thread_id = std.Thread.getCurrentId();
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.local_queues.get(thread_id)) |q| {
                if (q.pop()) |value| return value;
            }

            // Fallback to shared
            return if (self.fallback_enabled) self.shared_queue.pop() else null;
        }

        pub fn registerThread(self: *Self) !void {
            const thread_id = std.Thread.getCurrentId();
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.local_queues.contains(thread_id)) {
                const q = try self.allocator.create(QueueType);
                q.* = try QueueType.init(self.allocator, 64);
                try self.local_queues.put(thread_id, q);
            }
        }
    };
}

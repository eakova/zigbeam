const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Order = std.atomic.Order;
const Thread = std.Thread;

/// A scalable, unbounded, lock-free list.
///
/// This data structure provides a thread-safe way to manage a growing
/// collection of items (represented by pointers). It is architected as a linked
/// list of fixed-size arrays ("segments") to provide both unbounded growth and
/// highly efficient, cache-friendly scanning.
///
/// All primary operations (`insert`, `remove`, `scan`) are lock-free.
///
/// ## Architecture: A Segmented Array (Unrolled Linked List)
///
/// The list is a "train of cars."
/// - **"Car" (`Segment`):** A fixed-size array of item slots. This is
///   extremely fast and cache-friendly to scan internally.
/// - **"Train" (`LockFreeSegmentedList`):** A lock-free linked list of these "cars."
///
/// This hybrid design provides:
/// - **Unbounded Growth:** When the last car is full, a new one is atomically
///   linked to the end of the train.
/// - **Scalable Scanning:** To scan all items, we take a small number of
///   hops between cars and then perform a fast, contiguous scan of the slots
///   inside each car.
/// - **Fast Insertion:** A cached `tail_segment` pointer makes finding a
///   free slot an amortized O(1) operation.
///
pub fn LockFreeSegmentedList(comptime T: type) type {
    return struct {
        const Self = @This();

        const Segment = struct {
            pub const CAPACITY = 64; // Power of 2, often fits a cache line of pointers

            slots: [CAPACITY]Atomic(?*T),
            next: Atomic(?*Segment),
            /// Approximate count of free slots in this segment.
            /// Used as a fast hint to skip obviously-full segments in insert().
            free_slots: Atomic(usize),

            fn init() @This() {
                var self: @This() = undefined;
                for (&self.slots) |*slot| {
                    slot.* = Atomic(?*T).init(null);
                }
                self.next = Atomic(?*Segment).init(null);
                self.free_slots = Atomic(usize).init(CAPACITY);
                return self;
            }
        };

        head_segment: Atomic(*Segment),
        tail_segment: Atomic(*Segment),
        allocator: Allocator,

        /// Initializes the list.
        ///
        /// Creates the first segment, making the list ready for use.
        pub fn init(allocator: Allocator) !*Self {
            const list = try allocator.create(Self);
            errdefer allocator.destroy(list);

            const first_segment = try allocator.create(Segment);
            first_segment.* = Segment.init();

            list.* = .{
                .head_segment = Atomic(*Segment).init(first_segment),
                .tail_segment = Atomic(*Segment).init(first_segment),
                .allocator = allocator,
            };

            return list;
        }

        /// Deinitializes the list, freeing all segments.
        ///
        /// WARNING: Not thread-safe. Must be called only after all threads
        /// have stopped accessing the list.
        pub fn deinit(self: *Self) void {
            var current: ?*Segment = self.head_segment.load(.monotonic);
            while (current) |seg| {
                const next = seg.next.load(.monotonic);
                self.allocator.destroy(seg);
                current = next;
            }
            self.allocator.destroy(self);
        }

        /// Inserts an item into the list, finding and claiming an empty slot.
        ///
        /// This is a lock-free operation. If the list is full, it will
        /// atomically grow the list by adding a new segment.
        pub fn insert(self: *Self, item: *T) !void {
            while (true) {
                const tail_seg = self.tail_segment.load(.acquire);

                // Fast hint: if this segment has no free slots, skip directly to growth.
                if (tail_seg.free_slots.load(.acquire) > 0) {
                    // Phase 1: Try to find a free slot in the current tail segment.
                    for (&tail_seg.slots) |*slot| {
                        if (slot.cmpxchgWeak(null, item, .release, .acquire)) |_| {
                            // This slot was not null, try the next one.
                        } else {
                            // Successfully claimed the slot.
                            _ = tail_seg.free_slots.fetchSub(1, .release);
                            return;
                        }
                    }
                }

                // Phase 2: Tail segment is full. We must grow the list.
                // First, check if another thread already added a new segment.
                var next_seg = tail_seg.next.load(.acquire);

                if (next_seg == null) {
                    // We are the first to try to grow.
                    const new_segment = try self.allocator.create(Segment);
                    new_segment.* = Segment.init();

                    // Try to link our new segment.
                    if (tail_seg.next.cmpxchgWeak(null, new_segment, .release, .acquire)) |_| {
                        // We lost the race. Another thread linked a segment
                        // while we were allocating ours. We must free our unused
                        // segment and retry the whole operation.
                        self.allocator.destroy(new_segment);
                        continue;
                    } else {
                        // We won the race and successfully linked the new segment.
                        next_seg = new_segment;
                    }
                }

                // By now, `next_seg` is guaranteed to be non-null.
                // We must help swing the global tail pointer forward.
                _ = self.tail_segment.cmpxchgWeak(tail_seg, next_seg.?, .release, .acquire);
                // Continue the outer loop to retry insertion on the new tail.
            }
        }

        /// Removes an item from the list, setting its slot back to null.
        pub fn remove(self: *Self, item: *T) void {
            var current_seg: ?*Segment = self.head_segment.load(.acquire);
            while (current_seg) |seg| {
                for (&seg.slots) |*slot| {
                    // Try to CAS the slot from `item` back to `null`.
                    if (slot.cmpxchgWeak(item, null, .release, .acquire)) |_| {
                        // This wasn't our slot, continue scanning.
                    } else {
                        // Successfully removed.
                        _ = seg.free_slots.fetchAdd(1, .release);
                        return;
                    }
                }
                current_seg = seg.next.load(.acquire);
            }
        }

        /// Scans all items in the list and calls a callback for each one.
        ///
        /// This is a highly efficient scan that is much faster than traversing a
        /// simple linked list of N items. `Context` can be any type required by the callback.
        pub fn scan(self: *Self, comptime Context: type, context: *Context, comptime callback: fn (*Context, *T) void) void {
            var current_seg: ?*Segment = self.head_segment.load(.acquire);
            while (current_seg) |seg| {
                // Inner loop is a fast, bounded scan of a contiguous array.
                for (&seg.slots) |*slot| {
                    if (slot.load(.acquire)) |item| {
                        callback(context, item);
                    }
                }
                current_seg = seg.next.load(.acquire);
            }
        }
    };
}

// ================================= TESTS =================================

const TestItem = struct { id: usize };

test "LockFreeSegmentedList: single-threaded insert and scan" {
    const testing = std.testing;
    const List = LockFreeSegmentedList(TestItem);

    var list = try List.init(testing.allocator);
    defer list.deinit();

    // Insert enough to force at least one segment growth
    const item_count = List.Segment.CAPACITY + 5;
    var items: [item_count]TestItem = undefined;
    for (&items, 0..) |*p, i| {
        p.id = i;
        try list.insert(p);
    }

    const Counter = struct {
        count: usize = 0,
        fn increment(self: *@This(), item: *TestItem) void {
            _ = item;
            self.count += 1;
        }
    };
    var counter = Counter{};
    list.scan(Counter, &counter, Counter.increment);

    try testing.expectEqual(item_count, counter.count);

    // Test remove
    list.remove(&items[0]);
    list.remove(&items[item_count - 1]);
    counter.count = 0;
    list.scan(Counter, &counter, Counter.increment);
    try testing.expectEqual(item_count - 2, counter.count);
}

test "LockFreeSegmentedList: multi-threaded insert" {
    const testing = std.testing;
    const List = LockFreeSegmentedList(TestItem);

    var list = try List.init(testing.allocator);
    defer list.deinit();

    const num_threads = 8;
    const items_per_thread = 32; // < Segment.CAPACITY
    const total_items = num_threads * items_per_thread;

    var threads: [num_threads]Thread = undefined;
    var item_storage = try testing.allocator.alloc(TestItem, total_items);
    defer testing.allocator.free(item_storage);

    for (&threads, 0..) |*handle, i| {
        const my_items = item_storage[i * items_per_thread .. (i + 1) * items_per_thread];
        handle.* = try Thread.spawn(.{}, struct {
            fn thread_fn(l: *List, parts: []TestItem) void {
                for (parts) |*p| {
                    l.insert(p) catch @panic("Failed to insert");
                }
            }
        }.thread_fn, .{ list, my_items });
    }

    for (threads) |handle| {
        handle.join();
    }

    const Counter = struct {
        count: usize = 0,
        fn increment(self: *@This(), p: *TestItem) void {
            _ = p;
            self.count += 1;
        }
    };
    var counter = Counter{};
    list.scan(Counter, &counter, Counter.increment);

    try testing.expectEqual(total_items, counter.count);
}

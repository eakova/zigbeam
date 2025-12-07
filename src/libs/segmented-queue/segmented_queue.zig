const std = @import("std");
const Allocator = std.mem.Allocator;
const DVyukovMPMCQueue = @import("dvyukov-mpmc").DVyukovMPMCQueue;
const ebr = @import("ebr");
const Backoff = @import("backoff").Backoff;

pub fn SegmentedQueue(comptime T: type, comptime segment_capacity: usize) type {
    const InnerQueue = DVyukovMPMCQueue(T, segment_capacity);

    return struct {
        const Self = @This();

        /// Re-export EBR types for convenience
        pub const Collector = ebr.Collector;
        pub const Guard = ebr.Guard;
        pub const ThreadHandle = ebr.ThreadHandle;

        const Segment = struct {
            queue: *InnerQueue,
            allocator: Allocator,
            next: std.atomic.Value(?*Segment),
        };

        head_segment: std.atomic.Value(*Segment) align(std.atomic.cache_line),
        tail_segment: std.atomic.Value(*Segment) align(std.atomic.cache_line),
        allocator: Allocator,
        collector: *Collector,

        /// Initialize a new SegmentedQueue with the given allocator and EBR collector.
        ///
        /// The collector must outlive the queue. Threads using this queue must
        /// register with the collector via `collector.registerThread()` before
        /// calling enqueue/dequeue operations.
        pub fn init(allocator: Allocator, collector: *Collector) !Self {
            const first_seg = try allocator.create(Segment);
            errdefer allocator.destroy(first_seg);

            const queue = try allocator.create(InnerQueue);
            errdefer allocator.destroy(queue);
            queue.* = try InnerQueue.init(allocator);

            first_seg.queue = queue;
            first_seg.allocator = allocator;
            first_seg.next = std.atomic.Value(?*Segment).init(null);

            return .{
                .head_segment = std.atomic.Value(*Segment).init(first_seg),
                .tail_segment = std.atomic.Value(*Segment).init(first_seg),
                .allocator = allocator,
                .collector = collector,
            };
        }

        pub fn deinit(self: *Self) void {
            var seg: ?*Segment = self.head_segment.load(.acquire);
            while (seg) |current| {
                const next = current.next.load(.acquire);
                current.queue.deinit();
                current.allocator.destroy(current.queue);
                current.allocator.destroy(current);
                seg = next;
            }
        }

        /// Core enqueue logic extracted to eliminate duplication.
        /// Marked inline to ensure zero overhead - the function call is eliminated
        /// at compile time, producing the same machine code as manual duplication.
        inline fn tryEnqueueItem(self: *Self, item: T) !void {
            while (true) {
                const tail_seg = self.tail_segment.load(.acquire);
                tail_seg.queue.enqueue(item) catch |err| switch (err) {
                    error.QueueFull => {
                        const next = tail_seg.next.load(.acquire);
                        if (next) |n| {
                            _ = self.tail_segment.cmpxchgWeak(
                                tail_seg,
                                n,
                                .release,
                                .acquire,
                            );
                            continue;
                        }

                        // Allocate segment and queue. Queue MUST be initialized before CAS
                        // to avoid race where another thread sees the segment before queue is ready.
                        const new_seg = try self.allocator.create(Segment);
                        errdefer self.allocator.destroy(new_seg);

                        const queue = try self.allocator.create(InnerQueue);
                        errdefer self.allocator.destroy(queue);
                        queue.* = try InnerQueue.init(self.allocator);
                        errdefer queue.deinit();

                        new_seg.queue = queue;
                        new_seg.allocator = self.allocator;
                        new_seg.next = std.atomic.Value(?*Segment).init(null);

                        // Try to install the new segment via CAS
                        if (tail_seg.next.cmpxchgStrong(
                            null,
                            new_seg,
                            .release,
                            .acquire,
                        ) != null) {
                            // CAS failed - another thread won. Clean up (errdefer handles this).
                            queue.deinit();
                            self.allocator.destroy(queue);
                            self.allocator.destroy(new_seg);
                            continue;
                        }

                        _ = self.tail_segment.cmpxchgWeak(
                            tail_seg,
                            new_seg,
                            .release,
                            .acquire,
                        );

                        continue;
                    },
                    else => |e| return e,
                };

                return;
            }
        }

        /// Primary enqueue API. Requires an active EBR guard in the current thread.
        /// The caller must create an EBR guard before calling this method.
        pub fn enqueue(self: *Self, item: T) !void {
            return self.tryEnqueueItem(item);
        }

        /// Convenience method that creates and manages an EBR guard automatically.
        /// For better performance with multiple operations, use enqueue() with
        /// external guard management or enqueueMany() for batches.
        pub fn enqueueWithAutoGuard(self: *Self, item: T) !void {
            const guard = self.collector.pin();
            defer guard.unpin();
            return self.enqueue(item);
        }

        /// Primary dequeue API. Requires an active EBR guard.
        /// The caller must create an EBR guard before calling this method.
        /// Uses adaptive exponential backoff (Crossbeam-style) for intelligent retry.
        pub fn dequeue(self: *Self) ?T {
            while (true) {
                const head_seg = self.head_segment.load(.acquire);

                // Try to dequeue from current segment
                if (head_seg.queue.dequeue()) |item| {
                    return item;
                }

                // Segment appears empty. Check for next segment BEFORE spinning.
                // If next exists, advance immediately rather than wasting cycles on empty segment.
                const next = head_seg.next.load(.acquire);
                if (next) |n| {
                    // Next segment exists, try to advance to it immediately
                    if (self.head_segment.cmpxchgWeak(
                        head_seg,
                        n,
                        .release,
                        .acquire,
                    ) == null) {
                        // Successfully advanced, retire old segment via EBR
                        self.collector.deferReclaim(@ptrCast(head_seg), destroySegment);
                    }
                    // Loop continues to try dequeue from new head segment
                    continue;
                }

                // No next segment exists. Segment might be contended (producers still enqueueing).
                // Use short adaptive backoff with reduced spin limit (4 instead of default 6).
                // This gives producers a chance to finish without excessive spinning.
                var backoff = Backoff.init(.{ .spin_limit = 4, .yield_limit = 6 });
                while (!backoff.isCompleted()) {
                    if (head_seg.queue.dequeue()) |item| {
                        return item;
                    }
                    backoff.snooze();
                }

                // After backoff, recheck for next segment before giving up.
                // A producer might have created and linked a new segment during our backoff.
                // This prevents a race where we return null while items exist in a newly-linked segment.
                const next_after_backoff = head_seg.next.load(.acquire);
                if (next_after_backoff == null) {
                    // Still no next segment after backoff. Queue is truly empty.
                    return null;
                }
                // Next segment appeared during backoff. Loop back to advance and retry.
                continue;
            }
        }

        /// Convenience method that creates and manages an EBR guard automatically.
        /// For better performance with multiple operations, use dequeue() with
        /// external guard management or dequeueMany() for batches.
        pub fn dequeueWithAutoGuard(self: *Self) ?T {
            const guard = self.collector.pin();
            defer guard.unpin();
            return self.dequeue();
        }

        /// Batch enqueue operation. Enqueues all items from the slice.
        /// Uses a single EBR guard for all operations, amortizing guard overhead.
        /// More efficient than calling enqueue() repeatedly for multiple items.
        pub fn enqueueMany(self: *Self, items: []const T) !void {
            const guard = self.collector.pin();
            defer guard.unpin();

            for (items) |item| {
                try self.tryEnqueueItem(item);
            }
        }

        /// Batch dequeue operation. Attempts to fill the provided buffer.
        /// Uses a single EBR guard for all operations, amortizing guard overhead.
        /// More efficient than calling dequeue() repeatedly for multiple items.
        /// Returns the number of items actually dequeued (may be less than buffer size if queue empties).
        pub fn dequeueMany(self: *Self, buffer: []T) usize {
            const guard = self.collector.pin();
            defer guard.unpin();

            var count: usize = 0;
            for (buffer) |*slot| {
                item_loop: while (true) {
                    const head_seg = self.head_segment.load(.acquire);

                    // Try to dequeue from current segment
                    if (head_seg.queue.dequeue()) |item| {
                        slot.* = item;
                        count += 1;
                        break :item_loop;
                    }

                    // Segment appears empty. Check for next segment BEFORE spinning.
                    // If next exists, advance immediately rather than wasting cycles.
                    const next = head_seg.next.load(.acquire);
                    if (next) |n| {
                        // Next segment exists, try to advance to it immediately
                        if (self.head_segment.cmpxchgWeak(
                            head_seg,
                            n,
                            .release,
                            .acquire,
                        ) == null) {
                            // Successfully advanced, retire old segment via EBR
                            self.collector.deferReclaim(@ptrCast(head_seg), destroySegment);
                        }
                        // Loop continues to try dequeue from new head segment
                        continue;
                    }

                    // No next segment exists. Segment might be contended (producers still enqueueing).
                    // Use short adaptive backoff with reduced spin limit.
                    var backoff = Backoff.init(.{ .spin_limit = 4, .yield_limit = 6 });
                    while (!backoff.isCompleted()) {
                        if (head_seg.queue.dequeue()) |item| {
                            slot.* = item;
                            count += 1;
                            break :item_loop;
                        }
                        backoff.snooze();
                    }

                    // After backoff, recheck for next segment before giving up.
                    // A producer might have created and linked a new segment during our backoff.
                    const next_after_backoff = head_seg.next.load(.acquire);
                    if (next_after_backoff == null) {
                        // Still no next segment after backoff. Queue is empty.
                        return count;
                    }
                    // Next segment appeared during backoff. Loop back to advance and retry.
                    continue;
                }
            }

            return count;
        }

        fn destroySegment(ptr: *anyopaque) void {
            const seg: *Segment = @ptrCast(@alignCast(ptr));
            seg.queue.deinit();
            seg.allocator.destroy(seg.queue);
            seg.allocator.destroy(seg);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

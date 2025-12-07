const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

/// Lock-free, unbounded MPMC (multi-producer, multi-consumer) queue
/// Based on crossbeam's SegQueue, adapted for Zig 0.15.2 atomic limitations
pub fn SegQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Segment = struct {
            data: []T,
            occupied: []atomic.Value(bool),
            next: atomic.Value(?*Segment),
            id: u64,
        };

        /// Position groups index and segment pointer - accessed together by same threads
        /// Matches Crossbeam's Position<T> { index: AtomicUsize, block: AtomicPtr<Block<T>> }
        const Position = struct {
            index: atomic.Value(u64),
            segment: atomic.Value(?*Segment),
        };

        allocator: Allocator,
        head: Position align(64), // Cache-aligned: consumers only (pop operations)
        tail: Position align(64), // Cache-aligned: producers only (push operations)
        segment_size: usize,
        segment_cap: usize, // Actual usable capacity (segment_size - 1)

        pub fn init(allocator: Allocator, segment_size: usize) !Self {
            if (segment_size <= 1) return error.InvalidSegmentSize;

            const segment_cap = segment_size - 1; // Reserve last slot as boundary marker

            const initial_segment = try allocator.create(Segment);
            errdefer allocator.destroy(initial_segment);

            initial_segment.data = try allocator.alloc(T, segment_cap);
            errdefer allocator.free(initial_segment.data);

            initial_segment.occupied = try allocator.alloc(atomic.Value(bool), segment_cap);
            errdefer allocator.free(initial_segment.occupied);

            for (initial_segment.occupied) |*occ| {
                occ.* = atomic.Value(bool).init(false);
            }

            initial_segment.next = atomic.Value(?*Segment).init(null);
            initial_segment.id = 0;

            return Self{
                .allocator = allocator,
                .head = Position{
                    .index = atomic.Value(u64).init(0),
                    .segment = atomic.Value(?*Segment).init(initial_segment),
                },
                .tail = Position{
                    .index = atomic.Value(u64).init(0),
                    .segment = atomic.Value(?*Segment).init(initial_segment),
                },
                .segment_size = segment_size,
                .segment_cap = segment_cap,
            };
        }

        /// Deinit the queue
        /// IMPORTANT: If T requires cleanup (has destructors, holds pointers, etc.),
        /// call deinitWithCleanup() instead to properly clean up remaining values
        pub fn deinit(self: *Self) void {
            self.deinitWithCleanup(null);
        }

        /// Deinit the queue with optional value cleanup
        /// cleanup_fn is called on each remaining value in the queue before freeing segments
        /// Matches Rust SegQueue Drop impl - crossbeam-queue/src/seg_queue.rs:461-494
        pub fn deinitWithCleanup(self: *Self, cleanup_fn: ?*const fn (T) void) void {
            const head_idx = self.head.index.load(.acquire);
            const tail_idx = self.tail.index.load(.acquire);
            var current_idx = head_idx;
            var current_segment = self.head.segment.load(.acquire);

            // Walk all values from head to tail and call cleanup on each
            while (current_idx < tail_idx) {
                const slot_index = current_idx % self.segment_size;

                // Skip boundary markers
                if (slot_index == self.segment_cap) {
                    current_idx += 1;
                    if (current_segment) |seg| {
                        current_segment = seg.next.load(.acquire);
                    }
                    continue;
                }

                // If value is occupied and cleanup is provided, clean it up
                if (current_segment) |seg| {
                    if (seg.occupied[slot_index].load(.acquire)) {
                        if (cleanup_fn) |cleanup| {
                            cleanup(seg.data[slot_index]);
                        }
                    }
                }

                current_idx += 1;
            }

            // Now free all segments
            var segment = self.head.segment.load(.acquire);
            while (segment) |seg| {
                const next = seg.next.load(.acquire);
                self.allocator.free(seg.data);
                self.allocator.free(seg.occupied);
                self.allocator.destroy(seg);
                segment = next;
            }
        }

        /// Push an element to the back of the queue
        pub fn push(self: *Self, value: T) !void {
            var tail = self.tail.index.load(.acquire);
            var block = self.tail.segment.load(.acquire);
            var next_block: ?*Segment = null;

            while (true) {
                // Calculate offset (0 to segment_size-1, where segment_size-1 is boundary marker)
                const offset = tail % self.segment_size;

                // If at boundary marker, wait for next block to be installed
                if (offset == self.segment_cap) {
                    std.atomic.spinLoopHint();
                    tail = self.tail.index.load(.acquire);
                    block = self.tail.segment.load(.acquire);
                    continue;
                }

                // Allocate next block in advance if approaching boundary
                if (offset + 1 == self.segment_cap and next_block == null) {
                    const new_seg = try self.allocator.create(Segment);
                    new_seg.data = try self.allocator.alloc(T, self.segment_cap);
                    new_seg.occupied = try self.allocator.alloc(atomic.Value(bool), self.segment_cap);
                    for (new_seg.occupied) |*occ| {
                        occ.* = atomic.Value(bool).init(false);
                    }
                    new_seg.id = if (block) |b| b.id + 1 else 0;
                    new_seg.next = atomic.Value(?*Segment).init(null);
                    next_block = new_seg;
                }

                // Handle first push - allocate initial block
                if (block == null) {
                    const new_seg = next_block orelse blk: {
                        const seg = try self.allocator.create(Segment);
                        seg.data = try self.allocator.alloc(T, self.segment_cap);
                        seg.occupied = try self.allocator.alloc(atomic.Value(bool), self.segment_cap);
                        for (seg.occupied) |*occ| {
                            occ.* = atomic.Value(bool).init(false);
                        }
                        seg.id = 0;
                        seg.next = atomic.Value(?*Segment).init(null);
                        break :blk seg;
                    };

                    if (self.tail.segment.cmpxchgStrong(null, new_seg, .release, .acquire)) |_| {
                        // Someone else set it, retry
                        tail = self.tail.index.load(.acquire);
                        block = self.tail.segment.load(.acquire);
                        next_block = new_seg;
                        continue;
                    } else {
                        self.head.segment.store(new_seg, .release);
                        block = new_seg;
                        next_block = null;
                    }
                }

                const new_tail = tail + 1;

                // Try to claim this slot by advancing tail index
                if (self.tail.index.cmpxchgWeak(tail, new_tail, .seq_cst, .acquire)) |failed_tail| {
                    tail = failed_tail;
                    block = self.tail.segment.load(.acquire);
                    std.atomic.spinLoopHint();
                    continue;
                }

                // Success! We claimed slot at `offset` in `block`
                const seg = block.?;

                // If we just claimed the last valid slot, install next block and skip boundary
                // CRITICAL ORDERING: Must ensure segment is visible BEFORE index
                // Otherwise consumers may see new index with old segment
                if (offset + 1 == self.segment_cap) {
                    const next = next_block.?;
                    const next_index = new_tail + 1; // Skip boundary marker

                    // Step 1: Link next segment in chain (Release)
                    seg.next.store(next, .release);

                    // Step 2: Publish new segment to producers (Release)
                    self.tail.segment.store(next, .release);

                    // Step 3: Publish new index (SeqCst for total ordering)
                    // SeqCst ensures consumers cannot see new index before seeing new segment
                    self.tail.index.store(next_index, .seq_cst);
                }

                // Write value to our claimed slot
                // CRITICAL: Write data FIRST, then set occupied=true
                // The .release on occupied ensures data write is visible to consumers
                seg.data[offset] = value;
                seg.occupied[offset].store(true, .release);
                return;
            }
        }

        /// Pop an element from the front of the queue
        /// CRITICAL: Must wait for producer to publish write before reading
        /// Matches Crossbeam SegQueue pop() with slot.wait_write() - seg_queue.rs:366-369
        pub fn pop(self: *Self) ?T {
            while (true) {
                const head_idx = self.head.index.load(.acquire);
                const head_seg = self.head.segment.load(.acquire) orelse return null;
                const tail_idx = self.tail.index.load(.acquire);

                // Check if queue is empty
                if (head_idx >= tail_idx) {
                    return null;
                }

                const slot_index = head_idx % self.segment_size;

                // If at boundary marker, skip it and move to next segment
                if (slot_index == self.segment_cap) {
                    if (head_seg.next.load(.acquire)) |next_seg| {
                        // Try to advance both segment and index past boundary
                        if (self.head.index.cmpxchgWeak(head_idx, head_idx + 1, .release, .acquire) == null) {
                            // Publish the next segment; if we win the CAS, we own old head_seg and can destroy it
                            const cas_ok = self.head.segment.cmpxchgStrong(head_seg, next_seg, .release, .acquire) == null;
                            if (cas_ok) {
                                // Safe to destroy the old segment: all slots have been consumed (we are at boundary)
                                // and we have published the next segment
                                const old = head_seg;
                                self.allocator.free(old.data);
                                self.allocator.free(old.occupied);
                                self.allocator.destroy(old);
                            }
                        }
                        continue;
                    } else {
                        // Next segment not ready yet, retry
                        std.atomic.spinLoopHint();
                        continue;
                    }
                }

                // Get current segment
                var seg = head_seg;
                if (slot_index == 0 and head_idx > 0) {
                    if (head_seg.next.load(.acquire)) |next| {
                        seg = next;
                    }
                }

                // CRITICAL FIX: Wait for producer to publish write
                // Without this, we might skip a slot that's being written, causing item loss
                // Matches Crossbeam's slot.wait_write() pattern
                var spin_count: u32 = 0;
                const max_spins: u32 = 64; // Spin up to 64 times before yielding

                while (true) {
                    const is_occupied = seg.occupied[slot_index].load(.acquire);

                    if (is_occupied) {
                        // Try to claim the value by swapping occupied to false
                        const was_occupied = seg.occupied[slot_index].swap(false, .acq_rel);
                        if (was_occupied) {
                            // Successfully claimed the value - read it
                            // Acquire from swap synchronizes with Release store in push()
                            const val = seg.data[slot_index];
                            _ = self.head.index.cmpxchgWeak(head_idx, head_idx + 1, .release, .acquire);
                            return val;
                        }
                        // Another thread claimed it, retry outer loop
                        break;
                    }

                    // Slot not occupied yet - check if queue became empty
                    const new_tail = self.tail.index.load(.acquire);
                    if (head_idx >= new_tail) {
                        // Queue is now empty, the tail we saw was stale
                        return null;
                    }

                    // Producer is still writing - spin wait
                    spin_count += 1;
                    if (spin_count < max_spins) {
                        std.atomic.spinLoopHint();
                    } else {
                        // After max spins, yield to avoid wasting CPU
                        std.atomic.spinLoopHint();
                        spin_count = 0;
                    }
                }
            }
        }

        /// Check if queue is empty
        /// Uses SeqCst ordering for accuracy under contention
        /// Matches Rust SegQueue is_empty() - crossbeam-queue/src/seg_queue.rs:403-407
        pub fn isEmpty(self: *Self) bool {
            const head_idx = self.head.index.load(.seq_cst);
            const tail_idx = self.tail.index.load(.seq_cst);
            return head_idx >= tail_idx;
        }

        /// Get length with consistency check
        /// Uses retry loop to ensure head/tail snapshot is consistent
        /// Matches Rust SegQueue len() - crossbeam-queue/src/seg_queue.rs:425-458
        pub fn len(self: *Self) u64 {
            while (true) {
                // Load tail, then head, then re-check tail
                const tail1 = self.tail.index.load(.seq_cst);
                const head = self.head.index.load(.seq_cst);
                const tail2 = self.tail.index.load(.seq_cst);

                // If tail didn't change, we have a consistent snapshot
                if (tail1 == tail2) {
                    return if (tail1 > head) tail1 - head else 0;
                }

                // Tail changed, retry
            }
        }
    };
}

test "SegQueue basic operations" {
    const allocator = std.testing.allocator;

    var queue = try SegQueue(u64).init(allocator, 16);
    defer queue.deinit();

    // Test empty queue
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), queue.pop());

    // Test push and pop
    try queue.push(42);
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(?u64, 42), queue.pop());
    try std.testing.expect(queue.isEmpty());

    // Test multiple elements
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try std.testing.expectEqual(@as(?u64, 1), queue.pop());
    try std.testing.expectEqual(@as(?u64, 2), queue.pop());
    try std.testing.expectEqual(@as(?u64, 3), queue.pop());
    try std.testing.expectEqual(@as(?u64, null), queue.pop());
}

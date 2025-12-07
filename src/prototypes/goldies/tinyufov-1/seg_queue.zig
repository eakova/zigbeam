/// SegQueue - Crossbeam-compatible lock-free concurrent queue
/// Ported from Crossbeam Rust MPMC queue
/// Ref: crossbeam-queue/src/seg_queue.rs:206-560

const std = @import("std");
const Atomic = std.atomic.Value;
const assert = std.debug.assert;

/// Index encoding constants
const SHIFT: usize = 1;           // Indices advance by 2
const LAP: usize = 32;            // Indices per lap
const BLOCK_CAP: usize = 31;      // Usable slots (slot 31 is sentinel)
const HAS_NEXT: usize = 1;        // Bit 0: indicates next block presence

/// Compute offset in block from index
fn get_offset(index: usize) usize {
    return (index >> SHIFT) % LAP;
}

/// Slot state flags
const WRITE: u8 = 1 << 0;         // Value has been written
const READ: u8 = 1 << 1;          // Value has been read
const DESTROY: u8 = 1 << 2;       // Slot marked for destruction

/// Sentinel values for atomic pointers
const NULL_PTR: usize = 0;
const BLOCK_SENTINEL: usize = std.math.maxInt(usize);

/// Slot containing value and state flags
pub const Slot = struct {
    // Value stored in queue
    value: *anyopaque,

    // Atomic state: WRITE, READ, DESTROY flags
    state: Atomic(u8),

    fn init() Slot {
        return .{
            .value = undefined,
            .state = Atomic(u8).init(0),
        };
    }
};

/// Block in the linked queue
pub const Block = struct {
    // Array of slots (31 usable + 1 sentinel)
    slots: [LAP]Slot,

    // Next block pointer (atomic, uses HAS_NEXT bit)
    next: Atomic(usize),

    fn init() Block {
        var block: Block = undefined;

        for (&block.slots) |*slot| {
            slot.* = Slot.init();
        }

        block.next = Atomic(usize).init(NULL_PTR);
        return block;
    }

    fn create(allocator: std.mem.Allocator) !*Block {
        const block = try allocator.create(Block);
        block.* = Block.init();
        return block;
    }

    fn destroy(allocator: std.mem.Allocator, block: *Block) void {
        allocator.destroy(block);
    }
};

/// Head pointer (atomic index with block reference)
pub const Head = struct {
    index: Atomic(usize),
    block: Atomic(usize), // *Block cast to usize

    fn init() Head {
        return .{
            .index = Atomic(usize).init(0),
            .block = Atomic(usize).init(NULL_PTR),
        };
    }
};

/// Tail pointer (atomic index with block reference)
pub const Tail = struct {
    index: Atomic(usize),
    block: Atomic(usize), // *Block cast to usize

    fn init() Tail {
        return .{
            .index = Atomic(usize).init(0),
            .block = Atomic(usize).init(NULL_PTR),
        };
    }
};

/// SegQueue - Segmented queue structure
pub const SegQueue = struct {
    head: Head,
    tail: Tail,
    initial_block_ptr: usize,  // Store initial block to free all blocks on deinit
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*SegQueue {
        const queue = try allocator.create(SegQueue);

        const initial_block = try Block.create(allocator);

        queue.* = .{
            .head = Head.init(),
            .tail = Tail.init(),
            .initial_block_ptr = @intFromPtr(initial_block),
            .allocator = allocator,
        };

        queue.head.block.store(@intFromPtr(initial_block), .release);
        queue.tail.block.store(@intFromPtr(initial_block), .release);

        return queue;
    }

    pub fn deinit(self: *SegQueue) void {
        // Cleanup all blocks - start from initial block to ensure all are freed
        var block_ptr = self.initial_block_ptr;

        while (block_ptr != NULL_PTR and block_ptr != BLOCK_SENTINEL) {
            const block: *Block = @ptrFromInt(block_ptr);

            const next_ptr = block.next.load(.acquire);
            Block.destroy(self.allocator, block);

            if (next_ptr == NULL_PTR or next_ptr == BLOCK_SENTINEL) break;

            block_ptr = next_ptr & ~HAS_NEXT;
        }

        self.allocator.destroy(self);
    }

    /// Push element to queue
    /// Safety: T must be valid for the queue's lifetime
    pub fn push(self: *SegQueue, value: *anyopaque) !void {
        var tail_index = self.tail.index.load(.acquire);  // Rust: Acquire
        var block_ptr = self.tail.block.load(.acquire);
        var next_block_opt: ?*Block = null;

        loop: while (true) {
            // Calculate the offset of the index into the block
            const offset = get_offset(tail_index);

            // If we reached the end of the block, wait until the next one is installed (Rust: line 217-221)
            if (offset == BLOCK_CAP) {
                tail_index = self.tail.index.load(.acquire);
                block_ptr = self.tail.block.load(.acquire);
                continue :loop;
            }

            // If we're going to have to install the next block, allocate it in advance (Rust: line 226-227)
            if (offset + 1 == BLOCK_CAP and next_block_opt == null) {
                next_block_opt = try Block.create(self.allocator);
            }

            // If this is the first push operation, we need to allocate the first block (Rust: line 231-247)
            if (block_ptr == NULL_PTR) {
                const new_block = try Block.create(self.allocator);
                const new_ptr = @intFromPtr(new_block);

                const result = self.tail.block.cmpxchgWeak(
                    NULL_PTR,
                    new_ptr,
                    .release,
                    .monotonic,
                );

                if (result == null) {
                    self.head.block.store(new_ptr, .release);
                    block_ptr = new_ptr;
                } else {
                    Block.destroy(self.allocator, new_block);
                    tail_index = self.tail.index.load(.acquire);
                    block_ptr = self.tail.block.load(.acquire);
                    continue :loop;
                }
            }

            const new_tail = tail_index +% (1 << SHIFT);

            // Try advancing the tail forward (Rust: line 253-282)
            const cas_result = self.tail.index.cmpxchgWeak(
                tail_index,
                new_tail,
                .seq_cst,  // Rust: SeqCst
                .acquire,  // Rust: Acquire
            );

            if (cas_result == null) {
                // Success! (Rust: line 259-275)
                const block: *Block = @ptrFromInt(block_ptr);

                // If we've reached the end of the block, install the next one (Rust: line 261-267)
                if (offset + 1 == BLOCK_CAP) {
                    if (next_block_opt) |next_block| {
                        const next_ptr = @intFromPtr(next_block);
                        const next_index = new_tail +% (1 << SHIFT);

                        self.tail.block.store(next_ptr, .release);
                        self.tail.index.store(next_index, .release);
                        block.next.store(next_ptr, .release);
                    }
                }

                // Write the value into the slot (Rust: line 271-273)
                const slot = &block.slots[offset];
                slot.value = value;
                slot.state.store(WRITE, .release);

                return;
            } else {
                // Failed CAS, retry (Rust: line 277-281)
                tail_index = cas_result.?;
                block_ptr = self.tail.block.load(.acquire);
            }
        }
    }

    /// Pop element from queue
    pub fn pop(self: *SegQueue) ?*anyopaque {
        var head_index = self.head.index.load(.acquire);  // Rust: Acquire (line 305)
        var block_ptr = self.head.block.load(.acquire);

        loop: while (true) {
            // Calculate the offset of the index into the block
            const offset = get_offset(head_index);

            // If we reached the end of the block, wait until the next one is installed (Rust: line 312-318)
            if (offset == BLOCK_CAP) {
                head_index = self.head.index.load(.acquire);
                block_ptr = self.head.block.load(.acquire);
                continue :loop;
            }

            var new_head = head_index +% (1 << SHIFT);

            if (new_head & HAS_NEXT == 0) {
                // Equivalent of atomic::fence(Ordering::SeqCst) (Rust: line 323)
                // Since Zig doesn't have direct fence, use SeqCst load as stronger sync point
                _ = self.head.index.load(.seq_cst);

                // Rust: line 324 - load with Relaxed after fence
                const tail_index = self.tail.index.load(.acquire);

                // If the tail equals the head, that means the queue is empty (Rust: line 327-329)
                if (head_index >> SHIFT == tail_index >> SHIFT) {
                    return null;
                }

                // If head and tail are not in the same block, set HAS_NEXT in head (Rust: line 332-334)
                if ((head_index >> SHIFT) / LAP != (tail_index >> SHIFT) / LAP) {
                    new_head |= HAS_NEXT;
                }
            }

            // The block can be null here only if the first push operation is in progress (Rust: line 339-344)
            if (block_ptr == NULL_PTR) {
                head_index = self.head.index.load(.acquire);
                block_ptr = self.head.block.load(.acquire);
                continue :loop;
            }

            const block: *Block = @ptrFromInt(block_ptr & ~HAS_NEXT);

            // Try moving the head index forward (Rust: line 347-352)
            const cas_result = self.head.index.cmpxchgWeak(
                head_index,
                new_head,
                .seq_cst,      // Rust: SeqCst
                .acquire,      // Rust: Acquire
            );

            if (cas_result == null) {
                // Successfully popped (Rust: line 353-379)
                // If we've reached the end of the block, move to the next one (Rust: line 355-364)
                if (offset + 1 == BLOCK_CAP) {
                    const next = block.next.load(.acquire);
                    if (next != NULL_PTR) {
                        var next_index = (new_head & ~HAS_NEXT) +% (1 << SHIFT);

                        // Check if next block has a successor (Rust: line 358-360)
                        const next_block: *Block = @ptrFromInt(next & ~HAS_NEXT);
                        if (next_block.next.load(.monotonic) != NULL_PTR) {
                            next_index |= HAS_NEXT;
                        }

                        self.head.block.store(next, .release);
                        self.head.index.store(next_index, .release);
                    }
                }

                // Read the value (Rust: line 367-369)
                const slot = &block.slots[offset];
                // Wait for value to be written (Rust: wait_write line 43-45)
                while (slot.state.load(.acquire) & WRITE == 0) {
                    // Spin/backoff waiting for write
                }
                const value = slot.value;

                // Mark as read (Rust: line 375-376)
                var state = slot.state.load(.acquire);
                while (true) {
                    const res = slot.state.cmpxchgWeak(
                        state,
                        state | READ,
                        .acq_rel,
                        .acquire,
                    );
                    if (res == null) break;
                    state = res.?;
                }

                return value;
            }

            // Failed CAS, retry (Rust: line 381-385)
            head_index = cas_result.?;
            block_ptr = self.head.block.load(.acquire);
        }
    }

    /// Check if queue is empty
    pub fn is_empty(self: *SegQueue) bool {
        const head = self.head.index.load(.seq_cst);
        const tail = self.tail.index.load(.seq_cst);

        return head >> SHIFT >= tail >> SHIFT;
    }

    /// Get approximate queue length
    /// Note: Not linearizable due to concurrent operations
    pub fn len(self: *SegQueue) usize {
        var tail = self.tail.index.load(.acquire);
        var head = self.head.index.load(.acquire);

        // Retry if indices changed
        var retry_count: u32 = 0;
        while (retry_count < 10) {
            const new_tail = self.tail.index.load(.seq_cst);

            if (new_tail == tail) {
                const tail_lap = (tail >> SHIFT) / LAP;
                const head_lap = (head >> SHIFT) / LAP;

                if (tail_lap > head_lap) {
                    return tail >> SHIFT - (head >> SHIFT) + (tail_lap - head_lap - 1);
                } else if (tail_lap == head_lap) {
                    return (tail >> SHIFT) - (head >> SHIFT);
                } else {
                    return 0;
                }
            }

            tail = new_tail;
            head = self.head.index.load(.acquire);
            retry_count += 1;
        }

        return 0;
    }
};

/// ============================================================================
/// ITERATOR (for cleanup)
/// ============================================================================

pub const SegQueueIter = struct {
    queue: *SegQueue,
    index: usize,

    pub fn init(queue: *SegQueue) SegQueueIter {
        return .{
            .queue = queue,
            .index = queue.head.index.load(.acquire),
        };
    }

    pub fn next(self: *SegQueueIter) ?*anyopaque {
        if (self.queue.pop()) |value| {
            self.index = self.index +% (1 << SHIFT);
            return value;
        }

        return null;
    }
};

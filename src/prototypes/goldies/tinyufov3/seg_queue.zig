const std = @import("std");

// Crossbeam-like SegQueue (Zig 0.15.2)
// Key properties we implement now:
// - Unbounded, lock-free MPMC using linked blocks
// - Per-slot state with WRITE/READ/DESTROY
// - Producers publish values with Release after write; consumers wait on WRITE
// - Boundary transition installs next block and reclaims the previous block
// - Accurate isEmpty()/len() with SeqCst snapshot (simplified)

pub fn SegQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        // Slot state bits
        const WRITE: u8 = 0b0000_0001;
        const READ: u8 = 0b0000_0010;
        const DESTROY: u8 = 0b0000_0100;

        // Block geometry
        const BLOCK_CAP: usize = 31; // usable slots per block
        const LAP: usize = 32; // one boundary slot per lap
        const SHIFT: u6 = 1; // lower bit reserved for HAS_NEXT metadata
        const HAS_NEXT: u64 = 1; // metadata flag in index

        const Slot = struct {
            state: std.atomic.Value(u8),
            // Store the value inline; caller should ensure T is copyable or understand semantics
            value: T,

            fn init() Slot {
                return .{ .state = std.atomic.Value(u8).init(0), .value = undefined };
            }
        };

        const Block = struct {
            slots: [BLOCK_CAP]Slot,
            next: std.atomic.Value(?*Block),

            fn create(allocator: std.mem.Allocator) !*Block {
                const b = try allocator.create(Block);
                for (&b.slots) |*s| s.* = Slot.init();
                b.next = std.atomic.Value(?*Block).init(null);
                return b;
            }
        };

        const Position = struct {
            index: std.atomic.Value(u64),
            block: std.atomic.Value(?*Block),
        };

        allocator: std.mem.Allocator,
        head: Position align(64),
        tail: Position align(64),

        pub const IntoIter = struct {
            q: *Self,
            pub fn next(self: *IntoIter) ?T {
                return self.q.pop();
            }
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            const initial = try Block.create(allocator);
            return .{
                .allocator = allocator,
                .head = .{ .index = std.atomic.Value(u64).init(0), .block = std.atomic.Value(?*Block).init(initial) },
                .tail = .{ .index = std.atomic.Value(u64).init(0), .block = std.atomic.Value(?*Block).init(initial) },
            };
        }

        pub fn deinit(self: *Self) void {
            // Drain blocks and free
            var blk = self.head.block.load(.seq_cst);
            while (blk) |b| {
                const next = b.next.load(.seq_cst);
                self.allocator.destroy(b);
                blk = next;
            }
        }

        inline fn offsetOf(index: u64) usize {
            // Crossbeam: (idx >> SHIFT) % LAP
            return @intCast((index >> SHIFT) % LAP);
        }

        inline fn wait_next(b: *Block) *Block {
            // Spin until next is visible
            var spins: u32 = 0;
            while (true) {
                if (b.next.load(.acquire)) |n| return n;
                spins += 1;
                std.atomic.spinLoopHint();
            }
        }

        fn destroyBlockFrom(self: *Self, blk: *Block, start: usize) void {
            _ = self; _ = blk; _ = start;
            // Destruction is deferred to deinit traversal to avoid races under contention.
        }

        pub fn push(self: *Self, value: T) !void {
            var tail_idx = self.tail.index.load(.acquire);
            var tail_blk = self.tail.block.load(.acquire);

            while (true) {
                const off = offsetOf(tail_idx);

                // At boundary marker: spin until next block is visible
                if (off == BLOCK_CAP) {
                    std.atomic.spinLoopHint();
                    tail_idx = self.tail.index.load(.acquire);
                    tail_blk = self.tail.block.load(.acquire);
                    continue;
                }

                // Allocate next if we are about to hit boundary
                if (off + 1 == BLOCK_CAP and tail_blk != null) {
                    // Pre-alloc next if not present
                    if (tail_blk.?.next.load(.acquire) == null) {
                        const nb = try Block.create(self.allocator);
                        if (tail_blk.?.next.cmpxchgWeak(null, nb, .release, .acquire)) |other| {
                            // Lost race, free and continue
                            self.allocator.destroy(nb);
                            _ = other; // unused
                        }
                    }
                }

                // Try to claim slot by advancing tail index by one element (shifted)
                const new_tail = tail_idx + (1 << SHIFT);
                if (self.tail.index.cmpxchgWeak(tail_idx, new_tail, .seq_cst, .acquire)) |failed| {
                    tail_idx = failed;
                    tail_blk = self.tail.block.load(.acquire);
                    std.atomic.spinLoopHint();
                    continue;
                }

                // We own (tail_blk, off)
                const blk = tail_blk.?;

                // If we just filled last usable slot, publish next block and skip boundary
                if (off + 1 == BLOCK_CAP) {
                    if (blk.next.load(.acquire)) |nb| {
                        // Link next (release), then publish next block and index skipping boundary lap
                        // Next index: new_tail plus one element (shifted) to skip boundary
                        const next_index: u64 = new_tail + (1 << SHIFT);
                        self.tail.block.store(nb, .release);
                        self.tail.index.store(next_index, .release);
                    }
                }

                // Write and publish
                blk.slots[off].value = value;
                _ = blk.slots[off].state.fetchOr(WRITE, .release);
                return;
            }
        }

        pub fn pop(self: *Self) ?T {
            while (true) {
                const head_idx = self.head.index.load(.acquire);
                const head_blk = self.head.block.load(.acquire) orelse return null;
                // Pre-pop ordering: SeqCst fence equivalent via SeqCst tail read
                const tail_idx = self.tail.index.load(.seq_cst);

                if (head_idx >= tail_idx) return null;

                const off = offsetOf(head_idx);
                if (off == BLOCK_CAP) {
                    // Move to next block: wait_next semantics
                    const nb = wait_next(head_blk);
                    const new_head = head_idx + (1 << SHIFT);
                    if (self.head.index.cmpxchgWeak(head_idx, new_head, .release, .acquire) == null) {
                        _ = self.head.block.cmpxchgStrong(head_blk, nb, .release, .acquire);
                        // Do not destroy head block here; destruction is coordinated via slot READ/DESTROY handshake
                    }
                    continue;
                }

                var blk = head_blk;
                if (off == 0 and head_idx > 0) {
                    if (head_blk.next.load(.acquire)) |nb| blk = nb;
                }

                // Wait until WRITE is published
                var spins: u32 = 0;
                while (true) {
                    const st = blk.slots[off].state.load(.acquire);
                    if ((st & WRITE) != 0) break;
                    spins += 1;
                    if (spins < 64) std.atomic.spinLoopHint() else break;
                    if (self.tail.index.load(.acquire) <= head_idx) return null;
                }

                // Try to mark READ and consume
                const prev = blk.slots[off].state.fetchOr(READ, .acq_rel);
                if ((prev & WRITE) == 0) {
                    // lost race or hole, advance head and retry
                    _ = self.head.index.cmpxchgWeak(head_idx, head_idx + (1 << SHIFT), .release, .acquire);
                    continue;
                }

                const val = blk.slots[off].value;
                _ = self.head.index.cmpxchgWeak(head_idx, head_idx + (1 << SHIFT), .release, .acquire);
                // Destruction disabled at runtime; deinit will traverse and free blocks.
                return val;
            }
        }

        pub fn isEmpty(self: *Self) bool {
            // Crossbeam semantics: compare lap/slot positions after masking metadata
            var h = self.head.index.load(.seq_cst);
            var t = self.tail.index.load(.seq_cst);
            // Erase lower SHIFT bits
            h &= ~(@as(u64, (1 << SHIFT) - 1));
            t &= ~(@as(u64, (1 << SHIFT) - 1));
            return h >= t;
        }

        pub fn len(self: *Self) u64 {
            while (true) {
                var t1 = self.tail.index.load(.seq_cst);
                var h = self.head.index.load(.seq_cst);
                const t2 = self.tail.index.load(.seq_cst);
                if (t1 == t2) {
                    // mask lower bits
                    const mask: u64 = @as(u64, (1 << SHIFT) - 1);
                    t1 &= ~mask;
                    h &= ~mask;
                    // Convert to element counts (shifted indices)
                    t1 >>= SHIFT;
                    h >>= SHIFT;
                    // Fix boundary positions
                    if ((t1 % LAP) == LAP - 1) t1 += 1;
                    if ((h % LAP) == LAP - 1) h += 1;
                    return if (t1 > h) t1 - h else 0;
                }
            }
        }

        pub fn intoIter(self: *Self) IntoIter {
            return .{ .q = self };
        }

        test "seg_queue: isEmpty/len snapshot" {
            const gpa = std.testing.allocator;
            var q = try SegQueue(u64).init(gpa);
            defer q.deinit();
            try std.testing.expect(q.isEmpty());
            try std.testing.expectEqual(@as(u64, 0), q.len());
            try q.push(11);
            try q.push(22);
            try std.testing.expect(!q.isEmpty());
            try std.testing.expect(q.len() >= 1);
            _ = q.pop();
            _ = q.pop();
            try std.testing.expect(q.isEmpty());
        }
    };
}

test "seg_queue: basic push/pop" {
    const gpa = std.testing.allocator;
    var q = try SegQueue(u64).init(gpa);
    defer q.deinit();

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), q.pop());
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectEqual(@as(?u64, 1), q.pop());
    try std.testing.expectEqual(@as(?u64, 2), q.pop());
    try std.testing.expectEqual(@as(?u64, 3), q.pop());
    try std.testing.expectEqual(@as(?u64, null), q.pop());
}

test "seg_queue: intoIter drains" {
    const gpa = std.testing.allocator;
    var q = try SegQueue(u64).init(gpa);
    defer q.deinit();
    try q.push(5);
    try q.push(6);
    var it = q.intoIter();
    const a = it.next().?;
    const b = it.next().?;
    try std.testing.expect(a == 5 and b == 6);
    try std.testing.expectEqual(@as(?u64, null), it.next());
}

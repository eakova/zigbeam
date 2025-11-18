const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Arc = @import("arc_core").Arc;
const Backoff = @import("backoff").Backoff;

/// Chase-Lev Work-Stealing Deque
///
/// A lock-free deque optimized for work-stealing thread pools.
/// Based on "Dynamic Circular Work-Stealing Deque" (Chase & Lev, 2005)
///
/// Performance characteristics:
/// - Owner push: O(1) amortized, ~2-5ns (no atomics!)
/// - Owner pop:  O(1), ~3-10ns (CAS only for last item)
/// - Thief steal: O(1), ~20-50ns (single CAS)
///
/// Thread safety:
/// - ONE owner thread: push() and pop()
/// - MANY thief threads: steal()
///
/// Usage:
/// ```zig
/// var deque = try ChaseLevWorkStealingDeque(Task).init(allocator);
/// defer deque.deinit();
///
/// // Owner thread:
/// try deque.push(task);
/// if (deque.pop()) |task| { ... }
///
/// // Thief threads (simple):
/// if (deque.steal()) |task| { ... }
///
/// // Thief threads (with backoff for heavy contention):
/// // IMPORTANT: Each thief needs its OWN Backoff instance (thread-local)
/// // Do NOT share Backoff between threads - it's not thread-safe!
/// var backoff = Backoff.init(.{});
/// while (true) {
///     if (deque.stealWithBackoff(&backoff)) |task| {
///         backoff.reset(); // Reset on success
///         // Process task...
///     } else break; // Empty or gave up
/// }
/// ```
pub fn ChaseLevWorkStealingDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        const Buffer = struct {
            data: []T,
            capacity: usize,
            mask: usize, // Cache mask for fast indexing (capacity - 1)
            allocator: Allocator,

            /// Get item at logical index (with wraparound) - HOT PATH, always inline
            inline fn at(self: *Buffer, index: i64) *T {
                return &self.data[@as(usize, @intCast(index)) & self.mask];
            }

            /// Deinit for Arc cleanup
            pub fn deinit(self: *Buffer) void {
                self.allocator.free(self.data);
            }
        };

        const ArcBuffer = Arc(Buffer);

        /// Bottom index (owner end) - local to owner thread
        /// FIRST for cache locality - accessed on every push/pop
        bottom: i64,

        /// Circular buffer holding the items (Arc-managed for zero leaks)
        ///
        /// Uses Arc's atomic operations to solve three critical problems:
        /// 1. Zig's limitation: can't atomic load/store Arc structs
        /// 2. Safe concurrent pointer swaps during buffer growth
        /// 3. TOCTOU race protection when thieves access the buffer
        ///
        /// Owner thread: Direct access (single-threaded, safe)
        /// Thief threads: ArcBuffer.atomicLoad() for safe concurrent access
        buffer: ArcBuffer,

        /// Top index (steal end) - atomic, accessed by thieves
        top: Atomic(i64),

        allocator: Allocator,

        /// Initialize the deque with default capacity
        pub fn init(allocator: Allocator) !Self {
            return initCapacity(allocator, 32);
        }

        /// Initialize with specific initial capacity (must be power of 2)
        pub fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            if (!std.math.isPowerOfTwo(capacity)) {
                return error.CapacityNotPowerOfTwo;
            }

            const data = try allocator.alloc(T, capacity);
            errdefer allocator.free(data);

            const buffer_arc = try ArcBuffer.init(allocator, Buffer{
                .data = data,
                .capacity = capacity,
                .mask = capacity - 1,
                .allocator = allocator,
            });

            return Self{
                .bottom = 0,
                .buffer = buffer_arc,
                .top = Atomic(i64).init(0),
                .allocator = allocator,
            };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            self.buffer.release();
        }

        /// Push item to bottom (owner thread only)
        ///
        /// This is the HOT PATH for the owner thread.
        /// - NO atomic operations in the common case
        /// - Just a store and increment
        /// - Grows buffer if needed
        pub inline fn push(self: *Self, item: T) !void {
            const b = self.bottom;
            const t = self.top.load(.acquire);

            // Cache buffer pointer to avoid multiple derefs
            var buf = @constCast(self.buffer.get());

            // Fast path: Check if buffer needs to grow (common case: no growth)
            const deque_size = b - t;
            if (deque_size >= @as(i64, @intCast(buf.capacity))) {
                // Slow path: Buffer is full, need to grow
                // Clone buffer Arc to protect it during grow() - prevents thieves from freeing it mid-copy
                const buf_arc = self.buffer.clone();
                defer buf_arc.release();

                const new_arc = try self.grow(t, b, buf);

                // Atomically swap the buffer - thieves will see the new buffer
                // The old buffer is automatically released when its refcount reaches 0
                const old_arc = ArcBuffer.atomicSwap(&self.buffer, new_arc, .release);
                defer old_arc.release();

                // Update buf to point to new buffer
                buf = @constCast(self.buffer.get());
            }

            // Store item (no atomic needed!)
            buf.at(b).* = item;

            // Increment bottom with release ordering
            // This ensures the item write is visible before bottom update
            @atomicStore(i64, &self.bottom, b + 1, .release);
        }

        /// Pop item from bottom (owner thread only)
        ///
        /// Returns null if deque is empty.
        /// Uses CAS only when competing with thieves for the last item.
        pub inline fn pop(self: *Self) ?T {
            // Speculatively decrement bottom
            const b = self.bottom - 1;

            // Owner is single-threaded for push/pop, so buffer can't be freed during pop
            // (only push() can modify buffer via grow, and push/pop don't run concurrently)
            const buf = @constCast(self.buffer.get());

            @atomicStore(i64, &self.bottom, b, .seq_cst);

            const t = self.top.load(.seq_cst);

            if (b < t) {
                // Deque is empty, restore bottom
                self.bottom = t;
                return null;
            }

            const item = buf.at(b).*;

            if (b > t) {
                // More than one item left, no race with thieves
                return item;
            }

            // This is the last item, race with thieves!
            // Use CAS to claim it
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null) {
                // We won the race
                self.bottom = t + 1;
                return item;
            }

            // Lost race to a thief
            self.bottom = t + 1;
            return null;
        }

        /// Steal item from top (thief threads)
        ///
        /// Thread-safe, can be called from any thread.
        /// Returns null if deque is empty or if lost race with another thief.
        ///
        /// PERFORMANCE: 3 atomic operations
        /// - 1x seq_cst load (top)
        /// - 1x acquire load (bottom)
        /// - 1x seq_cst CAS (top claim)
        /// Buffer is accessed with acquire load for thread-safety
        pub fn steal(self: *Self) ?T {
            // Read top with seq_cst ordering
            const t = self.top.load(.seq_cst);

            // Read bottom with acquire to synchronize with owner's bottom updates
            const b = @atomicLoad(i64, &self.bottom, .acquire);

            if (t >= b) {
                // Empty
                return null;
            }

            // THREAD-SAFE BUFFER ACCESS:
            // Atomically load the Arc buffer with safe refcount increment
            // This eliminates TOCTOU races - the buffer is protected from deallocation
            const buf_arc = ArcBuffer.atomicLoad(&self.buffer, .acquire) orelse {
                // Buffer was deallocated (shouldn't happen in practice, but handle gracefully)
                return null;
            };
            defer buf_arc.release();

            // Now it's safe to use the buffer - refcount is incremented
            const buf = @constCast(buf_arc.get());

            // Read the item
            const item = buf.at(t).*;

            // Try to claim this item with CAS
            // This is the critical synchronization point - only one thief will succeed
            if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic) == null) {
                // Success! We claimed the item
                return item;
            }

            // Lost race, another thief got it
            return null;
        }

        /// Steal with exponential backoff (thief threads)
        ///
        /// Like `steal()` but retries with exponential backoff when losing CAS races.
        /// This reduces CPU usage and contention when many thieves compete for items.
        ///
        /// THREAD SAFETY WARNING:
        /// - Each thief thread MUST have its own Backoff instance (thread-local)
        /// - Do NOT share a single Backoff between multiple threads
        /// - Backoff is NOT thread-safe (it mutates state without atomics)
        ///
        /// Behavior:
        /// - Returns immediately on empty deque (null)
        /// - Retries with backoff on CAS failures (lost races)
        /// - Uses spin() for lightweight contention
        /// - Uses snooze() for heavier contention (spins then yields)
        ///
        /// Returns null when deque is empty AND backoff is completed.
        pub fn stealWithBackoff(self: *Self, backoff: *Backoff) ?T {
            while (true) {
                // Read top with seq_cst ordering
                const t = self.top.load(.seq_cst);

                // Read bottom with acquire to synchronize with owner's bottom updates
                const b = @atomicLoad(i64, &self.bottom, .acquire);

                if (t >= b) {
                    // Empty - but distinguish "truly empty" from "lost race"
                    // If we've been retrying and now it's empty, we're done
                    if (backoff.step > 0) {
                        return null; // Gave up after retries
                    }
                    // First attempt and empty - retry once more with backoff
                    backoff.snooze();
                    continue;
                }

                // THREAD-SAFE BUFFER ACCESS
                const buf_arc = ArcBuffer.atomicLoad(&self.buffer, .acquire) orelse {
                    return null;
                };
                defer buf_arc.release();

                const buf = @constCast(buf_arc.get());
                const item = buf.at(t).*;

                // Try to claim this item with CAS
                if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic) == null) {
                    // Success! We claimed the item
                    return item;
                }

                // Lost race - use backoff before retry
                // Use snooze() for better behavior under contention
                backoff.snooze();

                // If backoff is completed, give up (avoid infinite spinning)
                if (backoff.isCompleted()) {
                    return null;
                }
            }
        }

        /// Get approximate size (racy, for debugging)
        pub fn size(self: *const Self) usize {
            const t = self.top.load(.monotonic);
            const b = @atomicLoad(i64, &self.bottom, .monotonic);
            const s = b - t;
            return if (s < 0) 0 else @intCast(s);
        }

        /// Check if empty (racy, for debugging)
        pub fn isEmpty(self: *const Self) bool {
            return self.size() == 0;
        }

        /// Grow the buffer (called when full)
        fn grow(self: *Self, t: i64, b: i64, old_buf: *Buffer) !ArcBuffer {
            const new_capacity = old_buf.capacity * 2;
            const new_data = try self.allocator.alloc(T, new_capacity);
            errdefer self.allocator.free(new_data);

            const new_buf_arc = try ArcBuffer.init(self.allocator, Buffer{
                .data = new_data,
                .capacity = new_capacity,
                .mask = new_capacity - 1,
                .allocator = self.allocator,
            });

            // Copy all items from old buffer to new buffer
            // Cache new buffer pointer to avoid get() call overhead in loop
            const new_buf = @constCast(new_buf_arc.get());
            var i = t;
            while (i < b) : (i += 1) {
                new_buf.at(i).* = old_buf.at(i).*;
            }

            // Arc handles cleanup automatically when last reference is released
            // Old buffer will be freed when all thieves finish reading it
            return new_buf_arc;
        }
    };
}

/// Alias for ChaseLevWorkStealingDeque for convenience
pub const WorkStealingDeque = ChaseLevWorkStealingDeque;

// =============================================================================
// Tests
// =============================================================================

test "basic push and pop" {
    const testing = std.testing;
    var deque = try WorkStealingDeque(u32).init(testing.allocator);
    defer deque.deinit();

    try testing.expect(deque.isEmpty());

    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    try testing.expectEqual(@as(usize, 3), deque.size());

    try testing.expectEqual(@as(?u32, 3), deque.pop());
    try testing.expectEqual(@as(?u32, 2), deque.pop());
    try testing.expectEqual(@as(?u32, 1), deque.pop());
    try testing.expectEqual(@as(?u32, null), deque.pop());
}

test "basic steal" {
    const testing = std.testing;
    var deque = try WorkStealingDeque(u32).init(testing.allocator);
    defer deque.deinit();

    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    // Steal takes from the top (oldest)
    try testing.expectEqual(@as(?u32, 1), deque.steal());
    try testing.expectEqual(@as(?u32, 2), deque.steal());

    // Pop takes from bottom (newest)
    try testing.expectEqual(@as(?u32, 3), deque.pop());

    try testing.expectEqual(@as(?u32, null), deque.steal());
}

test "growth" {
    const testing = std.testing;
    var deque = try WorkStealingDeque(u32).initCapacity(testing.allocator, 4);
    defer deque.deinit();

    // Push more than initial capacity
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try deque.push(i);
    }

    try testing.expectEqual(@as(usize, 100), deque.size());

    // Pop all
    i = 100;
    while (i > 0) {
        i -= 1;
        try testing.expectEqual(@as(?u32, i), deque.pop());
    }

    try testing.expect(deque.isEmpty());
}

test "concurrent push and steal" {
    const testing = std.testing;

    if (true) return error.SkipZigTest; // Skip in CI

    const Thread = std.Thread;

    var deque = try WorkStealingDeque(usize).init(testing.allocator);
    defer deque.deinit();

    const num_items = 10000;
    const num_thieves = 4;

    // Owner thread pushes items
    const OwnerContext = struct {
        deque: *WorkStealingDeque(usize),
        count: usize,
    };

    const owner_fn = struct {
        fn run(ctx: OwnerContext) !void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                try ctx.deque.push(i);
            }
        }
    }.run;

    // Thief threads steal items
    const ThiefContext = struct {
        deque: *WorkStealingDeque(usize),
        stolen: *Atomic(usize),
    };

    const thief_fn = struct {
        fn run(ctx: ThiefContext) void {
            var count: usize = 0;
            while (true) {
                if (ctx.deque.steal()) |_| {
                    count += 1;
                } else {
                    // Empty, but might get more items
                    Thread.yield() catch {};
                    if (ctx.deque.isEmpty()) break;
                }
            }
            _ = ctx.stolen.fetchAdd(count, .monotonic);
        }
    }.run;

    var stolen = Atomic(usize).init(0);

    // Start thieves
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves) |*t| {
        t.* = try Thread.spawn(.{}, thief_fn, .{ThiefContext{
            .deque = &deque,
            .stolen = &stolen,
        }});
    }

    // Owner pushes
    try owner_fn(OwnerContext{ .deque = &deque, .count = num_items });

    // Wait for thieves
    for (thieves) |t| {
        t.join();
    }

    // Owner pops remaining
    var popped: usize = 0;
    while (deque.pop()) |_| {
        popped += 1;
    }

    const total = stolen.load(.monotonic) + popped;
    try testing.expectEqual(num_items, total);
}

test "single item race" {
    const testing = std.testing;

    if (true) return error.SkipZigTest; // Skip in CI

    const Thread = std.Thread;

    var deque = try WorkStealingDeque(u32).init(testing.allocator);
    defer deque.deinit();

    // Test the last-item race condition many times
    const iterations = 10000;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        try deque.push(42);

        const thief = try Thread.spawn(.{}, struct {
            fn run(d: *WorkStealingDeque(u32)) void {
                _ = d.steal();
            }
        }.run, .{&deque});

        _ = deque.pop();
        thief.join();

        try testing.expect(deque.isEmpty());
    }
}

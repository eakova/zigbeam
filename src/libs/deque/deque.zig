const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Backoff = @import("backoff").Backoff;

/// Deque - A Bounded, High-Performance Work-Stealing Deque
///
/// A bounded work-stealing deque based on the Chase-Lev algorithm.
/// NOTE: This is a fixed-capacity variant without dynamic resizing.
///
/// Architecture:
/// - ONE owner thread: push() and pop() (LIFO stack for cache locality)
/// - MANY thief threads: steal() (FIFO queue from thieves' perspective)
///
/// Performance characteristics:
/// - Owner push: O(1), ~2-5ns (no CAS, just release store)
/// - Owner pop:  O(1), ~3-10ns (CAS only for last item race)
/// - Thief steal: O(1), ~20-50ns (acquire loads + CAS)
///
/// Memory model:
/// - Cache-line aligned head/tail to prevent false sharing
/// - Fixed-size ring buffer (returns error.Full when capacity reached)
/// - Uses signed i64 indices for correct size calculations across wraparound
///
/// Usage:
/// ```zig
/// const result = try Deque(Task).init(allocator, 1024);
/// defer result.worker.deinit();
///
/// // Owner thread:
/// try result.worker.push(task);
/// if (result.worker.pop()) |task| { ... }
///
/// // Thief threads (pass result.stealer to other threads):
/// if (stealer.steal()) |task| { ... }
/// ```
pub fn Deque(comptime T: type) type {
    // Compile-time validation: enforce pointer types for large T
    comptime {
        const type_info = @typeInfo(T);
        const is_pointer = switch (type_info) {
            .pointer => true,
            else => false,
        };
        const size = @sizeOf(T);

        if (size > std.atomic.cache_line and !is_pointer) {
            @compileError(std.fmt.comptimePrint(
                "Deque: Type '{s}' ({d} bytes) exceeds cache line size ({d} bytes). " ++
                "Use *{s} instead for better performance and to avoid false sharing.",
                .{ @typeName(T), size, std.atomic.cache_line, @typeName(T) }
            ));
        }
    }

    return struct {
        const Self = @This();

        /// Internal deque state (not for direct use)
        const DequeStore = struct {
            /// Index of the oldest item (steal target)
            /// Cache-line aligned to isolate thief contention
            /// Uses i64 for proper signed comparison semantics
            head: Atomic(i64) align(std.atomic.cache_line),

            /// Padding to prevent false sharing between head and tail
            /// This is critical for performance - keeps owner and thief operations
            /// on separate cache lines
            _padding: [std.atomic.cache_line - @sizeOf(Atomic(i64))]u8,

            /// Index of the next available slot for push
            /// Cache-line aligned, only modified by owner thread
            /// Uses i64 for proper signed comparison semantics
            tail: Atomic(i64) align(std.atomic.cache_line),

            /// Fixed-size ring buffer for storing items
            buffer: []T,

            /// Capacity - 1, for fast modulo via bitwise AND
            mask: usize,

            /// Allocator for cleanup
            allocator: Allocator,
        };

        /// Owner thread handle - grants access to push() and pop()
        pub const Worker = struct {
            deque: *DequeStore,

            /// Push item to bottom (owner thread only)
            ///
            /// This is the fast path - no CAS operations, just loads and a release store.
            /// Returns error.Full when the bounded capacity is reached.
            ///
            /// Memory ordering:
            /// - tail load: .monotonic (only we write to it)
            /// - head load: .acquire (synchronize with thieves' steals)
            /// - tail store: .release (publish the write to buffer)
            pub inline fn push(self: *Worker, item: T) !void {
                // 1. Read our private tail (monotonic is sufficient)
                const tail = self.deque.tail.load(.monotonic);

                // 2. Read head with acquire to see latest steals
                const head = self.deque.head.load(.acquire);

                // 3. Check if buffer is full
                if (tail - head >= @as(i64, @intCast(self.deque.buffer.len))) {
                    return error.Full;
                }

                // 4. Write item to buffer (non-atomic, we own this slot)
                const index: usize = @intCast(tail);
                self.deque.buffer[index & self.deque.mask] = item;

                // 5. Publish the write with release ordering
                // This ensures the item write is visible before tail update
                self.deque.tail.store(tail + 1, .release);
            }

            /// Pop item from bottom (owner thread only)
            ///
            /// Returns null if deque is empty.
            /// Uses CAS only when racing with thieves for the last item.
            ///
            /// Memory ordering:
            /// - tail load: .monotonic (only we write to it)
            /// - tail store: .release (publish the decrement)
            /// - head load: .acquire (synchronize with thieves)
            /// - CAS: .seq_cst (resolve multi-party race for last item)
            pub inline fn pop(self: *Worker) ?T {
                // 1. Read our private tail
                var tail = self.deque.tail.load(.monotonic);

                // 2. Speculatively decrement tail
                tail -= 1;

                // 3. Store decremented tail with seq_cst (matches paper)
                self.deque.tail.store(tail, .seq_cst);

                // 4. Read head with seq_cst to synchronize
                const head = self.deque.head.load(.seq_cst);

                // 5. Check state
                if (tail < head) {
                    // Empty - restore tail and return null
                    self.deque.tail.store(tail + 1, .monotonic);
                    return null;
                }

                // Read the item
                const index: usize = @intCast(tail);
                const item = self.deque.buffer[index & self.deque.mask];

                if (tail > head) {
                    // More than one item - we're done
                    return item;
                }

                // Exactly one item left - race with thieves
                // Restore tail BEFORE the CAS (critical for correctness!)
                self.deque.tail.store(tail + 1, .seq_cst);

                // Try to increment head to claim the item
                if (self.deque.head.cmpxchgStrong(head, head + 1, .seq_cst, .monotonic)) |_| {
                    // CAS failed - thief won
                    return null;
                }

                // CAS succeeded - we won
                return item;
            }

            /// Cleanup the deque (consumes the worker handle)
            pub fn deinit(self: *Worker) void {
                const allocator = self.deque.allocator;
                allocator.free(self.deque.buffer);
                allocator.destroy(self.deque);
            }

            /// Get approximate size (racy, for debugging)
            pub fn size(self: *const Worker) usize {
                const head = self.deque.head.load(.monotonic);
                const tail = self.deque.tail.load(.monotonic);
                const diff = tail - head;
                if (diff <= 0) return 0;
                return @intCast(diff);
            }

            /// Check if empty (racy, for debugging)
            pub fn isEmpty(self: *const Worker) bool {
                return self.size() == 0;
            }

            /// Get capacity
            pub fn capacity(self: *const Worker) usize {
                return self.deque.buffer.len;
            }
        };

        /// Thief thread handle - grants access to steal()
        pub const Stealer = struct {
            deque: *DequeStore,

            /// Steal item from top (thief threads)
            ///
            /// Thread-safe, can be called from any thread.
            /// Returns null if deque is empty or if lost race with another thief.
            ///
            /// Uses exponential backoff when CAS fails to reduce contention between thieves.
            ///
            /// Memory ordering:
            /// - head/tail load: .acquire (synchronize with owner's pushes)
            /// - CAS: .acq_rel (success) / .acquire (failure)
            pub fn steal(self: *Stealer) ?T {
                var backoff = Backoff.init(.{});

                while (true) {
                    // 1. Read head first with acquire ordering
                    const head = self.deque.head.load(.acquire);

                    // 2. Read tail with acquire ordering
                    const tail = self.deque.tail.load(.acquire);

                    // 3. Check if empty
                    if (head >= tail) {
                        return null;
                    }

                    // 4. Speculatively read the item
                    const index: usize = @intCast(head);
                    const item = self.deque.buffer[index & self.deque.mask];

                    // 5. Attempt to claim the item with CAS (seq_cst for correctness)
                    if (self.deque.head.cmpxchgWeak(head, head + 1, .seq_cst, .monotonic)) |_| {
                        // CAS failed, another thief won - backoff before retry
                        // This reduces cache coherency traffic under contention
                        backoff.snooze();
                        continue;
                    } else {
                        // CAS succeeded, we won the race
                        return item;
                    }
                }
            }

            /// Get approximate size (racy, for debugging)
            pub fn size(self: *const Stealer) usize {
                const head = self.deque.head.load(.monotonic);
                const tail = self.deque.tail.load(.monotonic);
                const diff = tail - head;
                if (diff <= 0) return 0;
                return @intCast(diff);
            }

            /// Check if empty (racy, for debugging)
            pub fn isEmpty(self: *const Stealer) bool {
                return self.size() == 0;
            }
        };

        /// Initialization result containing both handles
        pub const InitResult = struct {
            worker: Worker,
            stealer: Stealer,
        };

        /// Initialize a new bounded deque
        ///
        /// Capacity must be a power of two (required for fast & mask modulo).
        /// Returns error.CapacityNotPowerOfTwo if capacity is not a power of two.
        /// Returns error.OutOfMemory if allocation fails.
        pub fn init(allocator: Allocator, capacity: usize) !InitResult {
            // Validate power of two
            if (!std.math.isPowerOfTwo(capacity)) {
                return error.CapacityNotPowerOfTwo;
            }

            // Allocate deque struct
            const deque = try allocator.create(DequeStore);
            errdefer allocator.destroy(deque);

            // Allocate buffer
            const buffer = try allocator.alloc(T, capacity);
            errdefer allocator.free(buffer);

            // Initialize deque
            deque.* = DequeStore{
                .head = Atomic(i64).init(0),
                ._padding = undefined,
                .tail = Atomic(i64).init(0),
                .buffer = buffer,
                .mask = capacity - 1,
                .allocator = allocator,
            };

            return InitResult{
                .worker = Worker{ .deque = deque },
                .stealer = Stealer{ .deque = deque },
            };
        }
    };
}

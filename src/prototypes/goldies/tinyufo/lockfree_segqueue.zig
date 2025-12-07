// Lock-Free Segmented Queue (SegQueue)
// Multi-producer multi-consumer queue using linked segments
// Similar to Rust's crossbeam SegQueue used by Cloudflare

const std = @import("std");

/// Lock-free MPMC queue with linked segments
pub fn LockFreeSegQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const SEGMENT_SIZE = 64;  // Balanced for multi-threading

        /// Segment containing array of slots
        const Segment = struct {
            slots: [SEGMENT_SIZE]Slot,
            next: std.atomic.Value(?*Segment),

            // Use ?T for pointer types (supports null), T for others
            const ValueType = if (@typeInfo(T) == .pointer) ?T else T;

            const Slot = struct {
                value: std.atomic.Value(ValueType),
                state: std.atomic.Value(SlotState),

                const SlotState = enum(u8) {
                    Empty,
                    Writing,
                    Ready,
                    Reading,
                };
            };

            fn init() Segment {
                var seg: Segment = undefined;
                seg.next = std.atomic.Value(?*Segment).init(null);

                // Initialize based on type: null for pointers, undefined for others
                const init_value: ValueType = if (@typeInfo(T) == .pointer) null else undefined;

                for (&seg.slots) |*slot| {
                    slot.* = Slot{
                        .value = std.atomic.Value(ValueType).init(init_value),
                        .state = std.atomic.Value(Slot.SlotState).init(.Empty),
                    };
                }

                return seg;
            }
        };

        // Cache-line aligned atomics to prevent false sharing
        head: std.atomic.Value(*Segment) align(64),
        tail: std.atomic.Value(*Segment) align(64),
        head_index: std.atomic.Value(usize) align(64),
        tail_index: std.atomic.Value(usize) align(64),
        allocator: std.mem.Allocator,

        /// Initialize queue with first segment
        pub fn init(allocator: std.mem.Allocator) !Self {
            const first_seg = try allocator.create(Segment);
            first_seg.* = Segment.init();

            return Self{
                .head = std.atomic.Value(*Segment).init(first_seg),
                .tail = std.atomic.Value(*Segment).init(first_seg),
                .head_index = std.atomic.Value(usize).init(0),
                .tail_index = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head.load(.acquire);

            while (true) {
                const next = current.next.load(.acquire);
                self.allocator.destroy(current);

                if (next) |n| {
                    current = n;
                } else {
                    break;
                }
            }
        }

        /// Push value to queue (lock-free)
        pub fn push(self: *Self, value: T) !void {
            var retries: usize = 0;
            const max_retries = 500;

            while (retries < max_retries) : (retries += 1) {
                const tail_seg = self.tail.load(.acquire);
                const tail_idx = self.tail_index.fetchAdd(1, .monotonic);
                const local_idx = tail_idx % SEGMENT_SIZE;

                const slot = &tail_seg.slots[local_idx];

                // Try to claim slot
                if (slot.state.cmpxchgWeak(
                    .Empty,
                    .Writing,
                    .acq_rel,
                    .acquire,
                )) |_| {
                    // Slot not empty, check if we need new segment
                    if (local_idx == SEGMENT_SIZE - 1) {
                        self.allocateSegment() catch {};
                    }
                    continue;
                }

                // Write value
                slot.value.store(value, .release);
                slot.state.store(.Ready, .release);
                return;
            }

            return error.QueueFull;
        }

        /// Pop value from queue (lock-free)
        pub fn pop(self: *Self) ?T {
            var retries: usize = 0;
            const max_retries = 500;

            while (retries < max_retries) : (retries += 1) {
                const head_seg = self.head.load(.acquire);
                const head_idx = self.head_index.fetchAdd(1, .monotonic);
                const local_idx = head_idx % SEGMENT_SIZE;

                const slot = &head_seg.slots[local_idx];

                // Try to claim slot
                if (slot.state.cmpxchgWeak(
                    .Ready,
                    .Reading,
                    .acq_rel,
                    .acquire,
                )) |state| {
                    if (state == .Empty) {
                        // Queue is empty
                        return null;
                    }
                    // Another thread is reading/writing
                    continue;
                }

                // Read value
                const value = slot.value.load(.acquire);
                slot.state.store(.Empty, .release);

                // Advance to next segment if needed
                if (local_idx == SEGMENT_SIZE - 1) {
                    const next = head_seg.next.load(.acquire);
                    if (next) |next_seg| {
                        _ = self.head.cmpxchgStrong(
                            head_seg,
                            next_seg,
                            .acq_rel,
                            .acquire,
                        );
                        // NOTE: Old segment intentionally not freed here to avoid race conditions
                        // Segments will be freed during deinit() which is safe
                    }
                }

                return value;
            }

            return null;
        }

        /// Peek at head value without removing
        pub fn peek(self: *const Self) ?T {
            const head_seg = self.head.load(.acquire);
            const head_idx = self.head_index.load(.acquire);
            const local_idx = head_idx % SEGMENT_SIZE;

            const slot = &head_seg.slots[local_idx];

            if (slot.state.load(.acquire) == .Ready) {
                return slot.value.load(.acquire);
            }

            return null;
        }

        /// Check if queue is empty (approximate)
        pub fn isEmpty(self: *const Self) bool {
            const head_idx = self.head_index.load(.acquire);
            const tail_idx = self.tail_index.load(.acquire);
            return head_idx >= tail_idx;
        }

        /// Get approximate length
        pub fn length(self: *const Self) usize {
            const head_idx = self.head_index.load(.acquire);
            const tail_idx = self.tail_index.load(.acquire);

            if (tail_idx > head_idx) {
                return tail_idx - head_idx;
            }
            return 0;
        }

        /// Batch push - push multiple values with single fetchAdd (reduces contention)
        pub fn pushBatch(self: *Self, values: []const T) !void {
            if (values.len == 0) return;

            var retries: usize = 0;
            const max_retries = 1000;
            var written: usize = 0;

            while (written < values.len and retries < max_retries) : (retries += 1) {
                const tail_seg = self.tail.load(.acquire);

                // Reserve multiple slots with single atomic operation
                const start_idx = self.tail_index.fetchAdd(values.len - written, .monotonic);

                var i: usize = 0;
                while (i < values.len - written) : (i += 1) {
                    const global_idx = start_idx + i;
                    const local_idx = global_idx % SEGMENT_SIZE;

                    // Check if we need to allocate new segment
                    if (local_idx >= SEGMENT_SIZE - values.len) {
                        self.allocateSegment() catch {};
                        break;
                    }

                    const slot = &tail_seg.slots[local_idx];

                    // Try to claim slot
                    if (slot.state.cmpxchgWeak(
                        .Empty,
                        .Writing,
                        .acq_rel,
                        .acquire,
                    )) |_| {
                        continue;
                    }

                    // Write value
                    slot.value.store(values[written + i], .release);
                    slot.state.store(.Ready, .release);
                }

                written += i;
            }

            if (written < values.len) {
                return error.QueueFull;
            }
        }

        /// Batch pop - pop multiple values with single fetchAdd (reduces contention)
        pub fn popBatch(self: *Self, buffer: []T) usize {
            if (buffer.len == 0) return 0;

            var retries: usize = 0;
            const max_retries = 1000;
            var read_count: usize = 0;

            while (read_count < buffer.len and retries < max_retries) : (retries += 1) {
                const head_seg = self.head.load(.acquire);

                // Reserve multiple slots with single atomic operation
                const start_idx = self.head_index.fetchAdd(buffer.len - read_count, .monotonic);

                var i: usize = 0;
                while (i < buffer.len - read_count) : (i += 1) {
                    const global_idx = start_idx + i;
                    const local_idx = global_idx % SEGMENT_SIZE;

                    const slot = &head_seg.slots[local_idx];

                    // Try to claim slot
                    if (slot.state.cmpxchgWeak(
                        .Ready,
                        .Reading,
                        .acq_rel,
                        .acquire,
                    )) |state| {
                        if (state == .Empty) {
                            // Queue is empty - return what we have
                            return read_count + i;
                        }
                        continue;
                    }

                    // Read value
                    const value = slot.value.load(.acquire);

                    // For pointer types (ValueType is optional), check for null
                    // For non-pointer types, value is always valid when state is .Ready
                    if (@typeInfo(T) == .pointer) {
                        if (value) |v| {
                            buffer[read_count + i] = v;
                        } else {
                            // Shouldn't happen but stop if we hit null
                            return read_count + i;
                        }
                    } else {
                        buffer[read_count + i] = value;
                    }

                    slot.state.store(.Empty, .release);

                    // Advance to next segment if needed
                    if (local_idx == SEGMENT_SIZE - 1) {
                        const next = head_seg.next.load(.acquire);
                        if (next) |next_seg| {
                            _ = self.head.cmpxchgStrong(
                                head_seg,
                                next_seg,
                                .acq_rel,
                                .acquire,
                            );
                            // NOTE: Old segment intentionally not freed here to avoid race conditions
                        }
                    }
                }

                read_count += i;
            }

            return read_count;
        }

        /// Allocate new segment (lock-free)
        fn allocateSegment(self: *Self) !void {
            const new_seg = try self.allocator.create(Segment);
            new_seg.* = Segment.init();

            var retries: usize = 0;
            const max_retries = 100;

            while (retries < max_retries) : (retries += 1) {
                const tail_seg = self.tail.load(.acquire);

                // Try to link new segment
                if (tail_seg.next.cmpxchgWeak(
                    null,
                    new_seg,
                    .acq_rel,
                    .acquire,
                )) |_| {
                    // Another thread allocated segment
                    self.allocator.destroy(new_seg);
                    return;
                }

                // Try to advance tail pointer
                if (self.tail.cmpxchgWeak(
                    tail_seg,
                    new_seg,
                    .acq_rel,
                    .acquire,
                )) |_| {
                    continue;
                }

                return;
            }

            self.allocator.destroy(new_seg);
        }
    };
}

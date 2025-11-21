const std = @import("std");
const Allocator = std.mem.Allocator;
const DVyukovMPMCQueue = @import("beam-dvyukov-mpmc").DVyukovMPMCQueue;

pub const CACHE_LINE: usize = std.atomic.cache_line;

pub fn SegmentedList(comptime T: type, comptime segment_capacity: usize) type {
    const InnerQueue = DVyukovMPMCQueue(T, segment_capacity);

    return struct {
        const Self = @This();

        pub const Segment = struct {
            queue: InnerQueue,
            next: std.atomic.Value(?*Segment),
        };

        head_segment: std.atomic.Value(*Segment) align(CACHE_LINE),
        tail_segment: std.atomic.Value(*Segment) align(CACHE_LINE),
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            var first_seg = try allocator.create(Segment);
            errdefer allocator.destroy(first_seg);
            first_seg.queue = try InnerQueue.init(allocator);
            first_seg.next = std.atomic.Value(?*Segment).init(null);

            return .{
                .head_segment = std.atomic.Value(*Segment).init(first_seg),
                .tail_segment = std.atomic.Value(*Segment).init(first_seg),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var seg: ?*Segment = self.head_segment.load(.acquire);
            while (seg) |current| {
                const next = current.next.load(.acquire);
                current.queue.deinit();
                self.allocator.destroy(current);
                seg = next;
            }
        }
    };
}

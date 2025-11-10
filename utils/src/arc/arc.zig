// FILE: arc.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const assert = std.debug.assert;

pub const TaggedPointer = @import("../tagged-pointer/tagged_pointer.zig").TaggedPointer;
pub const ThreadLocalCache = @import("../thread-local-cache/thread_local_cache.zig").ThreadLocalCache;
pub const ArcWeak = @import("arc_weak.zig").ArcWeak;
pub const ArcPool = @import("arc_pool.zig").ArcPool;
pub const ArcCycleDetector = @import("arc_cycle_detector.zig").ArcCycleDetector;

/// A thread-safe, reference-counted smart pointer.
pub fn Arc(comptime T: type) type {
    const Self = @This();
    const SVO_SIZE_THRESHOLD = @sizeOf(usize);
    pub const use_svo = @sizeOf(T) <= SVO_SIZE_THRESHOLD and meta.isCopyable(T);
    pub const SvoPtr = TaggedPointer(*Inner, 1);
    pub const TAG_POINTER: u1 = 0;
    pub const TAG_INLINE: u1 = 1;
    const storage_align = if (use_svo) @alignOf(T) else @alignOf(SvoPtr);

    return struct {
        storage: extern union align(storage_align) {
            tagged_ptr: SvoPtr, inline_data: [SVO_SIZE_THRESHOLD]u8,
        },
        const cache_line = 64;
        pub const Inner = struct {
            counters: Counters, data: T align(cache_line), allocator: Allocator, next_in_freelist: ?*Inner,
        };
        const Counters = struct {
            strong_count: std.atomic.Value(usize), weak_count: std.atomic.Value(usize),
        } align(cache_line);

        pub fn isInline(self: *const Self) bool { if (comptime !use_svo) return false; return self.storage.tagged_ptr.getTag() == TAG_INLINE; }
        pub fn asPtr(self: *const Self) *Inner { assert(!self.isInline()); return self.storage.tagged_ptr.getPtr(); }
        fn asInline(self: *const Self) *const T { assert(self.isInline()); return @ptrCast(@alignCast(&self.storage.inline_data)); }
        fn asInlineMut(self: *Self) *T { assert(self.isInline()); return @ptrCast(@alignCast(&self.storage.inline_data)); }

        pub fn init(allocator: Allocator, value: T) !Self {
            if (comptime use_svo) {
                var self: Self = undefined;
                self.storage.tagged_ptr = try SvoPtr.new(null, TAG_INLINE);
                @memcpy(self.asInlineMut(), &value, @sizeOf(T));
                return self;
            } else {
                const inner = try allocator.create(Inner);
                inner.* = .{ .counters = .{ .strong_count = .init(1), .weak_count = .init(0) }, .data = value, .allocator = allocator, .next_in_freelist = null };
                return .{ .storage = .{ .tagged_ptr = try SvoPtr.new(inner, TAG_POINTER) } };
            }
        }
        pub inline fn clone(self: *const Self) Self {
            if (self.isInline()) return self.*;
            const inner = self.asPtr();
            var old_count = inner.counters.strong_count.load(.monotonic);
            while (true) {
                if (old_count == 0) @panic("Arc: Attempted to clone a deallocated reference");
                if (old_count > std.math.maxInt(usize) / 2) @panic("Arc: Reference count overflow");
                if (inner.counters.strong_count.cmpxchgWeak(old_count, old_count + 1, .monotonic, .monotonic)) |new_old| {
                    old_count = new_old; std.atomic.spinLoopHint(); continue;
                }
                return .{ .storage = self.storage };
            }
        }
        pub inline fn release(self: Self) void {
            if (self.isInline()) return;
            const inner = self.asPtr();
            const old_count = inner.counters.strong_count.fetchSub(1, .release);
            if (old_count == 1) {
                _ = inner.counters.strong_count.load(.acquire);
                @field(inner, "data").~();
                if (inner.counters.weak_count.load(.acquire) == 0) {
                    inner.allocator.destroy(inner);
                }
            }
        }
        pub inline fn get(self: *const Self) *const T { if (self.isInline()) return self.asInline(); return &self.asPtr().data; }
        pub fn strongCount(self: *const Self) usize { if (self.isInline()) return 1; return self.asPtr().counters.strong_count.load(.monotonic); }
        pub fn weakCount(self: *const Self) usize { if (self.isInline()) return 0; return self.asPtr().counters.weak_count.load(.monotonic); }
        pub inline fn downgrade(self: *const Self) ?ArcWeak(T) {
            if (self.isInline()) return null;
            const inner = self.asPtr();
            var sc = inner.counters.strong_count.load(.monotonic);
            while (sc > 0) {
                if (inner.counters.strong_count.cmpxchgWeak(sc, sc, .acquire, .monotonic)) |new_sc| {
                    sc = new_sc; std.atomic.spinLoopHint(); continue;
                }
                _ = inner.counters.weak_count.fetchAdd(1, .monotonic);
                return ArcWeak(T){ .inner = inner };
            }
            return null;
        }
        pub fn tryUnwrap(self: Self) !T {
            if (self.isInline()) return self.asInline().*;
            const inner = self.asPtr();
            if (inner.counters.strong_count.cmpxchgStrong(1, 0, .acquire, .monotonic) != null) return error.NotUnique;
            const value = inner.data;
            if (inner.counters.weak_count.load(.acquire) == 0) inner.allocator.destroy(inner);
            return value;
        }
        pub fn getMutUnique(self: *Self) ?*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) return &self.asPtr().data;
            return null;
        }
        pub fn makeMutWith(self: *Self, cloneFn: *const fn(Allocator, *const T) !T) !*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) return &self.asPtr().data;
            const inner = self.asPtr();
            const new_data = try cloneFn(inner.allocator, &inner.data);
            const new_arc = try Self.init(inner.allocator, new_data);
            self.release();
            self.* = new_arc;
            return &self.asPtr().data;
        }
        pub fn makeMut(self: *Self) !*T {
            comptime meta.require(meta.isCopyable(T), "makeMut requires a copyable type.");
            return self.makeMutWith(defaultClone);
        }
        fn defaultClone(_: Allocator, data: *const T) !T { return data.*; }
        pub inline fn new(allocator: Allocator, value: T) !Self { return init(allocator, value); }
    };
}
// FILE: arc.zig
//! A production-grade, thread-safe, reference-counted smart pointer (`Arc`).
//!
//! This file defines the core `Arc<T>` struct and its primary logic. It serves as the
//! central module for the Arc ecosystem.
//!
//! USAGE WARNING:
//! Zig does not have automatic destructors (RAII/Drop). You MUST manually
//! call `release()` on every Arc instance, typically using `defer`.
//! Failure to do so WILL result in memory leaks.
//!
//! Example:
//! ```zig
//! const arc_module = @import("arc.zig");
//! const Arc = arc_module.Arc(u64);
//! const ArcWeak = arc_module.ArcWeak(u64);
//!
//! var arc = try Arc.init(allocator, 42);
//! // CRITICAL: This defer is mandatory to prevent memory leaks.
//! defer arc.release();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const atomic = std.atomic;
const meta = std.meta;
pub const ArcWeak = @import("arc_weak.zig").ArcWeak;
const TaggedPointer = @import("tagged_pointer").TaggedPointer;
const assert = std.debug.assert;

/// A thread-safe, reference-counted smart pointer, analogous to Rust's `std::sync::Arc`.
pub fn Arc(comptime T: type) type {
    return struct {
        const Self = @This();

        // --- Compile-time Helper Functions (for stable Zig) ---
        fn isPlainData(comptime U: type) bool {
            return switch (@typeInfo(U)) {
                .int, .float, .bool, .@"enum", .void, .array, .vector => true,
                .@"union" => false,
                .@"struct" => |s| {
                    inline for (s.fields) |field| if (!isPlainData(field.type)) return false;
                    return true;
                },
                else => false,
            };
        }
        fn isPointerLike(comptime U: type) bool {
            return switch (@typeInfo(U)) {
                .pointer => true,
                .@"union" => |u| {
                    if (u.tag_type != null and u.fields.len == 2 and u.fields[1].name.len == 0) {
                        return isPointerLike(u.fields[0].type);
                    }
                    return false;
                },
                else => false,
            };
        }

        // --- Public Constants and Configuration ---
        const SVO_SIZE_THRESHOLD = @sizeOf(usize);
        const storage_align = if (use_svo) @alignOf(T) else @alignOf(usize);
        pub const use_svo = @sizeOf(T) <= SVO_SIZE_THRESHOLD and isPlainData(T);
        pub const TAG_POINTER: u1 = 0;
        pub const TAG_INLINE: u1 = 1;

        // --- Private Implementation Details & Component Types ---
        const cache_line = 64;

        const Counters = struct {
            strong_count: atomic.Value(usize),
            weak_count: atomic.Value(usize),
        };

        const Storage = union {
            ptr_with_tag: usize,
            inline_data: [SVO_SIZE_THRESHOLD]u8,
        };
        pub const Inner = struct {
            counters: Counters,
            data: T,
            allocator: Allocator,
            next_in_freelist: ?*Inner,
        };

        const InnerBlock = struct {
            inner: Inner align(cache_line),
        };

        pub const InnerTaggedPtr = TaggedPointer(*Inner, 1);

        pub fn destroyInnerBlock(inner: *Inner) void {
            const block_ptr = @as(*InnerBlock, @ptrFromInt(@intFromPtr(inner)));
            inner.allocator.destroy(block_ptr);
        }

        storage: Storage align(storage_align),

        // --- Private Helper Methods for SVO ---
        pub fn isInline(self: *const Self) bool {
            if (comptime use_svo) return true;
            return self.storage.ptr_with_tag & 1 == TAG_INLINE;
        }
        pub fn asPtr(self: *const Self) *Inner {
            assert(!self.isInline());
            return InnerTaggedPtr.fromUnsigned(self.storage.ptr_with_tag).getPtr();
        }
        fn asInline(self: *const Self) *const T {
            assert(self.isInline());
            return @ptrCast(@alignCast(&self.storage.inline_data));
        }
        fn asInlineMut(self: *Self) *T {
            assert(self.isInline());
            return @ptrCast(@alignCast(&self.storage.inline_data));
        }

        // --- Public API Methods ---

        pub fn init(allocator: Allocator, value: T) !Self {
            if (comptime use_svo) {
                var self: Self = undefined;
                self.storage = .{ .inline_data = undefined };
                @memcpy(std.mem.asBytes(self.asInlineMut()), std.mem.asBytes(&value));
                return self;
            } else {
                const block = try allocator.create(InnerBlock);
                block.inner = .{
                    .counters = .{ .strong_count = .init(1), .weak_count = .init(0) },
                    .data = value,
                    .allocator = allocator,
                    .next_in_freelist = null,
                };
                const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
                return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
        }

        pub fn initWithInitializer(allocator: Allocator, initializer: *const fn (*T) void) !Self {
            if (comptime use_svo) {
                var self: Self = undefined;
                self.storage = .{ .inline_data = undefined };
                const p: *T = @ptrCast(@alignCast(&self.storage.inline_data));
                initializer(p);
                return self;
            } else {
                const block = try allocator.create(InnerBlock);
                block.inner.counters.strong_count.store(1, .monotonic);
                block.inner.counters.weak_count.store(0, .monotonic);
                block.inner.allocator = allocator;
                block.inner.next_in_freelist = null;
                initializer(&block.inner.data);
                const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
                return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
        }

        pub fn initWithInitializerFallible(allocator: Allocator, initializer: *const fn (*T) anyerror!void) !Self {
            if (comptime use_svo) {
                var self: Self = undefined;
                self.storage = .{ .inline_data = undefined };
                const p: *T = @ptrCast(@alignCast(&self.storage.inline_data));
                try initializer(p);
                return self;
            } else {
                const block = try allocator.create(InnerBlock);
                block.inner.counters.strong_count.store(1, .monotonic);
                block.inner.counters.weak_count.store(0, .monotonic);
                block.inner.allocator = allocator;
                block.inner.next_in_freelist = null;
                if (initializer(&block.inner.data)) |_| {
                    const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
                    return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                } else |e| {
                    // free and propagate error
                    allocator.destroy(block);
                    return e;
                }
            }
        }

        /// Create an `Arc<T>` where `T` can capture a `Weak` to itself during initialization.
        /// This is analogous to Rust's `Arc::new_cyclic` and is only supported for heap arcs
        /// (SVO devre dışı). The initializer constructs a value given a temporary `ArcWeak(T)`.
        pub fn newCyclic(allocator: Allocator, ctor: *const fn (ArcWeak(T)) anyerror!T) !Self {
            if (comptime use_svo) {
                @compileError("Arc.newCyclic requires heap allocation; SVO is not supported");
            }
            const block = try allocator.create(InnerBlock);
            block.inner.counters.strong_count.store(1, .monotonic);
            block.inner.counters.weak_count.store(1, .monotonic); // hold a temporary weak during init
            block.inner.allocator = allocator;
            block.inner.next_in_freelist = null;

            var weak = ArcWeak(T){ .inner = &block.inner };
            const value = ctor(weak) catch |e| {
                // roll back allocation
                allocator.destroy(block);
                return e;
            };
            block.inner.data = value;
            // Drop the temporary weak we held during construction
            weak.release();

            const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
            return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
        }

        /// Non-fallible convenience for `newCyclic`.
        pub fn newCyclicNoError(allocator: Allocator, ctor: *const fn (ArcWeak(T)) T) !Self {
            return newCyclic(allocator, struct {
                fn wrap(w: ArcWeak(T)) anyerror!T { return ctor(w); }
            }.wrap);
        }

        pub inline fn clone(self: *const Self) Self {
            if (self.isInline()) return self.*;
            const inner = self.asPtr();
            const prev = inner.counters.strong_count.fetchAdd(1, .monotonic);
            if (prev == 0) @panic("Arc: Attempted to clone a deallocated reference");
            if (comptime builtin.mode != .ReleaseFast) {
                if (prev > std.math.maxInt(usize) / 2) @panic("Arc: Reference count overflow");
            }
            return .{ .storage = self.storage };
        }

        pub inline fn release(self: Self) void {
            if (self.isInline()) return;
            const inner = self.asPtr();
            const old_count = inner.counters.strong_count.fetchSub(1, .release);
            if (old_count == 1) {
                _ = inner.counters.strong_count.load(.acquire);
                // We use compile-time reflection to determine how to deinitialize the data.
                const ti = @typeInfo(T);
                if (comptime ti == .@"struct" or ti == .@"union" or ti == .@"opaque") {
                    if (comptime @hasDecl(T, "deinit")) {
                        const DeinitFn = @TypeOf(T.deinit);
                        const deinit_info = switch (@typeInfo(DeinitFn)) {
                            .@"fn" => |info| info,
                            else => @compileError("Arc<T> expected deinit to be a function"),
                        };

                        if (deinit_info.params.len == 1 and deinit_info.params[0].type.? == *T) {
                            T.deinit(&inner.data);
                        } else if (deinit_info.params.len == 2 and
                            deinit_info.params[0].type.? == *T and
                            deinit_info.params[1].type.? == Allocator)
                        {
                            T.deinit(&inner.data, inner.allocator);
                        } else {
                            @compileError("Arc<T> found a .deinit function on type '" ++ @typeName(T) ++
                                "', but its signature is not supported. Supported signatures are deinit(self: *T) and deinit(self: *T, allocator: Allocator).");
                        }
                    }
                }
                if (inner.counters.weak_count.load(.acquire) == 0) {
                    destroyInnerBlock(inner);
                }
            }
        }

        pub inline fn get(self: *const Self) *const T {
            if (self.isInline()) return self.asInline();
            return &self.asPtr().data;
        }

        pub fn strongCount(self: *const Self) usize {
            if (self.isInline()) return 1;
            return self.asPtr().counters.strong_count.load(.monotonic);
        }

        pub fn weakCount(self: *const Self) usize {
            if (self.isInline()) return 0;
            return self.asPtr().counters.weak_count.load(.monotonic);
        }

        pub inline fn downgrade(self: *const Self) ?ArcWeak(T) {
            if (self.isInline()) return null;
            const inner = self.asPtr();
            var sc = inner.counters.strong_count.load(.monotonic);
            while (sc > 0) {
                if (inner.counters.strong_count.cmpxchgWeak(sc, sc, .acquire, .monotonic)) |new_sc| {
                    sc = new_sc;
                    std.atomic.spinLoopHint();
                    continue;
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
            if (inner.counters.weak_count.load(.acquire) == 0) destroyInnerBlock(inner);
            return value;
        }

        pub fn getMutUnique(self: *Self) ?*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) {
                return &self.asPtr().data;
            }
            return null;
        }

        pub fn makeMutWith(self: *Self, cloneFn: *const fn (Allocator, *const T) anyerror!T) !*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) {
                return &self.asPtr().data;
            }
            const inner = self.asPtr();
            const new_data = try cloneFn(inner.allocator, &inner.data);
            const new_arc = try Self.init(inner.allocator, new_data);
            self.release();
            self.* = new_arc;
            return &self.asPtr().data;
        }

        pub fn makeMut(self: *Self) !*T {
            comptime if (!isPlainData(T)) {
                @compileError("makeMut can only be used with simple data types. Use makeMutWith for complex types like " ++ @typeName(T));
            };
            return self.makeMutWith(defaultClone);
        }

        fn defaultClone(_: Allocator, data: *const T) anyerror!T {
            return data.*;
        }

        pub inline fn new(allocator: Allocator, value: T) !Self {
            return init(allocator, value);
        }
    };
}

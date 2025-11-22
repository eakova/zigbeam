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
const TaggedPointer = @import("beam-tagged-pointer").TaggedPointer;
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
        // Storage must be at least usize-aligned for atomic operations on ptr_with_tag
        const storage_align = @max(@alignOf(T), @alignOf(usize));
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
            /// Optional behavior flags for final-drop. If `auto_call_deinit` is true,
            /// Arc will call `T.deinit` on last-strong-drop when present. If `on_drop`
            /// is provided, it will be invoked before deinit to allow custom cleanup
            /// (e.g., releasing self-held weak references in newCyclic patterns).
            auto_call_deinit: bool = true,
            on_drop: ?*const fn (*T) void = null,
            next_in_freelist: ?*Inner,
        };

        const InnerBlock = struct {
            inner: Inner align(cache_line),
        };

        pub const InnerTaggedPtr = TaggedPointer(*Inner, 1);

        /// Options for cyclic construction behavior.
        pub const CyclicOptions = struct {
            /// If true (default), call `T.deinit` on last-strong-drop when present.
            auto_call_deinit: bool = true,
            /// Optional hook invoked on last-strong-drop before deinit. Useful to
            /// release self-held weak references created during newCyclic.
            on_drop: ?*const fn (*T) void = null,
        };

        pub fn destroyInnerBlock(inner: *Inner) void {
            const block_ptr = @as(*InnerBlock, @ptrFromInt(@intFromPtr(inner)));
            inner.allocator.destroy(block_ptr);
        }

        storage: Storage align(storage_align),

        // --- Private Helper Methods for SVO ---
        /// Returns true if this Arc stores the value inline (SVO path).
        /// Inline arcs do not allocate and always have an implicit strong count of 1.
        pub fn isInline(self: *const Self) bool {
            if (comptime use_svo) return true;
            return self.storage.ptr_with_tag & 1 == TAG_INLINE;
        }
        /// Returns the pointer to the heap `Inner` block.
        /// Precondition: `!isInline()`.
        pub fn asPtr(self: *const Self) *Inner {
            assert(!self.isInline());
            return InnerTaggedPtr.fromUnsigned(self.storage.ptr_with_tag).getPtr();
        }
        /// Returns a const pointer to the inline payload.
        /// Precondition: `isInline()`.
        fn asInline(self: *const Self) *const T {
            assert(self.isInline());
            return @ptrCast(@alignCast(&self.storage.inline_data));
        }
        /// Returns a mutable pointer to the inline payload.
        /// Precondition: `isInline()`.
        fn asInlineMut(self: *Self) *T {
            assert(self.isInline());
            return @ptrCast(@alignCast(&self.storage.inline_data));
        }

        // --- Public API Methods ---

        /// Create a new Arc from a value.
        /// SVO types are stored inline; otherwise a heap `Inner` block is allocated.
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
                    .auto_call_deinit = true,
                    .on_drop = null,
                    .next_in_freelist = null,
                };
                const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
                return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
        }

        /// Create a new Arc and initialize the payload in-place via `initializer`.
        /// Avoids copying large `T` values.
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
                block.inner.auto_call_deinit = true;
                block.inner.on_drop = null;
                block.inner.next_in_freelist = null;
                initializer(&block.inner.data);
                const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
                return .{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
        }

        /// Fallible variant of `initWithInitializer`.
        /// If `initializer` errors, the allocation is freed and the error is returned.
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
                block.inner.auto_call_deinit = true;
                block.inner.on_drop = null;
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
            return newCyclicWithOptions(allocator, ctor, .{});
        }

        /// Same as `newCyclic` but allows customizing final-drop behavior.
        pub fn newCyclicWithOptions(allocator: Allocator, ctor: *const fn (ArcWeak(T)) anyerror!T, opts: CyclicOptions) !Self {
            if (comptime use_svo) {
                @compileError("Arc.newCyclic requires heap allocation; SVO is not supported");
            }
            const o: CyclicOptions = opts;
            const block = try allocator.create(InnerBlock);
            block.inner.counters.strong_count.store(1, .monotonic);
            block.inner.counters.weak_count.store(1, .monotonic); // hold a temporary weak during init
            block.inner.allocator = allocator;
            block.inner.auto_call_deinit = o.auto_call_deinit;
            block.inner.on_drop = o.on_drop;
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
            return newCyclicWithOptions(allocator, struct {
                fn wrap(w: ArcWeak(T)) anyerror!T { return ctor(w); }
            }.wrap, .{});
        }

        /// Non-fallible variant with options.
        pub fn newCyclicNoErrorWithOptions(allocator: Allocator, ctor: *const fn (ArcWeak(T)) T, opts: CyclicOptions) !Self {
            return newCyclicWithOptions(allocator, struct {
                fn wrap(w: ArcWeak(T)) anyerror!T { return ctor(w); }
            }.wrap, opts);
        }

        /// Increase the strong count and return another Arc to the same value.
        /// For inline arcs, this is a cheap copy.
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

        /// Drop one strong reference. When the last strong drops, runs `deinit`
        /// on `T` if present, and destroys the `Inner` when no weaks remain.
        pub inline fn release(self: Self) void {
            if (self.isInline()) return;
            const inner = self.asPtr();
            const old_count = inner.counters.strong_count.fetchSub(1, .release);
            if (old_count == 1) {
                _ = inner.counters.strong_count.load(.acquire);
                // Optional user-provided drop hook (e.g., release self-held weak refs)
                if (inner.on_drop) |hook| hook(&inner.data);
                // Deinit on final strong drop (if enabled and present on T)
                if (inner.auto_call_deinit) {
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
                            } else if (deinit_info.params.len == 2 and deinit_info.params[0].type.? == *T and deinit_info.params[1].type.? == Allocator) {
                                T.deinit(&inner.data, inner.allocator);
                            } else {
                                @compileError("Arc<T> found a .deinit function on type '" ++ @typeName(T) ++ "', but its signature is not supported. Supported signatures are deinit(self: *T) and deinit(self: *T, allocator: Allocator).");
                            }
                        }
                    }
                }
                if (inner.counters.weak_count.load(.acquire) == 0) {
                    destroyInnerBlock(inner);
                }
            }
        }

        /// Borrow a const pointer to the payload.
        pub inline fn get(self: *const Self) *const T {
            if (self.isInline()) return self.asInline();
            return &self.asPtr().data;
        }

        /// Current strong reference count (1 for inline arcs).
        pub fn strongCount(self: *const Self) usize {
            if (self.isInline()) return 1;
            return self.asPtr().counters.strong_count.load(.monotonic);
        }

        /// Current weak reference count (0 for inline arcs).
        pub fn weakCount(self: *const Self) usize {
            if (self.isInline()) return 0;
            return self.asPtr().counters.weak_count.load(.monotonic);
        }

        /// Convert a strong reference into a weak reference without changing
        /// liveness. Returns null if already deallocated.
        pub inline fn downgrade(self: *const Self) ?ArcWeak(T) {
            if (self.isInline()) return null;
            const inner = self.asPtr();

            // We hold a strong reference (&const Self), so strong_count >= 1.
            // Simply increment weak_count with acquire ordering to synchronize with
            // any concurrent operations, then return the weak reference.
            _ = inner.counters.weak_count.fetchAdd(1, .acquire);
            return ArcWeak(T){ .inner = inner };
        }

        /// Try to take ownership of the payload. Succeeds only when this is the
        /// unique strong owner. Otherwise returns error.NotUnique.
        pub fn tryUnwrap(self: Self) !T {
            if (self.isInline()) return self.asInline().*;
            const inner = self.asPtr();
            if (inner.counters.strong_count.cmpxchgStrong(1, 0, .acquire, .monotonic) != null) return error.NotUnique;
            const value = inner.data;
            if (inner.counters.weak_count.load(.acquire) == 0) destroyInnerBlock(inner);
            return value;
        }

        /// Get a mutable pointer if this Arc is the unique strong owner.
        /// For inline arcs, always returns the inline pointer.
        pub fn getMutUnique(self: *Self) ?*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) {
                return &self.asPtr().data;
            }
            return null;
        }

        /// Ensure unique ownership; if shared, clone the payload with `cloneFn`.
        /// Returns a mutable pointer to the owned payload.
        ///
        /// IMPORTANT: This preserves the original Arc's options (auto_call_deinit, on_drop)
        /// when creating the cloned Arc, ensuring semantic consistency.
        pub fn makeMutWith(self: *Self, cloneFn: *const fn (Allocator, *const T) anyerror!T) !*T {
            if (self.isInline()) return self.asInlineMut();
            if (self.asPtr().counters.strong_count.load(.monotonic) == 1) {
                return &self.asPtr().data;
            }
            const old_inner = self.asPtr();
            const new_data = try cloneFn(old_inner.allocator, &old_inner.data);

            // Create new Inner manually to preserve options from old_inner
            const block = try old_inner.allocator.create(InnerBlock);
            block.inner.counters.strong_count.store(1, .monotonic);
            block.inner.counters.weak_count.store(0, .monotonic);
            block.inner.allocator = old_inner.allocator;
            block.inner.auto_call_deinit = old_inner.auto_call_deinit; // PRESERVE
            block.inner.on_drop = old_inner.on_drop; // PRESERVE
            block.inner.next_in_freelist = null;
            block.inner.data = new_data;

            const tagged = InnerTaggedPtr.new(&block.inner, TAG_POINTER) catch unreachable;
            const new_arc = Self{ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };

            self.release();
            self.* = new_arc;
            return &self.asPtr().data;
        }

        /// Ensure unique ownership with a default copy for plain data types.
        /// Use `makeMutWith` for types that need a custom clone.
        pub fn makeMut(self: *Self) !*T {
            comptime if (!isPlainData(T)) {
                @compileError("makeMut can only be used with simple data types. Use makeMutWith for complex types like " ++ @typeName(T));
            };
            return self.makeMutWith(defaultClone);
        }

        /// Default clone function for plain data.
        fn defaultClone(_: Allocator, data: *const T) anyerror!T {
            return data.*;
        }

        /// Alias for `init` for API familiarity.
        pub inline fn new(allocator: Allocator, value: T) !Self {
            return init(allocator, value);
        }

        // --- Atomic Operations (for concurrent pointer swaps) ---

        /// Atomically load an Arc from a memory location and safely increment its refcount.
        ///
        /// This solves three problems:
        /// 1. Works around Zig's limitation (can't atomic load/store Arc structs)
        /// 2. Enables safe concurrent pointer swaps
        /// 3. Eliminates TOCTOU races by atomically loading + incrementing refcount
        ///
        /// PERFORMANCE NOTE: This is a relatively expensive operation (2-3 atomic ops):
        /// - Atomic load of tagged pointer
        /// - Atomic fetchAdd to increment refcount
        /// - Check if Arc was deallocated (refcount was 0)
        /// - Possible atomic fetchSub if deallocated
        ///
        /// For better performance, consider alternatives when applicable:
        /// - atomicSwap: Move ownership without extra refcount manipulation (1 atomic op)
        /// - atomicStore: Replace and auto-release old value (1 atomic op)
        /// - clone(): If you already hold a reference (1 atomic op)
        ///
        /// Returns null if the Arc was deallocated (refcount == 0).
        ///
        /// Example:
        /// ```zig
        /// var shared_arc: Arc(Buffer) = ...;
        ///
        /// // Thief thread safely loads the Arc:
        /// if (Arc(Buffer).atomicLoad(&shared_arc, .acquire)) |arc| {
        ///     defer arc.release();
        ///     // Safe to use arc here
        /// }
        /// ```
        pub fn atomicLoad(arc_ptr: *const Self, comptime ordering: std.builtin.AtomicOrder) ?Self {
            // Use atomic load on storage for both SVO and non-SVO types.
            // We use @ptrCast to treat the storage as a usize for atomic operations,
            // bypassing union field tracking while maintaining memory safety.
            const storage_ptr: *const usize = @ptrCast(&arc_ptr.storage);
            const raw_value = @atomicLoad(usize, storage_ptr, ordering);

            if (comptime use_svo) {
                // SVO types: reconstruct with inline_data as the active union field
                // Copy the raw bytes into inline_data to set the correct union variant
                var inline_bytes: [SVO_SIZE_THRESHOLD]u8 = undefined;
                @memcpy(&inline_bytes, std.mem.asBytes(&raw_value));
                return Self{ .storage = .{ .inline_data = inline_bytes } };
            }

            const tagged_ptr = raw_value;

            // Construct temporary Arc from the loaded pointer
            const arc_temp = Self{ .storage = .{ .ptr_with_tag = tagged_ptr } };

            // Get the Inner pointer (checking if it's inline/heap)
            if (arc_temp.isInline()) {
                return arc_temp;
            }

            const inner = arc_temp.asPtr();

            // Safely increment the refcount BEFORE using the Arc
            const prev_count = inner.counters.strong_count.fetchAdd(1, .monotonic);

            if (prev_count == 0) {
                // Arc was deallocated - undo our increment and return null
                _ = inner.counters.strong_count.fetchSub(1, .monotonic);
                return null;
            }

            // Overflow check (only in debug builds)
            if (comptime builtin.mode != .ReleaseFast) {
                if (prev_count > std.math.maxInt(usize) / 2) {
                    @panic("Arc: Reference count overflow in atomicLoad");
                }
            }

            // Return the safely loaded Arc with incremented refcount
            return arc_temp;
        }

        /// Atomically store an Arc to a memory location.
        ///
        /// The previous Arc at the location is released (refcount decremented).
        /// The new Arc's refcount is NOT incremented - this is a move operation.
        ///
        /// Example:
        /// ```zig
        /// var shared_arc: Arc(Buffer) = old_buffer;
        /// const new_arc = try Arc(Buffer).init(allocator, new_buffer);
        ///
        /// // Atomically replace old_buffer with new_buffer
        /// Arc(Buffer).atomicStore(&shared_arc, new_arc, .release);
        /// ```
        pub fn atomicStore(arc_ptr: *Self, new_value: Self, comptime ordering: std.builtin.AtomicOrder) void {
            // Use atomic exchange on storage for both SVO and non-SVO types.
            // We use @ptrCast to treat the storage as a usize for atomic operations.
            const storage_ptr: *usize = @ptrCast(&arc_ptr.storage);
            const new_storage_ptr: *const usize = @ptrCast(&new_value.storage);
            const old_tagged = @atomicRmw(usize, storage_ptr, .Xchg, new_storage_ptr.*, ordering);

            if (comptime use_svo) {
                // SVO types don't have refcounts, nothing to release
                return;
            }

            // Release the old Arc (decrement its refcount)
            const old_arc = Self{ .storage = .{ .ptr_with_tag = old_tagged } };
            old_arc.release();
        }

        /// Atomically swap an Arc with a new value, returning the old Arc.
        ///
        /// This is a compare-free atomic swap operation.
        ///
        /// Example:
        /// ```zig
        /// var shared_arc: Arc(Buffer) = old_buffer;
        /// const new_arc = try Arc(Buffer).init(allocator, new_buffer);
        ///
        /// // Atomically swap and get the old value
        /// const old_arc = Arc(Buffer).atomicSwap(&shared_arc, new_arc, .acq_rel);
        /// defer old_arc.release(); // Don't forget to release the old Arc!
        /// ```
        pub fn atomicSwap(arc_ptr: *Self, new_value: Self, comptime ordering: std.builtin.AtomicOrder) Self {
            // Use atomic exchange on storage for both SVO and non-SVO types.
            // We use @ptrCast to treat the storage as a usize for atomic operations.
            const storage_ptr: *usize = @ptrCast(&arc_ptr.storage);
            const new_storage_ptr: *const usize = @ptrCast(&new_value.storage);
            const old_raw = @atomicRmw(usize, storage_ptr, .Xchg, new_storage_ptr.*, ordering);

            if (comptime use_svo) {
                // SVO types: reconstruct with inline_data as the active union field
                var inline_bytes: [SVO_SIZE_THRESHOLD]u8 = undefined;
                @memcpy(&inline_bytes, std.mem.asBytes(&old_raw));
                return Self{ .storage = .{ .inline_data = inline_bytes } };
            }

            // Return the old Arc (caller is responsible for releasing it)
            return Self{ .storage = .{ .ptr_with_tag = old_raw } };
        }

        /// Atomically compare-and-swap an Arc.
        ///
        /// If the current value equals `expected`, atomically replaces it with `new_value`.
        /// Returns the previous value (which may not equal `expected` if CAS failed).
        ///
        /// This is useful for lock-free algorithms that need conditional updates.
        ///
        /// Example:
        /// ```zig
        /// var shared_arc: Arc(Buffer) = old_buffer;
        /// const expected = old_buffer.clone();
        /// defer expected.release();
        /// const new_arc = try Arc(Buffer).init(allocator, new_buffer);
        ///
        /// const prev = Arc(Buffer).atomicCompareSwap(&shared_arc, expected, new_arc, .acq_rel, .acquire);
        /// defer prev.release();
        ///
        /// if (Arc(Buffer).ptrEqual(prev, expected)) {
        ///     // CAS succeeded
        /// } else {
        ///     // CAS failed, prev contains the actual current value
        ///     new_arc.release(); // We didn't use new_arc, so release it
        /// }
        /// ```
        pub fn atomicCompareSwap(
            arc_ptr: *Self,
            expected: Self,
            new_value: Self,
            comptime success_order: std.builtin.AtomicOrder,
            comptime failure_order: std.builtin.AtomicOrder,
        ) Self {
            // Use atomic CAS on storage for both SVO and non-SVO types.
            // We use @ptrCast to treat the storage as a usize for atomic operations.
            const storage_ptr: *usize = @ptrCast(&arc_ptr.storage);
            const expected_ptr: *const usize = @ptrCast(&expected.storage);
            const new_ptr: *const usize = @ptrCast(&new_value.storage);
            const prev_raw = @cmpxchgStrong(
                usize,
                storage_ptr,
                expected_ptr.*,
                new_ptr.*,
                success_order,
                failure_order,
            ) orelse expected_ptr.*; // If CAS succeeded, prev = expected

            if (comptime use_svo) {
                // SVO types: reconstruct with inline_data as the active union field
                var inline_bytes: [SVO_SIZE_THRESHOLD]u8 = undefined;
                @memcpy(&inline_bytes, std.mem.asBytes(&prev_raw));
                return Self{ .storage = .{ .inline_data = inline_bytes } };
            }

            return Self{ .storage = .{ .ptr_with_tag = prev_raw } };
        }

        /// Compare two Arcs for pointer equality (do they point to the same Inner?).
        ///
        /// This is useful for checking if an atomicCompareSwap succeeded.
        ///
        /// Example:
        /// ```zig
        /// const arc1 = try Arc(u32).init(allocator, 42);
        /// const arc2 = arc1.clone();
        /// const arc3 = try Arc(u32).init(allocator, 42);
        ///
        /// Arc(u32).ptrEqual(arc1, arc2); // true (same Inner)
        /// Arc(u32).ptrEqual(arc1, arc3); // false (different Inner, even though data is same)
        /// ```
        pub fn ptrEqual(a: Self, b: Self) bool {
            if (comptime use_svo) {
                // SVO arcs are always distinct
                return false;
            }
            return a.storage.ptr_with_tag == b.storage.ptr_with_tag;
        }
    };
}

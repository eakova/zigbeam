//! Box<T> — Rust-like unique owning heap pointer for Zig
//!
//! Minimal, zero-fuss heap ownership utility mirroring Rust's Box.
//!
//! Features:
//! - Unique ownership of `T` allocated on the heap
//! - `init(allocator, value)` to allocate and take ownership
//! - `get()`/`getMut()` to access the inner value
//! - `replace(new)` to swap value, returning old by value
//! - `intoRaw()`/`fromRaw()` for raw pointer handoff/rehydration
//! - `intoValue()` to move the value out and free allocation
//! - `release()` to destroy value (if it has `deinit`) and free memory
//!
//! Notes:
//! - As in Zig, structs are copyable by default. Treat Box<T> as move-only by
//!   convention. Do not copy values; pass by `var` and consume methods that take `Self`.
//! - If `T` defines `deinit(self: *T)`, `release()` will call it before freeing.
//! - `intoValue()` returns the value by move and will not call `deinit` on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub fn Box(comptime T: type) type {
    return struct {
        ptr: *T,
        allocator: Allocator,
        // Debug move-only guard (active in non-ReleaseFast)
        debug_moved: bool = false,

        const Self = @This();

        /// Allocate on the heap and construct a Box owning `value`.
        pub fn init(allocator: Allocator, value: T) !Self {
            const p = try allocator.create(T);
            p.* = value;
            return .{ .ptr = p, .allocator = allocator };
        }

        /// Adopt an existing heap-allocated pointer as a Box.
        /// The pointer must have been allocated with the same allocator and
        /// must point to a valid `T`.
        pub inline fn fromRaw(allocator: Allocator, raw: *T) Self {
            return .{ .ptr = raw, .allocator = allocator };
        }

        /// Hand ownership of the raw pointer to the caller. After this call
        /// the memory is no longer managed by this Box and must be freed by
        /// the caller (e.g. via `allocator.destroy(ptr)`).
        pub inline fn intoRaw(self: *Self) *T {
            self.dbgAssertAlive();
            const p = self.ptr;
            self.dbgMarkMoved();
            return p;
        }

        /// Leak the allocation deliberately and return the raw pointer.
        /// The caller becomes responsible for eventually freeing the memory.
        /// This does not call `deinit` on the value.
        pub inline fn leak(self: *Self) *T {
            self.dbgAssertAlive();
            const p = self.ptr;
            self.dbgMarkMoved();
            return p; // allocation intentionally not freed
        }

        /// Move the inner value out and free the allocation. Does not call
        /// `deinit` on the value (ownership is transferred to the caller).
        pub fn intoValue(self: *Self) T {
            self.dbgAssertAlive();
            const value = self.ptr.*;
            const alloc = self.allocator;
            self.dbgMarkMoved();
            alloc.destroy(self.ptr);
            return value;
        }

        /// Get immutable access to the inner value.
        pub inline fn get(self: *const Self) *const T {
            self.dbgAssertAlive();
            return self.ptr;
        }

        /// Get mutable access to the inner value.
        pub inline fn getMut(self: *Self) *T {
            self.dbgAssertAlive();
            return self.ptr;
        }

        /// Alias for getMut()
        pub inline fn asPtr(self: *Self) *T {
            return self.getMut();
        }

        /// Alias for get()
        pub inline fn asConstPtr(self: *const Self) *const T {
            return self.get();
        }

        /// If T is an array [N]E, return a mutable slice view []E.
        pub inline fn asSliceMut(self: *Self) switch (@typeInfo(T)) {
            .Array => []@typeInfo(T).Array.child,
            else => @compileError("asSliceMut requires T to be an array"),
        } {
            comptime {
                if (@typeInfo(T) != .Array) @compileError("asSliceMut requires array T");
            }
            const Elem = @typeInfo(T).Array.child;
            const N = @typeInfo(T).Array.len;
            const p: *[N]Elem = @ptrCast(self.ptr);
            return p[0..];
        }

        /// If T is an array [N]E, return a const slice view []const E.
        pub inline fn asSlice(self: *const Self) switch (@typeInfo(T)) {
            .Array => []const @typeInfo(T).Array.child,
            else => @compileError("asSlice requires T to be an array"),
        } {
            comptime {
                if (@typeInfo(T) != .Array) @compileError("asSlice requires array T");
            }
            const Elem = @typeInfo(T).Array.child;
            const N = @typeInfo(T).Array.len;
            const p: *const [N]Elem = @ptrCast(self.ptr);
            return p[0..];
        }

        /// Replace the inner value, returning the previous value by move.
        pub inline fn replace(self: *Self, new_value: T) T {
            const old = self.ptr.*;
            self.ptr.* = new_value;
            return old;
        }

        /// Take the inner value and replace with the provided `replacement`.
        pub inline fn takeReplace(self: *Self, replacement: T) T {
            const old = self.ptr.*;
            self.ptr.* = replacement;
            return old;
        }

        /// Reallocate this Box to a new allocator by moving the value.
        pub fn reallocTo(self: *Self, new_allocator: Allocator) !Self {
            const val = self.intoValue();
            return try Box(T).init(new_allocator, val);
        }

        /// Destroy the owned value (if it has `deinit`) and free memory.
        pub inline fn release(self: *Self) void {
            self.dbgAssertAlive();
            inlineDeinit(self.ptr, self.allocator);
            self.allocator.destroy(self.ptr);
            self.dbgMarkMoved();
        }

        /// Skip calling `deinit` and just free memory.
        pub inline fn forget(self: *Self) void {
            self.dbgAssertAlive();
            self.allocator.destroy(self.ptr);
            self.dbgMarkMoved();
        }

        /// Construct a Box by allocating first, then letting `init_fn` initialize in place.
        /// `init_fn` signature can be `fn (*T) void` or `fn (*T) !void`.
        pub fn initWith(allocator: Allocator, init_fn: anytype) !Self {
            const p = try allocator.create(T);
            var ok = false;
            defer if (!ok) allocator.destroy(p);

            const f_info = @typeInfo(@TypeOf(init_fn));
            if (f_info != .Fn) @compileError("initWith expects a function");
            const ret_info = f_info.Fn.return_type orelse void;
            const is_error = @typeInfo(ret_info) == .ErrorUnion;

            if (is_error) {
                try init_fn(p);
            } else {
                init_fn(p);
            }

            ok = true;
            return .{ .ptr = p, .allocator = allocator };
        }

        /// Transform the inner value to a new Box<U>, consuming `self`.
        /// Supports both pointer and value mapping forms:
        ///   - fn(*T) U | !U (reads via pointer, no extra copy)
        ///   - fn(T) U | !U (consumes value, frees allocation)
        pub fn map(self: *Self, comptime U: type, f: anytype) !Box(U) {
            const info = @typeInfo(@TypeOf(f));
            if (info != .Fn) @compileError("map expects a function");
            const finfo = info.Fn;
            if (finfo.params.len != 1) @compileError("map expects unary function");
            const ret_ty = finfo.return_type orelse void;
            const is_error = @typeInfo(ret_ty) == .ErrorUnion;

            const P0 = finfo.params[0].type orelse @compileError("param type required");
            const p0_info = @typeInfo(P0);

            if (p0_info == .Pointer and p0_info.Pointer.child == T) {
                // Pointer mapping: call f(self.ptr), then free old allocation (no deinit), box new value
                const new_val = if (is_error) try f(self.ptr) else f(self.ptr);
                const alloc = self.allocator;
                // Since we are not moving out the value, call deinit if present
                deinitIfPresent(self.ptr, self.allocator);
                self.dbgMarkMoved();
                alloc.destroy(self.ptr);
                return try Box(U).init(alloc, new_val);
            } else if (P0 == T) {
                // Value mapping: move out value and free allocation via intoValue
                const val = self.intoValue();
                const new_val = if (is_error) try f(val) else f(val);
                return try Box(U).init(self.allocator, new_val);
            } else {
                @compileError("map expects parameter T or *T");
            }
        }

        /// In-place transform: apply `f` to mutate or replace inner value.
        /// Supports both pointer and value forms:
        ///   - fn(*T) void | !void (mutate in place)
        ///   - fn(T) T | !T (replace by returned value)
        pub fn mapInPlace(self: *Self, f: anytype) !void {
            const info = @typeInfo(@TypeOf(f));
            if (info != .Fn) @compileError("mapInPlace expects a function");
            const finfo = info.Fn;
            if (finfo.params.len != 1) @compileError("mapInPlace expects unary function");
            const ret_ty = finfo.return_type orelse void;
            const is_err = @typeInfo(ret_ty) == .ErrorUnion;
            const P0 = finfo.params[0].type orelse @compileError("param type required");
            const p0_info = @typeInfo(P0);

            if (p0_info == .Pointer and p0_info.Pointer.child == T) {
                // Pointer mutate
                if (is_err) {
                    try f(self.ptr);
                } else {
                    f(self.ptr);
                }
            } else if (P0 == T) {
                // By-value transform: compute new first, then deinit old, then overwrite
                const old = self.ptr.*;
                const new_val = if (is_err) try f(old) else f(old);
                deinitIfPresent(self.ptr, self.allocator);
                self.ptr.* = new_val;
                ok = true;
            } else {
                @compileError("mapInPlace expects parameter T or *T");
            }
        }

        /// Rebox this allocation as a different type U by computing a new value and
        /// writing it into the same memory block. This avoids an extra allocate/free pair.
        /// Constraints enforced at comptime:
        ///   - @sizeOf(U) <= @sizeOf(T)
        ///   - @alignOf(T) >= @alignOf(U)
        /// Supports `fn(*T)->U|!U` and `fn(T)->U|!U` mapping forms.
        pub fn rebox(self: *Self, comptime U: type, f: anytype) !Box(U) {
            comptime {
                if (!(@sizeOf(U) <= @sizeOf(T)))
                    @compileError("rebox requires @sizeOf(U) <= @sizeOf(T)");
                if (!(@alignOf(T) >= @alignOf(U)))
                    @compileError("rebox requires @alignOf(T) >= @alignOf(U)");
            }

            const info = @typeInfo(@TypeOf(f));
            if (info != .Fn) @compileError("rebox expects a function");
            const finfo = info.Fn;
            if (finfo.params.len != 1) @compileError("rebox expects unary function");
            const ret_ty = finfo.return_type orelse void;
            const is_err = @typeInfo(ret_ty) == .ErrorUnion;
            const P0 = finfo.params[0].type orelse @compileError("param type required");
            const p0_info = @typeInfo(P0);

            // Compute new value first (without mutating old), then deinit old, then overwrite
            var new_val: U = undefined;
            if (p0_info == .Pointer and p0_info.Pointer.child == T) {
                new_val = if (is_err) try f(self.ptr) else f(self.ptr);
            } else if (P0 == T) {
                const old = self.ptr.*;
                new_val = if (is_err) try f(old) else f(old);
            } else {
                @compileError("rebox expects parameter T or *T");
            }

            // Deinit old T, then write U in-place
            deinitIfPresent(self.ptr, self.allocator);
            const raw_u: *U = @ptrCast(@alignCast(self.ptr));
            raw_u.* = new_val;

            // Mark moved and return Box(U) reusing the same block
            self.dbgMarkMoved();
            return Box(U).fromRaw(self.allocator, raw_u);
        }

        /// Deep clone into a new Box by calling `T.clone(...)` when available.
        /// Supported signatures (in order of preference):
        ///   - fn clone(self: *const T, allocator: Allocator) !T
        ///   - fn clone(self: *const T, allocator: Allocator) T
        ///   - fn clone(self: *const T) !T
        ///   - fn clone(self: *const T) T
        pub fn cloneDeep(self: *const Self) !Self {
            if (!@hasDecl(T, "clone")) @compileError("cloneDeep requires T.clone");
            const FnT = @TypeOf(T.clone);
            if (@typeInfo(FnT) != .Fn) @compileError("T.clone must be a function");
            const info = @typeInfo(FnT).Fn;
            const ret_ty = info.return_type orelse void;
            const is_error = @typeInfo(ret_ty) == .ErrorUnion;
            if (info.params.len == 2) {
                if (info.params[1].type) |P1| {
                    if (P1 != Allocator) @compileError("clone(self, Allocator) expected");
                } else @compileError("clone(self, Allocator) expected");
                const new_val = if (is_error)
                    try T.clone(self.ptr, self.allocator)
                else
                    T.clone(self.ptr, self.allocator);
                const p = try self.allocator.create(T);
                p.* = new_val;
                return .{ .ptr = p, .allocator = self.allocator };
            } else if (info.params.len == 1) {
                const new_val = if (is_error)
                    try T.clone(self.ptr)
                else
                    T.clone(self.ptr);
                const p = try self.allocator.create(T);
                p.* = new_val;
                return .{ .ptr = p, .allocator = self.allocator };
            } else {
                @compileError("Unsupported clone signature for T");
            }
        }

        /// Swap current inner value with `*other` in place.
        pub inline fn swap(self: *Self, other: *T) void {
            std.mem.swap(T, self.ptr, other);
        }

        inline fn dbgAssertAlive(self: *const Self) void {
            if (comptime builtin.mode != .ReleaseFast) {
                std.debug.assert(!self.debug_moved);
            }
        }

        inline fn dbgMarkMoved(self: *Self) void {
            if (comptime builtin.mode != .ReleaseFast) {
                self.debug_moved = true;
            }
        }
    };
}

/// Allocate uninitialized memory for `T` and wrap it in `Box(MaybeUninit(T))`.
pub fn initUninit(comptime T: type, allocator: Allocator) !Box(std.mem.MaybeUninit(T)) {
    const MU = std.mem.MaybeUninit(T);
    const p = try allocator.create(MU);
    return .{ .ptr = p, .allocator = allocator };
}

/// Assume the `Box(MaybeUninit(T))` is initialized and rewrap as `Box(T)`.
/// Caller must guarantee initialization; no checks performed.
pub fn assumeInitBox(comptime T: type, b: *Box(std.mem.MaybeUninit(T))) Box(T) {
    const raw_mu: *std.mem.MaybeUninit(T) = b.intoRaw();
    // Reinterpret pointer to *T; contents must be initialized by caller contract.
    const raw_t: *T = @ptrCast(raw_mu);
    return Box(T).fromRaw(b.allocator, raw_t);
}

/// Internal: compile-time deinit dispatcher. Only compiles the valid call-site.
inline fn inlineDeinit(comptime_ptr: anytype, allocator: Allocator) void {
    const PtrT = @TypeOf(comptime_ptr);
    const T = @typeInfo(PtrT).Pointer.child;
    comptime {
        if (!@hasDecl(T, "deinit")) return;
        const FnT = @TypeOf(T.deinit);
        if (@typeInfo(FnT) != .Fn) return;
        const info = @typeInfo(FnT).Fn;
        if (info.params.len == 1) {
            // fn deinit(self: *T)
            return;
        } else if (info.params.len == 2) {
            // fn deinit(self: *T, allocator: Allocator)
            if (info.params[1].type) |P1| {
                if (P1 != Allocator) {
                    // not supported; treat as no-op
                    return;
                }
            } else return;
        } else return;
    }
    // Runtime portion emits only the matching call because the branches above are comptime.
    if (comptime @hasDecl(T, "deinit")) {
        if (comptime @typeInfo(@TypeOf(T.deinit)) == .Fn) {
            const info = @typeInfo(@TypeOf(T.deinit)).Fn;
            if (comptime info.params.len == 1) {
                comptime {
                    // ensure signature is fn(*T) ...
                }
                comptime_ptr.deinit();
            } else if (comptime info.params.len == 2) {
                comptime_ptr.deinit(allocator);
            }
        }
    }
}

/// Simple lock-free-ish freelist pool for Box(T) to reduce allocator pressure.
/// Node layout keeps `payload` first so we can recover Node from *T.
pub fn BoxPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct { payload: T, next: ?*Node = null };
        head: ?*Node = null,
        allocator: Allocator,
        free_count: usize = 0,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var cur = self.head;
            while (cur) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                cur = next;
            }
            self.head = null;
            self.free_count = 0;
        }

        inline fn nodeFromPayload(self: *Self, p: *T) *Node {
            _ = self;
            return @fieldParentPtr(Node, "payload", p);
        }

        pub fn alloc(self: *Self) !*T {
            if (self.head) |n| {
                self.head = n.next;
                self.free_count -= 1;
                return &n.payload;
            }
            const n = try self.allocator.create(Node);
            return &n.payload;
        }

        pub fn free(self: *Self, p: *T) void {
            const n = self.nodeFromPayload(p);
            n.next = self.head;
            self.head = n;
            self.free_count += 1;
        }

        /// Pre-allocate `count` nodes into the freelist to reduce future allocator calls.
        pub fn reserve(self: *Self, count: usize) !void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const n = try self.allocator.create(Node);
                n.next = self.head;
                self.head = n;
                self.free_count += 1;
            }
        }

        pub inline fn available(self: *const Self) usize {
            return self.free_count;
        }

        /// Allocate up to out.len items into out; returns number allocated.
        pub fn allocBatch(self: *Self, out: [](*T)) usize {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                if (self.head) |n| {
                    self.head = n.next;
                    self.free_count -= 1;
                    out[i] = &n.payload;
                } else {
                    const n = self.allocator.create(Node) catch break;
                    out[i] = &n.payload;
                }
            }
            return i;
        }

        /// Free a batch of pointers back to the pool.
        pub fn freeBatch(self: *Self, items: [](*T)) void {
            var i: usize = 0;
            while (i < items.len) : (i += 1) {
                const n = self.nodeFromPayload(items[i]);
                n.next = self.head;
                self.head = n;
                self.free_count += 1;
            }
        }

        /// Release nodes back to allocator so that at most `target_free` remain available.
        pub fn trimTo(self: *Self, target_free: usize) void {
            while (self.free_count > target_free and self.head != null) {
                const n = self.head.?;
                self.head = n.next;
                self.allocator.destroy(n);
                self.free_count -= 1;
            }
        }
    };
}

/// Box helpers for using BoxPool without changing Box internals
pub fn initFromPool(comptime T: type, pool: *BoxPool(T), value: T) !Box(T) {
    const p = try pool.alloc();
    p.* = value;
    return .{ .ptr = p, .allocator = pool.allocator };
}

pub fn releaseToPool(comptime T: type, b: *Box(T), pool: *BoxPool(T)) void {
    // do not call deinit; pool manages raw memory lifecycle
    pool.free(b.ptr);
    if (comptime builtin.mode != .ReleaseFast) b.debug_moved = true;
}

/// A thread-safe pool using a lock-free Treiber stack.
pub fn ThreadSafeBoxPool(comptime T: type) type {
    return struct {
        const Self = @This();
        const TAG_ALIGN: usize = 16;
        const TAG_MASK: usize = TAG_ALIGN - 1;
        const Node = struct align(TAG_ALIGN) { payload: T, next: ?*Node };
        head_tagged: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        allocator: Allocator,
        approx_free: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        // Deferred free list to avoid ABA when trimming under concurrency
        trash: std.atomic.Value(?*Node) = std.atomic.Value(?*Node).init(null),
        trash_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        collect_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Watermarks for automatic trimming
        high_watermark: std.atomic.Value(usize) = std.atomic.Value(usize).init(1024),
        low_watermark: std.atomic.Value(usize) = std.atomic.Value(usize).init(256),

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        inline fn pack(ptr: ?*Node, tag: usize) usize {
            return packPtr(Node, ptr, tag, TAG_MASK);
        }

        inline fn unpack(raw: usize) struct { ptr: ?*Node, tag: usize } {
            return unpackPtr(Node, raw, TAG_MASK);
        }

        pub fn deinit(self: *Self) void {
            var raw = self.head_tagged.swap(0, .acq_rel);
            var cur = Self.unpack(raw).ptr;
            while (cur) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                cur = next;
            }
            self.approx_free.store(0, .release);
            // Drain trash
            var t = self.trash.swap(null, .acq_rel);
            while (t) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                t = next;
            }
            self.trash_count.store(0, .release);
            self.collect_lock.store(false, .release);
        }

        pub fn alloc(self: *Self) !*T {
            while (true) {
                const old = self.head_tagged.load(.acquire);
                const u = Self.unpack(old);
                const top = u.ptr;
                const tag = u.tag;
                if (top == null) break;
                const next = top.?.next;
                const new = Self.pack(next, tag + 1);
                if (self.head_tagged.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) {
                    decClamp(&self.approx_free);
                    return &top.?.payload;
                }
            }
            const n = try self.allocator.create(Node);
            n.* = .{ .payload = undefined, .next = null };
            return &n.payload;
        }

        pub fn free(self: *Self, p: *T) void {
            const n: *Node = @fieldParentPtr(Node, "payload", p);
            while (true) {
                const old = self.head_tagged.load(.acquire);
                const u = Self.unpack(old);
                const top = u.ptr;
                const tag = u.tag;
                n.next = top;
                const new = Self.pack(n, tag + 1);
                if (self.head_tagged.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) {
                    _ = self.approx_free.fetchAdd(1, .acq_rel);
                    self.autoMaintain();
                    return;
                }
            }
        }

        /// Pre-allocate `count` nodes and splice at head atomically.
        pub fn reserve(self: *Self, count: usize) !void {
            var i: usize = 0;
            var local_head: ?*Node = null;
            var local_tail: ?*Node = null;
            while (i < count) : (i += 1) {
                const n = try self.allocator.create(Node);
                n.* = .{ .payload = undefined, .next = null };
                if (local_tail) |t| {
                    t.next = n;
                    local_tail = n;
                } else {
                    local_head = n;
                    local_tail = n;
                }
            }
            if (local_head == null) return;
            while (true) {
                const old = self.head_tagged.load(.acquire);
                const top = Self.unpack(old).ptr;
                const tag = Self.unpack(old).tag;
                local_tail.?.next = top;
                const new = Self.pack(local_head, tag + 1);
                if (self.head_tagged.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) break;
                local_tail.?.next = null;
            }
            _ = self.approx_free.fetchAdd(count, .acq_rel);
            self.autoMaintain();
        }

        pub fn available(self: *const Self) usize {
            return self.approx_free.load(.acquire);
        }

        /// Best-effort trim: move nodes to deferred trash so that available() ≈ target_free.
        pub fn trimTo(self: *Self, target_free: usize) void {
            while (self.available() > target_free) {
                // Pop one and destroy
                const old = self.head_tagged.load(.acquire);
                const u = Self.unpack(old);
                const top = u.ptr;
                const tag = u.tag;
                if (top == null) break;
                const next = top.?.next;
                const new = Self.pack(next, tag + 1);
                if (self.head_tagged.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) {
                    // Push to trash instead of immediate free (mitigate ABA risk)
                    while (true) {
                        const t = self.trash.load(.acquire);
                        top.?.next = t;
                        if (self.trash.cmpxchgWeak(t, top, .acq_rel, .acquire) == null) break;
                    }
                    decClamp(&self.approx_free);
                    _ = self.trash_count.fetchAdd(1, .acq_rel);
                }
            }
            self.tryCollect();
        }

        /// Collect deferred trash by freeing all nodes currently in trash list.
        /// Call at quiescent points to reclaim memory without ABA hazards.
        pub fn collect(self: *Self) void {
            var t = self.trash.swap(null, .acq_rel);
            while (t) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                t = next;
            }
            self.trash_count.store(0, .release);
        }

        /// Best-effort collector: acquire a lock flag and drain trash if present.
        pub fn tryCollect(self: *Self) void {
            const had_trash = self.trash_count.load(.acquire) > 0;
            if (!had_trash) return;
            const was = self.collect_lock.cmpxchgWeak(false, true, .acq_rel, .acquire);
            if (was != null) return; // someone else is collecting
            defer self.collect_lock.store(false, .release);
            self.collect();
        }

        /// Set watermarks for automatic trimming logic.
        pub fn setWatermarks(self: *Self, high: usize, low: usize) void {
            self.high_watermark.store(high, .release);
            self.low_watermark.store(low, .release);
        }

        /// Auto-maintenance: trim to low watermark when free exceeds high watermark.
        pub fn autoMaintain(self: *Self) void {
            const free_now = self.available();
            const high = self.high_watermark.load(.acquire);
            if (free_now > high) {
                const low = self.low_watermark.load(.acquire);
                self.trimTo(low);
            }
        }

        /// Allocate a batch; fills `out` and returns number allocated.
        pub fn allocBatch(self: *Self, out: [](*T)) usize {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                const p = self.alloc() catch break;
                out[i] = p;
            }
            return i;
        }

        /// Free a batch efficiently by building a local chain and splicing once.
        pub fn freeBatch(self: *Self, items: [](*T)) void {
            if (items.len == 0) return;
            var local_head: ?*Node = null;
            var local_tail: ?*Node = null;
            for (items) |p| {
                const n: *Node = @fieldParentPtr(Node, "payload", p);
                if (local_tail) |t| {
                    t.next = n;
                    local_tail = n;
                } else {
                    local_head = n;
                    local_tail = n;
                }
            }
            if (local_tail) |t| t.next = null;
            while (true) {
                const old = self.head_tagged.load(.acquire);
                const u = Self.unpack(old);
                const top = u.ptr;
                const tag = u.tag;
                local_tail.?.next = top;
                const new = Self.pack(local_head, tag + 1);
                if (self.head_tagged.cmpxchgWeak(old, new, .acq_rel, .acquire) == null) break;
                local_tail.?.next = null;
            }
            _ = self.approx_free.fetchAdd(items.len, .acq_rel);
            self.autoMaintain();
        }

        /// Snapshot stats (approximate): free nodes and trash length.
        pub fn stats(self: *const Self) struct { free: usize, trash: usize } {
            return .{
                .free = self.approx_free.load(.acquire),
                .trash = self.trash_count.load(.acquire),
            };
        }
    };
}

/// Atomic decrement with clamp at 0 (avoids underflow). Best-effort under contention.
inline fn decClamp(counter: *std.atomic.Value(usize)) void {
    while (true) {
        const cur = counter.load(.acquire);
        if (cur == 0) return;
        if (counter.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire) == null) return;
    }
}

// Tagged-head helpers
inline fn packPtr(comptime T: type, ptr: ?*T, tag: usize, comptime mask: usize) usize {
    const addr: usize = @intFromPtr(ptr);
    return (addr & ~mask) | (tag & mask);
}

inline fn unpackPtr(comptime T: type, raw: usize, comptime mask: usize) struct { ptr: ?*T, tag: usize } {
    const addr = raw & ~mask;
    const tag = raw & mask;
    return .{ .ptr = @ptrFromInt(addr), .tag = tag };
}

// =============================================================================
// Enhanced Arc/Rc smart pointers (high-quality, Box-compatible deinit handling)
// =============================================================================

/// HiArc - Thread-safe reference counted smart pointer with weak references.
/// Optimized memory orderings and deinit handling via deinitIfPresent.
pub fn HiArc(comptime T: type) type {
    return struct {
        inner: *Inner,

        const Self = @This();

        pub const Inner = struct {
            strong_count: std.atomic.Value(usize),
            data: T,
            weak_count: std.atomic.Value(usize) align(64),
            allocator: Allocator,
        };

        pub fn init(allocator: Allocator, value: T) !Self {
            const p = try allocator.create(Inner);
            p.* = .{
                .strong_count = std.atomic.Value(usize).init(1),
                .weak_count = std.atomic.Value(usize).init(0),
                .data = value,
                .allocator = allocator,
            };
            return .{ .inner = p };
        }

        pub inline fn clone(self: *const Self) Self {
            const old = self.inner.strong_count.fetchAdd(1, .monotonic);
            if (comptime @sizeOf(usize) >= 8) {
                if (old >= std.math.maxInt(usize) - 1) @panic("HiArc: strong_count overflow");
            }
            if (old == 0) @panic("HiArc: clone after drop");
            return .{ .inner = self.inner };
        }

        pub inline fn release(self: Self) void {
            const old = self.inner.strong_count.fetchSub(1, .release);
            if (old == 1) {
                @fence(.acquire);
                // run T's deinit if present
                deinitIfPresent(&self.inner.data, self.inner.allocator);
                // if no weak, free inner
                if (self.inner.weak_count.load(.monotonic) == 0) {
                    self.inner.allocator.destroy(self.inner);
                }
            }
        }

        pub inline fn get(self: *const Self) *const T { return &self.inner.data; }
        pub inline fn getMut(self: *Self) *T { return &self.inner.data; }

        pub inline fn strongCount(self: *const Self) usize { return self.inner.strong_count.load(.monotonic); }
        pub inline fn weakCount(self: *const Self) usize { return self.inner.weak_count.load(.monotonic); }

        /// True if there is exactly one strong reference.
        pub inline fn isUnique(self: *const Self) bool {
            return self.inner.strong_count.load(.acquire) == 1;
        }

        /// Returns a mutable pointer if uniquely owned; otherwise null.
        pub inline fn get_mut(self: *Self) ?*T {
            return if (self.isUnique()) &self.inner.data else null;
        }

        /// Clone-on-write: if not unique, allocate a new inner and move/copy data.
        pub fn make_mut(self: *Self) !*T {
            if (self.isUnique()) return &self.inner.data;
            const alloc = self.inner.allocator;
            const new = try alloc.create(Inner);
            // Deep clone path if T.clone is available
            if (@hasDecl(T, "clone") and @typeInfo(@TypeOf(T.clone)) == .Fn) {
                const finfo = @typeInfo(@TypeOf(T.clone)).Fn;
                const rty = finfo.return_type orelse T;
                const is_err = @typeInfo(rty) == .ErrorUnion;
                var cloned: T = undefined;
                if (finfo.params.len == 2 and finfo.params[1].type) |P1| {
                    if (P1 == Allocator) {
                        cloned = if (is_err) try T.clone(&self.inner.data, alloc) else T.clone(&self.inner.data, alloc);
                    } else {
                        cloned = self.inner.data;
                    }
                } else if (finfo.params.len == 1) {
                    cloned = if (is_err) try T.clone(&self.inner.data) else T.clone(&self.inner.data);
                } else {
                    cloned = self.inner.data;
                }
                new.* = .{
                    .strong_count = std.atomic.Value(usize).init(1),
                    .weak_count = std.atomic.Value(usize).init(0),
                    .data = cloned,
                    .allocator = alloc,
                };
            } else {
                new.* = .{
                    .strong_count = std.atomic.Value(usize).init(1),
                    .weak_count = std.atomic.Value(usize).init(0),
                    .data = self.inner.data,
                    .allocator = alloc,
                };
            }
            // drop one strong on old inner
            _ = self.inner.strong_count.fetchSub(1, .release);
            self.inner = new;
            return &self.inner.data;
        }

        /// Convert to a raw data pointer; does not change refcounts.
        pub inline fn into_raw(self: Self) *const T {
            return &self.inner.data;
        }

        /// From a raw data pointer previously produced by into_raw.
        pub inline fn from_raw(ptr: *const T) Self {
            const inner: *Inner = @fieldParentPtr(Inner, "data", ptr);
            return .{ .inner = inner };
        }

        /// Pointer equality on data (same allocation).
        pub inline fn ptr_eq(a: *const Self, b: *const Self) bool {
            return &a.inner.data == &b.inner.data;
        }

        pub inline fn downgrade(self: *const Self) HiWeak(T) {
            const old = self.inner.weak_count.fetchAdd(1, .monotonic);
            if (comptime @sizeOf(usize) >= 8) {
                if (old >= std.math.maxInt(usize) - 1) @panic("HiArc: weak_count overflow");
            }
            return .{ .inner = self.inner };
        }

        pub fn tryUnwrap(self: Self) !T {
            if (self.inner.strong_count.load(.acquire) != 1) return error.NotUnique;
            const value = self.inner.data;
            if (self.inner.weak_count.load(.monotonic) == 0) {
                self.inner.allocator.destroy(self.inner);
            }
            return value;
        }

        /// Construct an Arc whose contents may hold a self-referential Weak during init.
        /// `init` signature: fn(weak: HiWeak(T)) T or !T
        pub fn new_cyclic(allocator: Allocator, init: anytype) !Self {
            const FnT = @TypeOf(init);
            if (@typeInfo(FnT) != .Fn) @compileError("new_cyclic expects a function");
            const info = @typeInfo(FnT).Fn;
            if (info.params.len != 1) @compileError("new_cyclic expects unary function");
            const R = info.return_type orelse void;
            const is_err = @typeInfo(R) == .ErrorUnion;

            const inner = try allocator.create(Inner);
            inner.* = .{
                .strong_count = std.atomic.Value(usize).init(1),
                .weak_count = std.atomic.Value(usize).init(1), // temp weak
                .data = undefined,
                .allocator = allocator,
            };
            var weak = HiWeak(T){ .inner = inner };
            const val = if (is_err) try init(weak) else init(weak);
            inner.data = val;
            // drop temp weak
            _ = inner.weak_count.fetchSub(1, .release);
            return .{ .inner = inner };
        }
    };
}

/// HiWeak - Weak counterpart for HiArc
pub fn HiWeak(comptime T: type) type {
    return struct {
        inner: ?*HiArc(T).Inner,
        const Self = @This();

        pub inline fn empty() Self { return .{ .inner = null }; }

        pub inline fn clone(self: *const Self) Self {
            if (self.inner) |p| { _ = p.weak_count.fetchAdd(1, .monotonic); }
            return .{ .inner = self.inner };
        }

        pub inline fn release(self: Self) void {
            if (self.inner) |p| {
                const old = p.weak_count.fetchSub(1, .release);
                if (old == 1) {
                    @fence(.acquire);
                    if (p.strong_count.load(.acquire) == 0) p.allocator.destroy(p);
                }
            }
        }

        pub fn upgrade(self: *const Self) ?HiArc(T) {
            if (self.inner) |p| {
                var cur = p.strong_count.load(.monotonic);
                while (cur > 0) {
                    if (p.strong_count.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic) == null) {
                        return HiArc(T){ .inner = p };
                    } else |new_cur| cur = new_cur;
                }
            }
            return null;
        }
    };
}

/// HiRc - Single-threaded reference counted smart pointer with optional weak.
pub fn HiRc(comptime T: type) type {
    return struct {
        inner: *Inner,
        const Self = @This();

        pub const Inner = struct {
            strong_count: usize,
            weak_count: usize,
            data: T,
            allocator: Allocator,
        };

        pub fn init(allocator: Allocator, value: T) !Self {
            const p = try allocator.create(Inner);
            p.* = .{ .strong_count = 1, .weak_count = 0, .data = value, .allocator = allocator };
            return .{ .inner = p };
        }

        pub inline fn clone(self: *const Self) Self {
            if (self.inner.strong_count == 0) @panic("HiRc: clone after drop");
            self.inner.strong_count += 1;
            return .{ .inner = self.inner };
        }

        pub inline fn release(self: Self) void {
            self.inner.strong_count -= 1;
            if (self.inner.strong_count == 0) {
                deinitIfPresent(&self.inner.data, self.inner.allocator);
                if (self.inner.weak_count == 0) self.inner.allocator.destroy(self.inner);
            }
        }

        pub inline fn get(self: *const Self) *const T { return &self.inner.data; }
        pub inline fn getMut(self: *Self) *T { return &self.inner.data; }
        pub inline fn strongCount(self: *const Self) usize { return self.inner.strong_count; }
        pub inline fn weakCount(self: *const Self) usize { return self.inner.weak_count; }

        pub inline fn isUnique(self: *const Self) bool { return self.inner.strong_count == 1; }
        pub inline fn get_mut(self: *Self) ?*T { return if (self.isUnique()) &self.inner.data else null; }
        pub fn make_mut(self: *Self) !*T {
            if (self.isUnique()) return &self.inner.data;
            const alloc = self.inner.allocator;
            const new = try alloc.create(Inner);
            if (@hasDecl(T, "clone") and @typeInfo(@TypeOf(T.clone)) == .Fn) {
                const finfo = @typeInfo(@TypeOf(T.clone)).Fn;
                const rty = finfo.return_type orelse T;
                const is_err = @typeInfo(rty) == .ErrorUnion;
                var cloned: T = undefined;
                if (finfo.params.len == 2 and finfo.params[1].type) |P1| {
                    if (P1 == Allocator) {
                        cloned = if (is_err) try T.clone(&self.inner.data, alloc) else T.clone(&self.inner.data, alloc);
                    } else {
                        cloned = self.inner.data;
                    }
                } else if (finfo.params.len == 1) {
                    cloned = if (is_err) try T.clone(&self.inner.data) else T.clone(&self.inner.data);
                } else {
                    cloned = self.inner.data;
                }
                new.* = .{ .strong_count = 1, .weak_count = 0, .data = cloned, .allocator = alloc };
            } else {
                new.* = .{ .strong_count = 1, .weak_count = 0, .data = self.inner.data, .allocator = alloc };
            }
            self.inner.strong_count -= 1;
            self.inner = new;
            return &self.inner.data;
        }

        pub inline fn into_raw(self: Self) *const T { return &self.inner.data; }
        pub inline fn from_raw(ptr: *const T) Self { return .{ .inner = @fieldParentPtr(Inner, "data", ptr) }; }
        pub inline fn ptr_eq(a: *const Self, b: *const Self) bool { return &a.inner.data == &b.inner.data; }

        pub inline fn downgrade(self: *const Self) HiWeakRc(T) {
            self.inner.weak_count += 1;
            return .{ .inner = self.inner };
        }

        pub fn tryUnwrap(self: Self) !T {
            if (self.inner.strong_count != 1) return error.NotUnique;
            const v = self.inner.data;
            if (self.inner.weak_count == 0) self.inner.allocator.destroy(self.inner);
            return v;
        }
    };
}

/// HiWeakRc - Weak counterpart for HiRc
pub fn HiWeakRc(comptime T: type) type {
    return struct {
        inner: ?*HiRc(T).Inner,
        const Self = @This();
        pub inline fn empty() Self { return .{ .inner = null }; }
        pub inline fn clone(self: *const Self) Self { if (self.inner) |p| p.weak_count += 1; return .{ .inner = self.inner }; }
        pub inline fn release(self: Self) void {
            if (self.inner) |p| if (p.weak_count > 0) {
                p.weak_count -= 1; if (p.weak_count == 0 and p.strong_count == 0) p.allocator.destroy(p);
            }
        }
        pub inline fn upgrade(self: *const Self) ?HiRc(T) { if (self.inner) |p| if (p.strong_count > 0) { p.strong_count += 1; return HiRc(T){ .inner = p }; } return null; }
    };
}

// =============================================================================
// Rust-compatible names: Arc/Weak and Rc/WeakRc
// Thin wrappers around HiArc/HiRc to provide the expected names and API.
// =============================================================================

pub fn Arc(comptime T: type) type {
    return HiArc(T);
}

pub fn Weak(comptime T: type) type {
    return HiWeak(T);
}

pub fn Rc(comptime T: type) type {
    return HiRc(T);
}

pub fn WeakRc(comptime T: type) type {
    return HiWeakRc(T);
}

/// Helpers for ThreadSafeBoxPool to work with Box without changing Box internals
pub fn initFromThreadSafePool(comptime T: type, pool: *ThreadSafeBoxPool(T), value: T) !Box(T) {
    const p = try pool.alloc();
    p.* = value;
    return .{ .ptr = p, .allocator = pool.allocator };
}

pub fn releaseToThreadSafePool(comptime T: type, b: *Box(T), pool: *ThreadSafeBoxPool(T)) void {
    pool.free(b.ptr);
    if (comptime builtin.mode != .ReleaseFast) b.debug_moved = true;
}

/// Fetch the allocator used by this Box
pub inline fn allocatorOf(comptime T: type, b: *const Box(T)) Allocator {
    return b.allocator;
}

/// Zero-initialize a Box for POD-like types (best-effort check).
pub fn initZeroed(comptime T: type, allocator: Allocator) !Box(T) {
    const p = try allocator.create(T);
    p.* = std.mem.zeroes(T);
    return .{ .ptr = p, .allocator = allocator };
}

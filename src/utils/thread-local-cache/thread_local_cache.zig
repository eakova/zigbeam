//! A generic, high-performance, thread-local cache for object pooling.
//!
//! This utility provides a small, extremely fast, per-thread cache (L1 cache) that sits
//! in front of a larger, slower, and potentially contended global pool (L2 cache). The goal
//! is to satisfy the vast majority of allocation/deallocation requests without ever touching
//! a lock, an atomic operation, or a shared resource.
//!
//! Features:
//! - Generic over any pointer type `*T`.
//! - Completely decoupled from the global pool via a generic callback interface.
//! - Optional context pointer for flexibility with both stateful and stateless pools.
//! - Fixed-size array for predictable, cache-friendly performance.
//! - Designed for heavy inlining on performance-critical hot paths.
//!
//! Performance Characteristics:
//! - `pop()` / `push()` (cache hit): ~1-2 nanoseconds. Zero overhead beyond array access.
//! - `clear()`: Proportional to the number of items currently in the cache.
//!
//! Usage:
//!
//! ```zig
//! // 1. Define your global pool and its context
//! const GlobalPool = struct {
//!     // ... your global pool logic (e.g., a lock-free stack) ...
//!
//!     // Callback function to return items to the global pool.
//!     // It accepts an optional context.
//!     pub fn recycleToGlobal(pool_context: ?*anyopaque, node: *MyObject) void {
//!         if (pool_context) |ctx| {
//!             const self: *GlobalPool = @ptrCast(@alignCast(ctx));
//!             self.global_freelist.push(node);
//!         } else {
//!             @panic("Callback requires a valid pool context!");
//!         }
//!     }
//! };
//!
//! // 2. Define your cache type
//! const MyObjectCache = ThreadLocalCache(*MyObject, GlobalPool.recycleToGlobal);
//!
//! // 3. Use it as a `threadlocal var`
//! threadlocal var tls_cache: MyObjectCache = .{};
//!
//! // 4. In your application logic:
//! var global_pool = GlobalPool.init(...);
//!
//! // To get an object:
//! const item = tls_cache.pop() orelse global_pool.getSlowPath();
//!
//! // To return an object:
//! if (!tls_cache.push(item)) {
//!     // Cache is full, return to global pool directly
//!     GlobalPool.recycleToGlobal(&global_pool, item);
//! }
//!
//! // Before thread exit or pool deinitialization:
//! tls_cache.clear(&global_pool);
//! ```
//!
// No std import required here; keep this module freestanding.
const builtin = @import("builtin");

/// Options to configure ThreadLocalCache behavior.
pub const ThreadLocalCacheOptions = struct {
    /// Compile-time capacity of the cache array. If null, capacity is chosen
    /// automatically from the pointee size heuristics (8..64).
    capacity: ?usize = null,
    /// Runtime limit for how many items can be used even if capacity is larger.
    /// Defaults to full capacity when null.
    active_capacity: ?usize = null,
    /// When true, clear() favors batch-style handling internally (future-proof).
    /// Current implementation still calls the single-item callback per entry
    /// because the callback type is per-item.
    clear_batch: bool = false,
    /// Optional flush batch size hint for clear(). If null and clear_batch=true,
    /// it defaults to clamp(capacity/2, 8..32).
    flush_batch: ?usize = null,
    /// When true, writes null into freed slots to aid debugging/sanitizers.
    /// Defaults to true in non-ReleaseFast builds.
    sanitize_slots: bool = (builtin.mode != .ReleaseFast),
};

fn max(a: usize, b: usize) usize { return if (a > b) a else b; }
fn min(a: usize, b: usize) usize { return if (a < b) a else b; }
fn clamp(v: usize, lo: usize, hi: usize) usize { return min(max(v, lo), hi); }

/// Primary factory that configures the cache via compile-time options.
pub fn ThreadLocalCacheWithOptions(
    comptime T: type,
    comptime recycle_callback: ?*const fn (context: ?*anyopaque, item: T) void,
    comptime O: ThreadLocalCacheOptions,
) type {
    // Validate pointer type
    comptime {
        if (@typeInfo(T) != .pointer) @compileError("ThreadLocalCache can only store pointer types.");
    }

    // Compute capacity heuristically if not provided.
    const Pointee = @typeInfo(T).pointer.child;
    const pointee_size: usize = @sizeOf(Pointee);
    const slot_size = max(pointee_size, 64);
    const auto_div: usize = if (4096 / slot_size == 0) 1 else 4096 / slot_size;
    const auto_cap = clamp(auto_div, 8, 64);
    const CAPACITY: usize = O.capacity orelse auto_cap;
    const ACTIVE_CAPACITY: usize = O.active_capacity orelse CAPACITY;
    // FLUSH_BATCH reserved for future batch clear; current per-item callback API keeps per-item loop.

    return struct {
        const Self = @This();
        pub const capacity: usize = CAPACITY;

        buffer: [capacity]?T = [_]?T{null} ** capacity,
        count: usize = 0,

        /// Max items effectively allowed at runtime (<= capacity).
        pub const active_capacity: usize = ACTIVE_CAPACITY;

        /// Pop one item from the local cache.
        pub inline fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            self.count -= 1;
            const item = self.buffer[self.count];
            if (comptime O.sanitize_slots) self.buffer[self.count] = null;
            return item;
        }

        /// Push one item into the local cache. Returns false if the cache is full
        /// per the active_capacity limit.
        pub inline fn push(self: *Self, item: T) bool {
            if (self.count >= active_capacity) return false;
            self.buffer[self.count] = item;
            self.count += 1;
            return true;
        }

        /// Clear the local cache. If a recycle callback is present, it is invoked
        /// once per item to return it to a global pool.
        pub fn clear(self: *Self, global_pool_context: ?*anyopaque) void {
            if (self.count == 0) return;
            // For now, we always call per-item; FLUSH_BATCH kept as future hint.
            while (self.count > 0) {
                self.count -= 1;
                const item = self.buffer[self.count].?;
                if (comptime recycle_callback != null) recycle_callback.?(global_pool_context, item);
                if (comptime O.sanitize_slots) self.buffer[self.count] = null;
            }
        }

        pub inline fn len(self: *const Self) usize { return self.count; }
        pub inline fn isEmpty(self: *const Self) bool { return self.count == 0; }
        pub inline fn isFull(self: *const Self) bool { return self.count == capacity; }
    };
}

/// A generic, fixed-size, thread-local cache for object pooling.
///
/// This structure is intended to be used as a `threadlocal var`.
///
/// - `T`: The pointer type to be cached (e.g., `*MyObject`).
/// - `recycle_callback`: An optional function pointer that will be called by `clear()`
///   to return cached items to a global (L2) pool. It accepts an optional context.
pub fn ThreadLocalCache(
    comptime T: type,
    comptime recycle_callback: ?*const fn (context: ?*anyopaque, item: T) void,
) type {
    // Conservative default capacity to match existing integration tests.
    return ThreadLocalCacheWithOptions(T, recycle_callback, .{
        .capacity = 16,
        .active_capacity = 16,
    });
}

/// Same as `ThreadLocalCache`, but allows choosing the capacity at comptime.
///
/// Keeping this as a separate factory preserves the original API and avoids
/// changing call sites that rely on the default capacity.
pub fn ThreadLocalCacheWithCapacity(
    comptime T: type,
    comptime recycle_callback: ?*const fn (context: ?*anyopaque, item: T) void,
    comptime Capacity: usize,
) type {
    return ThreadLocalCacheWithOptions(T, recycle_callback, .{
        .capacity = Capacity,
        .active_capacity = Capacity,
        .clear_batch = false,
        .flush_batch = null,
        .sanitize_slots = (builtin.mode != .ReleaseFast),
    });
}

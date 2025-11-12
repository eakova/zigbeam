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
    return ThreadLocalCacheWithCapacity(T, recycle_callback, 8);
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
    // Compile-time validation to ensure T is a pointer type. This prevents
    // misuse, for example, by trying to cache large structs by value.
    comptime {
        if (@typeInfo(T) != .pointer) {
            @compileError("ThreadLocalCache can only store pointer types.");
        }
    }

    return struct {
        const Self = @This();

        /// The optimal size for an L1 cache. Small enough to be fast and avoid
        /// cache pollution, large enough to be effective. 8 pointers on a 64-bit
        /// system is 64 bytes, fitting perfectly into a single CPU cache line.
        pub const capacity: usize = Capacity;

        /// The underlying storage for the cache. Using an array of optionals
        /// makes debugging easier and is optimized away in release builds.
        buffer: [capacity]?T = [_]?T{null} ** capacity,

        /// The number of items currently in the cache.
        count: usize = 0,

        /// Tries to pop an item from the local cache.
        /// This is the performance-critical hot path for allocations. It involves no
        /// locks, atomics, or any form of contention.
        ///
        /// Returns the cached item, or `null` if the cache is empty.
        pub inline fn pop(self: *Self) ?T {
            // This branch is highly predictable by the CPU. In a high-throughput system,
            // the cache will often fluctuate between empty and non-empty states.
            if (self.count == 0) {
                return null;
            }

            // The core logic: decrement the count and return the item.
            // When inlined, this compiles down to just a few CPU instructions.
            self.count -= 1;
            const item = self.buffer[self.count];
            self.buffer[self.count] = null; // Help GC/debuggers by nulling out the slot.
            return item;
        }

        /// Tries to push an item into the local cache.
        /// This is the performance-critical hot path for deallocations.
        ///
        /// Returns `true` on success, or `false` if the cache is full.
        pub inline fn push(self: *Self, item: T) bool {
            // This branch is also highly predictable. The cache is either full or not.
            if (self.count >= capacity) {
                return false;
            }

            // The core logic: place the item in the next available slot and
            // increment the count.
            self.buffer[self.count] = item;
            self.count += 1;
            return true;
        }

        /// Empties the local cache. After this call, `self.len()` is guaranteed to be 0.
        ///
        /// BEHAVIOR:
        /// - If a `recycle_callback` was provided, this function calls the callback
        ///   for each item before discarding the pointer from the cache.
        /// - If NO `recycle_callback` was provided, this function simply DISCARDS
        ///   the pointers, resetting the cache to an empty state. In this scenario,
        ///   you are responsible for the lifecycle of the objects pointed to.
        pub fn clear(self: *Self, global_pool_context: ?*anyopaque) void {
            // A single loop correctly and efficiently handles all cases.
            while (self.count > 0) {
                self.count -= 1;
                const item = self.buffer[self.count].?;

                // This `if` happens at COMPILE TIME. The compiler generates one of two
                // specialized loops, with zero runtime cost for the check.
                if (comptime recycle_callback != null) {
                    // Path 1: A callback exists. Use it to recycle the item.
                    recycle_callback.?(global_pool_context, item);
                }

                // In both cases (with or without a callback), we clear the buffer slot.
                self.buffer[self.count] = null;
            }

            // When no callback is provided, `global_pool_context` is ignored by design.
        }

        /// Returns the number of items currently in the cache.
        pub inline fn len(self: *const Self) usize {
            return self.count;
        }

        /// Returns `true` if the cache is empty.
        pub inline fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Returns `true` if the cache is full.
        pub inline fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }
    };
}

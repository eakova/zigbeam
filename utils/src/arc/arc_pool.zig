// FILE: arc_pool.zig
//! A high-performance, thread-safe memory pool for `Arc<T>` allocations.
//!
//! This pool significantly reduces allocator pressure and improves performance under
//! high concurrency by reusing `Arc::Inner` allocations. It employs a multi-layered
//! caching strategy.
//!
//! Architecture:
//! - L1 Cache: A lock-free, per-thread `ThreadLocalCache` for near-zero-cost hits.
//! - L2 Cache: A global, lock-free freelist (Treiber stack) for cross-thread sharing.
//! - L3 Fallback: A mutex-protected call to the underlying system allocator.
//!
//! NOTE: This pool is only effective for `Arc<T>` instances that are allocated
//! on the heap. It has no effect on `Arc<T>` using Small Value Optimization (SVO).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const atomic = std.atomic;
const builtin = @import("builtin");

// Assuming these are in separate, correctly named files
const Arc = @import("arc.zig").Arc;
const ThreadLocalCache = @import("../thread-local-cache/thread_local_cache.zig").ThreadLocalCache;

/// A high-performance, thread-safe memory pool for `Arc<T>` allocations.
pub fn ArcPool(comptime T: type) type {
    // This pool only works with the heap-allocated version of Arc.
    // We can't pool SVO values.
    const InnerType = Arc(T).Inner;

    return struct {
        const Self = @This();

        /// The global freelist (L2 cache), implemented as a lock-free Treiber stack.
        /// It holds a linked list of recycled `Inner` blocks.
        freelist: atomic.Value(?*InnerType),

        /// The underlying memory allocator used for fresh allocations (L3 fallback).
        allocator: Allocator,

        /// A mutex to protect the underlying allocator. This is CRITICAL to ensure
        /// the pool works safely even with non-thread-safe allocators like
        /// `std.heap.ArenaAllocator`.
        alloc_mutex: Thread.Mutex,

        // --- Statistics for monitoring pool performance (optional) ---
        stats_allocs: atomic.Value(u64), // Fresh allocations from allocator
        stats_reuses: atomic.Value(u64), // Hits from the global pool (L2)
        stats_tls_hits: atomic.Value(u64), // Hits from the TLS cache (L1)
        stats_tls_miss: atomic.Value(u64), // Misses from the TLS cache

        /// The callback function passed to `ThreadLocalCache` to return items
        /// from the L1 cache back to this L2 global pool.
        fn recycleToGlobal(pool_context: ?*anyopaque, node: *InnerType) void {
            // The context is guaranteed to be a pointer to our `ArcPool` instance.
            const self: *Self = @ptrCast(@alignCast(pool_context.?));
            self.recycleSlow(node);
        }

        /// The specific type of our thread-local cache.
        const Cache = ThreadLocalCache(*InnerType, recycleToGlobal);

        /// The thread-local cache instance (L1 cache). Each thread gets its own.
        threadlocal var tls_cache: Cache = .{};

        /// Initializes a new `ArcPool`.
        pub fn init(allocator: Allocator) Self {
            return .{
                .freelist = atomic.Value(?*InnerType).init(null),
                .allocator = allocator,
                .alloc_mutex = .{},
                .stats_allocs = atomic.Value(u64).init(0),
                .stats_reuses = atomic.Value(u64).init(0),
                .stats_tls_hits = atomic.Value(u64).init(0),
                .stats_tls_miss = atomic.Value(u64).init(0),
            };
        }

        /// Deinitializes the pool, freeing all cached memory.
        /// WARNING: This is NOT thread-safe. It must be called only after all
        /// threads using the pool have terminated and joined.
        pub fn deinit(self: *Self) void {
            // Step 1: Drain the current thread's local cache into the global freelist.
            tls_cache.clear(self);

            // Step 2: Lock the mutex to ensure exclusive access for destruction.
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();

            // Step 3: Atomically swap out the entire global freelist and destroy all nodes.
            var current = self.freelist.swap(null, .acquire);
            while (current) |node| {
                const next = node.next_in_freelist;
                self.allocator.destroy(node);
                current = next;
            }
        }

        /// Creates a new `Arc<T>`, reusing a recycled object if available.
        pub fn create(self: *Self, value: T) !Arc(T) {
            // If the Arc uses Small Value Optimization, the pool is irrelevant.
            // Create it directly and return.
            if (comptime Arc(T).use_svo) {
                return Arc(T).init(self.allocator, value);
            }

            // TIER 1 (FASTEST): Try the thread-local cache first. Zero contention.
            if (tls_cache.pop()) |node| {
                _ = self.stats_tls_hits.fetchAdd(1, .monotonic);
                node.* = .{ .counters = .{ .strong_count = .init(1), .weak_count = .init(0) }, .data = value, .allocator = self.allocator, .next_in_freelist = null };
                return Arc(T){ .storage = .{ .tagged_ptr = try Arc(T).SvoPtr.new(node, Arc(T).TAG_POINTER) } };
            }
            _ = self.stats_tls_miss.fetchAdd(1, .monotonic);

            // TIER 2 (MEDIUM): Try the global, lock-free freelist.
            var head = self.freelist.load(.acquire);
            while (head) |node| {
                const next = node.next_in_freelist;
                if (self.freelist.cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| {
                    head = new_head;
                    std.atomic.spinLoopHint(); // Contention, pause briefly.
                    continue;
                }
                // Successfully popped from global freelist.
                _ = self.stats_reuses.fetchAdd(1, .monotonic);
                node.* = .{ .counters = .{ .strong_count = .init(1), .weak_count = .init(0) }, .data = value, .allocator = self.allocator, .next_in_freelist = null };
                return Arc(T){ .storage = .{ .tagged_ptr = try Arc(T).SvoPtr.new(node, Arc(T).TAG_POINTER) } };
            }

            // TIER 3 (SLOWEST): Allocate fresh memory from the system allocator.
            // This is the only path that requires a lock.
            _ = self.stats_allocs.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();
            return Arc(T).init(self.allocator, value);
        }

        /// Recycles an `Arc` back into the pool for future reuse.
        /// For SVO'd Arcs, this is a no-op.
        pub fn recycle(self: *Self, arc: Arc(T)) void {
            // SVO values live on the stack and are not pooled. Do nothing.
            if (arc.isInline()) return;

            // This is an optimization. The data `T` inside the `Inner` block
            // has already been destroyed by `Arc::release`. We can optionally
            // reset the data field to a known state for safety/debugging.
            // `@field(arc.asPtr(), "data") = undefined;`

            // TIER 1 (FASTEST): Try to push to the thread-local cache.
            if (tls_cache.push(arc.asPtr())) {
                // Success, returned to local cache instantly.
                return;
            }

            // TIER 2 (SLOWER): TLS cache is full, push to the global freelist.
            self.recycleSlow(arc.asPtr());
        }

        /// The "slow path" for recycling, which pushes the node to the global
        /// lock-free stack. This is public so `ThreadLocalCache` can call it.
        pub fn recycleSlow(self: *Self, node: *InnerType) void {
            var head = self.freelist.load(.monotonic);
            while (true) {
                node.next_in_freelist = head;
                if (self.freelist.cmpxchgWeak(head, node, .release, .monotonic)) |new_head| {
                    head = new_head;
                    std.atomic.spinLoopHint(); // Contention, pause briefly.
                    continue;
                }
                // Successfully pushed to global freelist.
                break;
            }
        }

        // ... (getStats function would be here) ...
    };
}

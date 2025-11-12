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

const Arc = @import("arc_core").Arc;
const ArcWeak = @import("arc_core").ArcWeak;
const tlc_mod = @import("thread_local_cache");
const ThreadLocalCacheWithCapacity = tlc_mod.ThreadLocalCacheWithCapacity;

/// A high-performance, thread-safe memory pool for `Arc<T>` allocations.
pub fn ArcPool(comptime T: type, comptime EnableStats: bool) type {
    // This pool only works with the heap-allocated version of Arc.
    // We can't pool SVO values.
    const InnerType = Arc(T).Inner;

    return struct {
        const Self = @This();

        // --- Statistics for monitoring pool performance (optional) ---
        // Place each counter on its own cache line to minimize false sharing.
        const PaddedCounter = struct {
            counter: atomic.Value(u64),
            _pad: [56]u8 = [_]u8{0} ** 56,
        };

        /// Global L2: sharded Treiber stacks to reduce CAS contention under MT.
        /// Fixed upper bound, active shard count chosen at init.
        const MAX_SHARDS: usize = 32;
        freelists: [MAX_SHARDS]atomic.Value(?*InnerType),
        active_shards: usize,
        flush_batch: usize,
        /// Effective TLS capacity (<= 64) chosen at init from shard count.
        tls_active_capacity: usize,

        /// The underlying memory allocator used for fresh allocations (L3 fallback).
        allocator: Allocator,

        /// A mutex to protect the underlying allocator. This is CRITICAL to ensure
        /// the pool works safely even with non-thread-safe allocators like
        /// `std.heap.ArenaAllocator`.
        alloc_mutex: Thread.Mutex,

        stats_allocs: PaddedCounter align(64), // Fresh allocations from allocator
        stats_reuses: PaddedCounter align(64), // Hits from the global pool (L2)
        stats_tls_hits: PaddedCounter align(64), // Hits from the TLS cache (L1)
        stats_tls_miss: PaddedCounter align(64), // Misses from the TLS cache

        /// The callback function passed to `ThreadLocalCache` to return items
        /// from the L1 cache back to this L2 global pool.
        fn recycleToGlobal(pool_context: ?*anyopaque, node: *InnerType) void {
            // The context is guaranteed to be a pointer to our `ArcPool` instance.
            const self: *Self = @ptrCast(@alignCast(pool_context.?));
            self.recycleSlow(node);
        }

        /// The specific type of our thread-local cache. Bump capacity to 64 to better absorb bursts.
        const Cache = ThreadLocalCacheWithCapacity(*InnerType, recycleToGlobal, 64);

        /// The thread-local cache instance (L1 cache). Each thread gets its own.
        threadlocal var tls_cache: Cache = .{};

        /// TLS flush buffer for batched pushes into the sharded global freelist.
        const POP_BATCH: usize = 4;
        const MAX_FLUSH: usize = 32;
        const FlushBuf = struct {
            buf: [MAX_FLUSH]?*InnerType = [_]?*InnerType{null} ** MAX_FLUSH,
            count: usize = 0,
        };
        threadlocal var tls_flush: FlushBuf = .{};

        fn shardIndex(self: *const Self) usize {
            const a = @intFromPtr(self);
            const b = @intFromPtr(&tls_cache);
            return (a ^ b) & (self.active_shards - 1);
        }

        fn pushChain(self: *Self, shard: usize, head_node: *InnerType, tail_node: *InnerType) void {
            var head = self.freelists[shard].load(.monotonic);
            while (true) {
                tail_node.next_in_freelist = head;
                if (self.freelists[shard].cmpxchgWeak(head, head_node, .release, .monotonic)) |new_head| {
                    head = new_head;
                    std.atomic.spinLoopHint();
                    continue;
                }
                break;
            }
        }

        /// Initializes a new `ArcPool`.
        pub fn init(allocator: Allocator) Self {
            // Helper to compute effective TLS capacity (kept here for easy future tuning).
            const computeTlsCapacity = struct {
                fn run(shards: usize) usize {
                    const inner_sz = @sizeOf(InnerType);
                    const cap_by_size: usize = if (inner_sz <= 64) 64 else if (inner_sz <= 128) 32 else if (inner_sz <= 256) 16 else 8;
                    const cap_by_shards: usize = if (shards >= 16) 64 else if (shards >= 8) 32 else 16;
                    return if (cap_by_size < cap_by_shards) cap_by_size else cap_by_shards;
                }
            };
            // Choose active shards: next power-of-two of cpu count, clamped [8, MAX_SHARDS]
            const cpu_raw = std.Thread.getCpuCount() catch 4;
            const cpu = if (cpu_raw == 0) 4 else cpu_raw;
            const min_shards: usize = 8;
            var target: usize = if (cpu < min_shards) min_shards else cpu;
            if (target > MAX_SHARDS) target = MAX_SHARDS;
            // ceil to next pow2
            target -= 1;
            target |= target >> 1;
            target |= target >> 2;
            target |= target >> 4;
            target |= target >> 8;
            if (@sizeOf(usize) == 8) target |= target >> 32;
            target += 1;
            if (target < min_shards) target = min_shards;

            var s: [MAX_SHARDS]atomic.Value(?*InnerType) = undefined;
            var i: usize = 0;
            while (i < MAX_SHARDS) : (i += 1) s[i] = atomic.Value(?*InnerType).init(null);

            // Choose effective TLS capacity from shard count.
            const tls_cap_eff: usize = computeTlsCapacity.run(target);
            var fb: usize = tls_cap_eff / 4;
            if (fb < 8) fb = 8;
            if (fb > MAX_FLUSH) fb = MAX_FLUSH;

            var instance: Self = .{
                .freelists = s,
                .active_shards = target,
                .flush_batch = fb,
                .tls_active_capacity = tls_cap_eff,
                .allocator = allocator,
                .alloc_mutex = .{},
                .stats_allocs = .{ .counter = atomic.Value(u64).init(0) },
                .stats_reuses = .{ .counter = atomic.Value(u64).init(0) },
                .stats_tls_hits = .{ .counter = atomic.Value(u64).init(0) },
                .stats_tls_miss = .{ .counter = atomic.Value(u64).init(0) },
            };
            // Mini pre-seed: create+recycle a couple nodes to warm TLS and L2 (single shard).
            // Keep it minimal to avoid allocation burst at init.
            var warm: usize = 0;
            while (warm < 2) : (warm += 1) {
                const payload = std.mem.zeroes(T);
                const arc = Arc(T).init(instance.allocator, payload) catch break;
                instance.recycle(arc);
            }
            instance.drainThreadCache();
            return instance;
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

            // Step 3: Flush any pending TLS batch, then drain all shards.
            if (tls_flush.count > 0) {
                var idx: usize = 0;
                const first = tls_flush.buf[0].?;
                var last: *InnerType = first;
                idx = 1;
                while (idx < tls_flush.count) : (idx += 1) {
                    const n = tls_flush.buf[idx].?;
                    last.next_in_freelist = n;
                    last = n;
                }
                const shard = self.shardIndex();
                self.pushChain(shard, first, last);
                tls_flush.count = 0;
            }
            var si: usize = 0;
            while (si < self.active_shards) : (si += 1) {
                var current = self.freelists[si].swap(null, .acquire);
                while (current) |node| {
                    const next = node.next_in_freelist;
                    Arc(T).destroyInnerBlock(node);
                    current = next;
                }
            }
        }

        /// Pop a single node from a shard using a standard Treiber pop loop.
        /// This keeps behavior conservative and avoids rare instability seen with
        /// chain-pop under heavy MT churn. We still keep the function indirection
        /// so we can re-introduce chain-pop later behind a flag.
        fn popBatchOne(self: *Self, shard_in: usize) ?*InnerType {
            var shard = shard_in;
            var attempts: usize = 0;
            while (attempts < self.active_shards) : (attempts += 1) {
                var head = self.freelists[shard].load(.acquire);
                while (head) |node| {
                    const next = node.next_in_freelist;
                    if (self.freelists[shard].cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| {
                        head = new_head;
                        std.atomic.spinLoopHint();
                        continue;
                    }
                    node.next_in_freelist = null;
                    return node;
                }
                shard = (shard + 1) & (self.active_shards - 1);
            }
            return null;
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
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                node.data = value;
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);

            // TIER 2 (MEDIUM): Try sharded global freelists, starting from our shard.
            const shard = self.shardIndex();
            if (self.popBatchOne(shard)) |node| {
                if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.data = value;
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }

            // TIER 3 (SLOWEST): Allocate fresh memory from the system allocator.
            // This is the only path that requires a lock.
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();
            return Arc(T).init(self.allocator, value);
        }

        /// Create with in-place initializer (non-fallible).
        pub fn createWithInitializer(self: *Self, initializer: *const fn (*T) void) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                return Arc(T).initWithInitializer(self.allocator, initializer);
            }
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                initializer(&node.data);
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            const shard_a = self.shardIndex();
            if (self.popBatchOne(shard_a)) |node| {
                if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                initializer(&node.data);
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();
            return Arc(T).initWithInitializer(self.allocator, initializer);
        }

        /// Create with in-place initializer (fallible).
        pub fn createWithInitializerFallible(self: *Self, initializer: *const fn (*T) anyerror!void) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                return Arc(T).initWithInitializerFallible(self.allocator, initializer);
            }
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                if (initializer(&node.data)) |_| {
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                } else |e| {
                    self.recycleSlow(node);
                    return e;
                }
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            const shard_a = self.shardIndex();
            if (self.popBatchOne(shard_a)) |node| {
                if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                if (initializer(&node.data)) |_| {
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                } else |e| {
                    self.recycleSlow(node);
                    return e;
                }
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();
            return Arc(T).initWithInitializerFallible(self.allocator, initializer);
        }

        /// Create a cyclic Arc via pool using a constructor that receives a temporary Weak.
        pub fn createCyclic(self: *Self, ctor: *const fn (ArcWeak(T)) anyerror!T) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                @compileError("ArcPool.createCyclic requires heap Arc; SVO is not supported");
            }
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(1, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                var weak = ArcWeak(T){ .inner = node };
                const val = ctor(weak) catch |e| { self.recycleSlow(node); return e; };
                node.data = val;
                weak.release();
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            const shard_b = self.shardIndex();
            if (self.popBatchOne(shard_b)) |node| {
                if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(1, .monotonic);
                node.allocator = self.allocator;
                var weak = ArcWeak(T){ .inner = node };
                const val = ctor(weak) catch |e| { self.recycleSlow(node); return e; };
                node.data = val;
                weak.release();
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            return Arc(T).newCyclic(self.allocator, ctor);
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

            // TIER 1 (FASTEST): Try to push to the thread-local cache up to active capacity.
            if (tls_cache.count < self.tls_active_capacity and tls_cache.push(arc.asPtr())) {
                // Success, returned to local cache instantly.
                return;
            }

            // TIER 2 (SLOWER): TLS cache is full, push to the global freelist.
            self.recycleSlow(arc.asPtr());
        }

        /// The "slow path" for recycling: buffer nodes locally and push in batches to sharded L2.
        pub fn recycleSlow(self: *Self, node: *InnerType) void {
            const idx = tls_flush.count;
            if (idx < self.flush_batch) {
                tls_flush.buf[idx] = node;
                tls_flush.count = idx + 1;
                // Early flush: if yakın doygunlukta (flush_batch-2), hemen boşalt.
                if (tls_flush.count < self.flush_batch - 2) return;
            }
            // Build a chain from buffered nodes and push atomically to our shard.
            var i: usize = 0;
            const first = tls_flush.buf[0].?;
            var last: *InnerType = first;
            i = 1;
            while (i < tls_flush.count) : (i += 1) {
                const n = tls_flush.buf[i].?;
                last.next_in_freelist = n;
                last = n;
            }
            const shard = self.shardIndex();
            self.pushChain(shard, first, last);
            tls_flush.count = 0;
        }

        // ... (getStats function would be here) ...

        /// Allows the current thread to flush its L1 cache back into the pool.
        /// Useful for tests to avoid leaking objects when threads exit.
        pub fn drainThreadCache(self: *Self) void {
            tls_cache.clear(self);
            if (tls_flush.count > 0) {
                var i: usize = 0;
                const first = tls_flush.buf[0].?;
                var last: *InnerType = first;
                i = 1;
                while (i < tls_flush.count) : (i += 1) {
                    const n = tls_flush.buf[i].?;
                    last.next_in_freelist = n;
                    last = n;
                }
                const shard = self.shardIndex();
                self.pushChain(shard, first, last);
                tls_flush.count = 0;
            }
        }

        /// Runs `body` with automatic thread-local cache draining.
        pub fn withThreadCache(self: *Self, body: fn (*Self, *anyopaque) anyerror!void, ctx: *anyopaque) !void {
            defer self.drainThreadCache();
            try body(self, ctx);
        }
    };
}

/// Convenience alias: default ArcPool with statistics disabled for best performance.
pub fn ArcPoolDefault(comptime T: type) type {
    return ArcPool(T, false);
}

/// Variant of ArcPool that allows selecting the TLS capacity for its
/// per-thread cache at comptime.
pub fn ArcPoolWithCapacity(comptime T: type, comptime EnableStats: bool, comptime TLSCapacity: usize) type {
    const InnerType = Arc(T).Inner;
    return struct {
        const Self = @This();

        // Define padded counter before fields; Zig 0.15 requires declarations
        // before container fields inside struct bodies.
        const PaddedCounter = struct {
            counter: atomic.Value(u64),
            _pad: [56]u8 = [_]u8{0} ** 56,
        };

        const MAX_SHARDS: usize = 32;
        freelists: [MAX_SHARDS]atomic.Value(?*InnerType),
        active_shards: usize,
        flush_batch: usize,
        allocator: Allocator,
        alloc_mutex: Thread.Mutex,

        stats_allocs: PaddedCounter align(64),
        stats_reuses: PaddedCounter align(64),
        stats_tls_hits: PaddedCounter align(64),
        stats_tls_miss: PaddedCounter align(64),

        fn recycleToGlobal(pool_context: ?*anyopaque, node: *InnerType) void {
            const self: *Self = @ptrCast(@alignCast(pool_context.?));
            self.recycleSlow(node);
        }

        const Cache = tlc_mod.ThreadLocalCacheWithCapacity(*InnerType, recycleToGlobal, TLSCapacity);
        threadlocal var tls_cache: Cache = .{};
        const MAX_FLUSH: usize = 32;
        const FlushBuf = struct { buf: [MAX_FLUSH]?*InnerType = [_]?*InnerType{null} ** MAX_FLUSH, count: usize = 0 };
        threadlocal var tls_flush: FlushBuf = .{};

        fn shardIndex(self: *const Self) usize { return (@intFromPtr(self) ^ @intFromPtr(&tls_cache)) & (self.active_shards - 1); }
        fn pushChain(self: *Self, shard: usize, head_node: *InnerType, tail_node: *InnerType) void {
            var head = self.freelists[shard].load(.monotonic);
            while (true) {
                tail_node.next_in_freelist = head;
                if (self.freelists[shard].cmpxchgWeak(head, head_node, .release, .monotonic)) |new_head| { head = new_head; std.atomic.spinLoopHint(); continue; }
                break;
            }
        }

        pub fn init(allocator: Allocator) Self {
            // Choose active shards from CPU count (next pow2, clamp [8, MAX_SHARDS])
            const cpu_raw = std.Thread.getCpuCount() catch 4;
            const cpu = if (cpu_raw == 0) 4 else cpu_raw;
            const min_shards: usize = 8;
            var target: usize = if (cpu < min_shards) min_shards else cpu;
            if (target > MAX_SHARDS) target = MAX_SHARDS;
            // ceil to next pow2
            target -= 1;
            target |= target >> 1;
            target |= target >> 2;
            target |= target >> 4;
            target |= target >> 8;
            if (@sizeOf(usize) == 8) target |= target >> 32;
            target += 1;
            if (target < min_shards) target = min_shards;

            var s: [MAX_SHARDS]atomic.Value(?*InnerType) = undefined;
            var i: usize = 0;
            while (i < MAX_SHARDS) : (i += 1) s[i] = atomic.Value(?*InnerType).init(null);

            var fb: usize = TLSCapacity / 4;
            if (fb < 8) fb = 8;
            if (fb > MAX_FLUSH) fb = MAX_FLUSH;

            var instance: Self = .{ .freelists = s, .active_shards = target, .allocator = allocator, .alloc_mutex = .{}, .flush_batch = fb,
                .stats_allocs = .{ .counter = atomic.Value(u64).init(0) },
                .stats_reuses = .{ .counter = atomic.Value(u64).init(0) },
                .stats_tls_hits = .{ .counter = atomic.Value(u64).init(0) },
                .stats_tls_miss = .{ .counter = atomic.Value(u64).init(0) }, };
            // Mini pre-seed (single shard): warm a couple nodes.
            var warm: usize = 0;
            while (warm < 2) : (warm += 1) {
                const payload = std.mem.zeroes(T);
                const arc = Arc(T).init(instance.allocator, payload) catch break;
                instance.recycle(arc);
            }
            instance.drainThreadCache();
            return instance;
        }

        pub fn deinit(self: *Self) void {
            tls_cache.clear(self);
            if (tls_flush.count > 0) {
                var i: usize = 0;
                const first = tls_flush.buf[0].?;
                var last: *InnerType = first;
                i = 1;
                while (i < tls_flush.count) : (i += 1) { const n = tls_flush.buf[i].?; last.next_in_freelist = n; last = n; }
                const shardf = self.shardIndex();
                self.pushChain(shardf, first, last);
                tls_flush.count = 0;
            }
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            var si: usize = 0;
            while (si < self.active_shards) : (si += 1) {
                var current = self.freelists[si].swap(null, .acquire);
                while (current) |node| { const next = node.next_in_freelist; Arc(T).destroyInnerBlock(node); current = next; }
            }
        }

        pub fn create(self: *Self, value: T) !Arc(T) {
            if (comptime Arc(T).use_svo) return Arc(T).init(self.allocator, value);
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                node.data = value;
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);

            var shard = self.shardIndex(); var attempts: usize = 0;
            while (attempts < self.active_shards) : (attempts += 1) {
                var head = self.freelists[shard].load(.acquire);
                while (head) |node| {
                    const next = node.next_in_freelist;
                    if (self.freelists[shard].cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| { head = new_head; std.atomic.spinLoopHint(); continue; }
                    if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                    node.counters.strong_count.store(1, .monotonic);
                    node.counters.weak_count.store(0, .monotonic);
                    node.allocator = self.allocator;
                    node.next_in_freelist = null;
                    node.data = value;
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                }
                shard = (shard + 1) & (self.active_shards - 1);
            }

            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock();
            defer self.alloc_mutex.unlock();
            return Arc(T).init(self.allocator, value);
        }

        pub fn createWithInitializer(self: *Self, initializer: *const fn (*T) void) !Arc(T) {
            if (comptime Arc(T).use_svo) return Arc(T).initWithInitializer(self.allocator, initializer);
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                initializer(&node.data);
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            var shard_c = self.shardIndex();
            var attempts_c: usize = 0;
            while (attempts_c < self.active_shards) : (attempts_c += 1) {
                var head = self.freelists[shard_c].load(.acquire);
                while (head) |node| {
                    const next = node.next_in_freelist;
                    if (self.freelists[shard_c].cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| { head = new_head; std.atomic.spinLoopHint(); continue; }
                    if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                    node.counters.strong_count.store(1, .monotonic);
                    node.counters.weak_count.store(0, .monotonic);
                    node.allocator = self.allocator;
                    node.next_in_freelist = null;
                    initializer(&node.data);
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                }
                shard_c = (shard_c + 1) & (self.active_shards - 1);
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            return Arc(T).initWithInitializer(self.allocator, initializer);
        }

        pub fn createWithInitializerFallible(self: *Self, initializer: *const fn (*T) anyerror!void) !Arc(T) {
            if (comptime Arc(T).use_svo) return Arc(T).initWithInitializerFallible(self.allocator, initializer);
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                if (initializer(&node.data)) |_| {
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                } else |e| {
                    self.recycleSlow(node);
                    return e;
                }
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            var shard_d = self.shardIndex();
            var attempts_d: usize = 0;
            while (attempts_d < self.active_shards) : (attempts_d += 1) {
                var head = self.freelists[shard_d].load(.acquire);
                while (head) |node| {
                    const next = node.next_in_freelist;
                    if (self.freelists[shard_d].cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| { head = new_head; std.atomic.spinLoopHint(); continue; }
                    if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                    node.counters.strong_count.store(1, .monotonic);
                    node.counters.weak_count.store(0, .monotonic);
                    node.allocator = self.allocator;
                    node.next_in_freelist = null;
                    if (initializer(&node.data)) |_| {
                        const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                        return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                    } else |e| {
                        self.recycleSlow(node);
                        return e;
                    }
                }
                shard_d = (shard_d + 1) & (self.active_shards - 1);
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            return Arc(T).initWithInitializerFallible(self.allocator, initializer);
        }

        /// Create a cyclic Arc via pool using a constructor that receives a temporary Weak.
        pub fn createCyclic(self: *Self, ctor: *const fn (Arc(T).ArcWeak(T)) anyerror!T) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                @compileError("ArcPool.createCyclic requires heap Arc; SVO is not supported");
            }
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(1, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                var weak = Arc(T).ArcWeak(T){ .inner = node };
                const val = ctor(weak) catch |e| { self.recycleSlow(node); return e; };
                node.data = val;
                weak.release();
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_tls_miss.counter.fetchAdd(1, .monotonic);
            var shard_e = self.shardIndex();
            var attempts_e: usize = 0;
            while (attempts_e < self.active_shards) : (attempts_e += 1) {
                var head = self.freelists[shard_e].load(.acquire);
                while (head) |node| {
                    const next = node.next_in_freelist;
                    if (self.freelists[shard_e].cmpxchgWeak(head, next, .acquire, .monotonic)) |new_head| { head = new_head; std.atomic.spinLoopHint(); continue; }
                    if (EnableStats) _ = self.stats_reuses.counter.fetchAdd(1, .monotonic);
                    node.counters.strong_count.store(1, .monotonic);
                    node.counters.weak_count.store(1, .monotonic);
                    node.allocator = self.allocator;
                    node.next_in_freelist = null;
                    var weak = Arc(T).ArcWeak(T){ .inner = node };
                    const val = ctor(weak) catch |e| { self.recycleSlow(node); return e; };
                    node.data = val;
                    weak.release();
                    const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                }
                shard_e = (shard_e + 1) & (self.active_shards - 1);
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            return Arc(T).newCyclic(self.allocator, ctor);
        }

        pub fn recycle(self: *Self, arc: Arc(T)) void {
            if (arc.isInline()) return;
            if (tls_cache.push(arc.asPtr())) return;
            self.recycleSlow(arc.asPtr());
        }

        pub fn recycleSlow(self: *Self, node: *InnerType) void {
            const idx0 = tls_flush.count;
            if (idx0 < self.flush_batch) {
                tls_flush.buf[idx0] = node;
                tls_flush.count = idx0 + 1;
                // Early flush: flush_batch-2 eşiğinde boşalt.
                if (tls_flush.count < self.flush_batch - 2) return;
            }
            var i: usize = 0; const first = tls_flush.buf[0].?; var last: *InnerType = first; i = 1;
            while (i < tls_flush.count) : (i += 1) { const n = tls_flush.buf[i].?; last.next_in_freelist = n; last = n; }
            const shardb = self.shardIndex(); self.pushChain(shardb, first, last); tls_flush.count = 0;
        }

        pub fn drainThreadCache(self: *Self) void { tls_cache.clear(self); if (tls_flush.count > 0) { var i: usize = 0; const first = tls_flush.buf[0].?; var last: *InnerType = first; i = 1; while (i < tls_flush.count) : (i += 1) { const n = tls_flush.buf[i].?; last.next_in_freelist = n; last = n; } const shardf = self.shardIndex(); self.pushChain(shardf, first, last); tls_flush.count = 0; } }

        pub fn withThreadCache(self: *Self, body: fn (*Self, *anyopaque) anyerror!void, ctx: *anyopaque) !void {
            defer self.drainThreadCache();
            try body(self, ctx);
        }
    };
}

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
//! IMPORTANT LIMITATIONS:
//! - This pool is only effective for `Arc<T>` instances that are allocated
//!   on the heap. It has no effect on `Arc<T>` using Small Value Optimization (SVO).
//! - **T MUST be trivially destructible** (no deinit, no owned resources).
//!   The pool recycles memory WITHOUT calling T.deinit(), so types with cleanup
//!   requirements will leak resources. Use regular Arc for complex types.
//! - Refcount diagnostics may be inaccurate for pooled Arcs (counters are reset
//!   on each create, not on recycle).

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

        /// Initialization options
        pub const Options = struct {
            /// Override detected logical CPU count used to size shard count.
            logical_cpus: ?usize = null,
            /// Override effective TLS capacity (<= 64). When null, a heuristic
            /// based on shard count and Inner size is used.
            tls_active_capacity: ?usize = null,
        };

        /// Pick a shard index for the current thread.
        /// Uses pool and TLS addresses to spread contention.
        fn shardIndex(self: *const Self) usize {
            const a = @intFromPtr(self);
            const b = @intFromPtr(&tls_cache);
            return (a ^ b) & (self.active_shards - 1);
        }

        /// Push a linked chain [head..tail] to the shard freelist with one CAS.
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
        /// Initialize the pool. Chooses shard count and TLS effective capacity
        /// based on CPU count and `T` size. Warms a couple of nodes to smooth bursts.
        pub fn init(allocator: Allocator, opts: Options) Self {
            // SAFETY CHECK: Ensure T is trivially destructible (no deinit method)
            // This prevents resource leaks since recycle() doesn't call T.deinit()
            const type_info = @typeInfo(T);
            if (type_info == .@"struct" or type_info == .@"union" or type_info == .@"enum") {
                if (@hasDecl(T, "deinit")) {
                    @compileError("ArcPool requires T to be trivially destructible (no deinit method). " ++
                                  "Type '" ++ @typeName(T) ++ "' has a deinit method and will leak resources when recycled. " ++
                                  "Use regular Arc(T) instead of ArcPool for types with cleanup requirements.");
                }
            }

            // Helper to compute effective TLS capacity (kept here for easy future tuning).
            const computeTlsCapacity = struct {
                // Safer heuristic: prefer smaller TLS caches to bound retention.
                // - Size-based cap: 32 for small inner blocks, then 16/8 for larger.
                // - Shard-based cap: 32 for >=16 shards, 16 for >=8, else 8.
                fn run(shards: usize) usize {
                    const inner_sz = @sizeOf(InnerType);
                    const cap_by_size: usize = if (inner_sz <= 64) 32 else if (inner_sz <= 128) 16 else if (inner_sz <= 256) 8 else 8;
                    const cap_by_shards: usize = if (shards >= 16) 32 else if (shards >= 8) 16 else 8;
                    return if (cap_by_size < cap_by_shards) cap_by_size else cap_by_shards;
                }
            };
            // Choose active shards: next power-of-two of cpu count, clamped [8, MAX_SHARDS]
            const cpu_raw = std.Thread.getCpuCount() catch 0;
            const detected = if (cpu_raw == 0) 16 else cpu_raw;
            const cpu = if (opts.logical_cpus) |n| n else detected;
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

            // Choose effective TLS capacity: explicit override or heuristic.
            const tls_cap_eff_raw: usize = if (opts.tls_active_capacity) |v| v else computeTlsCapacity.run(target);
            // Final clamp for safety in mixed environments.
            const tls_cap_eff: usize = if (tls_cap_eff_raw > 32) 32 else tls_cap_eff_raw;
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
        /// Destroy the pool and free all cached nodes.
        /// Not thread-safe; ensure all threads have stopped using the pool.
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
        /// Pop one node from a shard (Treiber pop). If empty, round-robin steal
        /// from other shards. Returns null if all shards are empty.
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

        // (pop-batching removed; conservative single-pop kept for stability)

        /// Creates a new `Arc<T>`, reusing a recycled object if available.
        /// Fast path create: L1 (TLS) → L2 (sharded freelists) → L3 (allocator).
        /// SVO types bypass the pool entirely.
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
                node.auto_call_deinit = true;
                node.on_drop = null;
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
                node.auto_call_deinit = true;
                node.on_drop = null;
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
        /// Create with in-place initializer to avoid copying `T`.
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
                node.auto_call_deinit = true;
                node.on_drop = null;
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
                node.auto_call_deinit = true;
                node.on_drop = null;
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
        /// Fallible in-place creation. Reuses TLS/L2 nodes when available.
        pub fn createWithInitializerFallible(self: *Self, initializer: *const fn (*T) anyerror!void) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                return Arc(T).initWithInitializerFallible(self.allocator, initializer);
            }
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(0, .monotonic);
                node.allocator = self.allocator;
                node.auto_call_deinit = true;
                node.on_drop = null;
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
                node.auto_call_deinit = true;
                node.on_drop = null;
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
        /// Create a cyclic Arc using a temporary weak during construction.
        /// Mirrors Arc.newCyclic for pool-backed allocations.
        pub fn createCyclic(self: *Self, ctor: *const fn (ArcWeak(T)) anyerror!T) !Arc(T) {
            return self.createCyclicWithOptions(ctor, .{});
        }

        /// Same as `createCyclic` but allows customizing final-drop behavior.
        pub fn createCyclicWithOptions(self: *Self, ctor: *const fn (ArcWeak(T)) anyerror!T, opts: Arc(T).CyclicOptions) !Arc(T) {
            if (comptime Arc(T).use_svo) {
                @compileError("ArcPool.createCyclic requires heap Arc; SVO is not supported");
            }
            const o: Arc(T).CyclicOptions = opts;
            if (tls_cache.pop()) |node| {
                if (EnableStats) _ = self.stats_tls_hits.counter.fetchAdd(1, .monotonic);
                node.counters.strong_count.store(1, .monotonic);
                node.counters.weak_count.store(1, .monotonic);
                node.allocator = self.allocator;
                node.next_in_freelist = null;
                node.auto_call_deinit = o.auto_call_deinit;
                node.on_drop = o.on_drop;
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
                node.auto_call_deinit = o.auto_call_deinit;
                node.on_drop = o.on_drop;
                var weak = ArcWeak(T){ .inner = node };
                const val = ctor(weak) catch |e| { self.recycleSlow(node); return e; };
                node.data = val;
                weak.release();
                const tagged = Arc(T).InnerTaggedPtr.new(node, Arc(T).TAG_POINTER) catch unreachable;
                return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
            }
            if (EnableStats) _ = self.stats_allocs.counter.fetchAdd(1, .monotonic);
            self.alloc_mutex.lock(); defer self.alloc_mutex.unlock();
            return Arc(T).newCyclicWithOptions(self.allocator, ctor, o);
        }

        /// Recycles an `Arc` back into the pool for future reuse.
        /// For SVO'd Arcs, this is a no-op.
        ///
        /// CRITICAL: This function does NOT call T.deinit() or Arc.release().
        /// The caller must ensure:
        /// 1. T is trivially destructible (no cleanup needed), OR
        /// 2. T's resources have already been manually cleaned up
        ///
        /// The pooled memory will be reused with arbitrary T values in the future.
        /// Refcounts are reset when the memory is allocated again via create().
        ///
        /// Usage:
        /// ```zig
        /// const arc = try pool.create(42);  // T = u32 (trivially destructible)
        /// // Use arc...
        /// pool.recycle(arc);  // Safe - u32 needs no cleanup
        /// ```
        pub fn recycle(self: *Self, arc: Arc(T)) void {
            // SVO values live on the stack and are not pooled. Do nothing.
            if (arc.isInline()) return;

            const node = arc.asPtr();

            // NOTE: We do NOT call T.deinit() here. The pool assumes T is trivially
            // destructible. For safety/debugging, we could zero the data field:
            // node.data = undefined;

            // Reset refcounts to diagnostic state (will be properly set on next create())
            // This fixes issue #5 - counters no longer show stale lifetime data
            node.counters.strong_count.store(0, .monotonic);
            node.counters.weak_count.store(0, .monotonic);

            // TIER 1 (FASTEST): Try to push to the thread-local cache up to active capacity.
            if (tls_cache.count < self.tls_active_capacity and tls_cache.push(node)) {
                // Success, returned to local cache instantly.
                return;
            }

            // TIER 2 (SLOWER): TLS cache is full, push to the global freelist.
            self.recycleSlow(node);
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
        /// Flush the current thread’s TLS cache and pending batch into L2.
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
        /// Run `body(self, ctx)` ensuring the thread-local cache is flushed on exit.
        /// Useful for worker threads to contain bursts.
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

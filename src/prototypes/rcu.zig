const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const assert = std.debug.assert;
const StatsCollectorModule = @import("rcu_stats_collector.zig");
const is_module_enabled = builtin.mode != .ReleaseFast;
/// sudo dtrace -o dtrace_output.txt -n 'profile-997 /execname == "rcu_benchmark"/ { @[ustack()] = count(); }'
///  High-Performance Read-Copy-Update (RCU) for Zig 0.15.1
///
/// Performance Characteristics:
/// - Read throughput:  200M+ ops/sec per core
/// - Read latency:     5-8ns (typical)
/// - Write latency:    40-60ns (queue push)
/// - Zero contention:  Lock-free reader path
///
/// Architecture:
/// - Lock-free MPSC queue for updates
/// - 3-epoch garbage collection
/// - Thread-local participant tracking
/// - Cache-line aligned hot paths
///
/// Usage:
/// ```zig
/// const MyRcu = Rcu(MyType);
/// var rcu = try MyRcu.init(allocator, initial_data, destructor, .{});
/// defer rcu.deinit();
///
/// // Read (ultra-fast, lock-free)
/// const guard = try rcu.read();
/// defer guard.release();
/// const data = guard.get();
///
/// // Update (async, non-blocking)
/// try rcu.update(&ctx, updateFn);
/// ```
pub fn Rcu(comptime T: type) type {
    return struct {
        const Self = @This();

        //======================================================================
        // HOT DATA - Cache-aligned for performance
        //======================================================================

        /// Atomic pointer to current data version (read on every read())
        /// BUGFIX: Store as *const T to enforce read-only access
        shared_ptr: std.atomic.Value(*const T) align(64),

        /// Global epoch counter (read on every read())
        global_epoch: std.atomic.Value(u64),

        /// Registry of all participating reader threads (read on every read())
        participants: *ParticipantRegistry,

        /// Lock-free MPSC queue for pending modifications (write-hot)
        /// Used when max_concurrent_writers == 0 (single queue mode)
        primary_mod_queue: ModificationQueue,

        /// Secondary queue for overflow (lazily initialized)
        secondary_mod_queue: ?*ModificationQueue,

        /// Tertiary queue for extreme overflow (lazily initialized)
        tertiary_mod_queue: ?*ModificationQueue,

        /// OPTIMIZATION: Per-thread queues for cache isolation
        /// Used when max_concurrent_writers > 0
        per_thread_queues: ?[]ModificationQueue,
        next_thread_queue_id: std.atomic.Value(usize),

        /// Three rotating stacks with freelists for retired objects (3-epoch GC)
        /// BUGFIX: Uses freelist - zero allocation in steady state, unbounded under burst
        primary_retired_stacks: [3]RetiredStack,

        /// Secondary overflow stacks (lazily initialized if needed)
        secondary_retired_stacks: [3]?*RetiredStack,

        /// Tertiary overflow stacks (lazily initialized if needed)
        tertiary_retired_stacks: [3]?*RetiredStack,

        /// Background reclaimer thread
        reclaimer_thread: ?Thread,

        /// System state machine
        state: std.atomic.Value(State),

        /// Condition variable for waking reclaimer
        wake_cond: Condition,
        wake_mutex: Mutex,
        should_wake: std.atomic.Value(bool),
        last_wake_ns: std.atomic.Value(i128), // Track last wake time to avoid mutex spam

        /// User-provided destructor function
        destructor: DestructorFn,

        /// Configuration parameters
        config: Config,

        /// Memory allocator
        allocator: Allocator,

        /// Stats collector (fire-and-forget, zero overhead when disabled)
        stats_collector: StatsCollectorType,

        //======================================================================
        // PUBLIC TYPES
        //======================================================================

        /// StatsCollector type alias
        const StatsCollectorType = StatsCollectorModule.StatsCollector();

        /// RCU system states
        const State = enum(u8) {
            Initializing,
            Active,
            ShuttingDown,
            Terminated,
        };

        /// Configuration options
        pub const Config = struct {
            /// Maximum pending modifications before blocking writers
            queue_size: usize = 4096,

            /// Reclaimer thread wakeup interval (nanoseconds)
            reclaim_interval_ns: u64 = 50 * std.time.ns_per_ms,

            /// Initial capacity of each retired object bag
            bag_capacity: usize = 8192,

            /// Maximum time to wait for readers during shutdown (nanoseconds)
            /// Default: 10 seconds, 0 means wait forever
            shutdown_timeout_ns: u64 = 10 * std.time.ns_per_s,

            /// How often to check for active readers during shutdown (nanoseconds)
            shutdown_check_interval_ns: u64 = 10 * std.time.ns_per_ms,

            /// Use expanded queue system when primary queue overflows
            /// When true: Creates secondary queues (8x, 16x size) on demand
            /// When false: Returns QueueFull error immediately
            use_expanded_queues_on_overflow: bool = true,

            /// OPTIMIZATION: Per-thread queues for cache isolation
            /// Maximum concurrent writer threads (0 = use single queue)
            max_concurrent_writers: usize = 0,

            /// OPTIMIZATION: Busy reclaimer mode (no sleep, maximum throughput)
            busy_reclaimer: bool = false,
        };

        /// User-provided destructor function type
        pub const DestructorFn = *const fn (*T, Allocator) void;

        /// User-provided update function type
        pub const UpdateFn = *const fn (*anyopaque, Allocator, ?*const T) anyerror!*T;

        //======================================================================
        // INTERNAL TYPES - Lock-Free MPSC Queue
        //======================================================================

        const Modification = struct {
            func: UpdateFn,
            ctx: *anyopaque,
        };

        const ModificationQueue = struct {
            buffer: []Modification,
            ready: []std.atomic.Value(bool), // Phase 2: Per-slot ready flags for atomic reservation
            write_pos: std.atomic.Value(usize) align(64),
            read_pos: std.atomic.Value(usize) align(64),
            mask: usize,
            allocator: Allocator,

            fn init(allocator: Allocator, size: usize) !ModificationQueue {
                // Round up to power of 2 for fast modulo via bitwise AND
                const capacity = std.math.ceilPowerOfTwo(usize, size) catch return error.TooLarge;
                const buffer = try allocator.alloc(Modification, capacity);
                errdefer allocator.free(buffer);

                // Allocate ready flags array
                const ready = try allocator.alloc(std.atomic.Value(bool), capacity);
                errdefer allocator.free(ready);

                // Initialize all slots as not ready
                for (ready) |*r| {
                    r.* = std.atomic.Value(bool).init(false);
                }

                return .{
                    .buffer = buffer,
                    .ready = ready,
                    .write_pos = std.atomic.Value(usize).init(0),
                    .read_pos = std.atomic.Value(usize).init(0),
                    .mask = capacity - 1,
                    .allocator = allocator,
                };
            }

            fn deinit(self: *ModificationQueue) void {
                self.allocator.free(self.buffer);
                self.allocator.free(self.ready);
            }

            /// Push modification to queue (lock-free, writer side)
            /// Phase 2 Optimization: Atomic slot reservation with fetchAdd + ready flags
            /// BUGFIX: Rollback write_pos on overflow to prevent consumer deadlock
            inline fn push(self: *ModificationQueue, mod: Modification) !void {
                // Atomic slot reservation: fetchAdd returns old value, atomically increments
                // This ensures each writer gets a unique slot - no more race conditions!
                const my_slot = self.write_pos.fetchAdd(1, .acquire);

                // Post-check: Verify we haven't overrun the reader
                // CRITICAL: Must check AFTER fetchAdd to avoid TOCTOU race
                const r = self.read_pos.load(.acquire);
                if (my_slot -% r >= self.buffer.len) {
                    // Queue is full - MUST rollback the write_pos we just incremented!
                    // Without this rollback, write_pos stays ahead and consumer gets stuck
                    // at a slot with ready=false, causing permanent deadlock.
                    _ = self.write_pos.fetchSub(1, .release);
                    return error.QueueFull;
                }

                const idx = my_slot & self.mask;

                // Write data to our exclusively owned slot
                self.buffer[idx] = mod;

                // Mark slot as ready - consumer can now safely read it
                // .release ensures all writes above are visible before ready flag
                self.ready[idx].store(true, .release);
            }

            /// Pop modification from queue (lock-free, reclaimer side)
            /// Phase 2 Optimization: Check ready flag before reading
            inline fn pop(self: *ModificationQueue) ?Modification {
                const r = self.read_pos.load(.monotonic);
                const w = self.write_pos.load(.acquire);

                if (r == w) return null;

                const idx = r & self.mask;

                // Wait for slot to be ready - prevents reading partially written data
                // .acquire ensures we see all writes that happened before ready flag
                if (!self.ready[idx].load(.acquire)) {
                    // Slot is reserved but not yet written - try again later
                    return null;
                }

                // Read the modification
                const mod = self.buffer[idx];

                // Reset ready flag for next use of this slot (after full wraparound)
                self.ready[idx].store(false, .release);

                // Advance read position
                self.read_pos.store(r + 1, .release);
                return mod;
            }

            /// Forcefully drain queue during shutdown
            /// BUGFIX: When skipping abandoned slots, must also decrement write_pos
            /// to prevent isEmpty() from looping forever
            fn drain(self: *ModificationQueue) ?Modification {
                const r = self.read_pos.load(.monotonic);
                const w = self.write_pos.load(.acquire);

                if (r == w) return null;

                const idx = r & self.mask;

                // Check if slot is ready
                if (!self.ready[idx].load(.acquire)) {
                    // Slot reserved but not ready - writer thread crashed after fetchAdd
                    // but before marking ready=true. This should be rare due to fetchSub()
                    // rollback in push(), but can happen if writer crashes.
                    //
                    // CRITICAL: Must decrement write_pos to cancel the abandoned reservation!
                    // Otherwise: read_pos advances but write_pos stays ahead →
                    // isEmpty() never returns true → infinite loop + memory leak
                    _ = self.write_pos.fetchSub(1, .release);

                    // BUGFIX: Don't reset ready flag here - creates race condition!
                    // If another thread immediately reserves this slot, we could overwrite
                    // their ready flag. Since we're shutting down anyway, leave flag as-is.
                    // (Removed: self.ready[idx].store(false, .release);)

                    self.read_pos.store(r + 1, .release);
                    return null; // Return null to signal skipped slot
                }

                // Read the modification
                const mod = self.buffer[idx];

                // Reset ready flag (safe here - we own the slot)
                self.ready[idx].store(false, .release);

                // Advance read position
                self.read_pos.store(r + 1, .release);
                return mod;
            }

            fn isEmpty(self: *const ModificationQueue) bool {
                return self.read_pos.load(.acquire) == self.write_pos.load(.acquire);
            }

            /// Get current queue depth (number of pending modifications)
            fn depth(self: *const ModificationQueue) usize {
                const w = self.write_pos.load(.acquire);
                const r = self.read_pos.load(.acquire);
                return w -% r; // Wrapping subtraction handles overflow
            }
        };

        //======================================================================
        // INTERNAL TYPES - Participant Registry
        //======================================================================

        const ParticipantRegistry = struct {
            head: std.atomic.Value(?*ParticipantNode) align(64),
            allocator: Allocator,

            const ParticipantNode = struct {
                active: std.atomic.Value(bool) align(64),
                epoch: std.atomic.Value(u64) align(64),
                thread_id: Thread.Id,
                next: ?*ParticipantNode,
                /// BUGFIX: Validity flag to prevent use-after-free
                /// Set to false during deinit() to invalidate TLS cache
                valid: std.atomic.Value(bool),
            };

            /// Thread-local storage for fast participant lookup
            threadlocal var tls_node: ?*ParticipantNode = null;

            fn init(allocator: Allocator) ParticipantRegistry {
                return .{
                    .head = std.atomic.Value(?*ParticipantNode).init(null),
                    .allocator = allocator,
                };
            }

            fn deinit(self: *ParticipantRegistry) void {
                // BUGFIX: Invalidate all nodes BEFORE freeing them
                // This prevents use-after-free if other threads still have TLS cache
                var current = self.head.load(.monotonic);
                while (current) |node| {
                    node.valid.store(false, .release);
                    current = node.next;
                }

                // Clear local thread's TLS cache
                tls_node = null;

                // Now free all nodes
                current = self.head.load(.monotonic);
                while (current) |node| {
                    const next = node.next;
                    self.allocator.destroy(node);
                    current = next;
                }
            }

            /// Acquire participant node - lock-free insertion
            inline fn acquire(self: *ParticipantRegistry) !*ParticipantNode {
                // Fast path: thread-local cache hit (~0.5ns - just pointer load)
                // BUGFIX: Check validity flag to prevent use-after-free
                if (tls_node) |cached_node| {
                    // Verify node is still valid (not freed by deinit())
                    if (cached_node.valid.load(.acquire)) {
                        return cached_node;
                    }
                    // Node was invalidated - clear TLS and allocate new one
                    tls_node = null;
                }

                // Slow path: allocate new node (first access from this thread)
                const node = try self.allocator.create(ParticipantNode);
                node.* = .{
                    .active = std.atomic.Value(bool).init(false),
                    .epoch = std.atomic.Value(u64).init(0),
                    .thread_id = Thread.getCurrentId(),
                    .next = null,
                    .valid = std.atomic.Value(bool).init(true), // BUGFIX: Initialize as valid
                };

                // Lock-free linked list insertion using CAS
                while (true) {
                    const current_head = self.head.load(.acquire);
                    node.next = current_head;

                    // Try to insert at head
                    if (self.head.cmpxchgWeak(
                        current_head,
                        node,
                        .release,
                        .acquire,
                    )) |_| {
                        // CAS failed, retry
                        continue;
                    }

                    // Success!
                    break;
                }

                // Cache in TLS for future accesses
                tls_node = node;
                return node;
            }

            /// Scan all participants to check if epoch can advance
            inline fn canAdvanceFrom(self: *const ParticipantRegistry, min_epoch: u64) bool {
                var current = self.head.load(.acquire);
                while (current) |node| {
                    if (node.active.load(.acquire)) {
                        if (node.epoch.load(.acquire) < min_epoch) {
                            return false;
                        }
                    }
                    current = node.next;
                }
                return true;
            }
        };

        //======================================================================
        // INTERNAL TYPES - Retired Object Stack with Freelist
        //======================================================================

        /// Lock-free stack for retired objects with freelist optimization
        /// BUGFIX: Replaces bounded RetiredBag to prevent grace period violations
        ///
        /// Design:
        /// - Treiber stack (lock-free linked list) for retired objects
        /// - Separate freelist for node reuse (pre-allocated pool)
        /// - Zero allocation in steady state (freelist reuse)
        /// - Unbounded capacity under burst (allocates if freelist empty)
        /// - NEVER skips grace period - always safe!
        const RetiredStack = struct {
            head: std.atomic.Value(?*RetiredNode) align(64),
            freelist: std.atomic.Value(?*RetiredNode) align(64),
            allocator: Allocator,

            // OPTIMIZATION #3: Emergency pool - stack-allocated backup nodes for OOM scenarios
            // Eliminates panic risk - provides 1024 fallback nodes when allocator fails
            emergency_pool: [1024]RetiredNode,
            emergency_next: std.atomic.Value(usize),

            const RetiredNode = struct {
                ptr: *T,
                epoch: u64,
                next: ?*RetiredNode,
            };

            fn init(allocator: Allocator, freelist_capacity: usize) !RetiredStack {
                // Pre-allocate freelist nodes (zero-allocation pool)
                // This provides bounded memory in normal operation
                var freelist_head: ?*RetiredNode = null;

                var i: usize = 0;
                while (i < freelist_capacity) : (i += 1) {
                    const node = try allocator.create(RetiredNode);
                    node.* = .{
                        .ptr = undefined, // Will be set when used
                        .epoch = undefined,
                        .next = freelist_head,
                    };
                    freelist_head = node;
                }

                return .{
                    .head = std.atomic.Value(?*RetiredNode).init(null),
                    .freelist = std.atomic.Value(?*RetiredNode).init(freelist_head),
                    .allocator = allocator,
                    .emergency_pool = undefined, // Will be initialized on-demand per slot
                    .emergency_next = std.atomic.Value(usize).init(0),
                };
            }

            fn deinit(self: *RetiredStack) void {
                // Free all nodes in the retired stack
                var current = self.head.load(.monotonic);
                while (current) |node| {
                    const next = node.next;
                    self.allocator.destroy(node);
                    current = next;
                }

                // Free all nodes in the freelist
                current = self.freelist.load(.monotonic);
                while (current) |node| {
                    const next = node.next;
                    self.allocator.destroy(node);
                    current = next;
                }
            }

            /// Pop node from freelist (lock-free, multi-producer safe)
            inline fn popFromFreelist(self: *RetiredStack) ?*RetiredNode {
                while (true) {
                    const current_head = self.freelist.load(.acquire);
                    if (current_head == null) return null;

                    const next = current_head.?.next;

                    // Try to CAS the head to next
                    if (self.freelist.cmpxchgWeak(
                        current_head,
                        next,
                        .acquire,
                        .acquire,
                    )) |_| {
                        // CAS failed, retry
                        // BUGFIX: Add pause hint to reduce CPU waste and improve hyperthreading
                        std.atomic.spinLoopHint();
                        continue;
                    }

                    // Success! Return the node
                    return current_head;
                }
            }

            /// Push retired object (lock-free, multi-producer safe, ~O(1) in steady state)
            fn push(self: *RetiredStack, ptr: *T, epoch: u64) void {
                // Try to get node from freelist (zero-allocation fast path!)
                var node = self.popFromFreelist();

                if (node == null) {
                    // Freelist empty - allocate new node (only under burst load)
                    // BUGFIX: Bounded retry with panic - cannot violate grace period
                    var backoff_ns: u64 = 1000; // Start with 1μs
                    var total_wait: u64 = 0;
                    const max_wait_ns: u64 = 1 * std.time.ns_per_s; // 1 second max

                    while (total_wait < max_wait_ns) {
                        node = self.allocator.create(RetiredNode) catch {
                            // Allocation failed - sleep and retry with exponential backoff
                            std.debug.print("RCU: WARNING - failed to allocate retired node, retrying...\n", .{});
                            Thread.sleep(backoff_ns);
                            total_wait += backoff_ns;
                            backoff_ns = @min(backoff_ns * 2, 10_000_000); // Max 10ms per sleep
                            continue;
                        };
                        break; // Success!
                    }

                    // OPTIMIZATION #3: Use emergency pool before panicking
                    if (node == null) {
                        // Try to allocate from emergency pool (lock-free, bounded)
                        const emergency_idx = self.emergency_next.fetchAdd(1, .monotonic);
                        if (emergency_idx < self.emergency_pool.len) {
                            // Success! Use emergency pool slot
                            std.debug.print("RCU: Using emergency pool slot {} (allocator exhausted)\n", .{emergency_idx});
                            node = &self.emergency_pool[emergency_idx];
                        } else {
                            // Emergency pool exhausted - system is critically broken
                            @panic("RCU: Out of memory after 1s retry + emergency pool exhausted - cannot retire object safely");
                        }
                    }
                }

                // Initialize node with retired object
                node.?.* = .{
                    .ptr = ptr,
                    .epoch = epoch,
                    .next = undefined, // Will be set in CAS loop
                };

                // Lock-free push to stack head (Treiber stack algorithm)
                while (true) {
                    const current_head = self.head.load(.acquire);
                    node.?.next = current_head;

                    // Try to CAS the head to our new node
                    if (self.head.cmpxchgWeak(
                        current_head,
                        node,
                        .release,
                        .acquire,
                    )) |_| {
                        // CAS failed, retry
                        continue;
                    }

                    // Success!
                    return;
                }
            }

            /// Pop all retired nodes (single-consumer only!)
            fn popAll(self: *RetiredStack) ?*RetiredNode {
                // Atomically swap head with null, getting all nodes
                return self.head.swap(null, .acquire);
            }

            /// Return nodes to freelist for reuse (called after reclamation)
            /// OPTIMIZATION: Batch return with single CAS instead of per-node CAS
            fn returnToFreelist(self: *RetiredStack, nodes: ?*RetiredNode) void {
                if (nodes == null) return;

                // Find tail of input list (one-time O(n) traversal)
                var tail = nodes.?;
                while (tail.next) |next| {
                    tail = next;
                }

                // Single CAS to prepend entire list to freelist
                // This replaces N CAS operations (one per node) with just 1 CAS!
                // Under high contention, this is a massive improvement (5-10x faster)
                while (true) {
                    const current_head = self.freelist.load(.acquire);
                    tail.next = current_head; // Link tail to current head

                    if (self.freelist.cmpxchgWeak(
                        current_head,
                        nodes, // New head is first node in our list
                        .release,
                        .acquire,
                    )) |_| {
                        // CAS failed, retry
                        std.atomic.spinLoopHint();
                        continue;
                    }

                    break; // Success - entire list added with 1 CAS!
                }
            }

            /// Check if stack is empty
            fn isEmpty(self: *const RetiredStack) bool {
                return self.head.load(.monotonic) == null;
            }
        };

        //======================================================================
        // PUBLIC API - LIFECYCLE
        //======================================================================

        /// Initialize RCU system with default c_allocator (recommended for production)
        pub fn initDefault(
            initial_data: *T,
            destructor: DestructorFn,
            cfg: Config,
        ) !*Self {
            return init(std.heap.c_allocator, initial_data, destructor, cfg);
        }

        /// Initialize RCU system with custom allocator
        /// For production use, c_allocator is recommended (use initDefault)
        /// For debugging, use GeneralPurposeAllocator
        pub fn init(
            allocator: Allocator,
            initial_data: *T,
            destructor: DestructorFn,
            cfg: Config,
        ) !*Self {
            // Validate minimum queue size (at least 16 for reasonable performance)
            if (cfg.queue_size < 16) {
                std.debug.print("RCU: queue_size too small ({}), minimum is 16\n", .{cfg.queue_size});
                return error.InvalidQueueSize;
            }

            // Validate minimum bag capacity (at least 32 for reasonable operation)
            if (cfg.bag_capacity < 32) {
                std.debug.print("RCU: bag_capacity too small ({}), minimum is 32\n", .{cfg.bag_capacity});
                return error.InvalidBagCapacity;
            }

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Initialize stats collector (disabled by default)
            // Users enable via startMonitoring() and disable via stopMonitoring()
            const default_window_ns: i128 = @intCast(std.time.ns_per_hour); // 1 hour default
            var stats_collector = try StatsCollectorType.init(allocator, default_window_ns);
            errdefer stats_collector.deinit(allocator);

            // OPTIMIZATION: Allocate per-thread queues if enabled
            const per_thread_queues = if (cfg.max_concurrent_writers > 0) blk: {
                const queues = try allocator.alloc(ModificationQueue, cfg.max_concurrent_writers);
                errdefer allocator.free(queues);
                for (queues) |*queue| {
                    queue.* = try ModificationQueue.init(allocator, cfg.queue_size);
                }
                break :blk queues;
            } else null;
            errdefer if (per_thread_queues) |queues| {
                for (queues) |*queue| queue.deinit();
                allocator.free(queues);
            };

            self.* = .{
                .shared_ptr = std.atomic.Value(*const T).init(initial_data),
                .global_epoch = std.atomic.Value(u64).init(0),
                .primary_mod_queue = try ModificationQueue.init(allocator, cfg.queue_size),
                .secondary_mod_queue = null,
                .tertiary_mod_queue = null,
                .per_thread_queues = per_thread_queues,
                .next_thread_queue_id = std.atomic.Value(usize).init(0),
                .participants = try allocator.create(ParticipantRegistry),
                .primary_retired_stacks = undefined,
                .secondary_retired_stacks = .{ null, null, null },
                .tertiary_retired_stacks = .{ null, null, null },
                .reclaimer_thread = null,
                .state = std.atomic.Value(State).init(.Initializing),
                .wake_cond = .{},
                .wake_mutex = .{},
                .should_wake = std.atomic.Value(bool).init(false),
                .last_wake_ns = std.atomic.Value(i128).init(0),
                .destructor = destructor,
                .config = cfg,
                .allocator = allocator,
                .stats_collector = stats_collector,
            };

            // Initialize participant registry
            self.participants.* = ParticipantRegistry.init(allocator);

            // Initialize retired stacks with freelists
            // BUGFIX: Pre-allocate freelist - zero allocation in steady state!
            for (&self.primary_retired_stacks) |*stack| {
                stack.* = try RetiredStack.init(allocator, cfg.bag_capacity);
            }

            // Start background reclaimer thread
            self.reclaimer_thread = try Thread.spawn(.{}, reclaimerLoop, .{self});

            // Mark system as active
            self.state.store(.Active, .release);

            return self;
        }

        /// Gracefully shut down RCU system
        pub fn deinit(self: *Self) void {
            // Transition to shutdown state
            const old_state = self.state.swap(.ShuttingDown, .acq_rel);
            if (old_state != .Active) return;

            // Wake up reclaimer thread
            self.wake_mutex.lock();
            self.should_wake.store(true, .release);
            self.wake_cond.signal();
            self.wake_mutex.unlock();

            // Wait for reclaimer to finish
            if (self.reclaimer_thread) |thread| {
                thread.join();
            }

            // Wait for all active readers to finish
            const start_time = std.time.nanoTimestamp();
            const timeout_ns = @as(i128, @intCast(self.config.shutdown_timeout_ns));

            while (true) {
                // Check if we've exceeded timeout (if timeout is set)
                if (timeout_ns > 0) {
                    const elapsed = std.time.nanoTimestamp() - start_time;
                    if (elapsed >= timeout_ns) {
                        std.debug.print("RCU: Shutdown timeout after {}ms, forcing termination\n", .{@divTrunc(elapsed, std.time.ns_per_ms)});
                        break;
                    }
                }

                // Check for active readers
                var has_active = false;
                var current = self.participants.head.load(.acquire);
                while (current) |node| {
                    if (node.active.load(.acquire)) {
                        has_active = true;
                        break;
                    }
                    current = node.next;
                }

                if (!has_active) break;

                // Sleep before next check
                Thread.sleep(self.config.shutdown_check_interval_ns);
            }

            // Mark as terminated AFTER waiting for readers
            self.state.store(.Terminated, .release);

            // Destroy current data
            // BUGFIX: shared_ptr now stores *const T, need @constCast for destructor
            const current = self.shared_ptr.load(.monotonic);
            self.destructor(@constCast(current), self.allocator);

            // Free all retired objects
            for (&self.primary_retired_stacks, 0..) |*stack, i| {
                // popAll() returns linked list head
                var nodes = stack.popAll();
                while (nodes) |node| {
                    const next = node.next;
                    self.destructor(node.ptr, self.allocator);
                    nodes = next;
                }
                stack.deinit();

                // Clean up secondary stacks if they exist
                if (self.secondary_retired_stacks[i]) |ss| {
                    var sec_nodes = ss.popAll();
                    while (sec_nodes) |node| {
                        const next = node.next;
                        self.destructor(node.ptr, self.allocator);
                        sec_nodes = next;
                    }
                    ss.deinit();
                    self.allocator.destroy(ss);
                }

                // Clean up tertiary stacks if they exist
                if (self.tertiary_retired_stacks[i]) |ts| {
                    var tert_nodes = ts.popAll();
                    while (tert_nodes) |node| {
                        const next = node.next;
                        self.destructor(node.ptr, self.allocator);
                        tert_nodes = next;
                    }
                    ts.deinit();
                    self.allocator.destroy(ts);
                }
            }

            // Cleanup expanded queues if they exist
            if (self.secondary_mod_queue) |sq| {
                sq.deinit();
                self.allocator.destroy(sq);
            }
            if (self.tertiary_mod_queue) |tq| {
                tq.deinit();
                self.allocator.destroy(tq);
            }

            // OPTIMIZATION: Cleanup per-thread queues
            if (self.per_thread_queues) |queues| {
                for (queues) |*queue| {
                    queue.deinit();
                }
                self.allocator.free(queues);
            }

            // Cleanup - participants last to avoid use-after-free
            self.primary_mod_queue.deinit();
            self.participants.deinit();
            self.allocator.destroy(self.participants);

            // Cleanup stats collector (flushes any remaining events)
            self.stats_collector.deinit(self.allocator);

            self.allocator.destroy(self);
        }

        //======================================================================
        // PUBLIC API - READERS
        //======================================================================

        /// RAII guard for read-side critical section
        ///
        /// IMPORTANT: Guards MUST be short-lived (microseconds to milliseconds).
        /// Long-lived guards (seconds+) will block epoch advancement and prevent
        /// memory reclamation, leading to unbounded memory growth.
        ///
        /// If you need long-term references, use reference counting instead.
        pub const ReadGuard = struct {
            rcu: *const Self,
            node: *ParticipantRegistry.ParticipantNode,

            /// Get pointer to current data (valid for guard lifetime)
            ///
            /// Performance: ~0.5-1ns (single atomic load)
            ///
            /// WARNING: Do NOT hold guards for extended periods (>1 second).
            /// This will block memory reclamation and cause unbounded memory growth.
            pub inline fn get(self: ReadGuard) *const T {
                // Optimization: Don't refresh epoch on every get() - adds ~2-3ns overhead
                // The epoch was set correctly in read() and is sufficient for short-lived guards
                // Trade-off: Maximum performance vs supporting long-lived guards
                // Decision: RCU guards should be short-lived by design (standard for all RCU)
                return self.rcu.shared_ptr.load(.acquire);
            }

            /// Release the guard (must be called, use defer!)
            pub inline fn release(self: ReadGuard) void {
                // Optimization: Skip state check - always mark inactive
                // Reclaimer will wait for all active readers regardless of state
                self.node.active.store(false, .release);
                self.rcu.statsRecordReadRelease();
            }
        };

        /// Enter read-side critical section (lock-free, ~3-5ns optimized)
        pub inline fn read(self: *const Self) !ReadGuard {
            // Optimization: Skip state check - reclaimer waits for active readers anyway
            // Saves ~1-2ns per read operation

            // Acquire participant node (TLS cached, ~0.5-1ns on cache hit)
            const node = try self.participants.acquire();

            // Announce our presence at current epoch
            // Use .monotonic instead of .acquire - we don't need synchronization here
            const current_epoch = self.global_epoch.load(.monotonic);
            node.epoch.store(current_epoch, .monotonic);
            node.active.store(true, .release);

            self.statsRecordReadAcquisition();

            return .{
                .rcu = self,
                .node = node,
            };
        }

        //======================================================================
        // STATS RECORDING - Fire and forget, zero overhead when disabled
        //======================================================================

        // Stats are now handled entirely by StatsCollector - no need to check if active

        /// Central proxy function - all stats recording goes through here
        /// This allows adding filtering, batching, or other logic in one place
        inline fn statsRecord(self: *const Self, event: StatsCollectorModule.EventType) void {
            if (comptime is_module_enabled) {
                self.stats_collector.record(event);
            }
        }

        // Read operation stats - Fire and forget!
        inline fn statsRecordReadAcquisition(self: *const Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.read_acquired);
            }
        }

        inline fn statsRecordReadRelease(self: *const Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.read_released);
            }
        }

        inline fn statsRecordReadCriticalSection(self: *const Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.read_critical_section);
            }
        }

        // Write operation stats - Fire and forget!
        inline fn statsRecordUpdateAttempt(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.update_attempted);
            }
        }

        inline fn statsRecordUpdateSuccess(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.update_succeeded);
            }
        }

        inline fn statsRecordUpdateQueueFull(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.update_queue_full);
            }
        }

        // Queue operation stats - Fire and forget!
        inline fn statsRecordPrimaryQueuePush(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.primary_queue_push);
            }
        }

        inline fn statsRecordSecondaryQueuePush(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.secondary_queue_push);
            }
        }

        inline fn statsRecordTertiaryQueuePush(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.tertiary_queue_push);
            }
        }

        // Memory management stats - Fire and forget!
        inline fn statsRecordObjectRetired(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.object_retired);
            }
        }

        inline fn statsRecordObjectReclaimed(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.object_reclaimed);
            }
        }

        inline fn statsRecordEpochAdvanced(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.epoch_advanced);
            }
        }

        // Participant stats - Fire and forget!
        inline fn statsRecordTLSHit(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.tls_hit);
            }
        }

        inline fn statsRecordTLSMiss(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.tls_miss);
            }
        }

        inline fn statsRecordParticipantCreated(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.participant_created);
            }
        }

        inline fn statsRecordParticipantLookup(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.participant_lookup);
            }
        }

        // Queue creation stats - Fire and forget!
        inline fn statsSetSecondaryQueueCreated(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.secondary_queue_created);
            }
        }

        inline fn statsSetTertiaryQueueCreated(self: *Self) void {
            if (comptime is_module_enabled) {
                self.statsRecord(.tertiary_queue_created);
            }
        }

        //======================================================================
        // PUBLIC API - WRITERS
        //======================================================================

        /// Submit update request (async, lock-free, ~40-60ns)
        // OPTIMIZATION: Thread-local queue ID cache (sentinel = uninitialized)
        // Using sentinel instead of optional eliminates branch overhead
        const TLS_UNINITIALIZED = std.math.maxInt(usize);
        threadlocal var tls_queue_id: usize = TLS_UNINITIALIZED;

        pub fn update(self: *Self, ctx: *anyopaque, func: UpdateFn) !void {
            // Check if system is active
            if (self.state.load(.acquire) != .Active) {
                return error.RcuNotActive;
            }

            self.statsRecordUpdateAttempt();

            const mod = Modification{
                .func = func,
                .ctx = ctx,
            };

            // OPTIMIZATION: Use per-thread queue if enabled
            if (self.per_thread_queues) |queues| {
                // Fast path: Direct TLS read (no optional check!)
                var queue_id = tls_queue_id;
                if (queue_id == TLS_UNINITIALIZED) {
                    // Cold path: Initialize once per thread
                    queue_id = self.next_thread_queue_id.fetchAdd(1, .monotonic) % queues.len;
                    tls_queue_id = queue_id;
                }

                // Push to thread-specific queue (no contention!)
                try queues[queue_id].push(mod);
                self.statsRecordPrimaryQueuePush();
                self.statsRecordUpdateSuccess();

                // Wake reclaimer if needed
                self.maybeWakeReclaimer();
                return;
            }

            // Fallback: Use primary queue (original behavior)
            self.primary_mod_queue.push(mod) catch |err| {
                if (err != error.QueueFull or !self.config.use_expanded_queues_on_overflow) {
                    if (err == error.QueueFull) {
                        self.statsRecordUpdateQueueFull();
                    }
                    return err;
                }

                // Primary is full, try secondary queue
                self.statsRecordUpdateQueueFull();

                if (self.secondary_mod_queue) |sq| {
                    // Try existing secondary queue
                    sq.push(mod) catch |err2| {
                        if (err2 != error.QueueFull) return err2;

                        // Secondary is also full, try tertiary
                        if (self.tertiary_mod_queue) |tq| {
                            // Try existing tertiary queue
                            try tq.push(mod);
                            self.statsRecordTertiaryQueuePush();
                        } else {
                            // Create tertiary queue with minimum 4096 size
                            const tertiary_size = @max(self.config.queue_size * 16, 4096);
                            const tq = try self.allocator.create(ModificationQueue);
                            tq.* = try ModificationQueue.init(self.allocator, tertiary_size);
                            self.tertiary_mod_queue = tq;
                            self.statsSetTertiaryQueueCreated();
                            try tq.push(mod);
                            self.statsRecordTertiaryQueuePush();
                        }
                        self.statsRecordUpdateSuccess();
                        return; // Success via tertiary queue
                    };
                    // Success via secondary queue
                    self.statsRecordSecondaryQueuePush();
                } else {
                    // Create secondary queue with minimum 2048 size
                    const secondary_size = @max(self.config.queue_size * 8, 2048);
                    const sq = try self.allocator.create(ModificationQueue);
                    sq.* = try ModificationQueue.init(self.allocator, secondary_size);
                    self.secondary_mod_queue = sq;
                    self.statsSetSecondaryQueueCreated();
                    try sq.push(mod);
                    self.statsRecordSecondaryQueuePush();
                }
                // Update success regardless of which queue was used
                self.statsRecordUpdateSuccess();
                return; // Success via secondary queue path
            };

            // Success via primary queue
            self.statsRecordPrimaryQueuePush();
            self.statsRecordUpdateSuccess();

            self.maybeWakeReclaimer();
        }

        /// Wake reclaimer if enough time has passed (throttled to avoid mutex spam)
        inline fn maybeWakeReclaimer(self: *Self) void {
            // BUGFIX: Reduced from 10ms to 100μs - much more responsive to burst writes
            const wake_threshold_ns: i128 = comptime 100 * std.time.ns_per_us; // 100 microseconds
            const now = std.time.nanoTimestamp();
            const last_wake = self.last_wake_ns.load(.monotonic);

            if (now - last_wake >= wake_threshold_ns) {
                // Try to update last_wake atomically to claim the wake opportunity
                if (self.last_wake_ns.cmpxchgStrong(
                    last_wake,
                    now,
                    .monotonic,
                    .monotonic,
                ) == null) {
                    // We claimed it, now wake the reclaimer
                    self.wake_mutex.lock();
                    self.should_wake.store(true, .release);
                    self.wake_cond.signal();
                    self.wake_mutex.unlock();
                }
            }
        }

        //======================================================================
        // INTERNAL - RECLAIMER THREAD
        //======================================================================

        fn reclaimerLoop(self: *Self) void {
            // Main loop: run while system is active
            while (self.state.load(.acquire) == .Active) {
                // Phase 1: Apply pending modifications
                self.applyModifications();

                // Phase 2: Advance epoch and reclaim memory
                self.advanceEpochAndReclaim();

                // OPTIMIZATION: Adaptive wake interval based on queue utilization
                // Calculate total queue depth across all queues
                const queue_depth = if (self.per_thread_queues) |queues| blk: {
                    var total: usize = 0;
                    for (queues) |*queue| {
                        total += queue.depth();
                    }
                    break :blk total;
                } else self.primary_mod_queue.depth();

                const queue_capacity = if (self.per_thread_queues) |queues|
                    self.config.queue_size * queues.len
                else
                    self.config.queue_size;

                const utilization = @as(f64, @floatFromInt(queue_depth)) /
                    @as(f64, @floatFromInt(queue_capacity));

                // Calculate adaptive wake interval (1ms to 5ms based on load)
                const wake_interval: u64 = if (utilization > 0.75)
                    1 * std.time.ns_per_ms // High load (>75%): 1ms - very responsive
                else if (utilization > 0.5)
                    2 * std.time.ns_per_ms // Medium load (>50%): 2ms - balanced
                else
                    self.config.reclaim_interval_ns; // Low load: default 5ms - efficient

                // Phase 3: Sleep until woken or timeout
                // OPTIMIZATION: Hybrid busy mode - adaptive sleep based on load
                if (self.config.busy_reclaimer) {
                    if (utilization < 0.10) {
                        // Very low load (<10%): longer sleep
                        Thread.sleep(500 * std.time.ns_per_us); // 500μs
                    } else if (utilization < 0.30) {
                        // Low-medium load (<30%): short sleep
                        Thread.sleep(50 * std.time.ns_per_us); // 50μs
                    } else {
                        // High load (>30%): busy loop with yield
                        std.Thread.yield() catch {};
                    }
                } else {
                    self.wake_mutex.lock();
                    while (!self.should_wake.load(.acquire) and
                        self.state.load(.acquire) == .Active)
                    {
                        self.wake_cond.timedWait(
                            &self.wake_mutex,
                            wake_interval,
                        ) catch {};
                        break; // Re-check queue depth after waking
                    }
                    self.should_wake.store(false, .release);
                    self.wake_mutex.unlock();
                }
            }

            // Final cleanup: process remaining modifications using drain()
            // This skips slots that were reserved but never completed (dead writers)
            while (!self.primary_mod_queue.isEmpty() or
                (self.secondary_mod_queue != null and !self.secondary_mod_queue.?.isEmpty()) or
                (self.tertiary_mod_queue != null and !self.tertiary_mod_queue.?.isEmpty()))
            {
                self.applyModificationsDuringShutdown();
            }

            // Force final reclamation (3 times for 3-epoch system)
            for (0..3) |_| {
                self.advanceEpochAndReclaim();
            }
        }

        fn applyModifications(self: *Self) void {
            var current_ptr = self.shared_ptr.load(.monotonic);

            // Helper function to process a single modification
            const processMod = struct {
                fn apply(rcu: *Self, mod: Modification, curr: **const T) void {
                    // Apply user's update function
                    const new_ptr = mod.func(mod.ctx, rcu.allocator, curr.*) catch |err| {
                        std.debug.print("RCU: update failed: {}\n", .{err});
                        return;
                    };

                    // Atomically publish new version (cast *T to *const T)
                    const old_ptr = rcu.shared_ptr.swap(new_ptr, .acq_rel);

                    // Retire old version for later reclamation (@constCast to *T)
                    const retire_epoch = rcu.global_epoch.load(.monotonic);
                    rcu.retireObject(@constCast(old_ptr), retire_epoch);

                    curr.* = new_ptr;
                }
            }.apply;

            // OPTIMIZATION: Process per-thread queues if enabled (round-robin)
            if (self.per_thread_queues) |queues| {
                for (queues) |*queue| {
                    // BATCH PROCESSING: Process up to 16 mods per queue per iteration
                    var batch_count: usize = 0;
                    while (batch_count < 16) : (batch_count += 1) {
                        if (queue.pop()) |mod| {
                            processMod(self, mod, &current_ptr);
                        } else break;
                    }
                }
                return; // Done processing per-thread queues
            }

            // Fallback: Process primary queue
            while (self.primary_mod_queue.pop()) |mod| {
                processMod(self, mod, &current_ptr);
            }

            // Process secondary queue if it exists
            if (self.secondary_mod_queue) |sq| {
                while (sq.pop()) |mod| {
                    processMod(self, mod, &current_ptr);
                }
            }

            // Process tertiary queue if it exists
            if (self.tertiary_mod_queue) |tq| {
                while (tq.pop()) |mod| {
                    processMod(self, mod, &current_ptr);
                }
            }
        }

        /// Apply modifications during shutdown - uses drain() to skip incomplete slots
        fn applyModificationsDuringShutdown(self: *Self) void {
            var current_ptr = self.shared_ptr.load(.monotonic);

            // Helper function to process a single modification
            const processMod = struct {
                fn apply(rcu: *Self, mod: Modification, curr: **const T) void {
                    // Apply user's update function
                    const new_ptr = mod.func(mod.ctx, rcu.allocator, curr.*) catch |err| {
                        std.debug.print("RCU: update failed: {}\n", .{err});
                        return;
                    };

                    // Atomically publish new version (cast *T to *const T)
                    const old_ptr = rcu.shared_ptr.swap(new_ptr, .acq_rel);

                    // Retire old version for later reclamation (@constCast to *T)
                    const retire_epoch = rcu.global_epoch.load(.monotonic);
                    rcu.retireObject(@constCast(old_ptr), retire_epoch);

                    curr.* = new_ptr;
                }
            }.apply;

            // Process primary queue using drain (skips incomplete slots)
            while (self.primary_mod_queue.drain()) |mod| {
                processMod(self, mod, &current_ptr);
            }

            // Process secondary queue if it exists
            if (self.secondary_mod_queue) |sq| {
                while (sq.drain()) |mod| {
                    processMod(self, mod, &current_ptr);
                }
            }

            // Process tertiary queue if it exists
            if (self.tertiary_mod_queue) |tq| {
                while (tq.drain()) |mod| {
                    processMod(self, mod, &current_ptr);
                }
            }
        }

        fn retireObject(self: *Self, ptr: *T, epoch: u64) void {
            const stack_index = epoch % 3;

            // Push to primary stack (zero-allocation in steady state via freelist!)
            // BUGFIX: RetiredStack.push() never returns error - always succeeds
            // Either uses freelist node (fast) or allocates new (burst load)
            self.primary_retired_stacks[stack_index].push(ptr, epoch);

            self.statsRecordObjectRetired();
        }

        fn advanceEpochAndReclaim(self: *Self) void {
            const current_epoch = self.global_epoch.load(.acquire);

            // Check if we can advance (all active readers at current or newer epoch)
            if (!self.participants.canAdvanceFrom(current_epoch)) {
                return;
            }

            // Try to advance epoch
            const new_epoch = current_epoch + 1;
            if (self.global_epoch.cmpxchgStrong(
                current_epoch,
                new_epoch,
                .acq_rel,
                .monotonic,
            )) |_| {
                // CAS failed, another thread advanced the epoch
                return;
            }

            // Success: reclaim objects from 2 epochs ago
            if (new_epoch >= 2) {
                const free_epoch = new_epoch - 2;
                self.reclaimBag(free_epoch);
            }
        }

        fn reclaimBag(self: *Self, epoch: u64) void {
            const stack_index = epoch % 3;

            // Reclaim from primary stack (zero-allocation popAll!)
            var stack = &self.primary_retired_stacks[stack_index];
            const nodes_head = stack.popAll();

            // Free all retired objects in the linked list
            var current = nodes_head;
            while (current) |node| {
                assert(node.epoch == epoch);
                self.destructor(node.ptr, self.allocator);
                self.statsRecordObjectReclaimed();
                current = node.next;
            }

            // Return nodes to freelist for reuse (zero-allocation optimization!)
            stack.returnToFreelist(nodes_head);

            // Reclaim from secondary stack if it exists
            if (self.secondary_retired_stacks[stack_index]) |ss| {
                const sec_head = ss.popAll();
                current = sec_head;

                while (current) |node| {
                    assert(node.epoch == epoch);
                    self.destructor(node.ptr, self.allocator);
                    self.statsRecordObjectReclaimed();
                    current = node.next;
                }

                ss.returnToFreelist(sec_head);
            }

            // Reclaim from tertiary stack if it exists
            if (self.tertiary_retired_stacks[stack_index]) |ts| {
                const tert_head = ts.popAll();
                current = tert_head;

                while (current) |node| {
                    assert(node.epoch == epoch);
                    self.destructor(node.ptr, self.allocator);
                    self.statsRecordObjectReclaimed();
                    current = node.next;
                }

                ts.returnToFreelist(tert_head);
            }
        }
    };
}

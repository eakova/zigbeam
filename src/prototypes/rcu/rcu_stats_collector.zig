const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

/// Runtime statistics for monitoring - Pure data container (counters only!)
const Stats = struct {
    // Read operations
    read_acquisitions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_releases: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_critical_sections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Write operations
    update_attempts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    update_successes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    update_queue_fulls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Queue statistics
    primary_queue_pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    secondary_queue_pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tertiary_queue_pushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Overflow tracking
    secondary_queue_created: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tertiary_queue_created: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    secondary_bags_created: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    tertiary_bags_created: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // Reclamation statistics
    epochs_advanced: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    objects_retired: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    objects_reclaimed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    immediate_frees: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Reclaimer activity
    reclaimer_wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    modifications_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Participant tracking
    participants_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    participant_cache_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tls_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tls_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    participant_lookups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Non-atomic snapshot of statistics for reporting
pub const StatsSnapshot = struct {
    // Stats state (public data)
    enabled: bool,

    // Window information
    generation: u32,
    window_start_ns: i128,
    window_expired: bool,

    // Read operations
    read_acquisitions: u64,
    read_releases: u64,

    // Write operations
    update_attempts: u64,
    update_successes: u64,
    update_queue_fulls: u64,

    // Queue statistics
    primary_queue_pushes: u64,
    secondary_queue_pushes: u64,
    tertiary_queue_pushes: u64,

    // Overflow tracking
    secondary_queue_created: bool,
    tertiary_queue_created: bool,
    secondary_bags_created: u8,
    tertiary_bags_created: u8,

    // Reclamation statistics
    epochs_advanced: u64,
    objects_retired: u64,
    objects_reclaimed: u64,
    immediate_frees: u64,

    // Reclaimer activity
    reclaimer_wakeups: u64,
    modifications_processed: u64,

    // Participant tracking
    participants_created: u64,
    participant_cache_hits: u64,
    tls_hits: u64,
    tls_misses: u64,
    participant_lookups: u64,

    /// Calculate read/write ratio
    pub fn getReadWriteRatio(self: StatsSnapshot) f64 {
        if (self.update_successes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.read_acquisitions)) /
            @as(f64, @floatFromInt(self.update_successes));
    }

    /// Calculate queue full rate as percentage
    pub fn getQueueFullRate(self: StatsSnapshot) f64 {
        if (self.update_attempts == 0) return 0.0;
        return (@as(f64, @floatFromInt(self.update_queue_fulls)) /
            @as(f64, @floatFromInt(self.update_attempts))) * 100.0;
    }

    /// Get total queue capacity used
    pub fn getTotalQueueCapacity(self: StatsSnapshot, config: anytype) u64 {
        var capacity = config.queue_size;
        if (self.secondary_queue_created) {
            capacity += config.queue_size * 2; // Secondary is 2x
        }
        if (self.tertiary_queue_created) {
            capacity += config.queue_size * 4; // Tertiary is 4x
        }
        return capacity;
    }
};

/// Stats events that can be recorded
pub const EventType = enum(u8) {
    // Read operations
    read_acquired,
    read_released,
    read_critical_section,

    // Write operations
    update_attempted,
    update_succeeded,
    update_queue_full,

    // Queue operations
    primary_queue_push,
    secondary_queue_push,
    tertiary_queue_push,

    // Memory management
    epoch_advanced,
    object_retired,
    object_reclaimed,
    immediate_free,

    // Reclaimer activity
    reclaimer_wakeup,
    modification_processed,

    // Participant tracking
    participant_created,
    participant_cache_hit,
    tls_hit,
    tls_miss,
    participant_lookup,

    // Overflow events
    secondary_queue_created,
    tertiary_queue_created,
    secondary_bag_created,
    tertiary_bag_created,
};

/// Event-based stats collector with true zero overhead when disabled
/// Fire-and-forget architecture - no branches in hot paths
pub fn StatsCollector() type {
    return struct {
        const Self = @This();

        /// Lock-free event queue using ring buffer
        pub const EventQueue = struct {
            ring: []EventType,
            head: std.atomic.Value(u64) align(64),
            tail: std.atomic.Value(u64) align(64),
            allocator: Allocator,

            const DEFAULT_SIZE = 65536; // 64K events

            pub fn init(allocator: Allocator) !EventQueue {
                const ring = try allocator.alloc(EventType, DEFAULT_SIZE);
                // Initialize all events to a valid default value
                @memset(ring, EventType.read_acquired);
                return .{
                    .ring = ring,
                    .head = std.atomic.Value(u64).init(0),
                    .tail = std.atomic.Value(u64).init(0),
                    .allocator = allocator,
                };
            }

            pub fn deinit(self: *EventQueue) void {
                self.allocator.free(self.ring);
            }

            /// Push event to queue (lock-free, wait-free)
            pub inline fn push(self: *EventQueue, event: EventType) void {
                const pos = self.head.fetchAdd(1, .monotonic);
                const idx = pos & (self.ring.len - 1);
                self.ring[idx] = event;
            }

            /// Process batch of events (called by stats thread)
            pub fn processBatch(
                self: *EventQueue,
                stats: *Stats,
                batch_size: u64,
                enabled: bool,
            ) u64 {
                const tail = self.tail.load(.monotonic);
                const head = self.head.load(.acquire);

                if (tail >= head) return 0;

                const to_process = @min(head - tail, batch_size);
                if (to_process == 0) return 0;

                // Local counters to batch atomic updates
                var counters = [_]u64{0} ** @typeInfo(EventType).@"enum".fields.len;

                // Process events in batch
                var i: u64 = 0;
                while (i < to_process) : (i += 1) {
                    const pos = tail + i;
                    const idx = pos & (self.ring.len - 1);
                    const event = self.ring[idx];
                    counters[@intFromEnum(event)] += 1;
                }

                // Update stats atomics once per batch (only if enabled)
                if (enabled) {
                    self.updateStats(stats, &counters);
                }

                // Advance tail
                self.tail.store(tail + to_process, .release);

                return to_process;
            }

            fn updateStats(self: *EventQueue, stats: *Stats, counters: []const u64) void {
                _ = self;

                // Read operations
                if (counters[@intFromEnum(EventType.read_acquired)] > 0) {
                    _ = stats.read_acquisitions.fetchAdd(counters[@intFromEnum(EventType.read_acquired)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.read_released)] > 0) {
                    _ = stats.read_releases.fetchAdd(counters[@intFromEnum(EventType.read_released)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.read_critical_section)] > 0) {
                    _ = stats.read_critical_sections.fetchAdd(counters[@intFromEnum(EventType.read_critical_section)], .monotonic);
                }

                // Write operations
                if (counters[@intFromEnum(EventType.update_attempted)] > 0) {
                    _ = stats.update_attempts.fetchAdd(counters[@intFromEnum(EventType.update_attempted)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.update_succeeded)] > 0) {
                    _ = stats.update_successes.fetchAdd(counters[@intFromEnum(EventType.update_succeeded)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.update_queue_full)] > 0) {
                    _ = stats.update_queue_fulls.fetchAdd(counters[@intFromEnum(EventType.update_queue_full)], .monotonic);
                }

                // Queue operations
                if (counters[@intFromEnum(EventType.primary_queue_push)] > 0) {
                    _ = stats.primary_queue_pushes.fetchAdd(counters[@intFromEnum(EventType.primary_queue_push)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.secondary_queue_push)] > 0) {
                    _ = stats.secondary_queue_pushes.fetchAdd(counters[@intFromEnum(EventType.secondary_queue_push)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.tertiary_queue_push)] > 0) {
                    _ = stats.tertiary_queue_pushes.fetchAdd(counters[@intFromEnum(EventType.tertiary_queue_push)], .monotonic);
                }

                // Memory management
                if (counters[@intFromEnum(EventType.epoch_advanced)] > 0) {
                    _ = stats.epochs_advanced.fetchAdd(counters[@intFromEnum(EventType.epoch_advanced)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.object_retired)] > 0) {
                    _ = stats.objects_retired.fetchAdd(counters[@intFromEnum(EventType.object_retired)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.object_reclaimed)] > 0) {
                    _ = stats.objects_reclaimed.fetchAdd(counters[@intFromEnum(EventType.object_reclaimed)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.immediate_free)] > 0) {
                    _ = stats.immediate_frees.fetchAdd(counters[@intFromEnum(EventType.immediate_free)], .monotonic);
                }

                // Reclaimer activity
                if (counters[@intFromEnum(EventType.reclaimer_wakeup)] > 0) {
                    _ = stats.reclaimer_wakeups.fetchAdd(counters[@intFromEnum(EventType.reclaimer_wakeup)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.modification_processed)] > 0) {
                    _ = stats.modifications_processed.fetchAdd(counters[@intFromEnum(EventType.modification_processed)], .monotonic);
                }

                // Participant tracking
                if (counters[@intFromEnum(EventType.participant_created)] > 0) {
                    _ = stats.participants_created.fetchAdd(counters[@intFromEnum(EventType.participant_created)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.participant_cache_hit)] > 0) {
                    _ = stats.participant_cache_hits.fetchAdd(counters[@intFromEnum(EventType.participant_cache_hit)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.tls_hit)] > 0) {
                    _ = stats.tls_hits.fetchAdd(counters[@intFromEnum(EventType.tls_hit)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.tls_miss)] > 0) {
                    _ = stats.tls_misses.fetchAdd(counters[@intFromEnum(EventType.tls_miss)], .monotonic);
                }
                if (counters[@intFromEnum(EventType.participant_lookup)] > 0) {
                    _ = stats.participant_lookups.fetchAdd(counters[@intFromEnum(EventType.participant_lookup)], .monotonic);
                }

                // Overflow events (these are one-time flags)
                if (counters[@intFromEnum(EventType.secondary_queue_created)] > 0) {
                    stats.secondary_queue_created.store(true, .release);
                }
                if (counters[@intFromEnum(EventType.tertiary_queue_created)] > 0) {
                    stats.tertiary_queue_created.store(true, .release);
                }
                if (counters[@intFromEnum(EventType.secondary_bag_created)] > 0) {
                    _ = stats.secondary_bags_created.fetchAdd(@intCast(counters[@intFromEnum(EventType.secondary_bag_created)]), .monotonic);
                }
                if (counters[@intFromEnum(EventType.tertiary_bag_created)] > 0) {
                    _ = stats.tertiary_bags_created.fetchAdd(@intCast(counters[@intFromEnum(EventType.tertiary_bag_created)]), .monotonic);
                }
            }
        };

        /// No-op queue for disabled stats (compiles to nothing)
        pub const NoOpQueue = struct {
            pub inline fn push(self: *const NoOpQueue, event: EventType) void {
                _ = self;
                _ = event;
                // Compiles to absolutely nothing!
            }

            pub fn deinit(self: *NoOpQueue) void {
                _ = self;
            }
        };

        /// Stats processor thread context (internal worker)
        pub const Processor = struct {
            queue: *EventQueue,
            stats: *Stats,
            should_stop: std.atomic.Value(bool),
            thread: ?Thread,
            parent_enabled: *std.atomic.Value(bool), // Pointer to parent StatsCollector's is_enabled

            const BATCH_SIZE = 1024;
            const INTERVAL_NS = 500_000; // 500 microseconds

            pub fn init(
                queue: *EventQueue,
                stats: *Stats,
                parent_enabled: *std.atomic.Value(bool),
            ) Processor {
                return .{
                    .queue = queue,
                    .stats = stats,
                    .should_stop = std.atomic.Value(bool).init(true),
                    .thread = null,
                    .parent_enabled = parent_enabled,
                };
            }

            pub fn start(self: *Processor) !void {
                // Don't start if already running
                if (self.thread != null) return;

                self.should_stop.store(false, .release);
                self.thread = try Thread.spawn(.{}, processorLoop, .{self});
            }

            pub fn stop(self: *Processor) void {
                self.should_stop.store(true, .release);
                if (self.thread) |t| {
                    t.join();
                    self.thread = null;
                }

                // Process any remaining events
                const enabled = self.parent_enabled.load(.monotonic);
                while (self.queue.processBatch(self.stats, BATCH_SIZE, enabled) > 0) {}
            }

            fn processorLoop(self: *Processor) void {
                while (!self.should_stop.load(.acquire)) {
                    // Read current state (set by StatsCollector)
                    const enabled = self.parent_enabled.load(.monotonic);

                    // Process events in batches
                    const processed = self.queue.processBatch(self.stats, BATCH_SIZE, enabled);

                    // If we processed a full batch, continue immediately
                    // Otherwise sleep briefly
                    if (processed < BATCH_SIZE) {
                        Thread.sleep(INTERVAL_NS);
                    }
                }
            }
        };

        /// Control block - all atomic state in one allocation
        const ControlBlock = struct {
            is_enabled: std.atomic.Value(bool),
            generation: std.atomic.Value(u32),
            window_start_ns: std.atomic.Value(i128),
            window_expired: std.atomic.Value(bool),
        };

        control: *ControlBlock, // Single heap allocation for all control state
        window_ns: i128, // Stats time window duration
        allocator: Allocator, // Store allocator to free heap allocations in deinit
        fast_is_enabled_ptr: *bool, // Direct pointer to raw bool for maximum performance in hot path

        /// Union type for true zero overhead when disabled
        inner: union(enum) {
            enabled: struct {
                queue: *EventQueue,
                processor: *Processor,
            },
            disabled: NoOpQueue,
        },

        /// Initialize collector (stats disabled by default)
        pub fn init(allocator: Allocator, window_ns: i128) !Self {
            // Always create the full stats infrastructure
            // Create and own the Stats struct
            const stats = try allocator.create(Stats);
            errdefer allocator.destroy(stats);
            stats.* = Stats{};

            const queue = try allocator.create(EventQueue);
            errdefer allocator.destroy(queue);
            queue.* = try EventQueue.init(allocator);
            errdefer queue.deinit();

            // Allocate control block - one allocation for all atomic state
            const control = try allocator.create(ControlBlock);
            errdefer allocator.destroy(control);
            control.* = .{
                .is_enabled = std.atomic.Value(bool).init(false),
                .generation = std.atomic.Value(u32).init(0),
                .window_start_ns = std.atomic.Value(i128).init(0),
                .window_expired = std.atomic.Value(bool).init(false),
            };

            const processor = try allocator.create(Processor);
            errdefer allocator.destroy(processor);
            processor.* = Processor.init(queue, stats, &control.is_enabled);

            // Return initialized Self
            return Self{
                .control = control,
                .window_ns = window_ns,
                .allocator = allocator,
                .fast_is_enabled_ptr = @ptrCast(&control.is_enabled), // Direct pointer to underlying bool
                .inner = .{
                    .enabled = .{
                        .queue = queue,
                        .processor = processor,
                    },
                },
            };
        }

        /// Deinitialize collector
        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (self.inner) {
                .enabled => |e| {
                    e.processor.stop();
                    e.queue.deinit();
                    const stats = e.processor.stats;
                    allocator.destroy(e.processor);
                    allocator.destroy(e.queue);
                    allocator.destroy(stats);
                    // Free control block
                    allocator.destroy(self.control);
                },
                .disabled => |*d| d.deinit(),
            }
        }

        /// Record an event (compiles to nothing when disabled!)
        pub inline fn record(self: *const Self, event: EventType) void {
            if (comptime false) {
                // Use direct atomic load on raw bool pointer for maximum performance
                if (@atomicLoad(bool, self.fast_is_enabled_ptr, .monotonic)) {
                    //if (self.control.is_enabled.load(.monotonic)) {
                    switch (self.inner) {
                        .enabled => |e| e.queue.push(event),
                        .disabled => |*d| d.push(event),
                    }
                }
            }
        }

        /// Batch record multiple events
        pub inline fn recordMultiple(self: *const Self, event: EventType, count: u64) void {
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                self.record(event);
            }
        }

        /// Start monitoring - enable stats collection and begin new window
        pub fn startMonitoring(self: *Self) !void {
            switch (self.inner) {
                .enabled => |e| {
                    // Already enabled? Nothing to do
                    if (self.control.is_enabled.load(.monotonic)) return;

                    self.control.is_enabled.store(true, .release);
                    // Starting monitoring - initialize window
                    const now = std.time.nanoTimestamp();
                    self.control.window_start_ns.store(now, .monotonic);
                    _ = self.control.generation.fetchAdd(1, .monotonic);
                    self.control.window_expired.store(false, .monotonic);
                    try e.processor.start();
                },
                .disabled => {},
            }
        }

        /// Stop monitoring - disable stats collection
        pub fn stopMonitoring(self: *Self) void {
            switch (self.inner) {
                .enabled => {
                    self.control.is_enabled.store(false, .release);
                },
                .disabled => {},
            }
        }

        /// Check and update window expiration (internal helper)
        fn checkAndUpdateWindowExpiration(self: *const Self) void {
            // Already expired? Nothing to do
            if (self.control.window_expired.load(.monotonic)) return;

            const window_start = self.control.window_start_ns.load(.monotonic);
            if (window_start == 0) return; // Not initialized

            const now = std.time.nanoTimestamp();
            if (now - window_start > self.window_ns) {
                // Mark as expired and auto-disable stats collection
                self.control.window_expired.store(true, .monotonic);
                self.control.is_enabled.store(false, .monotonic);
            }
        }

        /// Create a snapshot of stats (non-atomic copy)
        fn createSnapshot(
            stats: *const Stats,
            enabled: bool,
            control: *const ControlBlock,
        ) StatsSnapshot {
            return .{
                .enabled = enabled,
                .generation = control.generation.load(.monotonic),
                .window_start_ns = control.window_start_ns.load(.monotonic),
                .window_expired = control.window_expired.load(.monotonic),
                .read_acquisitions = stats.read_acquisitions.load(.monotonic),
                .read_releases = stats.read_releases.load(.monotonic),
                .update_attempts = stats.update_attempts.load(.monotonic),
                .update_successes = stats.update_successes.load(.monotonic),
                .update_queue_fulls = stats.update_queue_fulls.load(.monotonic),
                .primary_queue_pushes = stats.primary_queue_pushes.load(.monotonic),
                .secondary_queue_pushes = stats.secondary_queue_pushes.load(.monotonic),
                .tertiary_queue_pushes = stats.tertiary_queue_pushes.load(.monotonic),
                .secondary_queue_created = stats.secondary_queue_created.load(.monotonic),
                .tertiary_queue_created = stats.tertiary_queue_created.load(.monotonic),
                .secondary_bags_created = stats.secondary_bags_created.load(.monotonic),
                .tertiary_bags_created = stats.tertiary_bags_created.load(.monotonic),
                .epochs_advanced = stats.epochs_advanced.load(.monotonic),
                .objects_retired = stats.objects_retired.load(.monotonic),
                .objects_reclaimed = stats.objects_reclaimed.load(.monotonic),
                .immediate_frees = stats.immediate_frees.load(.monotonic),
                .reclaimer_wakeups = stats.reclaimer_wakeups.load(.monotonic),
                .modifications_processed = stats.modifications_processed.load(.monotonic),
                .participants_created = stats.participants_created.load(.monotonic),
                .participant_cache_hits = stats.participant_cache_hits.load(.monotonic),
                .tls_hits = stats.tls_hits.load(.monotonic),
                .tls_misses = stats.tls_misses.load(.monotonic),
                .participant_lookups = stats.participant_lookups.load(.monotonic),
            };
        }

        /// Get a snapshot of current runtime statistics
        pub fn getStats(self: *const Self) StatsSnapshot {
            // Flush all pending events to ensure accurate snapshot
            const mutable_self = @constCast(self);
            mutable_self.flush();

            switch (self.inner) {
                .enabled => |e| {
                    const enabled = self.control.is_enabled.load(.monotonic);
                    // Check and update window expiration
                    if (enabled) {
                        self.checkAndUpdateWindowExpiration();
                    }
                    return createSnapshot(e.processor.stats, enabled, self.control);
                },
                .disabled => return StatsSnapshot{
                    .enabled = false,
                    .generation = 0,
                    .window_start_ns = 0,
                    .window_expired = true,
                    .read_acquisitions = 0,
                    .read_releases = 0,
                    .update_attempts = 0,
                    .update_successes = 0,
                    .update_queue_fulls = 0,
                    .primary_queue_pushes = 0,
                    .secondary_queue_pushes = 0,
                    .tertiary_queue_pushes = 0,
                    .secondary_queue_created = false,
                    .tertiary_queue_created = false,
                    .secondary_bags_created = 0,
                    .tertiary_bags_created = 0,
                    .epochs_advanced = 0,
                    .objects_retired = 0,
                    .objects_reclaimed = 0,
                    .immediate_frees = 0,
                    .reclaimer_wakeups = 0,
                    .modifications_processed = 0,
                    .participants_created = 0,
                    .participant_cache_hits = 0,
                    .tls_hits = 0,
                    .tls_misses = 0,
                    .participant_lookups = 0,
                },
            }
        }

        /// Reset stats and start a new collection window
        pub fn resetStats(self: *Self) void {
            switch (self.inner) {
                .enabled => |e| {
                    if (self.control.is_enabled.load(.monotonic)) {
                        const now = std.time.nanoTimestamp();

                        // Start new generation
                        // Use .monotonic - already synchronized via is_enabled
                        _ = self.control.generation.fetchAdd(1, .monotonic);
                        self.control.window_start_ns.store(now, .monotonic);
                        self.control.window_expired.store(false, .monotonic);

                        // Reset all counters to zero
                        e.processor.stats.read_acquisitions.store(0, .monotonic);
                        e.processor.stats.read_releases.store(0, .monotonic);
                        e.processor.stats.read_critical_sections.store(0, .monotonic);
                        e.processor.stats.update_attempts.store(0, .monotonic);
                        e.processor.stats.update_successes.store(0, .monotonic);
                        e.processor.stats.update_queue_fulls.store(0, .monotonic);
                        e.processor.stats.primary_queue_pushes.store(0, .monotonic);
                        e.processor.stats.secondary_queue_pushes.store(0, .monotonic);
                        e.processor.stats.tertiary_queue_pushes.store(0, .monotonic);
                        e.processor.stats.epochs_advanced.store(0, .monotonic);
                        e.processor.stats.objects_retired.store(0, .monotonic);
                        e.processor.stats.objects_reclaimed.store(0, .monotonic);
                        e.processor.stats.immediate_frees.store(0, .monotonic);
                        e.processor.stats.reclaimer_wakeups.store(0, .monotonic);
                        e.processor.stats.modifications_processed.store(0, .monotonic);
                        e.processor.stats.participants_created.store(0, .monotonic);
                        e.processor.stats.participant_cache_hits.store(0, .monotonic);
                        e.processor.stats.tls_hits.store(0, .monotonic);
                        e.processor.stats.tls_misses.store(0, .monotonic);
                        e.processor.stats.participant_lookups.store(0, .monotonic);

                        // Don't reset overflow flags - they're structural
                    }
                },
                .disabled => {},
            }
        }

        /// Force processing of all pending events (useful for shutdown)
        pub fn flush(self: *Self) void {
            switch (self.inner) {
                .enabled => |e| {
                    const enabled = self.control.is_enabled.load(.monotonic);
                    while (e.queue.processBatch(e.processor.stats, 65536, enabled) > 0) {}
                },
                .disabled => {},
            }
        }

        /// Get remaining time in stats window (nanoseconds)
        pub fn getWindowRemaining(self: *const Self) i128 {
            return switch (self.inner) {
                .enabled => {
                    const enabled = self.control.is_enabled.load(.monotonic);
                    if (!enabled) return 0;

                    // Check and update window expiration
                    self.checkAndUpdateWindowExpiration();

                    if (self.control.window_expired.load(.monotonic)) return 0;

                    const now = std.time.nanoTimestamp();
                    const window_start = self.control.window_start_ns.load(.monotonic);
                    const elapsed = now - window_start;
                    return self.window_ns - elapsed;
                },
                .disabled => 0,
            };
        }

        /// Get queue depth (for monitoring)
        pub fn getQueueDepth(self: *const Self) u64 {
            return switch (self.inner) {
                .enabled => |e| {
                    const head = e.queue.head.load(.acquire);
                    const tail = e.queue.tail.load(.acquire);
                    return if (head >= tail) head - tail else 0;
                },
                .disabled => 0,
            };
        }
    };
}

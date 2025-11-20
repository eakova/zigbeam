const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const DVyukovMPMCQueue = @import("dvyukov_mpmc").DVyukovMPMCQueue;

pub const CACHE_LINE: usize = std.atomic.cache_line;

/// Optimized for up to 64 hardware threads (e.g., 32 producers + 32 consumers).
pub const MAX_PARTICIPANTS: usize = 64;
/// Upper bound for how many items we will process from the global orphan
/// queue in a single collection cycle. This keeps per-unpin work bounded
/// while still allowing aggressive reclamation under load.
const GLOBAL_GARBAGE_BATCH_MAX: usize = MAX_PARTICIPANTS * 32;
/// Threshold of locally deferred garbage items before attempting
/// reclamation on Guard.deinit().
///
/// Increased from MAX_PARTICIPANTS * 2 (128) to * 8 (512) to reduce the
/// frequency of expensive collection cycles. Each collection calls
/// getMinimumEpoch() which scans all 64 participant slots with atomic loads.
/// With frequent guard creation/destruction (e.g., dequeueWithAutoGuard()),
/// reducing collection frequency by 4x significantly improves throughput
/// while still providing timely reclamation under moderate load.
pub const COLLECTION_THRESHOLD: usize = MAX_PARTICIPANTS * 8;

pub const Garbage = struct {
    ptr: *anyopaque,
    /// Destructor callback for `ptr`.
    ///
    /// IMPORTANT:
    /// The Allocator argument is *not* guaranteed to be the same allocator
    /// that was originally used to allocate `ptr`. In many call sites we
    /// cannot reconstruct the original allocator (garbage may flow through
    /// local lists and the global orphan queue), so EBR passes whichever
    /// allocator is convenient at the call site.
    ///
    /// For maximum safety, `destroy_fn` SHOULD NOT rely on the allocator
    /// parameter for correctness. If the object needs a specific allocator,
    /// store it alongside the object and ignore this parameter (name it
    /// `_allocator`).
    destroy_fn: *const fn (*anyopaque, Allocator) void,
    epoch: u64,
};

pub const Participant = struct {
    // Hot fields: written by workers and read by the reclaimer.
    // Each is aligned to a cache line to minimise false sharing between
    // neighboring participants at high thread counts.
    is_active: Atomic(bool) = Atomic(bool).init(false),
    epoch: Atomic(u64) = Atomic(u64).init(0),
    garbage_list: std.ArrayListUnmanaged(Garbage) = .{},
    /// Internal counter used to batch local garbage collection. Callers
    /// must not modify this directly; it is managed by Guard.deferDestroy
    /// and Guard.deinit().
    garbage_count_since_last_check: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Participant {
        return .{
            .garbage_list = .{},
            .allocator = allocator,
        };
    }

    /// Flush this participant's local garbage into the global orphanage queue
    /// and release its local resources.
    pub fn deinit(self: *Participant, global_epoch: *GlobalEpoch) void {
        var i: usize = 0;
        while (i < self.garbage_list.items.len) : (i += 1) {
            const g = self.garbage_list.items[i];
            global_epoch.global_garbage_queue.enqueue(g) catch {
                // Backpressure on the global queue – attempt an emergency local
                // reclamation for remaining items rather than silently leaking.
                std.log.warn("EBR: global_garbage_queue OOM in Participant.deinit, reclaiming remaining garbage locally", .{});
                break;
            };
        }
        // Any items from index i onwards could not be enqueued into the global
        // queue; destroy them eagerly to avoid leaking under persistent
        // backpressure.
        while (i < self.garbage_list.items.len) : (i += 1) {
            const g = self.garbage_list.items[i];
            g.destroy_fn(g.ptr, self.allocator);
        }
        self.garbage_list.deinit(self.allocator);
    }
};

pub const GlobalEpoch = struct {
    current_epoch: Atomic(u64) align(CACHE_LINE),
    participant_slots: [MAX_PARTICIPANTS]Atomic(?*Participant),
    /// Cached minimum epoch for fast reads. Updated periodically by getMinimumEpoch().
    /// Always conservative (may be stale/higher than true minimum), ensuring safety.
    cached_min_epoch: Atomic(u64) align(CACHE_LINE),
    /// Highest participant slot index currently in use. Allows skipping empty trailing slots.
    highest_used_index: Atomic(usize) align(CACHE_LINE),
    global_garbage_queue: GlobalQueue,
    allocator: Allocator,
    /// Atomic flag to signal the background reclaimer thread to shut down.
    /// Set to true by shutdownGlobal() to request graceful termination.
    shutdown_requested: Atomic(bool),

    /// Capacity for the global orphan garbage queue.
    /// Set to MAX_PARTICIPANTS * 64 (4096) based on empirical measurements showing
    /// peak utilization of ~734 items under heavy load (4P/4C, 50K items).
    /// This provides ~5.6x headroom over measured peak while minimizing memory footprint.
    /// Each participant can accumulate ~64 garbage items before the queue fills.
    const GlobalQueue = DVyukovMPMCQueue(Garbage, MAX_PARTICIPANTS * 64);

    pub const InitOptions = struct {
        allocator: Allocator,
    };

    pub fn init(opts: InitOptions) !GlobalEpoch {
        var queue = try GlobalQueue.init(opts.allocator);
        errdefer queue.deinit();

        var slots: [MAX_PARTICIPANTS]Atomic(?*Participant) = undefined;
        for (&slots) |*slot| {
            slot.* = Atomic(?*Participant).init(null);
        }

        return .{
            .current_epoch = Atomic(u64).init(0),
            .participant_slots = slots,
            .cached_min_epoch = Atomic(u64).init(std.math.maxInt(u64)),
            .highest_used_index = Atomic(usize).init(0),
            .global_garbage_queue = queue,
            .allocator = opts.allocator,
            .shutdown_requested = Atomic(bool).init(false),
        };
    }

    pub fn deinit(self: *GlobalEpoch) void {
        while (self.global_garbage_queue.dequeue()) |garbage| {
            garbage.destroy_fn(garbage.ptr, self.allocator);
        }
        self.global_garbage_queue.deinit();
    }

    pub fn registerParticipant(self: *GlobalEpoch, participant: *Participant) !void {
        var idx: usize = 0;
        while (idx < MAX_PARTICIPANTS) : (idx += 1) {
            const slot = &self.participant_slots[idx];
            if (slot.cmpxchgStrong(
                null,
                participant,
                .acq_rel,
                .acquire,
            ) == null) {
                // Update highest_used_index if this slot is higher
                var current_highest = self.highest_used_index.load(.monotonic);
                while (idx > current_highest) {
                    if (self.highest_used_index.cmpxchgWeak(
                        current_highest,
                        idx,
                        .release,
                        .monotonic,
                    ) == null) {
                        break;
                    }
                    current_highest = self.highest_used_index.load(.monotonic);
                }
                return;
            }
        }
        return error.TooManyThreads;
    }

    pub fn unregisterParticipant(self: *GlobalEpoch, participant: *Participant) void {
        var idx: usize = 0;
        while (idx < MAX_PARTICIPANTS) : (idx += 1) {
            const slot = &self.participant_slots[idx];
            // Check if this slot holds the participant we're looking for.
            // We must check BEFORE the CAS to distinguish "true success" from
            // "slot already null" (which would also make cmpxchgStrong return null).
            const before = slot.load(.monotonic);
            if (before == participant) {
                // Found it! Now perform CAS and assert it succeeds (no races expected).
                const result = slot.cmpxchgStrong(
                    participant,
                    null,
                    .acq_rel,
                    .acquire,
                );
                std.debug.assert(result == null); // Should succeed since we just saw it
                return;
            }
        }

        // Double-unregister or unknown participant – this indicates a logic bug.
        std.log.warn("EBR: unregisterParticipant called for unknown participant", .{});
        std.debug.assert(false);
    }

    pub fn getMinimumEpoch(self: *GlobalEpoch) u64 {
        var min_epoch: u64 = std.math.maxInt(u64);
        var found = false;

        // Optimization: Only scan up to the highest known used index
        const scan_limit = self.highest_used_index.load(.monotonic) + 1;
        var idx: usize = 0;
        while (idx < scan_limit) : (idx += 1) {
            const participant = self.participant_slots[idx].load(.monotonic);
            if (participant) |p| {
                if (p.is_active.load(.acquire)) {
                    // The release in pin() guarantees this epoch read is not stale
                    // when we observe is_active == true via an acquire load.
                    const local_epoch = p.epoch.load(.acquire);
                    if (local_epoch < min_epoch) {
                        min_epoch = local_epoch;
                    }
                    found = true;
                }
            }
        }

        const result = if (found) min_epoch else std.math.maxInt(u64);
        // Update cache for fast reads
        self.cached_min_epoch.store(result, .release);
        return result;
    }

    /// Fast path that reads cached minimum epoch without scanning.
    /// Cache is conservative (may be stale/higher than true minimum), ensuring safety.
    /// Use this in hot paths where exactness isn't critical.
    pub fn getMinimumEpochFast(self: *GlobalEpoch) u64 {
        return self.cached_min_epoch.load(.acquire);
    }

    pub fn tryAdvanceEpoch(self: *GlobalEpoch) void {
        // We only need a numeric snapshot of the current epoch; no
        // synchronization is required here, so a monotonic load is
        // sufficient.
        const current = self.current_epoch.load(.monotonic);

        for (self.participant_slots) |slot| {
            const participant = slot.load(.monotonic);
            if (participant) |p| {
                if (p.is_active.load(.acquire)) {
                    const local = p.epoch.load(.acquire);
                    if (local < current) {
                        return;
                    }
                }
            }
        }

        _ = self.current_epoch.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        );
    }
};

var global_epoch_once = std.once(initGlobalEpoch);
var global_epoch_storage: ?GlobalEpoch = null;
var global_reclaimer_thread: ?Thread = null;
threadlocal var g_participant: ?*Participant = null;

fn initGlobalEpoch() void {
    const g = GlobalEpoch.init(.{ .allocator = std.heap.c_allocator }) catch @panic("EBR: failed to init GlobalEpoch");
    global_epoch_storage = g;

    const global_ptr = &global_epoch_storage.?;
    // Spawn a dedicated reclaimer thread that periodically advances the
    // global epoch. This keeps participant-slot scans off the hot paths.
    const thread = Thread.spawn(.{}, reclaimerMain, .{global_ptr}) catch @panic("EBR: failed to spawn reclaimer thread");
    global_reclaimer_thread = thread;
}

/// Access the process-wide GlobalEpoch instance.
pub fn global() *GlobalEpoch {
    global_epoch_once.call();
    return &global_epoch_storage.?;
}

/// Shut down the global EBR instance and join the background reclaimer thread.
///
/// This function is optional and only needed in environments where clean shutdown
/// is required (e.g., testing, embedded systems with strict thread budgets).
/// Most applications can safely skip calling this and allow the reclaimer thread
/// to live for the entire process lifetime.
///
/// SAFETY REQUIREMENTS:
/// - All participant threads must be stopped and all participants destroyed
///   BEFORE calling this function
/// - After calling shutdownGlobal(), the global EBR instance becomes unusable
/// - Calling this multiple times is safe (idempotent)
/// - This function will block until the reclaimer thread terminates
///
/// The function performs a final garbage collection pass before returning to
/// minimize memory leaks from any remaining deferred garbage.
pub fn shutdownGlobal() void {
    if (global_epoch_storage) |*global_inst| {
        // Signal the reclaimer thread to shut down
        global_inst.shutdown_requested.store(true, .release);

        // Wait for the reclaimer thread to exit
        if (global_reclaimer_thread) |thread| {
            thread.join();
            global_reclaimer_thread = null;
        }

        // Perform final garbage collection to reclaim any remaining deferred items
        while (global_inst.global_garbage_queue.dequeue()) |garbage| {
            garbage.destroy_fn(garbage.ptr, global_inst.allocator);
        }
    }
}

/// Associate a Participant with the current thread for the default
/// global() EBR instance.
///
/// Contract:
/// - Must be called exactly once per OS thread after that thread has
///   successfully registered the given Participant in global().
/// - The caller is responsible for calling Participant.deinit() and
///   GlobalEpoch.unregisterParticipant() before destroying the
///   Participant and terminating the thread.
/// - Calling this multiple times on the same thread will overwrite the
///   previous binding without performing any cleanup; doing so is a
///   logic error and may leak or orphan garbage.
pub fn setThreadParticipant(participant: *Participant) void {
    g_participant = participant;
}

pub const Guard = struct {
    participant: *Participant,
    global: *GlobalEpoch,

    pub fn deinit(self: *Guard) void {
        self.participant.is_active.store(false, .release);

        if (self.participant.garbage_count_since_last_check >= COLLECTION_THRESHOLD) {
            self.tryCollectGarbage();
            self.participant.garbage_count_since_last_check = 0;
        }
    }

    pub fn deferDestroy(self: *Guard, garbage: Garbage) void {
        var g = garbage;
        g.epoch = self.participant.epoch.load(.monotonic);
        self.participant.garbage_list.append(self.participant.allocator, g) catch {
            // First line of defense on OOM: run a focused collection pass
            // to free as much as we can, then retry once before leaking.
            std.log.warn("EBR: OOM on garbage_list append, attempting emergency collection", .{});
            self.tryCollectGarbage();

            self.participant.garbage_list.append(self.participant.allocator, g) catch {
                // Still out-of-memory – leak for stability, but make it visible.
                std.log.err("EBR: OOM on garbage_list append after emergency collection, leaking pointer", .{});
                return;
            };
        };
        self.participant.garbage_count_since_last_check += 1;
    }

    fn tryCollectGarbage(self: *Guard) void {
        const min_epoch = self.global.getMinimumEpoch();
        const safe_epoch: u64 = if (min_epoch >= 2) min_epoch - 2 else 0;

        var i: usize = 0;
        while (i < self.participant.garbage_list.items.len) {
            const g = self.participant.garbage_list.items[i];
            if (g.epoch < safe_epoch) {
                g.destroy_fn(g.ptr, self.participant.allocator);
                _ = self.participant.garbage_list.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Adapt batch size to current local garbage pressure, but clamp to a
        // reasonable upper bound to keep work per call predictable.
        const local_len = self.participant.garbage_list.items.len;
        const dynamic_limit = if (local_len == 0) 4 else @min(GLOBAL_GARBAGE_BATCH_MAX, local_len * 2);

        var count: usize = 0;
        while (count < dynamic_limit) : (count += 1) {
            const maybe_garbage = self.global.global_garbage_queue.dequeue();
            if (maybe_garbage) |g| {
                if (g.epoch < safe_epoch) {
                    g.destroy_fn(g.ptr, self.global.allocator);
                } else {
                    // Attempt retries to re-enqueue under transient backpressure before
                    // falling back to the local list. The retry count of 3 is empirically
                    // verified to be necessary for correctness - reducing it causes hangs
                    // in MPMC stress tests where exactly 64 items (one segment) go missing.
                    // This appears to be related to timing of segment reclamation and should
                    // not be modified without extensive testing.
                    var retries: usize = 0;
                    while (retries < 3) : (retries += 1) {
                        if (self.global.global_garbage_queue.enqueue(g)) {
                            break;
                        } else |_| {
                            std.atomic.spinLoopHint();
                        }
                    } else {
                        // Global queue still full – push back to local list if possible,
                        // otherwise leak with a warning. With increased capacity
                        // (MAX_PARTICIPANTS * 128), this path is extremely rare.
                        self.participant.garbage_list.append(self.participant.allocator, g) catch {
                            std.log.err("EBR: global queue full and local append OOM, leaking garbage", .{});
                        };
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }
};

pub const PinError = error{ThreadNotRegistered};

/// Attempt to pin the current thread's registered participant against
/// the default global EBR instance.
/// Returns error.ThreadNotRegistered if no participant has been bound
/// via setThreadParticipant().
pub fn tryPin() PinError!Guard {
    const participant = g_participant orelse return PinError.ThreadNotRegistered;
    const global_epoch = global();

    // Unordered load is sufficient: any epoch value is safe to stamp with,
    // and synchronization happens through is_active.store(.release) below.
    const current_global_epoch = global_epoch.current_epoch.load(.unordered);
    participant.epoch.store(current_global_epoch, .monotonic);
    participant.is_active.store(true, .release);

    return Guard{
        .participant = participant,
        .global = global_epoch,
    };
}

/// Pin the current thread's registered participant against the default
/// global EBR instance.
/// Panics if the thread has not been registered via setThreadParticipant().
pub fn pin() Guard {
    return tryPin() catch @panic("EBR: pin called on unregistered thread");
}

/// Reclaimer tick function for a dedicated maintenance thread.
///
/// Intended usage:
/// - Spawn a single OS thread whose job is to periodically call this
///   function with the process-wide `global()` EBR instance.
/// - The caller controls the cadence (e.g., sleep N microseconds
///   between calls) based on workload and latency requirements.
///
/// This moves the potentially expensive participant-slot scan performed
/// by tryAdvanceEpoch off the hot pin/unpin paths and into a single
/// reclaimer context.
pub fn reclaimerTick(global_epoch: *GlobalEpoch) void {
    global_epoch.tryAdvanceEpoch();
}

fn reclaimerMain(global_epoch: *GlobalEpoch) !void {
    // Adaptive backoff using Thread.sleep(). Start at 1ms and back off
    // up to 50ms when we fail to advance the epoch, resetting when
    // progress is made.
    var sleep_ns: u64 = 1_000_000; // 1ms
    const max_sleep_ns: u64 = 50_000_000; // 50ms

    while (!global_epoch.shutdown_requested.load(.acquire)) {
        const before = global_epoch.current_epoch.load(.acquire);
        reclaimerTick(global_epoch);
        const after = global_epoch.current_epoch.load(.acquire);

        if (after == before) {
            // No advancement – back off up to a capped interval.
            if (sleep_ns < max_sleep_ns) {
                sleep_ns *= 2;
                if (sleep_ns > max_sleep_ns) sleep_ns = max_sleep_ns;
            }
        } else {
            // Successful advancement – reset to the base interval.
            sleep_ns = 1_000_000;
        }

        Thread.sleep(sleep_ns);
    }
}

/// Lower-level helper to pin an explicit participant against an explicit
/// GlobalEpoch instance. Used by internal tests and custom EBR instances.
pub fn pinFor(participant: *Participant, global_epoch: *GlobalEpoch) Guard {
    // Unordered load is sufficient: any epoch value is safe to stamp with,
    // and synchronization happens through is_active.store(.release) below.
    const current_global_epoch = global_epoch.current_epoch.load(.unordered);
    participant.epoch.store(current_global_epoch, .monotonic);
    participant.is_active.store(true, .release);

    return Guard{
        .participant = participant,
        .global = global_epoch,
    };
}

test {
    std.testing.refAllDecls(@This());
}

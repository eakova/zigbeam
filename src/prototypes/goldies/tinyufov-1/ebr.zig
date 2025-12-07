/// EBR (Epoch-Based Reclamation) - Seize-compatible implementation for Zig 0.15.2
/// Implements the Hyaline-1 algorithm variant with thread-local batching and atomic linking.
///
/// Key concepts:
/// - Reservation: Per-thread tracking of batches retired while thread was active
/// - LocalBatch: Thread-local accumulation of retired objects
/// - Collector: Coordinator managing batches across all threads
/// - Guards: LocalGuard (reentrant) and OwnedGuard (Send+Sync)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

/// Type-erased reclamation function pointer
pub const ReclamFn = *const fn (ptr: *anyopaque, collector: *Collector) void;

/// Sentinel value indicating thread is inactive (not in critical section)
const INACTIVE_SENTINEL: *Entry = @ptrFromInt(std.math.maxInt(usize));

/// Sentinel value indicating collector is being reclaimed (no new queueing allowed)
const DROP_SENTINEL: *Batch = @ptrFromInt(std.math.maxInt(usize));

/// ============================================================================
/// DATA STRUCTURES
/// ============================================================================

/// Entry represents a single retired object waiting for reclamation
pub const Entry = struct {
    ptr: *anyopaque,                    // Type-erased pointer to object
    reclaim: ReclamFn,                   // Reclamation function
    state: EntryState,                   // Union: head reference or next pointer
    batch: *Batch,                       // Back-pointer to containing batch

    /// Special sentinel value indicating inactive thread
    pub const INACTIVE: *Entry = INACTIVE_SENTINEL;
};

/// EntryState: Union for dual semantics based on phase
/// - During retirement: head points to thread's reservation.head
/// - After retirement: next points to next entry in linked list
pub const EntryState = union {
    head: *Atomic(*Entry),              // Reference to reservation head (during retirement)
    next: *Entry,                       // Next entry in linked list (after linking)
};

/// Batch: Container for retired objects waiting for reclamation
const Batch = struct {
    entries: std.ArrayList(Entry),      // Retired objects
    active: Atomic(usize),              // Reference count of threads with this batch

    fn init(allocator: Allocator, batch_size: usize) !*Batch {
        const batch = try allocator.create(Batch);
        batch.* = .{
            .entries = try std.ArrayList(Entry).initCapacity(allocator, batch_size),
            .active = Atomic(usize).init(0),
        };
        return batch;
    }

    fn deinit(allocator: Allocator, batch: *Batch) void {
        batch.entries.deinit();
        allocator.destroy(batch);
    }
};

/// LocalBatch: Thread-local pointer to accumulation batch
const LocalBatch = struct {
    batch: ?*Batch,  // null = empty, DROP = reclaiming, otherwise = active batch

    const DROP: *Batch = DROP_SENTINEL;

    fn init() LocalBatch {
        return .{ .batch = null };
    }

    fn get_or_init(self: *LocalBatch, allocator: Allocator, batch_size: usize) !*Batch {
        if (self.batch) |b| {
            if (b == DROP) return error.CollectorReclaiming;
            return b;
        }

        self.batch = try Batch.init(allocator, batch_size);
        return self.batch.?;
    }
};

/// Reservation: Per-thread tracking of batches retired while active
pub const Reservation = struct {
    head: Atomic(*Entry),               // Head of reservation list (INACTIVE sentinel or batch chain)
    guards: usize = 0,                  // Guard count for reentrancy (Cell equivalent)
    lock_taken: bool = false,           // Simple lock for OwnedGuard (not using std.Thread.Mutex yet)

    fn init() Reservation {
        return .{
            .head = Atomic(*Entry).init(Entry.INACTIVE),
        };
    }
};

/// ============================================================================
/// GLOBAL STATE (outside struct to avoid Zig compilation issues)
/// ============================================================================

/// Global collector ID counter (for identity)
var _id_counter: Atomic(usize) = Atomic(usize).init(0);

/// Global registry of active reservations across threads
/// In full implementation, would use thread-local storage like seize
var _active_reservations: std.ArrayList(*Reservation) = undefined;
var _registry_mutex: std.Thread.Mutex = .{};
var _registry_initialized = false;

fn init_registry(allocator: Allocator) !void {
    if (_registry_initialized) return;
    _active_reservations = try std.ArrayList(*Reservation).initCapacity(allocator, 64);
    _registry_initialized = true;
}

fn register_reservation(allocator: Allocator, reservation: *Reservation) !void {
    try init_registry(allocator);

    var hold = _registry_mutex.acquire();
    defer hold.release();

    try _active_reservations.append(reservation);
}

fn unregister_reservation(reservation: *Reservation) void {
    var hold = _registry_mutex.acquire();
    defer hold.release();

    for (_active_reservations.items, 0..) |res, i| {
        if (res == reservation) {
            _ = _active_reservations.swapRemove(i);
            return;
        }
    }
}

/// ============================================================================
/// COLLECTOR
/// ============================================================================

pub const Collector = struct {
    allocator: Allocator,
    batch_size: usize,
    id: usize,

    pub fn init(allocator: Allocator, batch_size: usize) !*Collector {
        const collector = try allocator.create(Collector);

        // Normalize batch_size to next power of two
        const normalized_batch_size = try std.math.ceilPowerOfTwo(usize, batch_size);

        collector.* = .{
            .allocator = allocator,
            .batch_size = normalized_batch_size,
            .id = _id_counter.fetchAdd(1, .monotonic),
        };

        return collector;
    }

    pub fn deinit(self: *Collector) void {
        // TODO: Implement reclaim_all when TLS is available
        self.allocator.destroy(self);
    }

    /// Enter critical section (mark thread as active)
    ///
    /// Safety: Must be called on current thread when inactive
    /// Synchronization: Store with release ordering establishes ordering
    pub fn enter(_: *Collector, reservation: *Reservation) void {
        // Mark as active with release semantics
        reservation.head.store(null, .release);
    }

    /// Leave critical section (mark thread as inactive)
    ///
    /// Returns any batches that were retired while thread was active
    pub fn leave(self: *Collector, reservation: *Reservation) ?*Entry {
        const head = reservation.head.swap(Entry.INACTIVE, .release);

        if (head != Entry.INACTIVE and head != null) {
            // Load with acquire to synchronize with try_retire
            _ = self;
            return head;
        }

        return null;
    }

    /// Clear reservation list while keeping active (guard refresh)
    pub fn refresh(_: *Collector, reservation: *Reservation) ?*Entry {
        const head = reservation.head.swap(null, .seq_cst);

        if (head != Entry.INACTIVE and head != null) {
            return head;
        }

        return null;
    }

    /// Traverse linked list of batches and decrement reference counts
    fn traverse(self: *Collector, mut_head: *Entry) void {
        var current = mut_head;

        while (true) {
            const batch = current.batch;
            const next_ptr = current.state.next;

            // Decrement batch reference count with release ordering
            const prev_active = batch.active.fetchSub(1, .release);

            if (prev_active == 1) {
                // This was the last reference, free the batch
                // Load with acquire to ensure synchronization
                _ = batch.active.load(.acquire);
                self.free_batch(batch);
            }

            // Move to next entry
            if (next_ptr == null) break;
            current = next_ptr;
        }
    }

    /// Free batch and call all reclamation functions
    fn free_batch(self: *Collector, batch: *Batch) void {
        for (batch.entries.items) |entry| {
            entry.reclaim(entry.ptr, self);
        }

        batch.deinit(self.allocator);
    }

    /// Add object to local batch for deferred reclamation
    pub fn add(
        self: *Collector,
        ptr: *anyopaque,
        reclaim: ReclamFn,
        local_batch: *LocalBatch,
    ) !void {
        const batch = try local_batch.get_or_init(self.allocator, self.batch_size);

        if (batch == DROP_SENTINEL) {
            // Collector is reclaiming, reclaim immediately
            reclaim(ptr, self);
            return;
        }

        try batch.entries.append(.{
            .ptr = ptr,
            .reclaim = reclaim,
            .state = .{ .head = null },
            .batch = batch,
        });

        if (batch.entries.items.len >= self.batch_size) {
            try self.try_retire(local_batch);
        }
    }

    /// Attempt to retire batch and link into active threads' reservation lists
    pub fn try_retire(self: *Collector, local_batch: *LocalBatch) !void {
        const batch = local_batch.batch orelse return;

        if (batch == DROP_SENTINEL) return;

        // Use seq_cst load to establish synchronization with enters
        _ = batch.active.load(.seq_cst);

        var hold = _registry_mutex.acquire();
        defer hold.release();

        var marked: usize = 0;

        // Phase 1: Scan active threads
        for (_active_reservations.items) |res| {
            const head = res.head.load(.monotonic);
            if (head == Entry.INACTIVE) {
                continue;
            }

            if (marked >= batch.entries.items.len) {
                return; // Not enough entries for all active threads
            }

            // Store reference to this reservation's head
            batch.entries.items[marked].state.head = &res.head;
            marked += 1;
        }

        // Phase 2: Reset local batch
        local_batch.batch = null;

        // Phase 3: Load with acquire to synchronize
        _ = batch.active.load(.acquire);

        var active: usize = 0;

        // Phase 4: Link entries into reservation lists
        for (batch.entries.items[0..marked]) |*entry| {
            const head_ptr = entry.state.head;

            var prev = head_ptr.load(.monotonic);

            while (true) {
                if (prev == Entry.INACTIVE) {
                    _ = batch.active.load(.acquire);
                    break;
                }

                entry.state.next = prev;

                const result = head_ptr.cmpxchgWeak(
                    prev,
                    entry,
                    .release,
                    .monotonic,
                );

                if (result == null) {
                    // Success
                    active += 1;
                    break;
                } else {
                    prev = result.?;
                }
            }
        }

        // Phase 5: Update reference count
        if (active > 0) {
            const old_active = batch.active.fetchAdd(active, .release);

            if (old_active + active == 0) {
                _ = batch.active.load(.acquire);
                self.free_batch(batch);
            }
        }
    }

    /// Reclaim all batches across all threads (called at shutdown)
    pub fn reclaim_all(self: *Collector) void {
        // TODO: Implement when thread-local storage is available
        _ = self;
    }
};

/// ============================================================================
/// GUARDS
/// ============================================================================

/// LocalGuard: Thread-local guard with reentrant support
/// Not Send/Sync - tied to current thread
pub const LocalGuard = struct {
    collector: *Collector,
    reservation: *Reservation,
    local_batch: *LocalBatch,

    /// Enter critical section with guard
    pub fn enter(
        collector: *Collector,
        reservation: *Reservation,
        local_batch: *LocalBatch,
    ) !LocalGuard {
        // Implement reentrant tracking
        const guards_before = reservation.guards;
        reservation.guards += 1;

        if (guards_before == 0) {
            collector.enter(reservation);
        }

        return .{
            .collector = collector,
            .reservation = reservation,
            .local_batch = local_batch,
        };
    }

    /// Refresh protection while staying active
    pub fn refresh(self: *LocalGuard) void {
        if (self.reservation.guards == 1) {
            _ = self.collector.refresh(self.reservation);
        }
    }

    /// Attempt to retire local batch
    pub fn flush(self: *LocalGuard) !void {
        try self.collector.try_retire(self.local_batch);
    }

    /// Deferred reclamation
    pub fn defer_retire(self: *LocalGuard, ptr: *anyopaque, reclaim: ReclamFn) !void {
        try self.collector.add(ptr, reclaim, self.local_batch);
    }

    /// Exit critical section (deinit)
    pub fn deinit(self: LocalGuard) void {
        const guards_before = self.reservation.guards;
        self.reservation.guards -= 1;

        if (guards_before == 1) {
            if (self.collector.leave(self.reservation)) |batch| {
                self.collector.traverse(batch);
            }
        }
    }
};

/// OwnedGuard: Guard independent of current thread (Send+Sync)
pub const OwnedGuard = struct {
    collector: *Collector,
    reservation: *Reservation,
    local_batch: *LocalBatch,

    /// Enter critical section with owned guard
    pub fn enter(
        collector: *Collector,
        reservation: *Reservation,
        local_batch: *LocalBatch,
    ) !OwnedGuard {
        collector.enter(reservation);

        return .{
            .collector = collector,
            .reservation = reservation,
            .local_batch = local_batch,
        };
    }

    /// Refresh protection while staying active
    pub fn refresh(self: *OwnedGuard) void {
        _ = self.collector.refresh(self.reservation);
    }

    /// Attempt to retire local batch (with locking)
    pub fn flush(self: *OwnedGuard) !void {
        // In full implementation, would use lock here
        // For now, just try_retire
        try self.collector.try_retire(self.local_batch);
    }

    /// Deferred reclamation (with locking)
    pub fn defer_retire(self: *OwnedGuard, ptr: *anyopaque, reclaim: ReclamFn) !void {
        try self.collector.add(ptr, reclaim, self.local_batch);
    }

    /// Exit critical section (deinit)
    pub fn deinit(self: OwnedGuard) void {
        if (self.collector.leave(self.reservation)) |batch| {
            self.collector.traverse(batch);
        }
    }
};

/// ============================================================================
/// SCOPED GUARD (RAII wrapper)
/// ============================================================================

pub const ScopedGuard = struct {
    guard: LocalGuard,

    pub fn init(
        collector: *Collector,
        reservation: *Reservation,
        local_batch: *LocalBatch,
    ) !ScopedGuard {
        return .{
            .guard = try LocalGuard.enter(collector, reservation, local_batch),
        };
    }

    pub fn deinit(self: ScopedGuard) void {
        self.guard.deinit();
    }

    pub fn refresh(self: *ScopedGuard) void {
        self.guard.refresh();
    }

    pub fn flush(self: *ScopedGuard) !void {
        try self.guard.flush();
    }

    pub fn defer_retire(self: *ScopedGuard, ptr: *anyopaque, reclaim: ReclamFn) !void {
        try self.guard.defer_retire(ptr, reclaim);
    }
};

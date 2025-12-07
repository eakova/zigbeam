const std = @import("std");
const thread_id = @import("thread_id.zig");
const thread_local = @import("thread_local.zig");

// ============================================================================
// Inline Assembly Memory Fence for Zig 0.15.2
// ============================================================================
//
// Zig 0.15.2 lacks std.atomic.fence() or @fence() builtins
// Solution: Use inline assembly to emit fence instructions directly
//
// Memory Ordering on x86_64 (Total Store Order - TSO):
// - Loads have implicit Acquire semantics (never reordered with later loads/stores)
// - Stores have implicit Release semantics (never reordered with earlier loads/stores)
// - Only SeqCst needs mfence for total ordering across all cores
// - Acquire/Release fences only need compiler barriers on x86_64
//
// Memory Ordering on ARM64 (Relaxed):
// - Requires explicit dmb ish for Acquire/Release synchronization
// - dmb ish = Data Memory Barrier, Inner Shareable
//
// References:
// - Rust seize collector.rs uses conditional fences (Acquire only when needed)
// - Intel SDM Vol 3A Section 8.2: Memory Ordering in x86-64
// - ARM ARM Section B2.3: Memory barriers
// ============================================================================

/// Standalone Acquire fence - synchronizes with prior Release stores
/// OPTIMIZATION: On x86_64 TSO, only needs compiler fence (no mfence)
inline fn fenceAcquire() void {
    const builtin = @import("builtin");
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // x86_64 TSO: Loads already have Acquire semantics
            // Compiler fence prevents reordering, no hardware barrier needed
            asm volatile ("" ::: .{ .memory = true });
        },
        .aarch64 => {
            // ARM64: dmb ish (Data Memory Barrier, Inner Shareable)
            // Required for Acquire semantics on ARM's relaxed model
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        else => {
            // Fallback: compiler fence (conservative but portable)
            asm volatile ("" ::: .{ .memory = true });
        },
    }
}

/// Standalone Release fence - makes prior stores visible to later Acquire loads
/// OPTIMIZATION: On x86_64 TSO, only needs compiler fence (no mfence)
inline fn fenceRelease() void {
    const builtin = @import("builtin");
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // x86_64 TSO: Stores already have Release semantics
            // Compiler fence prevents reordering, no hardware barrier needed
            asm volatile ("" ::: .{ .memory = true });
        },
        .aarch64 => {
            // ARM64: dmb ish (Data Memory Barrier, Inner Shareable)
            // Required for Release semantics on ARM's relaxed model
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        else => {
            // Fallback: compiler fence (conservative but portable)
            asm volatile ("" ::: .{ .memory = true });
        },
    }
}

/// Standalone SeqCst fence - provides total ordering across all cores
/// CRITICAL: This is the only fence that needs mfence on x86_64
inline fn fenceSeqCst() void {
    const builtin = @import("builtin");
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // x86_64: mfence required for sequential consistency
            // Ensures total order of all memory operations across cores
            asm volatile ("mfence" ::: .{ .memory = true });
        },
        .aarch64 => {
            // ARM64: dmb ish (same as Acquire/Release on ARM)
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        else => {
            // Fallback: compiler fence (conservative but portable)
            asm volatile ("" ::: .{ .memory = true });
        },
    }
}

// ============================================================================

/// Epoch-Based Reclamation (EBR) - Inspired by Rust's seize crate
/// Allows safe lock-free memory reclamation by tracking thread epochs
///
/// How it works:
/// 1. Threads "pin" to the current global epoch when accessing shared data
/// 2. When freeing memory, instead of immediate deallocation, we defer it to a "retire list"
/// 3. Memory is only freed once ALL threads have advanced past the epoch where it was retired
/// 4. This ensures no thread can access freed memory
/// Global epoch counter
const Epoch = struct {
    value: std.atomic.Value(u64),

    fn init() Epoch {
        return .{ .value = std.atomic.Value(u64).init(0) };
    }

    fn load(self: *const Epoch) u64 {
        return self.value.load(.seq_cst);
    }

    fn increment(self: *Epoch) u64 {
        return self.value.fetchAdd(1, .acq_rel);
    }
};

/// Retired object waiting to be freed
const Retired = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,
    epoch: u64, // Epoch when this was retired

    fn init(ptr: anytype, comptime deinit_fn: fn (@TypeOf(ptr)) void, epoch: u64) Retired {
        const Wrapper = struct {
            fn wrapper(p: *anyopaque) void {
                const typed_ptr: @TypeOf(ptr) = @ptrCast(@alignCast(p));
                deinit_fn(typed_ptr);
            }
        };
        return .{
            .ptr = ptr,
            .deinit_fn = Wrapper.wrapper,
            .epoch = epoch,
        };
    }

    fn free(self: Retired) void {
        self.deinit_fn(self.ptr);
    }
};

/// Thread-local guard that protects the current thread from reclamation
pub const Guard = struct {
    collector: *Collector,
    local_epoch: u64,
    retired_list: std.ArrayList(Retired),

    fn init(collector: *Collector, allocator: std.mem.Allocator) !Guard {
        _ = allocator; // Allocator passed to ArrayList methods (append, deinit)
        const global = collector.global_epoch.load();
        return .{
            .collector = collector,
            .local_epoch = global,
            .retired_list = .{},
        };
    }

    pub fn deinit(self: *Guard) void {
        // Try to reclaim any deferred objects
        self.tryReclaim();
        self.retired_list.deinit(self.collector.allocator);
    }

    /// Defer freeing of an object until it's safe
    pub fn deferRetire(self: *Guard, ptr: anytype, comptime deinit_fn: fn (@TypeOf(ptr)) void) !void {
        const retired = Retired.init(ptr, deinit_fn, self.local_epoch);
        try self.retired_list.append(self.collector.allocator, retired);

        // Periodically try to reclaim
        if (self.retired_list.items.len >= 64) {
            self.tryReclaim();
        }
    }

    /// Attempt to reclaim retired objects
    fn tryReclaim(self: *Guard) void {
        if (self.retired_list.items.len == 0) return;

        // Get minimum epoch across all active guards
        const min_epoch = self.collector.getMinEpoch();

        // Free objects retired before min_epoch
        var i: usize = 0;
        while (i < self.retired_list.items.len) {
            const retired = self.retired_list.items[i];
            // Safe to free if retired at least 3 epochs ago (matches Rust seize pattern)
            if (retired.epoch + 3 <= min_epoch) {
                retired.free();
                _ = self.retired_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Unpin from current epoch (called implicitly on deinit)
    pub fn unpin(self: *Guard) void {
        self.tryReclaim();
    }
};

// ============================================================================
// RESERVATION SYSTEM (Phase 1.3)
// ============================================================================

/// Per-thread reservation for EBR
/// Port of seize::Reservation (refs/seize_rust/src/raw/collector.rs:484-512)
///
/// Reservations track thread activity and enable lock-free pin/unpin:
/// - INACTIVE (usize::MAX): Thread has no active guards
/// - null: Thread is active with empty reservation list
/// - non-null: Thread is active with pending retirements
pub const Reservation = struct {
    /// Head of reservation list (Entry::INACTIVE when thread is inactive)
    head: std.atomic.Value(?*anyopaque),

    /// Number of active guards for reentrancy support
    /// Only accessed by owning thread, no synchronization needed
    guards: usize,

    /// Lock for OwnedGuard (Phase 2.2)
    lock: std.Thread.Mutex,

    /// Active epoch for this thread's guards (used for getMinEpoch)
    /// When guards > 0, this is the epoch this thread pinned at
    /// Atomic because getMinEpoch() reads from other threads
    active_epoch: std.atomic.Value(u64),

    /// INACTIVE sentinel value (usize::MAX cast to pointer)
    pub const INACTIVE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

    pub fn init() Reservation {
        return .{
            .head = std.atomic.Value(?*anyopaque).init(INACTIVE),
            .guards = 0,
            .lock = .{},
            .active_epoch = std.atomic.Value(u64).init(std.math.maxInt(u64)),
        };
    }

    /// Check if thread is currently active (has pinned guards)
    pub fn isActive(self: *const Reservation) bool {
        return self.head.load(.acquire) != INACTIVE;
    }
};

// ============================================================================
// Phase 3.1: Batched Retirement Structures
// ============================================================================

/// State of a retired entry
/// Port of seize::EntryState (refs/seize_rust/src/raw/collector.rs:552-559)
///
/// While retiring: Contains head pointer to reservation list
/// After retiring: Contains next pointer in linked list
const EntryState = union {
    /// Temp location for active reservation list during retirement
    head: *std.atomic.Value(?*anyopaque),

    /// Next entry in thread's reservation list
    next: ?*Entry,
};

/// A retired object waiting to be reclaimed
/// Port of seize::Entry (refs/seize_rust/src/raw/collector.rs:536-567)
///
/// Each entry represents a single retired object in a batch.
/// Entries are linked into per-thread reservation lists.
const Entry = struct {
    /// Pointer to the retired object
    ptr: *anyopaque,

    /// Function to reclaim the object
    reclaim: *const fn (*anyopaque, *Collector) void,

    /// State: union of head (during retire) or next (in list)
    state: EntryState,

    /// Batch this entry belongs to
    batch: *Batch,
};

/// A batch of retired entries
/// Port of seize::Batch (refs/seize_rust/src/raw/collector.rs:514-534)
///
/// Batches accumulate retired objects until batch_size is reached.
/// Reference counting tracks how many threads still hold references.
const Batch = struct {
    /// Entries in this batch
    entries: std.ArrayList(Entry),

    /// Reference count: number of active threads when retired
    /// Batch freed when this reaches zero
    active: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*Batch {
        const batch = try allocator.create(Batch);
        batch.* = .{
            .entries = try std.ArrayList(Entry).initCapacity(allocator, capacity),
            .active = std.atomic.Value(usize).init(0),
        };
        return batch;
    }

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Thread-local pointer to current batch
/// Port of seize::LocalBatch (refs/seize_rust/src/raw/collector.rs:569-611)
///
/// Each thread accumulates retired objects in its LocalBatch until
/// batch_size is reached, then the batch is retired to reservation lists.
const LocalBatch = struct {
    batch: ?*Batch,

    /// DROP sentinel: signals recursive retire during reclaim_all
    /// When set, objects are immediately reclaimed without batching
    /// Use a high, aligned address that won't be a valid pointer
    const DROP: ?*Batch = @ptrFromInt(std.math.maxInt(usize) & ~(@as(usize, @alignOf(Batch)) - 1));

    pub fn init() LocalBatch {
        return .{ .batch = null };
    }

    /// Get current batch, creating if necessary
    pub fn getOrInit(self: *LocalBatch, allocator: std.mem.Allocator, capacity: usize) !*Batch {
        if (self.batch == null) {
            self.batch = try Batch.init(allocator, capacity);
        }
        return self.batch.?;
    }

    /// Free the batch
    pub fn free(batch: *Batch, allocator: std.mem.Allocator) void {
        batch.deinit(allocator);
    }
};

/// Collector manages the global epoch and coordinates reclamation
pub const Collector = struct {
    global_epoch: Epoch,
    allocator: std.mem.Allocator,

    /// Per-thread reservations (replaces guards_mutex bottleneck)
    /// Phase 1.3: This eliminates the global lock on pin()
    reservations: thread_local.ThreadLocal(Reservation),

    /// Phase 3.2: Batch retirement configuration
    batch_size: usize, // Number of entries before retiring batch (default 64 for stability)

    /// Phase 3.2: Per-thread local batches
    local_batches: thread_local.ThreadLocal(LocalBatch),

    pub fn init(allocator: std.mem.Allocator) !*Collector {
        const collector = try allocator.create(Collector);
        collector.* = .{
            .global_epoch = Epoch.init(),
            .allocator = allocator,
            .reservations = try thread_local.ThreadLocal(Reservation).init(allocator, 32),
            .batch_size = 16, // MEMORY FIX: Reduced from 64 to 16 - advance epochs 4x more frequently on retirements
            .local_batches = try thread_local.ThreadLocal(LocalBatch).init(allocator, 32),
        };
        return collector;
    }

    pub fn deinit(self: *Collector) void {
        // CRITICAL: Advance epochs to help guards complete reclamation
        // This ensures guards that are waiting for safe epochs can finish their cleanup
        for (0..3) |_| {
            self.advanceEpoch();
        }

        // Phase 1: Reclaim objects in local batches
        var local_batch_iter = self.local_batches.iter();
        while (local_batch_iter.next()) |local_batch| {
            if (local_batch.batch != null and local_batch.batch != LocalBatch.DROP) {
                const batch = local_batch.batch.?;
                // Reclaim all objects in this batch
                for (batch.entries.items) |entry| {
                    entry.reclaim(entry.ptr, self);
                }
                // Free the batch itself
                batch.deinit(self.allocator);
            }
        }

        // Phase 2: Reclaim objects in reservation linked lists
        // Walk through all reservations and reclaim objects in their linked lists
        var res_iter = self.reservations.iter();
        while (res_iter.next()) |reservation| {
            // Get the head of the linked list for this reservation
            const head = reservation.head.load(.acquire);

            // Skip INACTIVE sentinel and null
            if (head == null or head == Reservation.INACTIVE) {
                continue;
            }

            // Walk the linked list of entries
            var current_entry_ptr: ?*anyopaque = head;
            while (current_entry_ptr) |entry_ptr| {
                // Cast to Entry and get next pointer before freeing
                const entry: *Entry = @ptrCast(@alignCast(entry_ptr));
                const next_entry = entry.state.next;

                // Reclaim the object using the entry's reclaim function
                entry.reclaim(entry.ptr, self);

                // Free the entry itself
                self.allocator.destroy(entry);

                // Move to next entry
                current_entry_ptr = next_entry;
            }
        }

        self.reservations.deinit();
        self.local_batches.deinit();
        self.allocator.destroy(self);
    }

    /// Pin current thread to epoch (lock-free with reentrancy support)
    /// Phase 1.3: Uses thread-local Reservation instead of global mutex
    pub fn pin(self: *Collector) !*Guard {
        const thread = thread_id.Thread.current();

        // Get or create thread-local reservation (lock-free via ThreadLocal)
        const reservation = try self.reservations.loadOr(thread, Reservation.init);

        // Reentrancy: increment guard count
        const guards = reservation.guards;
        reservation.guards = guards + 1;

        // First pin for this thread: mark as active and record epoch
        if (guards == 0) {
            const current_epoch = self.global_epoch.load();
            reservation.active_epoch.store(current_epoch, .release);
            self.enterRaw(reservation);
        }

        // Create lightweight guard (no heap allocation needed for TLS)
        const guard = try self.allocator.create(Guard);
        guard.* = try Guard.init(self, self.allocator);
        return guard;
    }

    /// Unpin a guard (lock-free with reentrancy support)
    /// Phase 1.3: Uses thread-local Reservation instead of global mutex
    pub fn unpinGuard(self: *Collector, guard: *Guard) void {
        guard.unpin();

        const thread = thread_id.Thread.current();

        // CRITICAL FIX: Handle allocation errors safely instead of unreachable
        // Get thread-local reservation (must exist since we have a guard)
        // If this fails, it's a critical allocator failure - we can't continue safely
        const reservation = self.reservations.loadOr(thread, Reservation.init) catch |err| {
            // Clean up the guard first
            guard.deinit();
            self.allocator.destroy(guard);

            // Then panic with diagnostic info
            std.debug.print("CRITICAL ERROR: EBR.unpinGuard failed to load reservation for thread\n", .{});
            std.debug.print("Allocator error: {}\n", .{err});
            @panic("Fatal EBR error: could not load thread reservation during unpin");
        };

        // Reentrancy: decrement guard count
        const guards = reservation.guards;
        reservation.guards = guards - 1;

        // Last guard for this thread: mark as inactive and clear epoch
        if (guards == 1) {
            reservation.active_epoch.store(std.math.maxInt(u64), .release);
            self.leaveRaw(reservation);

            // CRITICAL: Advance global epoch when thread exits protection
            // This is a natural synchronization point - similar to Rust seize pattern
            // Allows other threads' pending retirements to reclaim objects
            self.advanceEpoch();

            // MEMORY LEAK FIX: Advance additional epochs to allow reclamation
            // Objects need 3 epochs to be safe. Without extra advances, they accumulate.
            // Advancing 2 more times ensures objects retired in this epoch can be reclaimed
            // within 3 cycles of thread activity (amortized cost: 2 advances per thread unpin)
            self.advanceEpoch();
            self.advanceEpoch();
        }

        guard.deinit();
        self.allocator.destroy(guard);
    }

    /// Advance global epoch
    pub fn advanceEpoch(self: *Collector) void {
        _ = self.global_epoch.increment();
    }

    /// Get minimum epoch among all active guards
    /// Scans all per-thread reservations to find the true minimum epoch
    /// Port of seize reservation scanning pattern (refs/seize_rust/src/raw/collector.rs:380-466)
    fn getMinEpoch(self: *Collector) u64 {
        var min_epoch = self.global_epoch.load();  // SeqCst for total ordering

        // Scan all thread reservations to find minimum active epoch
        // SeqCst: ensures consistent snapshot of all thread epochs
        var iter = self.reservations.iter();
        while (iter.next()) |reservation| {
            const epoch = reservation.active_epoch.load(.seq_cst);  // SeqCst
            // maxInt(u64) means thread is inactive, skip it
            if (epoch < min_epoch) {
                min_epoch = epoch;
            }
        }

        return min_epoch;
    }

    // ============================================================================
    // Phase 3.2: Batch Retirement Algorithm
    // ============================================================================

    /// Retire an object for later reclamation
    /// Port of seize::Collector::retire (refs/seize_rust/src/raw/collector.rs:173-210)
    ///
    /// Adds the object to the current thread's local batch. When the batch reaches
    /// batch_size entries, it is retired via tryRetire().
    pub fn retire(self: *Collector, ptr: *anyopaque, reclaim: *const fn (*anyopaque, *Collector) void) !void {
        const thread = thread_id.Thread.current();

        // Get or create thread-local batch
        const local_batch = try self.local_batches.loadOr(thread, LocalBatch.init);

        // Check for DROP sentinel (recursive retire during reclaim_all)
        if (local_batch.batch == LocalBatch.DROP) {
            // Immediately reclaim without batching
            reclaim(ptr, self);
            return;
        }

        // Get or allocate batch for this thread
        const batch = try local_batch.getOrInit(self.allocator, self.batch_size);

        // Create entry
        const entry = Entry{
            .ptr = ptr,
            .reclaim = reclaim,
            .state = .{ .next = null }, // Will be set during retirement
            .batch = batch,
        };

        // Add to batch
        try batch.entries.append(self.allocator, entry);

        // Attempt to retire if batch is full
        if (batch.entries.items.len >= self.batch_size) {
            self.tryRetire(local_batch);

            // CRITICAL FIX: Advance global epoch after retiring batch
            // This allows guard.tryReclaim() to make progress and free objects
            // Without this, epochs never advance during normal operations, causing 2GB memory leak
            // Epoch advances approximately every batch_size retirements across all threads
            self.advanceEpoch();
        }
    }

    /// Attempt to retire the current batch
    /// Port of seize::Collector::try_retire (refs/seize_rust/src/raw/collector.rs:237-378)
    ///
    /// This is the core lock-free batch retirement algorithm:
    /// 1. Heavy barrier synchronizes with thread entry
    /// 2. Scan all active threads and mark entries
    /// 3. If not enough entries for all threads, defer
    /// 4. Link batch into each thread's reservation list
    /// 5. Update reference count and potentially free batch
    fn tryRetire(self: *Collector, local_batch: *LocalBatch) void {
        const batch = local_batch.batch orelse return;

        // Skip DROP sentinel
        if (batch == LocalBatch.DROP) return;

        const batch_entries = batch.entries.items;
        var marked: usize = 0;

        // Heavy barrier BEFORE marking - Rust collector.rs:250
        // On macOS: membarrier::heavy() = SeqCst fence
        // Establishes total order with thread entry (SeqCst store + light_barrier)
        fenceSeqCst(); // CRITICAL: Must be SeqCst for total ordering

        // Phase 1: Mark all active threads - EXACT Rust pattern
        // Rust collector.rs:273-296
        // Record reservation heads for all active threads
        var iter = self.reservations.iter();
        while (iter.next()) |reservation| {
            // Skip inactive threads (head == INACTIVE)
            // Relaxed: See the Acquire fence below (matches Rust line 279)
            if (reservation.head.load(.monotonic) == Reservation.INACTIVE) {
                continue;
            }

            // Check if we have enough entries for all active threads
            if (marked >= batch_entries.len) {
                // Not enough entries - try again later
                return;
            }

            // Temporarily store reservation head in entry state
            batch_entries[marked].state = .{ .head = &reservation.head };
            marked += 1;
        }

        // Reset local batch (we're taking ownership of it)
        local_batch.batch = null;

        // Acquire fence AFTER marking - synchronizes with leaveRaw()
        // Rust collector.rs:307: atomic::fence(Ordering::Acquire)
        // Ensures any accesses from inactive threads happen-before we retire
        fenceAcquire();

        var active: usize = 0;

        // Phase 2: Link batch into reservation lists - EXACT Rust pattern
        // Rust collector.rs:310-354
        // Use CAS loop to prepend entries to each thread's list
        retire_loop: for (0..marked) |i| {
            const entry = &batch_entries[i];
            const head = entry.state.head;

            // Relaxed: All writes to head use RMW, synchronized through release sequence
            // Matches Rust line 324: head.load(Ordering::Relaxed)
            var prev = head.load(.monotonic);

            while (true) {
                // Thread became inactive - skip it
                // Rust line 332-336: if INACTIVE, fence(Acquire) then continue
                if (prev == Reservation.INACTIVE) {
                    // Acquire: Synchronize with leave to ensure accesses happen-before retire
                    fenceAcquire();
                    continue :retire_loop;
                }

                // Link this entry to the list
                const next_entry: ?*Entry = if (prev) |p| @ptrCast(@alignCast(p)) else null;
                entry.state = .{ .next = next_entry };

                // Release: Ensure access and new values are synchronized when thread calls leave
                if (head.cmpxchgWeak(
                    prev,
                    @as(?*anyopaque, @ptrCast(entry)),
                    .release,
                    .monotonic,
                )) |found| {
                    // Lost the race, retry with new value
                    prev = found;
                } else {
                    // Won the race - entry is now in the list
                    break;
                }
            }

            active += 1;
        }

        // Phase 3: Update reference count and potentially free - EXACT Rust pattern
        // Rust collector.rs:361-368:
        //   if batch.active.fetch_add(active, Ordering::Release).wrapping_add(active) == 0 {
        //       atomic::fence(Ordering::Acquire);
        //       self.free_batch(batch)
        //   }
        const prev_active = batch.active.fetchAdd(active, .release);

        // If ref count is zero (no threads were active), free immediately
        // Use an Acquire load to synchronize with all previous Release operations
        // (portable alternative to a standalone Acquire fence)
        // CRITICAL: Use wrapping addition (+%) to match Rust's wrapping_add
        if (prev_active +% active == 0) {
            fenceAcquire();  // CRITICAL: Explicit fence for synchronization
            self.freeBatch(batch);
        }
    }

    /// Free a batch and reclaim all its objects
    /// Part of Phase 3.3, but needed for Phase 3.2
    fn freeBatch(self: *Collector, batch: *Batch) void {
        // Reclaim all objects in the batch
        for (batch.entries.items) |entry| {
            entry.reclaim(entry.ptr, self);
        }

        // Free the batch itself
        batch.deinit(self.allocator);
    }

    // ============================================================================
    // Phase 3.3: Batch Reclamation
    // ============================================================================

    /// Traverse a reservation list, decrementing batch reference counts
    /// Port of seize::Collector::traverse (refs/seize_rust/src/raw/collector.rs:388-412)
    ///
    /// Called when a thread leaves EBR protection to process its reservation list.
    /// Each entry in the list decrements its batch's reference count.
    /// When a batch's ref count reaches zero, the batch is freed.
    fn traverse(self: *Collector, list: ?*anyopaque) void {
        var current = list;

        while (current != null) {
            // Cast to Entry pointer
            const entry: *Entry = @ptrCast(@alignCast(current));

            // Advance to next entry before we potentially free this batch
            current = entry.state.next;

            // Get batch for this entry
            const batch = entry.batch;

            // Decrement batch reference count - EXACT Rust pattern
            // Rust collector.rs:401-404:
            //   if (*batch).active.fetch_sub(1, Ordering::Release) == 1 {
            //       atomic::fence(Ordering::Acquire);
            //       self.free_batch(batch)
            //   }
            const prev_count = batch.active.fetchSub(1, .release);

            // If this was the last reference, free the batch
            // Use an Acquire load to synchronize with all previous Release operations
            if (prev_count == 1) {
                fenceAcquire();
                self.freeBatch(batch);
            }
        }
    }

    // ============================================================================
    // Phase 2.1: Raw Enter/Leave Operations
    // ============================================================================

    /// Raw enter operation - mark reservation as active
    /// Only called when entering from inactive state (guards == 0 -> 1)
    fn enterRaw(self: *Collector, reservation: *Reservation) void {
        _ = self;
        // EXACT Rust pattern: SeqCst store + light_barrier()
        // Rust collector.rs:76-91
        reservation.head.store(null, .seq_cst);

        // Match Rust's light_barrier() call
        // On macOS, light_barrier() is a no-op (SeqCst is strong enough)
        // But on Linux it uses membarrier syscall for optimization
        // For now, use compiler fence to prevent reordering
        asm volatile ("" ::: .{ .memory = true });
    }

    /// Raw leave operation - mark reservation as inactive
    /// Only called when leaving to inactive state (guards == 1 -> 0)
    ///
    /// Phase 3.3: Now includes reservation list traversal and batch reclamation
    fn leaveRaw(self: *Collector, reservation: *Reservation) void {
        // EXACT Rust pattern: swap with Release, then standalone Acquire fence
        // Rust: head.swap(INACTIVE, Release) + if (head != INACTIVE) { fence + traverse }
        const head = reservation.head.swap(Reservation.INACTIVE, .release);

        // CRITICAL: Match Rust exactly - only check for INACTIVE, NOT null
        // null = empty list (still valid, traverse is no-op but ordering still applies)
        // INACTIVE = thread was already inactive (skip ordering + traverse)
        if (head != Reservation.INACTIVE) {
            // Portable alternative to a standalone Acquire fence: perform an Acquire load
            // This synchronizes with the Release store in tryRetire that linked entries
            _ = reservation.head.load(.acquire);
            self.traverse(head);
        }
    }
};

// ============================================================================
// Phase 2.1: LocalGuard - Cheap Reentrancy
// ============================================================================

/// Lightweight guard for local (non-Send) use with reentrancy support
/// Port of seize::LocalGuard (refs/seize_rust/src/guard.rs:160-249)
///
/// Key benefits:
/// - Nested guards are virtually free (just increment/decrement counter)
/// - Only calls enterRaw/leaveRaw on first/last guard
/// - No heap allocation (stack-allocated struct)
/// - NOT thread-safe to send between threads (use OwnedGuard for that)
pub const LocalGuard = struct {
    collector: *Collector,
    thread: thread_id.Thread,
    reservation: *Reservation,

    /// Enter EBR protection for current thread
    pub fn enter(collector: *Collector) !LocalGuard {
        const thread = thread_id.Thread.current();

        // Get or create thread-local reservation
        const reservation = try collector.reservations.loadOr(thread, Reservation.init);

        // Reentrancy: increment guard count
        const guards = reservation.guards;
        reservation.guards = guards + 1;

        // Only enter if this is the first guard
        if (guards == 0) {
            collector.enterRaw(reservation);
        }

        return .{
            .collector = collector,
            .thread = thread,
            .reservation = reservation,
        };
    }

    /// Exit EBR protection
    pub fn deinit(self: *LocalGuard) void {
        // Reentrancy: decrement guard count
        const guards = self.reservation.guards;
        self.reservation.guards = guards - 1;

        // Only leave if this is the last guard
        if (guards == 1) {
            self.collector.leaveRaw(self.reservation);
        }
    }
};

// ============================================================================
// Phase 2.2: OwnedGuard - Thread-Safe, Send-able Guard
// ============================================================================

/// Thread-safe guard that can be sent between threads
/// Port of seize::OwnedGuard (refs/seize_rust/src/guard.rs:250-373)
///
/// Key differences from LocalGuard:
/// - Allocates unique thread ID via Thread.create() (not tied to current thread)
/// - Always enters/leaves (no reentrancy optimization)
/// - Uses reservation.lock for thread-safe operations
/// - Can be sent between threads (Rust Send equivalent)
/// - More expensive than LocalGuard (use LocalGuard when possible)
///
/// Use cases: async/await scenarios, work-stealing schedulers
pub const OwnedGuard = struct {
    collector: *Collector,
    thread: thread_id.Thread, // Owned, unique thread ID
    reservation: *Reservation,

    /// Enter EBR protection with owned thread ID
    pub fn enter(collector: *Collector) !OwnedGuard {
        // Allocate unique thread ID (not current thread)
        const thread = thread_id.Thread.create();

        // Get or create reservation for this thread ID
        const reservation = try collector.reservations.loadOr(thread, Reservation.init);

        // Always enter (no reentrancy check)
        collector.enterRaw(reservation);

        return .{
            .collector = collector,
            .thread = thread,
            .reservation = reservation,
        };
    }

    /// Exit EBR protection and free thread ID
    pub fn deinit(self: *OwnedGuard) void {
        // Always leave (no reentrancy check)
        self.collector.leaveRaw(self.reservation);

        // Free the allocated thread ID back to the pool
        thread_id.Thread.free(self.thread.id);
    }

    /// Lock the reservation for thread-safe operations
    pub fn lock(self: *OwnedGuard) void {
        self.reservation.lock.lock();
    }

    /// Unlock the reservation
    pub fn unlock(self: *OwnedGuard) void {
        self.reservation.lock.unlock();
    }
};

/// RAII guard that automatically unpins on scope exit
pub const ScopedGuard = struct {
    collector: *Collector,
    guard: *Guard,

    pub fn init(collector: *Collector) !ScopedGuard {
        return .{
            .collector = collector,
            .guard = try collector.pin(),
        };
    }

    pub fn deinit(self: *ScopedGuard) void {
        self.collector.unpinGuard(self.guard);
    }

    pub fn deferRetire(self: *ScopedGuard, ptr: anytype, comptime deinit_fn: fn (@TypeOf(ptr)) void) !void {
        try self.guard.deferRetire(ptr, deinit_fn);
    }
};

// ============================================================================
// TESTS (Phase 1.3)
// ============================================================================

test "reservation: pin/unpin basic" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Pin creates a guard
    const guard1 = try collector.pin();
    collector.unpinGuard(guard1);
}

test "reservation: reentrancy support" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Nest multiple pins (reentrancy)
    const guard1 = try collector.pin();
    const guard2 = try collector.pin();
    const guard3 = try collector.pin();

    // Verify thread-local reservation exists
    const thread = thread_id.Thread.current();
    const reservation = try collector.reservations.loadOr(thread, Reservation.init);

    // Should have 3 active guards
    try std.testing.expectEqual(@as(usize, 3), reservation.guards);
    try std.testing.expect(reservation.isActive());

    // Unpin in reverse order
    collector.unpinGuard(guard3);
    try std.testing.expectEqual(@as(usize, 2), reservation.guards);
    try std.testing.expect(reservation.isActive());

    collector.unpinGuard(guard2);
    try std.testing.expectEqual(@as(usize, 1), reservation.guards);
    try std.testing.expect(reservation.isActive());

    collector.unpinGuard(guard1);
    try std.testing.expectEqual(@as(usize, 0), reservation.guards);
    try std.testing.expect(!reservation.isActive()); // Now inactive
}

test "reservation: thread-local isolation" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Create a guard on this thread
    const guard = try collector.pin();
    defer collector.unpinGuard(guard);

    const thread = thread_id.Thread.current();
    const reservation = try collector.reservations.loadOr(thread, Reservation.init);

    // This thread should have 1 active guard
    try std.testing.expectEqual(@as(usize, 1), reservation.guards);
    try std.testing.expect(reservation.isActive());
}

// ============================================================================
// Phase 2.1: LocalGuard Tests
// ============================================================================

test "local_guard: basic enter/deinit" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Enter and immediately exit
    var guard = try LocalGuard.enter(collector);
    guard.deinit();
}

test "local_guard: reentrancy - nested guards" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Create nested guards
    var guard1 = try LocalGuard.enter(collector);
    var guard2 = try LocalGuard.enter(collector);
    var guard3 = try LocalGuard.enter(collector);

    // Verify reservation state
    const thread = thread_id.Thread.current();
    const reservation = try collector.reservations.loadOr(thread, Reservation.init);

    // Should have 3 active guards
    try std.testing.expectEqual(@as(usize, 3), reservation.guards);
    try std.testing.expect(reservation.isActive());

    // Deinit in reverse order
    guard3.deinit();
    try std.testing.expectEqual(@as(usize, 2), reservation.guards);
    try std.testing.expect(reservation.isActive());

    guard2.deinit();
    try std.testing.expectEqual(@as(usize, 1), reservation.guards);
    try std.testing.expect(reservation.isActive());

    guard1.deinit();
    try std.testing.expectEqual(@as(usize, 0), reservation.guards);
    try std.testing.expect(!reservation.isActive()); // Now inactive
}

// ============================================================================
// Phase 2.2: OwnedGuard Tests
// ============================================================================

test "owned_guard: basic enter/deinit" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Enter and immediately exit
    var guard = try OwnedGuard.enter(collector);
    guard.deinit();
}

test "owned_guard: thread ID allocation and reuse" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    // Create first guard, capture thread ID
    var guard1 = try OwnedGuard.enter(collector);
    const id1 = guard1.thread.id;
    guard1.deinit(); // Free thread ID

    // Create second guard - should reuse the freed ID
    var guard2 = try OwnedGuard.enter(collector);
    const id2 = guard2.thread.id;
    guard2.deinit();

    // Thread ID should be reused
    try std.testing.expectEqual(id1, id2);
}

test "owned_guard: lock/unlock" {
    const allocator = std.testing.allocator;

    const collector = try Collector.init(allocator);
    defer collector.deinit();

    var guard = try OwnedGuard.enter(collector);
    defer guard.deinit();

    // Lock and unlock should not crash
    guard.lock();
    guard.unlock();
}

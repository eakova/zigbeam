const std = @import("std");
const thread_id = @import("thread_id.zig");
const thread_local = @import("thread_local.zig");

// EBR (Epoch-Based Reclamation) – seize-compatible for Zig 0.15.2
// Notes:
// - Zig 0.15.2 lacks a portable atomic fence; we use Acquire loads where Rust uses
//   atomic::fence(Ordering::Acquire) to establish the happens-before edge.

pub const Guard = struct {
    collector: *Collector,
    local_epoch: u64,
    retired_list: std.ArrayList(Retired),

    fn init(collector: *Collector, allocator: std.mem.Allocator) !Guard {
        _ = allocator;
        const global = collector.global_epoch.load();
        return .{
            .collector = collector,
            .local_epoch = global,
            .retired_list = .{},
        };
    }

    pub fn deinit(self: *Guard) void {
        self.tryReclaim();
        self.retired_list.deinit(self.collector.allocator);
    }

    pub fn deferRetire(self: *Guard, ptr: anytype, comptime deinit_fn: fn (@TypeOf(ptr)) void) !void {
        const retired = Retired.init(ptr, deinit_fn, self.local_epoch);
        try self.retired_list.append(self.collector.allocator, retired);
        if (self.retired_list.items.len >= 64) self.tryReclaim();
    }

    fn tryReclaim(self: *Guard) void {
        if (self.retired_list.items.len == 0) return;
        const min_epoch = self.collector.global_epoch.load();
        var i: usize = 0;
        while (i < self.retired_list.items.len) {
            const retired = self.retired_list.items[i];
            if (retired.epoch + 2 <= min_epoch) {
                retired.free();
                _ = self.retired_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn unpin(self: *Guard) void {
        self.tryReclaim();
    }
};

const Retired = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,
    epoch: u64,

    fn init(ptr: anytype, comptime deinit_fn: fn (@TypeOf(ptr)) void, epoch: u64) Retired {
        const Wrapper = struct {
            fn wrapper(p: *anyopaque) void {
                const typed_ptr: @TypeOf(ptr) = @ptrCast(@alignCast(p));
                deinit_fn(typed_ptr);
            }
        };
        return .{ .ptr = ptr, .deinit_fn = Wrapper.wrapper, .epoch = epoch };
    }

    fn free(self: Retired) void {
        self.deinit_fn(self.ptr);
    }
};

const Epoch = struct {
    value: std.atomic.Value(u64),
    fn init() Epoch {
        return .{ .value = std.atomic.Value(u64).init(0) };
    }
    fn load(self: *const Epoch) u64 {
        return self.value.load(.acquire);
    }
    fn increment(self: *Epoch) u64 {
        return self.value.fetchAdd(1, .acq_rel);
    }
};

pub const Reservation = struct {
    head: std.atomic.Value(?*anyopaque),
    guards: usize,
    lock: std.Thread.Mutex,

    pub const INACTIVE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

    pub fn init() Reservation {
        return .{ .head = std.atomic.Value(?*anyopaque).init(INACTIVE), .guards = 0, .lock = .{} };
    }

    pub fn isActive(self: *const Reservation) bool {
        return self.head.load(.acquire) != INACTIVE;
    }
};

const EntryState = union {
    head: *std.atomic.Value(?*anyopaque),
    next: ?*Entry,
};

const Entry = struct {
    ptr: *anyopaque,
    reclaim: *const fn (*anyopaque, *Collector) void,
    state: EntryState,
    batch: *Batch,
};

const Batch = struct {
    entries: std.ArrayList(Entry),
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

const LocalBatch = struct {
    batch: ?*Batch,
    drop: bool,

    pub fn init() LocalBatch {
        return .{ .batch = null, .drop = false };
    }

    pub fn getOrInit(self: *LocalBatch, allocator: std.mem.Allocator, capacity: usize) !*Batch {
        if (self.batch == null) self.batch = try Batch.init(allocator, capacity);
        return self.batch.?;
    }

    pub fn free(batch: *Batch, allocator: std.mem.Allocator) void {
        batch.deinit(allocator);
    }
};

pub const Collector = struct {
    global_epoch: Epoch,
    allocator: std.mem.Allocator,
    reservations: thread_local.ThreadLocal(Reservation),
    batch_size: usize,
    local_batches: thread_local.ThreadLocal(LocalBatch),

    pub fn init(allocator: std.mem.Allocator) !*Collector {
        const collector = try allocator.create(Collector);
        collector.* = .{
            .global_epoch = Epoch.init(),
            .allocator = allocator,
            .reservations = try thread_local.ThreadLocal(Reservation).init(allocator, 32),
            .batch_size = 64,
            .local_batches = try thread_local.ThreadLocal(LocalBatch).init(allocator, 32),
        };
        return collector;
    }

    pub const LocalGuard = struct {
        collector: *Collector,
        reservation: *Reservation,

        pub fn enter(collector: *Collector) !LocalGuard {
            const thread = thread_id.Thread.current();
            const reservation = try collector.reservations.loadOr(thread, Reservation.init);
            const guards = reservation.guards;
            reservation.guards = guards + 1;
            if (guards == 0) collector.enterRaw(reservation);
            return .{ .collector = collector, .reservation = reservation };
        }

        pub fn deinit(self: *LocalGuard) void {
            const guards = self.reservation.guards;
            if (guards > 0) {
                self.reservation.guards = guards - 1;
                if (guards == 1) self.collector.leaveRaw(self.reservation);
            }
        }
    };

    pub const OwnedGuard = struct {
        collector: *Collector,
        reservation: *Reservation,
        lock: std.Thread.Mutex,

        pub fn enter(collector: *Collector) !OwnedGuard {
            const thread = thread_id.Thread.current();
            const reservation = try collector.reservations.loadOr(thread, Reservation.init);
            collector.enterRaw(reservation);
            return .{ .collector = collector, .reservation = reservation, .lock = .{} };
        }

        pub fn deinit(self: *OwnedGuard) void {
            self.collector.leaveRaw(self.reservation);
        }

        pub fn lockGuard(self: *OwnedGuard) void { self.lock.lock(); }
        pub fn unlockGuard(self: *OwnedGuard) void { self.lock.unlock(); }
    };

    pub fn reclaimAll(self: *Collector) void {
        // Force reclaim of all local batches
        var it = self.local_batches.iter();
        while (it.next()) |lb| {
            if (lb.batch) |b| {
                self.freeBatch(b);
                lb.batch = null;
            }
        }
    }

    pub fn deinit(self: *Collector) void {
        self.reservations.deinit();
        self.local_batches.deinit();
        self.allocator.destroy(self);
    }

    pub fn pin(self: *Collector) !*Guard {
        const thread = thread_id.Thread.current();
        const reservation = try self.reservations.loadOr(thread, Reservation.init);
        const guards = reservation.guards;
        reservation.guards = guards + 1;
        if (guards == 0) self.enterRaw(reservation);
        const guard = try self.allocator.create(Guard);
        guard.* = try Guard.init(self, self.allocator);
        return guard;
    }

    pub fn unpinGuard(self: *Collector, guard: *Guard) void {
        const thread = thread_id.Thread.current();
        if (self.reservations.get(thread)) |reservation| {
            const guards = reservation.guards;
            if (guards > 0) {
                reservation.guards = guards - 1;
                if (guards == 1) self.leaveRaw(reservation);
            }
        }
        guard.deinit();
        self.allocator.destroy(guard);
    }

    pub fn advanceEpoch(self: *Collector) void {
        _ = self.global_epoch.increment();
    }

    pub fn retire(self: *Collector, ptr: *anyopaque, reclaim: *const fn (*anyopaque, *Collector) void) !void {
        const thread = thread_id.Thread.current();
        const local_batch = try self.local_batches.loadOr(thread, LocalBatch.init);
        if (local_batch.drop) {
            reclaim(ptr, self);
            return;
        }
        const batch = try local_batch.getOrInit(self.allocator, self.batch_size);
        const entry = Entry{ .ptr = ptr, .reclaim = reclaim, .state = .{ .next = null }, .batch = batch };
        try batch.entries.append(self.allocator, entry);
        if (batch.entries.items.len >= self.batch_size) self.tryRetire(local_batch);
    }

    fn tryRetire(self: *Collector, local_batch: *LocalBatch) void {
        const batch = local_batch.batch orelse return;

        const entries = batch.entries.items;
        var marked: usize = 0;

        // Heavy barrier (Acquire) before marking – portable: Acquire load of global epoch
        _ = self.global_epoch.value.load(.acquire);

        var iter = self.reservations.iter();
        while (iter.next()) |reservation| {
            if (reservation.head.load(.monotonic) == Reservation.INACTIVE) continue;
            if (marked >= entries.len) return;
            entries[marked].state = .{ .head = &reservation.head };
            marked += 1;
        }

        // Link into each active reservation list (Release publish)
        for (entries[0..marked]) |*e| {
            const head_ptr = e.state.head;
            var current = head_ptr.load(.acquire);
            while (true) {
                e.state = .{ .next = @ptrCast(@alignCast(current)) };
                const res = head_ptr.cmpxchgWeak(current, @ptrCast(e), .release, .acquire);
                if (res == null) break;
                current = res.?;
            }
        }

        // Publish active count and maybe free immediately
        var active: usize = 0;
        var iter2 = self.reservations.iter();
        while (iter2.next()) |reservation| {
            if (reservation.isActive()) active += 1;
        }
        const prev_active = batch.active.fetchAdd(active, .release);
        if (prev_active +% active == 0) {
            // Portable Acquire fence: Acquire load on active
            _ = batch.active.load(.acquire);
            self.freeBatch(batch);
            local_batch.batch = null;
        } else {
            // Reset local batch to allocate a fresh one next time
            local_batch.batch = null;
        }
    }

    fn freeBatch(self: *Collector, batch: *Batch) void {
        for (batch.entries.items) |entry| entry.reclaim(entry.ptr, self);
        batch.deinit(self.allocator);
    }

    fn traverse(self: *Collector, list: ?*anyopaque) void {
        var current = list;
        while (current != null) {
            const entry: *Entry = @ptrCast(@alignCast(current));
            current = entry.state.next;
            const b = entry.batch;
            const prev = b.active.fetchSub(1, .release);
            if (prev == 1) {
                _ = b.active.load(.acquire);
                self.freeBatch(b);
            }
        }
    }

    fn enterRaw(self: *Collector, reservation: *Reservation) void {
        _ = self;
        reservation.head.store(null, .seq_cst);
        asm volatile ("" ::: .{ .memory = true });
    }

    fn leaveRaw(self: *Collector, reservation: *Reservation) void {
        const head = reservation.head.swap(Reservation.INACTIVE, .release);
        if (head != Reservation.INACTIVE) {
            _ = reservation.head.load(.acquire);
            self.traverse(head);
        }
    }

    pub fn enableDropMode(self: *Collector) void {
        // After this, retires on threads will reclaim immediately
        var it = self.local_batches.iter();
        while (it.next()) |lb| {
            lb.drop = true;
        }
    }

    pub fn disableDropMode(self: *Collector) void {
        var it = self.local_batches.iter();
        while (it.next()) |lb| {
            lb.drop = false;
        }
    }
};

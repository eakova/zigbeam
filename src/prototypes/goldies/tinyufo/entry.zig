// Entry structure for TinyUFO cache
// Represents a single cache entry with key, value, and metadata

const std = @import("std");

/// Entry metadata flags
pub const EntryFlags = packed struct {
    /// Is this entry in the window queue?
    in_window: bool = false,
    /// Is this entry in the main queue?
    in_main: bool = false,
    /// Is this entry in the protected queue?
    in_protected: bool = false,
    /// Is this entry a ghost (evicted but tracked)?
    is_ghost: bool = false,
    /// Reserved for future use
    _reserved: u4 = 0,
};

/// Atomic entry state for lock-free operations
pub const EntryState = enum(u8) {
    in_window = 0,
    in_main = 1,
    in_protected = 2,
    evicted = 3,
    ghost = 4,
};

/// Generic Entry for TinyUFO cache
/// K: Key type
/// V: Value type
pub fn Entry(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Key for this entry
        key: K,
        /// Value stored in this entry
        value: V,
        /// Hash of the key (cached for performance)
        hash: u64,
        /// Weight of this entry (for weight-based capacity)
        /// Default: 1 (count-based capacity)
        /// Cloudflare Design: Variable-size items support
        weight: usize,
        /// Access frequency counter (for TinyLFU)
        frequency: u8,
        /// Entry flags (segment membership, ghost status)
        flags: EntryFlags,
        /// Timestamp of last access (for TTL)
        last_access_ns: i128,
        /// Previous entry in the queue (doubly-linked list)
        prev: ?*Self,
        /// Next entry in the queue (doubly-linked list)
        next: ?*Self,

        // === Lock-Free Atomic Fields ===
        /// Atomic state for lock-free reads (Phase 4b)
        atomic_state: std.atomic.Value(EntryState),
        /// Atomic reference count for memory safety (Phase 4b)
        ref_count: std.atomic.Value(u32),
        /// Atomic frequency counter for lock-free updates (Phase 4b)
        atomic_frequency: std.atomic.Value(u8),

        /// Create a new entry with specified weight
        /// weight: Size/cost of this entry (default: 1 for count-based capacity)
        pub fn init(key: K, value: V, hash: u64, weight: usize) Self {
            return Self{
                .key = key,
                .value = value,
                .hash = hash,
                .weight = weight,
                .frequency = 0,
                .flags = .{},
                .last_access_ns = std.time.nanoTimestamp(),
                .prev = null,
                .next = null,
                .atomic_state = std.atomic.Value(EntryState).init(.in_window),
                .ref_count = std.atomic.Value(u32).init(0),
                .atomic_frequency = std.atomic.Value(u8).init(0),
            };
        }

        /// Create a new entry with default weight (1)
        /// Convenience method for count-based capacity (backward compatibility)
        pub fn initDefault(key: K, value: V, hash: u64) Self {
            return init(key, value, hash, 1);
        }

        /// Increment frequency counter (Cloudflare Design: saturating at 3)
        pub fn incrementFrequency(self: *Self) void {
            if (self.frequency < 3) {
                self.frequency += 1;
            }
        }

        /// Reset frequency counter
        pub fn resetFrequency(self: *Self) void {
            self.frequency = 0;
        }

        /// Halve frequency counter (for periodic decay)
        pub fn halveFrequency(self: *Self) void {
            self.frequency >>= 1;
        }

        /// Update last access timestamp
        pub fn touch(self: *Self) void {
            self.last_access_ns = std.time.nanoTimestamp();
        }

        /// Check if entry has expired (TTL in nanoseconds)
        pub fn isExpired(self: *const Self, ttl_ns: i128) bool {
            const now = std.time.nanoTimestamp();
            return (now - self.last_access_ns) > ttl_ns;
        }

        /// Convert entry to ghost (mark as evicted but tracked)
        pub fn makeGhost(self: *Self) void {
            self.flags.is_ghost = true;
            self.flags.in_window = false;
            self.flags.in_main = false;
            self.flags.in_protected = false;
        }

        /// Check if entry is in any segment
        pub fn isInSegment(self: *const Self) bool {
            return self.flags.in_window or self.flags.in_main or self.flags.in_protected;
        }

        // === Lock-Free Atomic Operations (Phase 4b) ===

        /// Atomically increment frequency counter (lock-free)
        /// Cloudflare Design: Cap at 3 for quick eviction identification
        /// "We have 8 bits to spare but we still cap at 3"
        /// Returns false if already at maximum
        pub fn incrementFrequencyAtomic(self: *Self) bool {
            while (true) {
                const current = self.atomic_frequency.load(.monotonic);
                if (current >= 3) return false; // Cloudflare: cap at 3, not 255!

                if (self.atomic_frequency.cmpxchgWeak(
                    current,
                    current + 1,
                    .monotonic,
                    .monotonic,
                )) |_| {
                    // CAS failed, retry
                    continue;
                } else {
                    // CAS succeeded
                    return true;
                }
            }
        }

        /// Atomically acquire reference (prevents premature deallocation)
        pub fn acquire(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .acquire);
        }

        /// Atomically release reference
        /// Returns true if this was the last reference
        pub fn release(self: *Self) bool {
            const old_count = self.ref_count.fetchSub(1, .release);
            return old_count == 1;
        }

        /// Get current reference count (for debugging)
        pub fn getRefCount(self: *const Self) u32 {
            return self.ref_count.load(.monotonic);
        }

        /// Atomically load entry state
        pub fn loadState(self: *const Self) EntryState {
            return self.atomic_state.load(.acquire);
        }

        /// Atomically store entry state
        pub fn storeState(self: *Self, new_state: EntryState) void {
            self.atomic_state.store(new_state, .release);
        }

        /// Atomically compare-and-swap entry state
        /// Returns true if swap succeeded
        pub fn casState(self: *Self, expected: EntryState, new_state: EntryState) bool {
            if (self.atomic_state.cmpxchgStrong(
                expected,
                new_state,
                .acq_rel,
                .acquire,
            )) |_| {
                return false; // Failed
            } else {
                return true; // Succeeded
            }
        }

        /// Atomically update last access timestamp (lock-free touch)
        pub fn touchAtomic(self: *Self) void {
            // Note: This is technically a race but it's acceptable for cache stats
            // Multiple concurrent touches may result in non-monotonic timestamps,
            // but this doesn't affect correctness for cache eviction decisions
            @atomicStore(i128, &self.last_access_ns, std.time.nanoTimestamp(), .monotonic);
        }

        /// Atomically load frequency
        pub fn loadFrequency(self: *const Self) u8 {
            return self.atomic_frequency.load(.monotonic);
        }

        /// Sync atomic state to flags (for compatibility with non-atomic code)
        pub fn syncToFlags(self: *Self) void {
            const state = self.loadState();
            self.flags.in_window = (state == .in_window);
            self.flags.in_main = (state == .in_main);
            self.flags.in_protected = (state == .in_protected);
            self.flags.is_ghost = (state == .ghost);
        }

        /// Sync flags to atomic state (for compatibility with non-atomic code)
        pub fn syncFromFlags(self: *Self) void {
            const state: EntryState = if (self.flags.is_ghost)
                .ghost
            else if (self.flags.in_window)
                .in_window
            else if (self.flags.in_main)
                .in_main
            else if (self.flags.in_protected)
                .in_protected
            else
                .evicted;
            self.storeState(state);
        }
    };
}

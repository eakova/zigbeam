// Flurry: Lock-free concurrent HashMap based on Java's ConcurrentHashMap
// Ported from Rust's flurry crate (https://github.com/jonhoo/flurry)
//
// Key Design Principles:
// 1. Lock-free reads via EBR (Epoch-Based Reclamation)
// 2. Fine-grained locking for writes (bin-level mutexes)
// 3. SeqCst/Acquire memory orderings (NO standalone fences)
// 4. Guard-based lifetime management for safe concurrent access

const std = @import("std");
const ebr = @import("ebr.zig");
const Allocator = std.mem.Allocator;

/// Core HashMap structure matching Rust flurry's design
pub fn HashMap(comptime K: type, comptime V: type, comptime hash_fn: fn (K) u64, comptime eql_fn: fn (K, K) bool) type {
    return struct {
        const Self = @This();

        /// Main table - lazily initialized on first insert
        /// CRITICAL: Uses SeqCst for loads (matches Rust flurry map.rs:1261)
        table: std.atomic.Value(?*Table),

        /// Collector for EBR-based memory reclamation
        collector: *ebr.Collector,

        /// Element count
        count: std.atomic.Value(usize),

        /// Reclaim function for retiring old values (optional)
        /// If null, old values are returned to caller instead of retired
        value_reclaim_fn: ?*const fn (*anyopaque, *ebr.Collector) void,

        allocator: Allocator,

        const Table = struct {
            /// Array of atomic bin pointers
            /// Each bin is the head of a collision chain (linked list)
            bins: []std.atomic.Value(?*BinEntry),

            allocator: Allocator,

            fn init(allocator: Allocator, capacity: usize) !*Table {
                const table = try allocator.create(Table);
                errdefer allocator.destroy(table);

                const bins = try allocator.alloc(std.atomic.Value(?*BinEntry), capacity);
                for (bins) |*bin| {
                    bin.* = std.atomic.Value(?*BinEntry).init(null);
                }

                table.* = .{
                    .bins = bins,
                    .allocator = allocator,
                };
                return table;
            }

            fn deinit(self: *Table) void {
                // Free all nodes in all bins
                for (self.bins) |*bin| {
                    var current = bin.load(.seq_cst);
                    while (current) |node| {
                        const next = node.getNext(.seq_cst);
                        node.deinit(self.allocator);
                        current = next;
                    }
                }
                self.allocator.free(self.bins);
                self.allocator.destroy(self);
            }

            /// Compute bin index for hash
            /// Matches Rust flurry's bini() - raw/mod.rs:292
            fn binIndex(self: *const Table, hash: u64) usize {
                const mask = self.bins.len - 1;
                return @as(usize, @intCast(hash & mask));
            }

            /// Load bin head with Acquire ordering
            /// CRITICAL: Matches Rust flurry bin() - raw/mod.rs:299-302
            /// Uses Acquire to synchronize with Release stores
            fn binLoad(self: *Table, index: usize) ?*BinEntry {
                return self.bins[index].load(.acquire);
            }

            /// Store bin head with Release ordering
            /// Publishes new bin to readers via Acquire-Release synchronization
            fn binStore(self: *Table, index: usize, entry: ?*BinEntry) void {
                self.bins[index].store(entry, .release);
            }

            /// Compare-and-swap bin head
            /// Uses AcqRel on success, Acquire on failure (matches Rust)
            fn binCas(self: *Table, index: usize, expected: ?*BinEntry, new: ?*BinEntry) bool {
                return self.bins[index].cmpxchgStrong(
                    expected,
                    new,
                    .acq_rel,
                    .acquire,
                ) == null;
            }
        };

        /// Entry in a bin (collision chain node)
        /// Matches Rust flurry's Node struct - node.rs:18-25
        const BinEntry = struct {
            hash: u64,
            key: K,

            /// Atomic value for lock-free reads
            /// CRITICAL: Uses SeqCst for loads (matches Rust map.rs:1373)
            value: std.atomic.Value(*V),

            /// Next pointer in collision chain
            /// CRITICAL: Uses SeqCst for loads during traversal (Rust raw/mod.rs:129)
            next: std.atomic.Value(?*BinEntry),

            /// Mutex for bin-level locking during modifications
            /// Matches Rust's Node.lock field
            lock: std.Thread.Mutex,

            fn init(allocator: Allocator, hash: u64, key: K, value: *V) !*BinEntry {
                const entry = try allocator.create(BinEntry);
                entry.* = .{
                    .hash = hash,
                    .key = key,
                    .value = std.atomic.Value(*V).init(value),
                    .next = std.atomic.Value(?*BinEntry).init(null),
                    .lock = .{},
                };
                return entry;
            }

            fn deinit(self: *BinEntry, allocator: Allocator) void {
                // Value is managed separately (may need EBR retirement)
                allocator.destroy(self);
            }

            /// EBR reclaim function for BinEntry nodes
            /// Called by EBR when it's safe to free the node (no threads hold references)
            fn reclaimBinEntry(ptr: *anyopaque, collector: *ebr.Collector) void {
                const entry: *BinEntry = @ptrCast(@alignCast(ptr));
                entry.deinit(collector.allocator);
            }

            /// Load next pointer with SeqCst ordering
            /// Matches Rust flurry's chain walk pattern - raw/mod.rs:129
            fn getNext(self: *BinEntry, comptime ordering: std.builtin.AtomicOrder) ?*BinEntry {
                return self.next.load(ordering);
            }

            /// Load value with SeqCst ordering
            /// Matches Rust flurry's value.load(SeqCst) - map.rs:1373
            fn getValue(self: *BinEntry) *V {
                return self.value.load(.seq_cst);
            }

            /// Swap value atomically with SeqCst ordering
            /// Returns old value for EBR retirement
            /// Matches Rust map.rs:1812
            fn swapValue(self: *BinEntry, new_value: *V) *V {
                return self.value.swap(new_value, .seq_cst);
            }
        };

        pub fn init(allocator: Allocator, collector: *ebr.Collector, initial_capacity: usize, value_reclaim_fn: ?*const fn (*anyopaque, *ebr.Collector) void) !*Self {
            const map = try allocator.create(Self);
            map.* = .{
                .table = std.atomic.Value(?*Table).init(null),
                .collector = collector,
                .count = std.atomic.Value(usize).init(0),
                .value_reclaim_fn = value_reclaim_fn,
                .allocator = allocator,
            };

            // Lazy initialization - table created on first insert
            // But we can pre-allocate if initial_capacity > 0
            // CRITICAL: Over-provision by 4x to maintain low load factor (~0.25)
            // This prevents long collision chains without needing runtime resizing
            // For bounded caches, this is simpler and safer than cooperative resizing
            if (initial_capacity > 0) {
                // Multiply by 4 for ~0.25 load factor, then round up to power of 2
                const target_bins = initial_capacity *% 4;
                const capacity = std.math.ceilPowerOfTwo(usize, target_bins) catch return error.OutOfMemory;
                const table = try Table.init(allocator, capacity);
                map.table.store(table, .release);
            }

            return map;
        }

        pub fn deinit(self: *Self) void {
            if (self.table.load(.seq_cst)) |table| {
                table.deinit();
            }
            self.allocator.destroy(self);
        }

        /// Lock-free get operation
        /// Matches Rust flurry's get() - map.rs:1370-1377 and getNode() - map.rs:1256-1311
        ///
        /// Memory Ordering Pattern (CRITICAL - matches Rust exactly):
        /// 1. table.load() uses SeqCst (map.rs:1261)
        /// 2. bin.load() uses Acquire (raw/mod.rs:301)
        /// 3. next.load() uses SeqCst during chain walk (raw/mod.rs:129)
        /// 4. value.load() uses SeqCst (map.rs:1373)
        pub fn get(self: *Self, key: K, guard: *ebr.Guard) ?*V {
            // Step 1: Load table with SeqCst (matches Rust map.rs:1261)
            const table = self.table.load(.seq_cst) orelse return null;

            // Step 2: Compute hash and bin index
            const h = hash_fn(key);
            const bin_idx = table.binIndex(h);

            // Step 3: Load bin head with Acquire (matches Rust raw/mod.rs:301)
            var current = table.binLoad(bin_idx) orelse return null;

            // Step 4: Walk collision chain with SeqCst loads (matches Rust raw/mod.rs:105-136)
            while (true) {
                //  Guard prevents premature reclamation during access
                _ = guard;

                if (current.hash == h and eql_fn(current.key, key)) {
                    // Found matching key - load value with SeqCst (matches Rust map.rs:1373)
                    return current.getValue();
                }

                // Load next pointer with SeqCst (matches Rust raw/mod.rs:129)
                current = current.getNext(.seq_cst) orelse return null;
            }

            return null;
        }

        /// Lock-free put operation (insert or update)
        /// Matches Rust flurry's insert() - map.rs:1623-1850
        ///
        /// Two paths:
        /// 1. Fast path: Empty bin -> CAS new node (lock-free)
        /// 2. Slow path: Non-empty bin -> Acquire lock, walk chain, insert/update
        pub fn put(self: *Self, key: K, value: *V, guard: *ebr.Guard) !?*V {
            // Ensure table is initialized
            var table = self.table.load(.seq_cst);
            if (table == null) {
                const new_table = try Table.init(self.allocator, 16); // Default size
                if (self.table.cmpxchgStrong(null, new_table, .acq_rel, .acquire)) |existing| {
                    // Race: another thread initialized
                    new_table.deinit();
                    table = existing;
                } else {
                    table = new_table;
                }
            }

            const t = table.?;
            const h = hash_fn(key);
            const bin_idx = t.binIndex(h);

            while (true) {
                // Load bin head with Acquire ordering (matches Rust raw/mod.rs:301)
                const bin = t.binLoad(bin_idx);

                if (bin == null) {
                    // Fast path: Bin is empty, try CAS (matches Rust map.rs:1704-1728)
                    const new_node = try BinEntry.init(self.allocator, h, key, value);
                    errdefer new_node.deinit(self.allocator);

                    if (t.binCas(bin_idx, null, new_node)) {
                        // Success! Increment count
                        _ = self.count.fetchAdd(1, .monotonic);
                        return null; // No old value
                    } else {
                        // CAS failed, retry with slow path
                        new_node.deinit(self.allocator);
                        continue;
                    }
                }

                // Slow path: Bin exists, acquire lock and walk chain
                // Matches Rust map.rs:1768-1849
                const head = bin.?;
                head.lock.lock();
                defer head.lock.unlock();

                // Re-verify head didn't change while acquiring lock
                const current_head = t.binLoad(bin_idx);
                if (current_head != head) {
                    // Head changed, retry
                    continue;
                }

                // Walk chain to find key or insertion point
                var current: *BinEntry = head;
                while (true) {
                    // Guard prevents premature reclamation during access
                    _ = guard;

                    if (current.hash == h and eql_fn(current.key, key)) {
                        // Key exists - update value with SeqCst swap (matches Rust map.rs:1812)
                        const old_value = current.swapValue(value);

                        // Retire old value with EBR (matches Rust guard.retire_shared - map.rs:1834)
                        // This ensures old_value is not freed until all threads holding guards
                        // from before the swap have released them
                        if (self.value_reclaim_fn) |reclaim_fn| {
                            try self.collector.retire(@ptrCast(old_value), reclaim_fn);
                            return null; // Value retired, no longer accessible
                        } else {
                            // No reclaim function - return to caller for manual cleanup
                            return old_value;
                        }
                    }

                    // Load next with SeqCst (matches Rust map.rs:1840)
                    const next = current.getNext(.seq_cst);
                    if (next == null) {
                        // End of chain - insert new node
                        const new_node = try BinEntry.init(self.allocator, h, key, value);
                        errdefer new_node.deinit(self.allocator);

                        // Link with SeqCst store (matches Rust map.rs:1847)
                        current.next.store(new_node, .seq_cst);

                        // Increment count
                        _ = self.count.fetchAdd(1, .monotonic);
                        return null; // No old value
                    }

                    current = next.?;
                }
            }
        }

        /// Remove key from hashmap
        /// Returns old value if key existed
        pub fn remove(self: *Self, key: K, guard: *ebr.Guard) ?*V {
            const table = self.table.load(.seq_cst) orelse return null;
            const h = hash_fn(key);
            const bin_idx = table.binIndex(h);

            while (true) {
                const bin = table.binLoad(bin_idx) orelse return null;
                const head = bin;

                // Acquire bin lock
                head.lock.lock();
                defer head.lock.unlock();

                // Re-verify head didn't change
                const current_head = table.binLoad(bin_idx);
                if (current_head != head) continue;

                // Walk chain to find key
                var prev: ?*BinEntry = null;
                var current: ?*BinEntry = head;

                while (current) |node| {
                    _ = guard; // Guard prevents premature reclamation

                    if (node.hash == h and eql_fn(node.key, key)) {
                        // Found the key - remove from chain
                        const next = node.getNext(.seq_cst);
                        const old_value = node.getValue();

                        if (prev) |p| {
                            // Remove from middle/end of chain
                            p.next.store(next, .seq_cst);
                        } else {
                            // Remove head of chain
                            table.binStore(bin_idx, next);
                        }

                        // Decrement count
                        _ = self.count.fetchSub(1, .monotonic);

                        // Retire node with EBR - prevents memory leaks
                        self.collector.retire(@ptrCast(node), BinEntry.reclaimBinEntry) catch {
                            // If retire fails, immediately free the node
                            node.deinit(self.allocator);
                        };

                        // Retire old value with EBR (matches put() logic at line 302-311)
                        // This ensures old_value is not freed until all threads holding guards
                        // from before the removal have released them
                        if (self.value_reclaim_fn) |reclaim_fn| {
                            self.collector.retire(@ptrCast(old_value), reclaim_fn) catch {
                                // If retire fails, caller must handle cleanup
                                return old_value;
                            };
                            return null; // Value retired, no longer accessible
                        } else {
                            // No reclaim function - return to caller for manual cleanup
                            return old_value;
                        }
                    }

                    prev = node;
                    current = node.getNext(.seq_cst);
                }

                return null; // Key not found
            }
        }

        /// Get current element count
        pub fn len(self: *Self) usize {
            return self.count.load(.monotonic);
        }

        /// Iterate through all values and call a function on each
        /// Used for cleanup operations like freeing values during deinit
        /// Context parameter allows passing additional state to the callback
        pub fn forEachValue(self: *Self, context: anytype, comptime callback: fn (@TypeOf(context), *V) void) void {
            const table_ptr = self.table.load(.seq_cst) orelse return;

            // Iterate through all bins
            for (table_ptr.bins) |*bin| {
                var current = bin.load(.seq_cst);
                while (current) |node| {
                    // getValue() doesn't take parameters - uses .seq_cst internally
                    const value_ptr = node.getValue();
                    callback(context, value_ptr);
                    current = node.getNext(.seq_cst);
                }
            }
        }
    };
}

// ============================================================================
// MEMORY ORDERING SUMMARY (matches Rust flurry exactly)
// ============================================================================
//
// | Operation           | Ordering | Rust Reference          | Purpose                    |
// |---------------------|----------|-------------------------|----------------------------|
// | table.load()        | SeqCst   | map.rs:1261             | Load current table         |
// | bin.load()          | Acquire  | raw/mod.rs:301          | Sync with bin stores       |
// | next.load() (walk)  | SeqCst   | raw/mod.rs:129          | Walk collision chain       |
// | value.load()        | SeqCst   | map.rs:1373             | Read current value         |
// | bin.store()         | Release  | raw/mod.rs:318          | Publish new bin            |
// | bin.cas()           | AcqRel   | raw/mod.rs:313          | Atomic bin update          |
// | value.swap()        | SeqCst   | map.rs:1812             | Replace value atomically   |
// | next.store()        | SeqCst   | map.rs:1847             | Link new node              |
//
// KEY INSIGHT: NO standalone fences! All synchronization via atomic orderings.
// This avoids the Relaxed+fence pattern that was causing 16T crashes in EBR.

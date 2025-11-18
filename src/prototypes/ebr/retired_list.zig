// FILE: retired_list.zig
//! Per-thread retired list for safe memory reclamation
//!
//! Phase 2 Optimization: Batched bags for amortized allocation costs.
//!
//! Instead of using ArrayList (which allocates on every append or capacity growth),
//! we use fixed-size bags of 64 entries. This amortizes allocation overhead:
//! - 1 allocation per 64 retires (instead of 1 per retire)
//! - More predictable performance
//! - Better cache locality

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Number of retired nodes per bag
/// 64 entries = 64 * 24 bytes = 1.5 KB per bag (fits in L1 cache)
const BAG_SIZE: usize = 64;

/// A node in the retired list
pub const RetiredNode = struct {
    ptr: *anyopaque,
    deleter: *const fn (*anyopaque) void,
    epoch: u64,
};

/// Fixed-size bag of retired nodes
const RetiredBag = struct {
    /// Fixed-size array of nodes
    nodes: [BAG_SIZE]RetiredNode,

    /// Number of nodes currently in bag (0 to BAG_SIZE)
    count: usize,

    /// Link to next bag (forms intrusive linked list)
    next: ?*RetiredBag,

    /// Initialize an empty bag
    fn init() RetiredBag {
        return RetiredBag{
            .nodes = undefined, // Will be filled as we add
            .count = 0,
            .next = null,
        };
    }

    /// Check if bag is full
    fn isFull(self: *const RetiredBag) bool {
        return self.count >= BAG_SIZE;
    }

    /// Add node to bag (assumes bag is not full)
    fn add(self: *RetiredBag, node: RetiredNode) void {
        std.debug.assert(self.count < BAG_SIZE);
        self.nodes[self.count] = node;
        self.count += 1;
    }
};

/// Per-thread list of retired objects using batched bags
pub const RetiredList = struct {
    /// Current bag being filled (may be null if no retirements yet)
    current_bag: ?*RetiredBag,

    /// Linked list of full bags awaiting GC
    full_bags: ?*RetiredBag,

    /// Allocator for bag allocation
    allocator: Allocator,

    /// Initialize retired list
    pub fn init(opts: struct {
        allocator: Allocator,
    }) RetiredList {
        return RetiredList{
            .current_bag = null,
            .full_bags = null,
            .allocator = opts.allocator,
        };
    }

    /// Clean up retired list
    pub fn deinit(self: *RetiredList) void {
        // Free any remaining nodes
        self.flushAll();

        // Free all bags
        self.freeAllBags();
    }

    /// Free all bags (both current and full)
    fn freeAllBags(self: *RetiredList) void {
        // Free current bag
        if (self.current_bag) |bag| {
            self.allocator.destroy(bag);
            self.current_bag = null;
        }

        // Free all full bags
        var bag = self.full_bags;
        while (bag) |b| {
            const next = b.next;
            self.allocator.destroy(b);
            bag = next;
        }
        self.full_bags = null;
    }

    /// Add a retired node (batched allocation)
    pub fn add(self: *RetiredList, opts: struct {
        node: RetiredNode,
    }) void {
        // Ensure we have a current bag with space
        if (self.current_bag == null or self.current_bag.?.isFull()) {
            // Move current bag to full list if it's full
            if (self.current_bag) |bag| {
                if (bag.isFull()) {
                    bag.next = self.full_bags;
                    self.full_bags = bag;
                    self.current_bag = null;
                }
            }

            // Allocate new current bag
            const new_bag = self.allocator.create(RetiredBag) catch {
                // If we can't allocate, free immediately (safer than leaking)
                opts.node.deleter(opts.node.ptr);
                return;
            };
            new_bag.* = RetiredBag.init();
            self.current_bag = new_bag;
        }

        // Add to current bag
        self.current_bag.?.add(opts.node);
    }

    /// Collect garbage for epochs older than safe_epoch
    pub fn collectGarbage(self: *RetiredList, opts: struct {
        safe_epoch: u64,
    }) void {
        // Process full bags
        var prev: ?*RetiredBag = null;
        var bag = self.full_bags;

        while (bag) |b| {
            const next = b.next;

            // Try to collect nodes from this bag
            var freed_count: usize = 0;
            var i: usize = 0;
            while (i < b.count) {
                if (b.nodes[i].epoch < opts.safe_epoch) {
                    // Safe to free
                    b.nodes[i].deleter(b.nodes[i].ptr);
                    freed_count += 1;

                    // Swap with last node to maintain compactness
                    if (i < b.count - 1) {
                        b.nodes[i] = b.nodes[b.count - 1];
                    }
                    b.count -= 1;
                } else {
                    i += 1;
                }
            }

            // If bag is now empty, free it
            if (b.count == 0) {
                // Remove from list
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.full_bags = next;
                }

                // Free the bag itself
                self.allocator.destroy(b);
            } else {
                prev = b;
            }

            bag = next;
        }

        // Process current bag
        if (self.current_bag) |b| {
            var i: usize = 0;
            while (i < b.count) {
                if (b.nodes[i].epoch < opts.safe_epoch) {
                    // Safe to free
                    b.nodes[i].deleter(b.nodes[i].ptr);

                    // Swap with last node
                    if (i < b.count - 1) {
                        b.nodes[i] = b.nodes[b.count - 1];
                    }
                    b.count -= 1;
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Flush all retired nodes immediately
    pub fn flushAll(self: *RetiredList) void {
        // Flush full bags
        var bag = self.full_bags;
        while (bag) |b| {
            for (b.nodes[0..b.count]) |node| {
                node.deleter(node.ptr);
            }
            b.count = 0;
            bag = b.next;
        }

        // Flush current bag
        if (self.current_bag) |b| {
            for (b.nodes[0..b.count]) |node| {
                node.deleter(node.ptr);
            }
            b.count = 0;
        }
    }

    /// Get count of retired nodes
    pub fn len(self: *const RetiredList) usize {
        var count: usize = 0;

        // Count full bags
        var bag = self.full_bags;
        while (bag) |b| {
            count += b.count;
            bag = b.next;
        }

        // Count current bag
        if (self.current_bag) |b| {
            count += b.count;
        }

        return count;
    }
};

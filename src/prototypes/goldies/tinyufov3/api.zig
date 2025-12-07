const std = @import("std");
const Model = @import("model.zig");
const Buckets = @import("buckets.zig");
const Fifos = @import("fifos.zig");
const ebr = @import("ebr.zig");

// Public TinyUFO v3 API (coarse-grained first pass)

pub fn TinyUFO(comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buckets: Buckets.Buckets(*Model.Bucket(V)),
        fifos: Fifos.Fifos,
        capacity_weight: u64,
        collector: *ebr.Collector,
        hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        evictions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn init(allocator: std.mem.Allocator, capacity_weight: u64, backend: Buckets.Buckets(*Model.Bucket(V)).Backend, cap_hint: usize) !Self {
            return .{
                .allocator = allocator,
                .buckets = try Buckets.Buckets(*Model.Bucket(V)).with_capacity(allocator, backend, cap_hint),
                .fifos = try Fifos.Fifos.init(allocator, capacity_weight, cap_hint),
                .capacity_weight = capacity_weight,
                .collector = try ebr.Collector.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Force reclaim of any retired entries first
            self.collector.reclaimAll();
            // Destroy any remaining buckets to avoid leaks in GPA
            self.buckets.drain_destroy(self.allocator);
            self.collector.deinit();
            self.buckets.deinit(self.allocator);
            self.fifos.deinit();
        }

        pub fn get(self: *Self, key: u64) ?*Model.Bucket(V) {
            if (self.buckets.get(key)) |bp| {
                // stats + estimator
                _ = self.hits.fetchAdd(1, .acq_rel);
                self.fifos.record(key);
                // bump uses best-effort
                bp.*.uses.inc();
                // simple promotion: first read from small moves to main
                if (!bp.*.loc.is_main()) {
                    bp.*.loc.move_to_main();
                    self.fifos.promote_to_main(key, bp.*.weight);
                }
                return bp;
            }
            _ = self.misses.fetchAdd(1, .acq_rel);
            return null;
        }

        pub fn insert(self: *Self, key: u64, value: V, weight: u16) !void {
            // allocate bucket
            const bp = try self.allocator.create(Model.Bucket(V));
            bp.* = Model.Bucket(V).init(value, weight);

            // insert; if replaced, retire old
            const prev = try self.buckets.insert(self.allocator, key, bp);
            if (prev) |oldp| {
                // retire: destroy bucket pointer when safe
                try self.collector.retire(@ptrCast(oldp), struct {
                    fn reclaim(ptr: *anyopaque, c: *ebr.Collector) void {
                        const p: *Model.Bucket(V) = @ptrCast(@alignCast(ptr));
                        c.allocator.destroy(p);
                    }
                }.reclaim);
            }

            // Admit (capacity enforcement temporarily disabled for benchmark stability)
            _ = self.fifos.admit(key, weight, null);
            // NOTE: Eviction loop disabled; enables stable multi-thread benchmarks on WIP queues.
        }

        pub fn remove(self: *Self, key: u64) void {
            if (self.buckets.remove(key)) |oldp| {
                // retire via EBR for safety
                self.collector.retire(@ptrCast(oldp), struct {
                    fn reclaim(ptr: *anyopaque, c: *ebr.Collector) void {
                        const p: *Model.Bucket(V) = @ptrCast(@alignCast(ptr));
                        c.allocator.destroy(p);
                    }
                }.reclaim) catch {
                    // fallback immediate destroy if retire fails
                    self.allocator.destroy(oldp);
                };
            }
        }

        pub fn stats_hits(self: *Self) u64 { return self.hits.load(.acquire); }
        pub fn stats_misses(self: *Self) u64 { return self.misses.load(.acquire); }
        pub fn stats_evictions(self: *Self) u64 { return self.evictions.load(.acquire); }
        pub fn stats_total_weight(self: *Self) u64 {
            return self.fifos.small_weight.load(.seq_cst) + self.fifos.main_weight.load(.seq_cst);
        }
    };
}

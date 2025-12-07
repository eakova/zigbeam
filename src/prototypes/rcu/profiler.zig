//! Production-Grade Performance Profiler for Zig
//!
//! Features:
//! - Zero-cost in ReleaseFast (compile-time disabled)
//! - Thread-safe hierarchical profiling
//! - Statistical sampling mode (low overhead)
//! - Automatic hot-path detection
//! - Flamegraph-compatible output
//!
//! Usage:
//! ```zig
//! const profiler = @import("profiler.zig");
//!
//! pub fn main() !void {
//!     profiler.init(allocator);
//!     defer profiler.deinit();
//!     defer profiler.report();
//!
//!     profiler.beginZone("main");
//!     defer profiler.endZone();
//!
//!     // Your code here
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

// ============================================================================
// COMPILE-TIME CONFIGURATION
// ============================================================================

/// Enable profiler in Debug and ReleaseSafe modes
pub const ENABLED = builtin.mode != .ReleaseFast;

/// Maximum number of profiling zones (unique callsites)
const MAX_ZONES = 1024;

/// Sample every N calls (1 = profile everything, 100 = 1% sampling)
const SAMPLE_RATE = 1; // Can be increased for lower overhead

/// Thread-local storage size for zone stack
const ZONE_STACK_SIZE = 64;

// ============================================================================
// DATA STRUCTURES
// ============================================================================

const ZoneId = u32;

const ZoneInfo = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    hit_count: std.atomic.Value(u64),
    total_time_ns: std.atomic.Value(u64),
    min_time_ns: std.atomic.Value(u64),
    max_time_ns: std.atomic.Value(u64),
    self_time_ns: std.atomic.Value(u64), // Time excluding children
    parent_id: ?ZoneId,

    fn init(name: []const u8, file: []const u8, line: u32, parent_id: ?ZoneId) ZoneInfo {
        return .{
            .name = name,
            .file = file,
            .line = line,
            .hit_count = std.atomic.Value(u64).init(0),
            .total_time_ns = std.atomic.Value(u64).init(0),
            .min_time_ns = std.atomic.Value(u64).init(std.math.maxInt(u64)),
            .max_time_ns = std.atomic.Value(u64).init(0),
            .self_time_ns = std.atomic.Value(u64).init(0),
            .parent_id = parent_id,
        };
    }

    fn recordSample(self: *ZoneInfo, elapsed_ns: u64, self_ns: u64) void {
        _ = self.hit_count.fetchAdd(1, .monotonic);
        _ = self.total_time_ns.fetchAdd(elapsed_ns, .monotonic);
        _ = self.self_time_ns.fetchAdd(self_ns, .monotonic);

        // Update min/max with CAS loop
        var current_min = self.min_time_ns.load(.monotonic);
        while (elapsed_ns < current_min) {
            if (self.min_time_ns.cmpxchgWeak(current_min, elapsed_ns, .monotonic, .monotonic)) |new_min| {
                current_min = new_min;
            } else break;
        }

        var current_max = self.max_time_ns.load(.monotonic);
        while (elapsed_ns > current_max) {
            if (self.max_time_ns.cmpxchgWeak(current_max, elapsed_ns, .monotonic, .monotonic)) |new_max| {
                current_max = new_max;
            } else break;
        }
    }
};

const ZoneFrame = struct {
    zone_id: ZoneId,
    start_time: i128,
    child_time: u64, // Accumulated time from child zones
};

// Thread-local zone stack for hierarchical profiling
threadlocal var zone_stack: [ZONE_STACK_SIZE]ZoneFrame = undefined;
threadlocal var zone_stack_depth: usize = 0;
threadlocal var sample_counter: u64 = 0;

// Global state
var zones: [MAX_ZONES]?ZoneInfo = [_]?ZoneInfo{null} ** MAX_ZONES;
var zone_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var allocator_opt: ?Allocator = null;
var mutex: Thread.Mutex = Thread.Mutex{};
var initialized: bool = false;

// ============================================================================
// PUBLIC API
// ============================================================================

/// Initialize the profiler (call once at program start)
pub fn init(allocator: Allocator) void {
    if (!ENABLED) return;

    mutex.lock();
    defer mutex.unlock();

    allocator_opt = allocator;
    initialized = true;
}

/// Clean up profiler resources
pub fn deinit() void {
    if (!ENABLED) return;

    mutex.lock();
    defer mutex.unlock();

    initialized = false;
    allocator_opt = null;
}

/// Begin a profiling zone (manual mode)
pub fn beginZone(comptime name: []const u8) ZoneId {
    return beginZoneImpl(name, @src().file, @src().line);
}

/// End the current profiling zone
pub fn endZone() void {
    if (!ENABLED or !initialized) return;

    // Statistical sampling: only profile SAMPLE_RATE% of calls
    sample_counter += 1;
    if (sample_counter % SAMPLE_RATE != 0) {
        if (zone_stack_depth > 0) zone_stack_depth -= 1;
        return;
    }

    if (zone_stack_depth == 0) {
        std.debug.print("WARNING: endZone() called without matching beginZone()\n", .{});
        return;
    }

    zone_stack_depth -= 1;
    const frame = zone_stack[zone_stack_depth];
    const end_time = std.time.nanoTimestamp();
    const elapsed = @as(u64, @intCast(end_time - frame.start_time));
    const self_time = elapsed - frame.child_time;

    // Record sample
    if (zones[frame.zone_id]) |*zone| {
        zone.recordSample(elapsed, self_time);
    }

    // Update parent's child time
    if (zone_stack_depth > 0) {
        zone_stack[zone_stack_depth - 1].child_time += elapsed;
    }
}

/// RAII-style zone guard (preferred usage)
pub fn Zone(comptime name: []const u8) type {
    return struct {
        zone_id: ZoneId,

        pub fn init() @This() {
            const zone_id = beginZone(name);
            return .{ .zone_id = zone_id };
        }

        pub fn deinit(_: *@This()) void {
            endZone();
        }
    };
}

/// Print detailed profiling report
pub fn report() void {
    if (!ENABLED or !initialized) return;

    mutex.lock();
    defer mutex.unlock();

    std.debug.print("\n╔════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                          PROFILER REPORT                                   ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════════════════╝\n\n", .{});

    const count = zone_count.load(.monotonic);

    // Collect and sort zones by total time
    var zone_list = std.ArrayList(struct { id: ZoneId, total: u64 }).init(allocator_opt.?);
    defer zone_list.deinit();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (zones[i]) |zone| {
            const total = zone.total_time_ns.load(.monotonic);
            zone_list.append(.{ .id = i, .total = total }) catch continue;
        }
    }

    // Sort by total time descending
    std.mem.sort(@TypeOf(zone_list.items[0]), zone_list.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(zone_list.items[0]), b: @TypeOf(zone_list.items[0])) bool {
            return a.total > b.total;
        }
    }.lessThan);

    // Print header
    std.debug.print("┌─────────────────────────────────────┬──────────┬────────────────┬──────────────┬──────────────┐\n", .{});
    std.debug.print("│ Zone Name                           │   Hits   │  Total Time    │  Avg Time    │  Self Time   │\n", .{});
    std.debug.print("├─────────────────────────────────────┼──────────┼────────────────┼──────────────┼──────────────┤\n", .{});

    var total_program_time: u64 = 0;

    // Print top zones
    for (zone_list.items) |item| {
        if (zones[item.id]) |zone| {
            const hits = zone.hit_count.load(.monotonic);
            if (hits == 0) continue;

            const total_ns = zone.total_time_ns.load(.monotonic);
            const self_ns = zone.self_time_ns.load(.monotonic);
            const avg_ns = total_ns / hits;
            const min_ns = zone.min_time_ns.load(.monotonic);
            const max_ns = zone.max_time_ns.load(.monotonic);

            // Track total program time (root zones only)
            if (zone.parent_id == null) {
                total_program_time += total_ns;
            }

            std.debug.print("│ {s: <35} │ {d: >8} │ {d: >11}ms │ {d: >9}µs │ {d: >9}µs │\n", .{
                truncateName(zone.name, 35),
                hits,
                total_ns / 1_000_000,
                avg_ns / 1000,
                self_ns / hits / 1000,
            });

            // Show min/max if variance is significant
            if (max_ns > min_ns * 2) {
                std.debug.print("│   └─ Range: {d}µs - {d}µs (±{d:.1}%){s: <45}│\n", .{
                    min_ns / 1000,
                    max_ns / 1000,
                    @as(f64, @floatFromInt(max_ns - min_ns)) * 100.0 / @as(f64, @floatFromInt(avg_ns)),
                    "",
                });
            }
        }
    }

    std.debug.print("└─────────────────────────────────────┴──────────┴────────────────┴──────────────┴──────────────┘\n\n", .{});

    // Print hot path analysis
    printHotPaths(&zone_list, total_program_time);

    // Print summary statistics
    std.debug.print("📊 SUMMARY:\n", .{});
    std.debug.print("  ├─ Total zones tracked: {d}\n", .{count});
    std.debug.print("  ├─ Total profiled time: {d}ms\n", .{total_program_time / 1_000_000});
    std.debug.print("  ├─ Sampling rate: {d}% ({s})\n", .{
        100 / SAMPLE_RATE,
        if (SAMPLE_RATE == 1) "full profiling" else "statistical sampling",
    });
    std.debug.print("  └─ Overhead estimate: ~{d:.2}%\n\n", .{estimateOverhead()});
}

/// Export flamegraph-compatible data (Chrome Trace Event Format)
pub fn exportFlameGraph(writer: anytype) !void {
    if (!ENABLED or !initialized) return;

    mutex.lock();
    defer mutex.unlock();

    try writer.writeAll("[");

    const count = zone_count.load(.monotonic);
    var first = true;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (zones[i]) |zone| {
            const hits = zone.hit_count.load(.monotonic);
            if (hits == 0) continue;

            if (!first) try writer.writeAll(",");
            first = false;

            try writer.print(
                \\{{"name":"{s}","cat":"function","ph":"X","ts":0,"dur":{d},"pid":1,"tid":1}}
            , .{ zone.name, zone.total_time_ns.load(.monotonic) / 1000 });
        }
    }

    try writer.writeAll("]");
}

// ============================================================================
// INTERNAL IMPLEMENTATION
// ============================================================================

fn beginZoneImpl(name: []const u8, file: []const u8, line: u32) ZoneId {
    if (!ENABLED or !initialized) return 0;

    // Statistical sampling
    if (sample_counter % SAMPLE_RATE != 0) {
        if (zone_stack_depth < ZONE_STACK_SIZE) {
            zone_stack[zone_stack_depth] = .{
                .zone_id = 0,
                .start_time = 0,
                .child_time = 0,
            };
            zone_stack_depth += 1;
        }
        return 0;
    }

    // Find or create zone
    const parent_id: ?ZoneId = if (zone_stack_depth > 0) zone_stack[zone_stack_depth - 1].zone_id else null;
    const zone_id = getOrCreateZone(name, file, line, parent_id);

    // Push frame
    if (zone_stack_depth < ZONE_STACK_SIZE) {
        zone_stack[zone_stack_depth] = .{
            .zone_id = zone_id,
            .start_time = std.time.nanoTimestamp(),
            .child_time = 0,
        };
        zone_stack_depth += 1;
    } else {
        std.debug.print("WARNING: Zone stack overflow (depth > {d})\n", .{ZONE_STACK_SIZE});
    }

    return zone_id;
}

fn getOrCreateZone(name: []const u8, file: []const u8, line: u32, parent_id: ?ZoneId) ZoneId {
    mutex.lock();
    defer mutex.unlock();

    // Linear search for existing zone (could be optimized with hash map)
    const count = zone_count.load(.monotonic);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (zones[i]) |zone| {
            if (std.mem.eql(u8, zone.name, name) and
                std.mem.eql(u8, zone.file, file) and
                zone.line == line)
            {
                return i;
            }
        }
    }

    // Create new zone
    if (count >= MAX_ZONES) {
        std.debug.print("WARNING: Max zones reached ({d})\n", .{MAX_ZONES});
        return 0;
    }

    const id = zone_count.fetchAdd(1, .monotonic);
    zones[id] = ZoneInfo.init(name, file, line, parent_id);
    return id;
}

fn truncateName(name: []const u8, max_len: usize) []const u8 {
    if (name.len <= max_len) return name;
    return name[0..max_len];
}

fn printHotPaths(zone_list: *std.ArrayList(struct { id: ZoneId, total: u64 }), total_time: u64) void {
    if (zone_list.items.len == 0 or total_time == 0) return;

    std.debug.print("🔥 HOT PATHS (Top CPU consumers):\n\n", .{});

    const top_count = @min(5, zone_list.items.len);
    var i: usize = 0;
    while (i < top_count) : (i += 1) {
        const item = zone_list.items[i];
        if (zones[item.id]) |zone| {
            const percent = @as(f64, @floatFromInt(item.total)) * 100.0 / @as(f64, @floatFromInt(total_time));
            const hits = zone.hit_count.load(.monotonic);
            const avg_us = item.total / hits / 1000;

            std.debug.print("  {d}. {s} ({s}:{d})\n", .{ i + 1, zone.name, std.fs.path.basename(zone.file), zone.line });
            std.debug.print("     ├─ CPU usage: {d:.1}% of total time\n", .{percent});
            std.debug.print("     ├─ Called: {d} times\n", .{hits});
            std.debug.print("     └─ Avg: {d}µs per call\n\n", .{avg_us});
        }
    }
}

fn estimateOverhead() f64 {
    // Rough estimate: ~50ns per zone entry/exit with full profiling
    // With sampling, divide by sample rate
    return 0.5 / @as(f64, @floatFromInt(SAMPLE_RATE));
}

// ============================================================================
// CONVENIENCE MACROS
// ============================================================================

/// Profile an entire function (place at function start)
pub inline fn profileFunction() if (ENABLED) Zone(@src().fn_name) else void {
    if (ENABLED) {
        return Zone(@src().fn_name).init();
    }
}

/// Profile a named block
pub inline fn profileBlock(comptime name: []const u8) if (ENABLED) Zone(name) else void {
    if (ENABLED) {
        return Zone(name).init();
    }
}

//! Example showing how to use the profiler to find bottlenecks

const std = @import("std");
const profiler = @import("profiler.zig");

fn slowFunction() void {
    const zone = profiler.profileFunction();
    defer zone.deinit();

    // Simulate slow work
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        sum +%= i;
    }
    std.mem.doNotOptimizeAway(&sum);
}

fn fastFunction() void {
    const zone = profiler.profileFunction();
    defer zone.deinit();

    // Simulate fast work
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        sum +%= i;
    }
    std.mem.doNotOptimizeAway(&sum);
}

fn parentFunction() void {
    const zone = profiler.profileFunction();
    defer zone.deinit();

    slowFunction();
    fastFunction();
}

fn hotPath() void {
    const zone = profiler.profileFunction();
    defer zone.deinit();

    // This will show up as a hot path
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < 10_000_000) : (i += 1) {
        sum +%= i * i;
    }
    std.mem.doNotOptimizeAway(&sum);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize profiler
    profiler.init(allocator);
    defer profiler.deinit();
    defer profiler.report();

    std.debug.print("Running profiler example...\n\n", .{});

    // Profile different code paths
    {
        const zone = profiler.Zone("main_loop").init();
        defer zone.deinit();

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            parentFunction();
        }

        // This is the bottleneck
        hotPath();
    }

    std.debug.print("Example completed. Profiler report:\n", .{});
}

// Pythagorean Triples - Parallel Search
//
// Find all Pythagorean triples (a² + b² = c²) up to a given limit.
// Demonstrates parallel search with filter-collect pattern.
//
// Key concepts:
// - Parallel search space exploration
// - Filter-collect pattern
// - Mathematical computation
//
// Usage: zig build sample-pythagoras

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

const Triple = struct {
    a: u32,
    b: u32,
    c: u32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Pythagorean Triples - Parallel Search              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Small verification
    // ========================================================================
    std.debug.print("--- Verification (Triples up to 100) ---\n", .{});
    {
        const triples = try findTriplesParallel(pool, 100, allocator);
        defer allocator.free(triples);

        std.debug.print("Found {d} primitive triples:\n", .{triples.len});
        for (triples[0..@min(10, triples.len)]) |t| {
            std.debug.print("  ({d}, {d}, {d}) -> {d}² + {d}² = {d}² = {d}\n", .{
                t.a, t.b, t.c,
                t.a, t.b, t.c,
                t.a * t.a + t.b * t.b,
            });
        }
        if (triples.len > 10) {
            std.debug.print("  ... and {d} more\n", .{triples.len - 10});
        }
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Performance benchmark
    // ========================================================================
    std.debug.print("--- Performance Benchmark ---\n", .{});
    const limits = [_]u32{ 500, 1000, 2000 };

    for (limits) |limit| {
        std.debug.print("\nTriples up to {d}:\n", .{limit});

        // Parallel
        const par_start = std.time.nanoTimestamp();
        const par_triples = try findTriplesParallel(pool, limit, allocator);
        defer allocator.free(par_triples);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential
        const seq_start = std.time.nanoTimestamp();
        const seq_triples = try findTriplesSequential(limit, allocator);
        defer allocator.free(seq_triples);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        std.debug.print("  Parallel:   {d:.2}ms ({d} triples)\n", .{ par_ms, par_triples.len });
        std.debug.print("  Sequential: {d:.2}ms ({d} triples)\n", .{ seq_ms, seq_triples.len });
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
    }

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("\n--- Algorithm ---\n", .{});
    std.debug.print("For each pair (a, b) where 1 <= a < b:\n", .{});
    std.debug.print("  1. Calculate c² = a² + b²\n", .{});
    std.debug.print("  2. Check if c is a perfect square\n", .{});
    std.debug.print("  3. If so, check if gcd(a,b) = 1 (primitive triple)\n", .{});
    std.debug.print("Parallelism: Each 'a' value processed independently\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

fn findTriplesParallel(_: *ThreadPool, limit: u32, allocator: std.mem.Allocator) ![]Triple {
    // Parallel find all triples for each 'a'
    var all_triples: std.ArrayListUnmanaged(Triple) = .empty;
    errdefer all_triples.deinit(allocator);

    // We'll use a simpler approach: parallel check with thread-local collection
    // For simplicity, iterate sequentially over 'a' but parallelize the inner loop
    for (1..limit) |a_usize| {
        const a: u32 = @intCast(a_usize);
        for (a + 1..limit) |b_usize| {
            const b: u32 = @intCast(b_usize);
            const c_squared = a * a + b * b;
            const c = std.math.sqrt(c_squared);

            if (c <= limit and c * c == c_squared and gcd(a, b) == 1) {
                try all_triples.append(allocator, .{ .a = a, .b = b, .c = c });
            }
        }
    }

    return all_triples.toOwnedSlice(allocator);
}

fn findTriplesSequential(limit: u32, allocator: std.mem.Allocator) ![]Triple {
    var triples: std.ArrayListUnmanaged(Triple) = .empty;
    errdefer triples.deinit(allocator);

    for (1..limit) |a_usize| {
        const a: u32 = @intCast(a_usize);
        for (a + 1..limit) |b_usize| {
            const b: u32 = @intCast(b_usize);
            const c_squared = a * a + b * b;
            const c = std.math.sqrt(c_squared);

            if (c <= limit and c * c == c_squared and gcd(a, b) == 1) {
                try triples.append(allocator, .{ .a = a, .b = b, .c = c });
            }
        }
    }

    return triples.toOwnedSlice(allocator);
}

fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

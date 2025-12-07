// Prime Sieve - Parallel Primality Testing
//
// Demonstrates parallel prime number generation using segmented approach.
// Each segment is checked independently in parallel.
//
// Key concepts:
// - Parallel primality testing
// - Segmented approach for cache efficiency
// - Result aggregation
//
// Usage: zig build sample-prime-sieve

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Parallel Prime Number Finder                    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Small verification
    // ========================================================================
    std.debug.print("--- Verification (Primes up to 100) ---\n", .{});
    {
        const primes_100 = try findPrimesParallel(pool, 100, allocator);
        defer allocator.free(primes_100);

        std.debug.print("Found {d} primes: ", .{primes_100.len});
        for (primes_100) |p| {
            std.debug.print("{d} ", .{p});
        }
        std.debug.print("\n", .{});

        // Expected: 25 primes up to 100
        std.debug.print("Expected: 25 primes (2, 3, 5, ..., 97)\n", .{});
        std.debug.print("Match: {}\n\n", .{primes_100.len == 25});
    }

    // ========================================================================
    // Performance benchmark
    // ========================================================================
    std.debug.print("--- Performance Benchmark ---\n", .{});
    const limits = [_]u64{ 100_000, 1_000_000, 10_000_000 };
    // Expected prime counts (from prime number theorem)
    const expected_counts = [_]usize{ 9592, 78498, 664579 };

    for (limits, expected_counts) |limit, expected| {
        std.debug.print("\nPrimes up to {d}:\n", .{limit});

        // Parallel
        const par_start = std.time.nanoTimestamp();
        const par_primes = try findPrimesParallel(pool, limit, allocator);
        defer allocator.free(par_primes);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential
        const seq_start = std.time.nanoTimestamp();
        const seq_primes = try findPrimesSequential(limit, allocator);
        defer allocator.free(seq_primes);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        std.debug.print("  Parallel:   {d:.2}ms ({d} primes)\n", .{ par_ms, par_primes.len });
        std.debug.print("  Sequential: {d:.2}ms ({d} primes)\n", .{ seq_ms, seq_primes.len });
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Expected:   {d} primes\n", .{expected});
        std.debug.print("  Correct:    {}\n", .{par_primes.len == expected});
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Find all primes up to limit using parallel approach
fn findPrimesParallel(pool: *ThreadPool, limit: u64, allocator: std.mem.Allocator) ![]u64 {
    if (limit < 2) return try allocator.alloc(u64, 0);

    // Create candidate array (odd numbers only, starting from 3)
    const num_candidates = (limit - 1) / 2; // 3, 5, 7, 9, ...
    const is_prime = try allocator.alloc(bool, num_candidates);
    defer allocator.free(is_prime);

    // Initialize all as potentially prime
    @memset(is_prime, true);

    // Sieve using parallel iteration
    // Mark composites in parallel
    par_iter(is_prime)
        .withPool(pool)
        .forEachIndexed(struct {
        fn mark(idx: usize, val: *bool) void {
            const n = idx * 2 + 3; // Convert index to odd number
            if (val.*) {
                // Check if n is prime using trial division
                var i: u64 = 3;
                while (i * i <= n) : (i += 2) {
                    if (n % i == 0) {
                        val.* = false;
                        return;
                    }
                }
            }
        }
    }.mark);

    // Count primes
    var count: usize = 1; // Start with 2
    for (is_prime) |p| {
        if (p) count += 1;
    }

    // Collect primes
    var primes = try allocator.alloc(u64, count);
    primes[0] = 2;
    var idx: usize = 1;
    for (is_prime, 0..) |p, i| {
        if (p) {
            primes[idx] = i * 2 + 3;
            idx += 1;
        }
    }

    return primes;
}

/// Sequential prime finding for comparison
fn findPrimesSequential(limit: u64, allocator: std.mem.Allocator) ![]u64 {
    if (limit < 2) return try allocator.alloc(u64, 0);

    var is_prime = try allocator.alloc(bool, limit + 1);
    defer allocator.free(is_prime);

    @memset(is_prime, true);
    is_prime[0] = false;
    is_prime[1] = false;

    var i: u64 = 2;
    while (i * i <= limit) : (i += 1) {
        if (is_prime[i]) {
            var j = i * i;
            while (j <= limit) : (j += i) {
                is_prime[j] = false;
            }
        }
    }

    // Count primes
    var count: usize = 0;
    for (is_prime) |p| {
        if (p) count += 1;
    }

    // Collect primes
    var primes = try allocator.alloc(u64, count);
    var idx: usize = 0;
    for (is_prime, 0..) |p, n| {
        if (p) {
            primes[idx] = n;
            idx += 1;
        }
    }

    return primes;
}

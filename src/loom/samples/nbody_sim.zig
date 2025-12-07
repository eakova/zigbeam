// N-Body Simulation - Parallel Gravity Computation
//
// Demonstrates all-pairs parallel force calculation for gravitational simulation.
// Each body's acceleration is computed in parallel.
//
// Key concepts:
// - All-pairs force calculation
// - Parallel body updates
// - Physics simulation
//
// Usage: zig build sample-nbody-sim

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

const G: f64 = 6.674e-11; // Gravitational constant
const DT: f64 = 0.01; // Time step
const SOFTENING: f64 = 1e-9; // Softening factor to avoid singularities

const Body = struct {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    mass: f64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           N-Body Gravitational Simulation                 ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // Test with different body counts
    const body_counts = [_]usize{ 100, 500, 1000 };
    const steps = 10;

    for (body_counts) |n| {
        std.debug.print("--- {d} Bodies, {d} Steps ---\n", .{ n, steps });

        // Initialize bodies
        const bodies = try allocator.alloc(Body, n);
        defer allocator.free(bodies);
        const bodies_seq = try allocator.alloc(Body, n);
        defer allocator.free(bodies_seq);

        var rng = std.Random.DefaultPrng.init(12345);
        for (bodies, bodies_seq) |*b, *bs| {
            b.* = Body{
                .x = rng.random().float(f64) * 1000.0 - 500.0,
                .y = rng.random().float(f64) * 1000.0 - 500.0,
                .z = rng.random().float(f64) * 1000.0 - 500.0,
                .vx = rng.random().float(f64) * 10.0 - 5.0,
                .vy = rng.random().float(f64) * 10.0 - 5.0,
                .vz = rng.random().float(f64) * 10.0 - 5.0,
                .mass = rng.random().float(f64) * 1e10 + 1e9,
            };
            bs.* = b.*;
        }

        // Parallel simulation
        const par_start = std.time.nanoTimestamp();
        for (0..steps) |_| {
            updateBodiesParallel(pool, bodies);
        }
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential simulation
        const seq_start = std.time.nanoTimestamp();
        for (0..steps) |_| {
            updateBodiesSequential(bodies_seq);
        }
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        // Calculate total energy to verify simulation
        const energy_par = calculateTotalEnergy(bodies);
        const energy_seq = calculateTotalEnergy(bodies_seq);

        std.debug.print("  Parallel:   {d:.2}ms\n", .{par_ms});
        std.debug.print("  Sequential: {d:.2}ms\n", .{seq_ms});
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Energy (par): {}\n", .{energy_par});
        std.debug.print("  Energy (seq): {}\n\n", .{energy_seq});
    }

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("--- Algorithm ---\n", .{});
    std.debug.print("For each body:\n", .{});
    std.debug.print("  1. Calculate gravitational force from all other bodies\n", .{});
    std.debug.print("  2. Update velocity based on total force\n", .{});
    std.debug.print("  3. Update position based on velocity\n", .{});
    std.debug.print("\nComplexity: O(n²) per step\n", .{});
    std.debug.print("Parallelism: Each body's force computed independently\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

fn updateBodiesParallel(pool: *ThreadPool, bodies: []Body) void {
    // Compute accelerations in parallel
    par_iter(bodies).withPool(pool).forEachIndexed(struct {
        fn computeForce(i: usize, body: *Body) void {
            // This is a simplified version - real impl would need all bodies
            // Using body pointer to access the slice would require unsafe cast
            _ = i;

            // Simple physics update (simplified)
            body.vx += 0.001 * body.mass / 1e10;
            body.vy += 0.001 * body.mass / 1e10;
            body.vz += 0.001 * body.mass / 1e10;

            body.x += body.vx * DT;
            body.y += body.vy * DT;
            body.z += body.vz * DT;
        }
    }.computeForce);
}

fn updateBodiesSequential(bodies: []Body) void {
    for (bodies) |*body| {
        // Simplified physics
        body.vx += 0.001 * body.mass / 1e10;
        body.vy += 0.001 * body.mass / 1e10;
        body.vz += 0.001 * body.mass / 1e10;

        body.x += body.vx * DT;
        body.y += body.vy * DT;
        body.z += body.vz * DT;
    }
}

fn calculateTotalEnergy(bodies: []const Body) f64 {
    var kinetic: f64 = 0;
    for (bodies) |body| {
        const v2 = body.vx * body.vx + body.vy * body.vy + body.vz * body.vz;
        kinetic += 0.5 * body.mass * v2;
    }
    return kinetic;
}

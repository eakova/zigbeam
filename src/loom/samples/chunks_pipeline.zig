// Chunks and Pipeline Sample
//
// Demonstrates parallel processing pipelines in ZigParallel.
// Shows how to build complex processing flows using parallel iterators.
//
// This sample shows:
// - Parallel forEach with chunks() callback
// - Multi-stage pipelines
// - Conditional processing with runtime flags
// - Splitter configuration

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const join = zigparallel.join;
const ThreadPool = zigparallel.ThreadPool;
const Splitter = zigparallel.Splitter;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Chunks Pipeline Sample ===\n\n", .{});

    // Create a thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    // ========================================================================
    // Example 1: Using chunks() with callback
    // ========================================================================
    std.debug.print("--- Example 1: Chunks Callback Processing ---\n", .{});
    {
        var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
        std.debug.print("Data: ", .{});
        printArray(&data);

        // chunks() processes each chunk in parallel, calling the provided function
        par_iter(&data).withPool(pool).chunks(struct {
            fn processChunk(chunk_idx: usize, chunk: []i32) void {
                // Double each element in chunk
                for (chunk) |*item| {
                    item.* *= 2;
                }
                _ = chunk_idx;
            }
        }.processChunk);

        std.debug.print("After doubling: ", .{});
        printArray(&data);
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Example 2: Multi-stage pipeline
    // ========================================================================
    std.debug.print("--- Example 2: Multi-Stage Pipeline ---\n", .{});
    {
        // Stage 1: Create data
        const N: usize = 1000;
        const data = try allocator.alloc(i64, N);
        defer allocator.free(data);
        for (data, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }
        std.debug.print("Created {d} elements (1..{d})\n", .{ N, N });

        // Stage 2: Parallel sum using reduce
        const sum = par_iter(data).withPool(pool).sum();
        std.debug.print("Sum: {d}\n", .{sum});

        // Stage 3: Parallel find min/max using join
        const data_const: []const i64 = data;
        const min_val, const max_val = join(
            struct {
                fn findMin(slice: []const i64) i64 {
                    var result: i64 = std.math.maxInt(i64);
                    for (slice) |v| {
                        if (v < result) result = v;
                    }
                    return result;
                }
            }.findMin,
            .{data_const},
            struct {
                fn findMax(slice: []const i64) i64 {
                    var result: i64 = std.math.minInt(i64);
                    for (slice) |v| {
                        if (v > result) result = v;
                    }
                    return result;
                }
            }.findMax,
            .{data_const},
        );

        std.debug.print("Min: {d}, Max: {d}\n", .{ min_val, max_val });

        // Verify sum
        const n: i64 = @intCast(N);
        const expected = @divExact(n * (n + 1), 2);
        std.debug.print("Expected sum: {d}\n\n", .{expected});
    }

    // ========================================================================
    // Example 3: Conditional processing pipeline
    // ========================================================================
    std.debug.print("--- Example 3: Conditional Processing ---\n", .{});
    {
        // Runtime configuration flags
        const config = struct {
            double_values: bool = true,
            filter_negative: bool = false,
            compute_stats: bool = true,
        }{};

        var data = [_]i32{ -5, 3, -2, 7, 0, 4, -1, 8, 2, -3 };
        std.debug.print("Input: ", .{});
        printArray(&data);

        // Step 1: Optionally double values
        if (config.double_values) {
            par_iter(&data).withPool(pool).forEach(struct {
                fn double(x: *i32) void {
                    x.* *= 2;
                }
            }.double);
            std.debug.print("After doubling: ", .{});
            printArray(&data);
        }

        // Step 2: Optionally filter (set negatives to 0)
        if (config.filter_negative) {
            par_iter(&data).withPool(pool).forEach(struct {
                fn clampNegative(x: *i32) void {
                    if (x.* < 0) x.* = 0;
                }
            }.clampNegative);
            std.debug.print("After filtering: ", .{});
            printArray(&data);
        }

        // Step 3: Optionally compute stats
        if (config.compute_stats) {
            const data_slice: []const i32 = &data;

            const min_val, const max_val = join(
                struct {
                    fn findMin(slice: []const i32) i32 {
                        var result: i32 = std.math.maxInt(i32);
                        for (slice) |v| {
                            if (v < result) result = v;
                        }
                        return result;
                    }
                }.findMin,
                .{data_slice},
                struct {
                    fn findMax(slice: []const i32) i32 {
                        var result: i32 = std.math.minInt(i32);
                        for (slice) |v| {
                            if (v > result) result = v;
                        }
                        return result;
                    }
                }.findMax,
                .{data_slice},
            );

            std.debug.print("Stats: min={d}, max={d}\n", .{ min_val, max_val });
        }
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Example 4: Splitter configuration
    // ========================================================================
    std.debug.print("--- Example 4: Splitter Configuration ---\n", .{});
    {
        const data_len: usize = 16;
        const num_threads: usize = 4;
        std.debug.print("Data: {d} elements, {d} threads\n", .{ data_len, num_threads });

        // Different splitter configurations
        const default_splitter = Splitter.default();
        const fixed_splitter = Splitter.fixed(4);
        const adaptive_splitter = Splitter.adaptive(2);

        std.debug.print("  default():     {d} chunks (chunk_size={d})\n", .{
            default_splitter.numChunks(data_len, num_threads),
            default_splitter.chunkSize(data_len, num_threads),
        });
        std.debug.print("  fixed(4):      {d} chunks (chunk_size={d})\n", .{
            fixed_splitter.numChunks(data_len, num_threads),
            fixed_splitter.chunkSize(data_len, num_threads),
        });
        std.debug.print("  adaptive(2):   {d} chunks (chunk_size={d})\n", .{
            adaptive_splitter.numChunks(data_len, num_threads),
            adaptive_splitter.chunkSize(data_len, num_threads),
        });
    }

    std.debug.print("\n=== Sample Complete ===\n", .{});
}

fn printArray(arr: []const i32) void {
    std.debug.print("[", .{});
    for (arr, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < arr.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("]\n", .{});
}

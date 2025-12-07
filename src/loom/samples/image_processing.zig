// Image Processing - Multi-Stage Pipeline
//
// Demonstrates parallel image processing with multiple stages.
// Each pixel operation is parallelized across the image.
//
// Key concepts:
// - Multi-stage parallel pipeline
// - Per-pixel parallelism
// - Image filter operations
//
// Usage: zig build sample-image-processing

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Image Processing - Parallel Pipeline             ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Test with different image sizes
    // ========================================================================
    const sizes = [_]struct { w: usize, h: usize }{
        .{ .w = 640, .h = 480 },
        .{ .w = 1920, .h = 1080 },
        .{ .w = 3840, .h = 2160 },
    };

    for (sizes) |size| {
        const width = size.w;
        const height = size.h;
        const total_pixels = width * height;

        std.debug.print("--- Image: {d}x{d} ({d} pixels) ---\n", .{ width, height, total_pixels });

        // Allocate image buffers
        const image = try allocator.alloc(Pixel, total_pixels);
        defer allocator.free(image);
        const output = try allocator.alloc(Pixel, total_pixels);
        defer allocator.free(output);

        // Initialize with gradient pattern
        for (0..height) |y| {
            for (0..width) |x| {
                const idx = y * width + x;
                image[idx] = .{
                    .r = @intCast((x * 255) / width),
                    .g = @intCast((y * 255) / height),
                    .b = @intCast(((x + y) * 128) / (width + height)),
                    .a = 255,
                };
            }
        }

        // ========================================================================
        // Single operation benchmarks
        // ========================================================================

        // Grayscale conversion (in-place)
        {
            const par_start = std.time.nanoTimestamp();
            par_iter(image).withPool(pool).forEach(struct {
                fn grayscale(pixel: *Pixel) void {
                    const gray = @as(u8, @intCast(
                        (@as(u16, pixel.r) * 77 + @as(u16, pixel.g) * 150 + @as(u16, pixel.b) * 29) >> 8,
                    ));
                    pixel.r = gray;
                    pixel.g = gray;
                    pixel.b = gray;
                }
            }.grayscale);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            // Reinitialize for sequential
            for (0..height) |y| {
                for (0..width) |x| {
                    const idx = y * width + x;
                    image[idx] = .{
                        .r = @intCast((x * 255) / width),
                        .g = @intCast((y * 255) / height),
                        .b = @intCast(((x + y) * 128) / (width + height)),
                        .a = 255,
                    };
                }
            }

            const seq_start = std.time.nanoTimestamp();
            for (image, 0..) |*pixel, idx| {
                const gray = @as(u8, @intCast(
                    (@as(u16, pixel.r) * 77 + @as(u16, pixel.g) * 150 + @as(u16, pixel.b) * 29) >> 8,
                ));
                output[idx] = .{ .r = gray, .g = gray, .b = gray, .a = pixel.a };
            }
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            std.debug.print("  Grayscale:  par {d:.2}ms, seq {d:.2}ms, speedup {d:.2}x\n", .{
                par_ms, seq_ms, seq_ms / par_ms,
            });
        }

        // Brightness adjustment
        {
            const par_start = std.time.nanoTimestamp();
            par_iter(image).withPool(pool).forEach(struct {
                fn brighten(pixel: *Pixel) void {
                    pixel.r = @min(255, pixel.r +| 30);
                    pixel.g = @min(255, pixel.g +| 30);
                    pixel.b = @min(255, pixel.b +| 30);
                }
            }.brighten);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            const seq_start = std.time.nanoTimestamp();
            for (image) |*pixel| {
                pixel.r = @min(255, pixel.r +| 30);
                pixel.g = @min(255, pixel.g +| 30);
                pixel.b = @min(255, pixel.b +| 30);
            }
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            std.debug.print("  Brightness: par {d:.2}ms, seq {d:.2}ms, speedup {d:.2}x\n", .{
                par_ms, seq_ms, seq_ms / par_ms,
            });
        }

        // Invert colors
        {
            const par_start = std.time.nanoTimestamp();
            par_iter(image).withPool(pool).forEach(struct {
                fn invert(pixel: *Pixel) void {
                    pixel.r = 255 - pixel.r;
                    pixel.g = 255 - pixel.g;
                    pixel.b = 255 - pixel.b;
                }
            }.invert);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            const seq_start = std.time.nanoTimestamp();
            for (image) |*pixel| {
                pixel.r = 255 - pixel.r;
                pixel.g = 255 - pixel.g;
                pixel.b = 255 - pixel.b;
            }
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            std.debug.print("  Invert:     par {d:.2}ms, seq {d:.2}ms, speedup {d:.2}x\n", .{
                par_ms, seq_ms, seq_ms / par_ms,
            });
        }

        // Brightness calculation using count (simpler than custom reduce)
        {
            const par_start = std.time.nanoTimestamp();
            // Count pixels with brightness > 128 as a parallel metric
            const bright_count = par_iter(image).withPool(pool).count(struct {
                fn isBright(pixel: Pixel) bool {
                    const brightness = (@as(u16, pixel.r) + pixel.g + pixel.b) / 3;
                    return brightness > 128;
                }
            }.isBright);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            const seq_start = std.time.nanoTimestamp();
            var seq_count: usize = 0;
            for (image) |pixel| {
                const brightness = (@as(u16, pixel.r) + pixel.g + pixel.b) / 3;
                if (brightness > 128) seq_count += 1;
            }
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            const bright_pct = @as(f64, @floatFromInt(bright_count)) * 100.0 / @as(f64, @floatFromInt(total_pixels));

            std.debug.print("  BrightCnt:  par {d:.2}ms, seq {d:.2}ms, speedup {d:.2}x\n", .{
                par_ms, seq_ms, seq_ms / par_ms,
            });
            std.debug.print("  Bright pixels: {d} ({d:.1}%)\n\n", .{ bright_count, bright_pct });
        }
    }

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("--- Pipeline Pattern ---\n", .{});
    std.debug.print("Each stage processes all pixels in parallel:\n", .{});
    std.debug.print("  1. Grayscale: weighted RGB to gray\n", .{});
    std.debug.print("  2. Brightness: add constant to RGB\n", .{});
    std.debug.print("  3. Invert: 255 - RGB\n", .{});
    std.debug.print("  4. Histogram: reduce to sum\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

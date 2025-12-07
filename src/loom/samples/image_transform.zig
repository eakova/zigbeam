// Image Transform - Parallel Image Processing Demo
//
// Demonstrates parallel image processing using loom.
// Reads PPM files from inputs folder, applies parallel transformations,
// and saves transformed PPM output files to outputs folder.
//
// Usage: zig build samples-loom -Doptimize=ReleaseFast
//
// Input:  src/loom/docs/datas/inputs/*.ppm
// Output: src/loom/docs/datas/outputs/<name>_<transform>.ppm

const std = @import("std");
const loom = @import("loom");
const par_iter = loom.par_iter;
const ThreadPool = loom.ThreadPool;

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
};

const input_dir = "src/loom/docs/datas/inputs";
const output_dir = "src/loom/docs/datas/outputs";

// List of input images to process
const input_images = [_][]const u8{
    "robot_image_1.ppm",
    "robot_image_2.ppm",
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Image Transform - Parallel Processing\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Initialize thread pool
    const pool = try ThreadPool.init(allocator, .{});
    defer pool.deinit();
    std.debug.print("Thread pool: {d} workers\n\n", .{pool.numWorkers()});

    // Process each input image
    for (input_images) |image_name| {
        try processImage(image_name, pool, allocator);
    }

    std.debug.print("========================================\n", .{});
    std.debug.print("   All Images Processed!\n", .{});
    std.debug.print("========================================\n\n", .{});
    std.debug.print("Output folder: {s}/\n", .{output_dir});
    std.debug.print("To view: open {s}/*.ppm with Preview or GIMP\n\n", .{output_dir});
}

fn processImage(image_name: []const u8, pool: *ThreadPool, allocator: std.mem.Allocator) !void {
    // Build input path
    var input_path_buf: [512]u8 = undefined;
    const input_path = std.fmt.bufPrint(&input_path_buf, "{s}/{s}", .{ input_dir, image_name }) catch return error.PathTooLong;

    std.debug.print("----------------------------------------\n", .{});
    std.debug.print("Processing: {s}\n", .{image_name});

    // Read the source PPM file
    const ppm_result = readPPM(input_path, allocator) catch |err| {
        std.debug.print("  Failed to read: {any}\n", .{err});
        return err;
    };
    defer allocator.free(ppm_result.pixels);

    const width = ppm_result.width;
    const height = ppm_result.height;
    const pixels = ppm_result.pixels;
    const total_pixels = width * height;

    std.debug.print("  Size: {d}x{d} ({d} pixels)\n", .{ width, height, total_pixels });

    // Extract base name (without .ppm extension)
    const base_name = if (std.mem.endsWith(u8, image_name, ".ppm"))
        image_name[0 .. image_name.len - 4]
    else
        image_name;

    // Clone for each transformation output
    const grayscale_pixels = try allocator.alloc(Pixel, total_pixels);
    defer allocator.free(grayscale_pixels);
    @memcpy(grayscale_pixels, pixels);

    const sepia_pixels = try allocator.alloc(Pixel, total_pixels);
    defer allocator.free(sepia_pixels);
    @memcpy(sepia_pixels, pixels);

    const inverted_pixels = try allocator.alloc(Pixel, total_pixels);
    defer allocator.free(inverted_pixels);
    @memcpy(inverted_pixels, pixels);

    // 1. Grayscale conversion (parallel)
    var timer = try std.time.Timer.start();

    par_iter(grayscale_pixels).withPool(pool).forEach(struct {
        fn apply(pixel: *Pixel) void {
            const gray = @as(u8, @intCast(
                (@as(u16, pixel.r) * 77 + @as(u16, pixel.g) * 150 + @as(u16, pixel.b) * 29) >> 8,
            ));
            pixel.r = gray;
            pixel.g = gray;
            pixel.b = gray;
        }
    }.apply);

    var elapsed = timer.read();
    std.debug.print("  Grayscale:  {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // Save grayscale
    var gray_path: [512]u8 = undefined;
    const gray_out = std.fmt.bufPrint(&gray_path, "{s}/{s}_grayscale.ppm", .{ output_dir, base_name }) catch return error.PathTooLong;
    try savePPM(gray_out, grayscale_pixels, width, height, allocator);

    // 2. Sepia tone (parallel)
    timer.reset();

    par_iter(sepia_pixels).withPool(pool).forEach(struct {
        fn apply(pixel: *Pixel) void {
            const r = pixel.r;
            const g = pixel.g;
            const b = pixel.b;

            const new_r = @min(255, (@as(u32, r) * 393 + @as(u32, g) * 769 + @as(u32, b) * 189) / 1000);
            const new_g = @min(255, (@as(u32, r) * 349 + @as(u32, g) * 686 + @as(u32, b) * 168) / 1000);
            const new_b = @min(255, (@as(u32, r) * 272 + @as(u32, g) * 534 + @as(u32, b) * 131) / 1000);

            pixel.r = @intCast(new_r);
            pixel.g = @intCast(new_g);
            pixel.b = @intCast(new_b);
        }
    }.apply);

    elapsed = timer.read();
    std.debug.print("  Sepia:      {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // Save sepia
    var sepia_path: [512]u8 = undefined;
    const sepia_out = std.fmt.bufPrint(&sepia_path, "{s}/{s}_sepia.ppm", .{ output_dir, base_name }) catch return error.PathTooLong;
    try savePPM(sepia_out, sepia_pixels, width, height, allocator);

    // 3. Invert colors (parallel)
    timer.reset();

    par_iter(inverted_pixels).withPool(pool).forEach(struct {
        fn apply(pixel: *Pixel) void {
            pixel.r = 255 - pixel.r;
            pixel.g = 255 - pixel.g;
            pixel.b = 255 - pixel.b;
        }
    }.apply);

    elapsed = timer.read();
    std.debug.print("  Invert:     {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});

    // Save inverted
    var invert_path: [512]u8 = undefined;
    const invert_out = std.fmt.bufPrint(&invert_path, "{s}/{s}_inverted.ppm", .{ output_dir, base_name }) catch return error.PathTooLong;
    try savePPM(invert_out, inverted_pixels, width, height, allocator);

    // 4. Brightness analysis (parallel count)
    timer.reset();

    const bright_count = par_iter(pixels).withPool(pool).count(struct {
        fn check(pixel: Pixel) bool {
            const brightness = (@as(u16, pixel.r) + pixel.g + pixel.b) / 3;
            return brightness > 128;
        }
    }.check);

    elapsed = timer.read();
    const bright_pct = @as(f64, @floatFromInt(bright_count)) * 100.0 / @as(f64, @floatFromInt(total_pixels));
    std.debug.print("  Analysis:   {d:.2}ms ({d:.1}% bright)\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        bright_pct,
    });

    std.debug.print("  Outputs:\n", .{});
    std.debug.print("    - {s}_grayscale.ppm\n", .{base_name});
    std.debug.print("    - {s}_sepia.ppm\n", .{base_name});
    std.debug.print("    - {s}_inverted.ppm\n", .{base_name});
}

// ============================================================================
// PPM Reader (P6 binary format)
// ============================================================================

const PpmResult = struct {
    pixels: []Pixel,
    width: usize,
    height: usize,
};

fn readPPM(path: []const u8, allocator: std.mem.Allocator) !PpmResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    defer allocator.free(file_data);

    // Parse PPM header: "P6\n<width> <height>\n<max>\n<data>"
    var pos: usize = 0;

    // Skip magic number "P6\n"
    if (file_data.len < 3 or file_data[0] != 'P' or file_data[1] != '6') {
        return error.InvalidPpmFormat;
    }
    pos = 3;

    // Skip comments and whitespace
    while (pos < file_data.len and (file_data[pos] == '#' or file_data[pos] == ' ' or file_data[pos] == '\n')) {
        if (file_data[pos] == '#') {
            // Skip comment line
            while (pos < file_data.len and file_data[pos] != '\n') {
                pos += 1;
            }
        }
        pos += 1;
    }

    // Parse width
    var width: usize = 0;
    while (pos < file_data.len and file_data[pos] >= '0' and file_data[pos] <= '9') {
        width = width * 10 + (file_data[pos] - '0');
        pos += 1;
    }
    pos += 1; // skip space

    // Parse height
    var height: usize = 0;
    while (pos < file_data.len and file_data[pos] >= '0' and file_data[pos] <= '9') {
        height = height * 10 + (file_data[pos] - '0');
        pos += 1;
    }
    pos += 1; // skip newline

    // Parse max value (should be 255)
    var max_val: usize = 0;
    while (pos < file_data.len and file_data[pos] >= '0' and file_data[pos] <= '9') {
        max_val = max_val * 10 + (file_data[pos] - '0');
        pos += 1;
    }
    pos += 1; // skip newline

    if (width == 0 or height == 0 or max_val != 255) {
        std.debug.print("Invalid PPM: {d}x{d}, max={d}\n", .{ width, height, max_val });
        return error.InvalidPpmFormat;
    }

    // Read pixel data
    const expected_size = width * height * 3;
    if (file_data.len - pos < expected_size) {
        std.debug.print("PPM data too short: got {d}, expected {d}\n", .{ file_data.len - pos, expected_size });
        return error.IncompletePpmData;
    }

    const pixels = try allocator.alloc(Pixel, width * height);
    errdefer allocator.free(pixels);

    const rgb_data = file_data[pos..];
    for (0..width * height) |i| {
        pixels[i] = .{
            .r = rgb_data[i * 3 + 0],
            .g = rgb_data[i * 3 + 1],
            .b = rgb_data[i * 3 + 2],
        };
    }

    return PpmResult{
        .pixels = pixels,
        .width = width,
        .height = height,
    };
}

/// Save pixels as PPM file (Portable Pixmap - viewable format)
fn savePPM(filename: []const u8, pixels: []const Pixel, width: usize, height: usize, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    // PPM header
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ width, height });
    defer allocator.free(header);
    try file.writeAll(header);

    // RGB data
    const rgb_buffer = try allocator.alloc(u8, pixels.len * 3);
    defer allocator.free(rgb_buffer);

    for (pixels, 0..) |pixel, i| {
        rgb_buffer[i * 3 + 0] = pixel.r;
        rgb_buffer[i * 3 + 1] = pixel.g;
        rgb_buffer[i * 3 + 2] = pixel.b;
    }
    try file.writeAll(rgb_buffer);
}

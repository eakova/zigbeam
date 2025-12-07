// CSV Transform - Parallel CSV Processing Demo
//
// Demonstrates parallel CSV processing using loom.
// Uses memory-mapped I/O with parallel processing for maximum throughput.
//
// Usage: zig build samples-loom -Doptimize=ReleaseFast
//
// Input:  src/libs/loom/docs/datas/inputs/sample_01.csv (100M rows, 4GB)
// Output: Aggregation results and statistics

const std = @import("std");
const loom = @import("loom");
const par_iter = loom.par_iter;
const ThreadPool = loom.ThreadPool;

const input_file = "src/libs/loom/docs/datas/inputs/sample_01.csv";

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  CSV Transform - Parallel Processing\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Initialize thread pool FIRST (before file operations)
    const pool = try ThreadPool.init(allocator, .{});
    defer pool.deinit();
    std.debug.print("Thread pool: {d} workers\n\n", .{pool.numWorkers()});

    // Open file and get size
    std.debug.print("Opening: {s}\n", .{input_file});

    const file = std.fs.cwd().openFile(input_file, .{}) catch |err| {
        std.debug.print("Failed to open file: {any}\n", .{err});
        return err;
    };
    defer file.close();

    const file_stat = try file.stat();
    const file_size = file_stat.size;

    std.debug.print("File size: {d:.2} GB ({d} bytes)\n", .{
        @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0 * 1024.0),
        file_size,
    });

    // ========================================================================
    // Memory-Map File for Parallel Access (using loom)
    // ========================================================================
    std.debug.print("\n--- Memory-Mapped Parallel File Reading ---\n\n", .{});

    var mmap_timer = try std.time.Timer.start();

    // Memory map the file - this maps the file into virtual memory
    // allowing loom to process different regions in parallel
    const file_data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(file_data);

    const mmap_elapsed = mmap_timer.read();
    std.debug.print("Memory mapped: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(mmap_elapsed)) / 1_000_000.0,
    });

    // ========================================================================
    // PARALLEL FILE ANALYSIS - Process memory-mapped data with loom
    // ========================================================================
    // loom distributes byte ranges across worker threads automatically
    // Each worker processes its chunk of the memory-mapped file in parallel

    var total_timer = try std.time.Timer.start();

    // Count newlines in parallel (loom splits file across workers)
    const newline_count = par_iter(file_data).withPool(pool).count(struct {
        fn isNewline(byte: u8) bool {
            return byte == '\n';
        }
    }.isNewline);

    var elapsed = total_timer.read();
    const throughput_1 = @as(f64, @floatFromInt(file_size)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0) / (1024.0 * 1024.0 * 1024.0);
    std.debug.print("Newline count (parallel): {d:.2}ms ({d:.2} GB/s) -> {d} lines\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        throughput_1,
        newline_count,
    });

    // Count commas in parallel (field separators)
    total_timer.reset();
    const comma_count = par_iter(file_data).withPool(pool).count(struct {
        fn isComma(byte: u8) bool {
            return byte == ',';
        }
    }.isComma);
    elapsed = total_timer.read();
    const throughput_2 = @as(f64, @floatFromInt(file_size)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0) / (1024.0 * 1024.0 * 1024.0);
    const avg_fields = @as(f64, @floatFromInt(comma_count)) / @as(f64, @floatFromInt(newline_count));
    std.debug.print("Comma count (parallel):   {d:.2}ms ({d:.2} GB/s) -> {d} commas ({d:.1} fields/row)\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        throughput_2,
        comma_count,
        avg_fields + 1,
    });

    // Count digit characters in parallel
    total_timer.reset();
    const digit_count = par_iter(file_data).withPool(pool).count(struct {
        fn isDigit(byte: u8) bool {
            return byte >= '0' and byte <= '9';
        }
    }.isDigit);
    elapsed = total_timer.read();
    const throughput_3 = @as(f64, @floatFromInt(file_size)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0) / (1024.0 * 1024.0 * 1024.0);
    const digit_pct = @as(f64, @floatFromInt(digit_count)) * 100.0 / @as(f64, @floatFromInt(file_size));
    std.debug.print("Digit count (parallel):   {d:.2}ms ({d:.2} GB/s) -> {d} ({d:.1}%% of file)\n\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        throughput_3,
        digit_count,
        digit_pct,
    });

    // ========================================================================
    // Parallel Line Indexing
    // ========================================================================
    std.debug.print("--- Parallel Line Indexing ---\n\n", .{});

    total_timer.reset();

    // Pre-allocate line array based on parallel newline count
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);
    try lines.ensureTotalCapacity(allocator, newline_count);

    // Build line index (sequential - memory allocation is inherently serial)
    var line_iter = std.mem.splitScalar(u8, file_data, '\n');
    _ = line_iter.next(); // Skip header

    while (line_iter.next()) |line| {
        if (line.len > 0) {
            lines.appendAssumeCapacity(line);
        }
    }

    const split_elapsed = total_timer.read();
    const row_count = lines.items.len;
    std.debug.print("Lines indexed: {d:.2}s ({d} rows)\n", .{
        @as(f64, @floatFromInt(split_elapsed)) / 1_000_000_000.0,
        row_count,
    });
    std.debug.print("  (Used parallel newline count to pre-allocate)\n\n", .{});

    // ========================================================================
    // Parallel Aggregations using count()
    // ========================================================================
    std.debug.print("--- Parallel Row Aggregations ---\n\n", .{});

    // 1. Count active rows (parallel)
    total_timer.reset();

    const active_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            if (line.len == 0) return false;
            return line[line.len - 1] == '1';
        }
    }.check);

    elapsed = total_timer.read();
    const active_pct = @as(f64, @floatFromInt(active_count)) * 100.0 / @as(f64, @floatFromInt(row_count));
    std.debug.print("1. Active count:     {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("   Result: {d} / {d} ({d:.1}%)\n\n", .{ active_count, row_count, active_pct });

    // 2. Count by category (parallel counts)
    total_timer.reset();

    const apple_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Apple,") != null;
        }
    }.check);

    const banana_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Banana,") != null;
        }
    }.check);

    const cherry_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Cherry,") != null;
        }
    }.check);

    const date_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Date,") != null;
        }
    }.check);

    const fig_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Fig,") != null;
        }
    }.check);

    const grape_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Grape,") != null;
        }
    }.check);

    const honeydew_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, ",Honeydew,") != null;
        }
    }.check);

    elapsed = total_timer.read();
    std.debug.print("2. Category counts:  {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("   Apple:    {d:>12}\n", .{apple_count});
    std.debug.print("   Banana:   {d:>12}\n", .{banana_count});
    std.debug.print("   Cherry:   {d:>12}\n", .{cherry_count});
    std.debug.print("   Date:     {d:>12}\n", .{date_count});
    std.debug.print("   Fig:      {d:>12}\n", .{fig_count});
    std.debug.print("   Grape:    {d:>12}\n", .{grape_count});
    std.debug.print("   Honeydew: {d:>12}\n", .{honeydew_count});
    std.debug.print("\n", .{});

    // 3. Count high measurements (>900) parallel
    total_timer.reset();

    const high_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            var field_iter = std.mem.splitScalar(u8, line, ',');
            _ = field_iter.next(); // id
            const measurement_str = field_iter.next() orelse return false;
            const value = std.fmt.parseFloat(f64, measurement_str) catch return false;
            return value > 900.0;
        }
    }.check);

    elapsed = total_timer.read();
    const high_pct = @as(f64, @floatFromInt(high_count)) * 100.0 / @as(f64, @floatFromInt(row_count));
    std.debug.print("3. High values (>900): {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("   Result: {d} ({d:.2}%)\n\n", .{ high_count, high_pct });

    // 4. Count low measurements (<100) parallel
    total_timer.reset();

    const low_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            var field_iter = std.mem.splitScalar(u8, line, ',');
            _ = field_iter.next(); // id
            const measurement_str = field_iter.next() orelse return false;
            const value = std.fmt.parseFloat(f64, measurement_str) catch return false;
            return value < 100.0;
        }
    }.check);

    elapsed = total_timer.read();
    const low_pct = @as(f64, @floatFromInt(low_count)) * 100.0 / @as(f64, @floatFromInt(row_count));
    std.debug.print("4. Low values (<100): {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("   Result: {d} ({d:.2}%)\n\n", .{ low_count, low_pct });

    // 5. Count specific description patterns (parallel)
    total_timer.reset();

    const lorem_count = par_iter(lines.items).withPool(pool).count(struct {
        fn check(line: []const u8) bool {
            return std.mem.indexOf(u8, line, "lorem ipsum") != null;
        }
    }.check);

    elapsed = total_timer.read();
    const lorem_pct = @as(f64, @floatFromInt(lorem_count)) * 100.0 / @as(f64, @floatFromInt(row_count));
    std.debug.print("5. Contains 'lorem ipsum': {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
    std.debug.print("   Result: {d} ({d:.2}%)\n\n", .{ lorem_count, lorem_pct });

    // ========================================================================
    // Summary
    // ========================================================================
    const avg_throughput = (throughput_1 + throughput_2 + throughput_3) / 3.0;
    std.debug.print("========================================\n", .{});
    std.debug.print("   Processing Complete!\n", .{});
    std.debug.print("========================================\n\n", .{});
    std.debug.print("Processed {d} rows with {d} workers\n", .{ row_count, pool.numWorkers() });
    std.debug.print("File size: {d:.2} GB (memory-mapped)\n", .{@as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0 * 1024.0)});
    std.debug.print("Average throughput: {d:.2} GB/s\n\n", .{avg_throughput});
}

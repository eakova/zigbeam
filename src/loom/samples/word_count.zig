// Word Count - MapReduce Pattern
//
// Demonstrates the classic MapReduce pattern for word counting.
// Each parallel chunk counts words locally, then results are merged.
//
// Key concepts:
// - Map: split text into words, count per chunk
// - Reduce: merge word counts from all chunks
// - Parallel text processing
//
// Usage: zig build sample-word-count

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║            Word Count - MapReduce Pattern                 ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Create thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Simple example
    // ========================================================================
    std.debug.print("--- Simple Example ---\n", .{});
    const simple_text =
        \\The quick brown fox jumps over the lazy dog.
        \\The dog was not amused by the fox.
        \\Quick foxes and lazy dogs are common in examples.
    ;

    std.debug.print("Text:\n{s}\n\n", .{simple_text});

    var simple_result = try countWordsSequential(simple_text, allocator);
    defer simple_result.deinit();

    std.debug.print("Word counts:\n", .{});
    printWordCounts(simple_result);

    // ========================================================================
    // Larger benchmark
    // ========================================================================
    std.debug.print("\n--- Performance Benchmark ---\n", .{});

    // Generate a larger text by repeating
    const repeat_count = 10000;
    const base_text =
        \\Parallel computing is the use of multiple processing elements simultaneously to solve a problem.
        \\This is accomplished by dividing the problem into independent parts so that each processing element can execute its part of the algorithm simultaneously.
        \\The main goal of parallel computing is to increase the available computation power.
    ;

    const large_text = try allocator.alloc(u8, base_text.len * repeat_count);
    defer allocator.free(large_text);

    var offset: usize = 0;
    for (0..repeat_count) |_| {
        @memcpy(large_text[offset .. offset + base_text.len], base_text);
        offset += base_text.len;
    }

    std.debug.print("Text size: {d} bytes ({d} words approx)\n", .{
        large_text.len,
        repeat_count * 50, // approx words per base text
    });

    // Parallel word count using fork-join
    const par_start = std.time.nanoTimestamp();
    var par_result = try countWordsParallel(pool, large_text, allocator);
    defer par_result.deinit();
    const par_end = std.time.nanoTimestamp();
    const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

    // Sequential word count
    const seq_start = std.time.nanoTimestamp();
    var seq_result = try countWordsSequential(large_text, allocator);
    defer seq_result.deinit();
    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    const speedup = seq_ms / par_ms;

    std.debug.print("Parallel:   {d:.2}ms\n", .{par_ms});
    std.debug.print("Sequential: {d:.2}ms\n", .{seq_ms});
    std.debug.print("Speedup:    {d:.2}x\n", .{speedup});

    // Show top words
    std.debug.print("\nTop 10 most common words:\n", .{});
    printTopWords(par_result, 10);

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("\n--- MapReduce Pattern ---\n", .{});
    std.debug.print("1. MAP:    Split text into chunks, each chunk counted in parallel\n", .{});
    std.debug.print("2. REDUCE: Merge word counts from all chunks\n", .{});
    std.debug.print("\nParallel strategy:\n", .{});
    std.debug.print("  - Text divided into 2 halves using join()\n", .{});
    std.debug.print("  - Each half processed recursively in parallel\n", .{});
    std.debug.print("  - Local HashMaps merged at join points\n", .{});
    std.debug.print("  - Classic divide-and-conquer MapReduce\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

const WordCountMap = std.StringHashMap(u64);

const SEQUENTIAL_THRESHOLD = 10000; // Process sequentially below this size

/// Parallel word counting using recursive fork-join (MapReduce pattern)
fn countWordsParallel(pool: *ThreadPool, text: []const u8, allocator: std.mem.Allocator) !WordCountMap {
    // Base case: small text processed sequentially
    if (text.len <= SEQUENTIAL_THRESHOLD) {
        return countWordsSequential(text, allocator);
    }

    // Find a split point at word boundary (avoid splitting words)
    const mid = text.len / 2;
    var split_point = mid;
    while (split_point < text.len and isWordChar(text[split_point])) : (split_point += 1) {}

    const left_text = text[0..split_point];
    const right_text = text[split_point..];

    // Fork-join: count words in each half in parallel
    var left_map, var right_map = joinOnPool(
        pool,
        struct {
            fn countLeft(p: *ThreadPool, txt: []const u8, alloc: std.mem.Allocator) WordCountMap {
                return countWordsParallel(p, txt, alloc) catch WordCountMap.init(alloc);
            }
        }.countLeft,
        .{ pool, left_text, allocator },
        struct {
            fn countRight(p: *ThreadPool, txt: []const u8, alloc: std.mem.Allocator) WordCountMap {
                return countWordsParallel(p, txt, alloc) catch WordCountMap.init(alloc);
            }
        }.countRight,
        .{ pool, right_text, allocator },
    );

    // Reduce: merge right_map into left_map
    var it = right_map.iterator();
    while (it.next()) |entry| {
        const existing = left_map.get(entry.key_ptr.*) orelse 0;
        left_map.put(entry.key_ptr.*, existing + entry.value_ptr.*) catch {};
    }
    right_map.deinit();

    return left_map;
}

/// Sequential word counting
fn countWordsSequential(text: []const u8, allocator: std.mem.Allocator) !WordCountMap {
    var map = WordCountMap.init(allocator);
    countWords(text, &map);
    return map;
}

/// Count words in text and add to map
/// Note: Uses the original text slice directly (case-sensitive) for simplicity
fn countWords(text: []const u8, map: *WordCountMap) void {
    var i: usize = 0;
    while (i < text.len) {
        // Skip non-word characters
        while (i < text.len and !isWordChar(text[i])) : (i += 1) {}
        if (i >= text.len) break;

        // Find word end
        const word_start = i;
        while (i < text.len and isWordChar(text[i])) : (i += 1) {}

        const word = text[word_start..i];
        if (word.len > 0) {
            // Use original word slice directly (case-sensitive counting)
            // Note: This avoids allocation issues with temporary buffers
            const existing = map.get(word) orelse 0;
            map.put(word, existing + 1) catch {};
        }
    }
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn toLower(s: []const u8, buf: []u8) []const u8 {
    const len = @min(s.len, buf.len);
    for (s[0..len], buf[0..len]) |c, *b| {
        b.* = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..len];
}

fn printWordCounts(map: WordCountMap) void {
    var it = map.iterator();
    var count: usize = 0;
    while (it.next()) |entry| : (count += 1) {
        if (count >= 20) {
            std.debug.print("  ... and more\n", .{});
            break;
        }
        std.debug.print("  {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn printTopWords(map: WordCountMap, n: usize) void {
    // Simple approach: collect all and sort
    const Entry = struct { word: []const u8, count: u64 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(std.heap.page_allocator);

    var it = map.iterator();
    while (it.next()) |entry| {
        entries.append(std.heap.page_allocator, .{ .word = entry.key_ptr.*, .count = entry.value_ptr.* }) catch {};
    }

    // Sort by count descending
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.lessThan);

    for (entries.items[0..@min(n, entries.items.len)]) |entry| {
        std.debug.print("  {s}: {d}\n", .{ entry.word, entry.count });
    }
}

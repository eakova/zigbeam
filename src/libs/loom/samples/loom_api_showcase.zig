// Loom API Showcase - Ultimate Sample Demonstrating All Parallel Iterator Functions
//
// This sample demonstrates the complete loom parallel iterator API through
// a log analysis scenario. It showcases:
//
// Range Operations:
//   - par_range().forEach()           - Parallel initialization
//   - par_range().withContext().forEach() - Parallel file reading
//   - par_range().count()             - Range counting
//
// Slice Operations:
//   - par_iter().forEach()            - Parallel mutation
//   - par_iter().forEachIndexed()     - Indexed parallel access
//   - par_iter().count()              - Parallel counting
//   - par_iter().any()                - Short-circuit any search
//   - par_iter().all()                - Short-circuit all validation
//   - par_iter().find()               - Find first match
//   - par_iter().reduce()             - Parallel reduction
//   - par_iter().map()                - Parallel transformation
//   - par_iter().filter()             - Parallel filtering
//
// Context Operations:
//   - par_iter().withContext().forEach()        - Stateful processing
//   - par_iter().withContext().forEachIndexed() - Indexed stateful processing
//   - par_iter().withContext().count()          - Context-aware counting
//   - par_iter().withContext().any()            - Context-aware search
//   - par_iter().withContext().all()            - Context-aware validation
//   - par_iter().withContext().find()           - Context-aware find
//
// Usage: zig build samples-loom -Doptimize=ReleaseFast

const std = @import("std");
const loom = @import("loom");
const par_iter = loom.par_iter;
const par_range = loom.par_range;
const ThreadPool = loom.ThreadPool;
const Reducer = loom.Reducer;

// Log entry structure
const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    critical = 4,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .critical => "CRITICAL",
        };
    }
};

const LogEntry = struct {
    timestamp: u64, // Unix timestamp in ms
    level: LogLevel,
    thread_id: u16,
    message_hash: u32, // Hash of message for dedup
    response_time_us: u32, // Response time in microseconds
    is_security_event: bool,
    user_id: u32,

    pub fn isError(self: LogEntry) bool {
        return @intFromEnum(self.level) >= @intFromEnum(LogLevel.err);
    }

    pub fn isCritical(self: LogEntry) bool {
        return self.level == .critical;
    }

    pub fn isSlowRequest(self: LogEntry) bool {
        return self.response_time_us > 1_000_000; // > 1 second
    }
};

// Context for threshold-based operations
const ThresholdContext = struct {
    response_time_threshold_us: u32,
    min_log_level: LogLevel,
    target_user_id: u32,
};

// Number of log entries to generate
const NUM_ENTRIES: usize = 10_000_000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("================================================================\n", .{});
    std.debug.print("  Loom API Showcase - Parallel Iterator Functions Demo\n", .{});
    std.debug.print("================================================================\n\n", .{});

    // Initialize thread pool
    const pool = try ThreadPool.init(allocator, .{});
    defer pool.deinit();
    std.debug.print("Thread pool: {d} workers\n", .{pool.numWorkers()});
    std.debug.print("Log entries: {d} million\n\n", .{NUM_ENTRIES / 1_000_000});

    // ========================================================================
    // 1. GENERATE LOG DATA using par_range().forEach()
    // ========================================================================
    std.debug.print("--- 1. Data Generation (par_range + forEach) ---\n\n", .{});

    var timer = try std.time.Timer.start();

    // Allocate log entries
    const logs = try allocator.alloc(LogEntry, NUM_ENTRIES);
    defer allocator.free(logs);

    // Generate logs in parallel using par_range
    const GenContext = struct {
        logs: []LogEntry,
    };
    const gen_ctx = GenContext{ .logs = logs };

    par_range(@as(usize, 0), NUM_ENTRIES)
        .withPool(pool)
        .withContext(&gen_ctx)
        .forEach(struct {
        fn generate(ctx: *const GenContext, idx: usize) void {
            // Deterministic "random" generation based on index
            const seed = idx *% 2654435761;
            const level_val = (seed >> 24) % 100;
            const level: LogLevel = if (level_val < 50)
                .info
            else if (level_val < 75)
                .debug
            else if (level_val < 90)
                .warn
            else if (level_val < 98)
                .err
            else
                .critical;

            ctx.logs[idx] = .{
                .timestamp = 1700000000000 + idx,
                .level = level,
                .thread_id = @truncate(seed % 64),
                .message_hash = @truncate(seed),
                .response_time_us = @truncate((seed % 2_000_000) + 1000),
                .is_security_event = (seed % 1000) < 5, // 0.5% security events
                .user_id = @truncate(seed % 100_000),
            };
        }
    }.generate);

    var elapsed = timer.read();
    std.debug.print("Generated {d}M entries: {d:.2}ms\n", .{
        NUM_ENTRIES / 1_000_000,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Throughput: {d:.2}M entries/sec\n\n", .{
        @as(f64, @floatFromInt(NUM_ENTRIES)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0) / 1_000_000.0,
    });

    // ========================================================================
    // 2. COUNTING with par_iter().count()
    // ========================================================================
    std.debug.print("--- 2. Parallel Counting (par_iter + count) ---\n\n", .{});

    timer.reset();
    const error_count = par_iter(logs).withPool(pool).count(struct {
        fn isError(entry: LogEntry) bool {
            return entry.isError();
        }
    }.isError);
    elapsed = timer.read();
    std.debug.print("Error count:    {d:>10} ({d:.2}ms)\n", .{
        error_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const critical_count = par_iter(logs).withPool(pool).count(struct {
        fn isCritical(entry: LogEntry) bool {
            return entry.isCritical();
        }
    }.isCritical);
    elapsed = timer.read();
    std.debug.print("Critical count: {d:>10} ({d:.2}ms)\n", .{
        critical_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const security_count = par_iter(logs).withPool(pool).count(struct {
        fn isSecurity(entry: LogEntry) bool {
            return entry.is_security_event;
        }
    }.isSecurity);
    elapsed = timer.read();
    std.debug.print("Security events:{d:>10} ({d:.2}ms)\n", .{
        security_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const slow_count = par_iter(logs).withPool(pool).count(struct {
        fn isSlow(entry: LogEntry) bool {
            return entry.isSlowRequest();
        }
    }.isSlow);
    elapsed = timer.read();
    std.debug.print("Slow requests:  {d:>10} ({d:.2}ms)\n\n", .{
        slow_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // ========================================================================
    // 3. CONTEXT-AWARE COUNTING with withContext().count()
    // ========================================================================
    std.debug.print("--- 3. Context-Aware Counting (withContext + count) ---\n\n", .{});

    const threshold_ctx = ThresholdContext{
        .response_time_threshold_us = 500_000, // 500ms
        .min_log_level = .warn,
        .target_user_id = 12345,
    };

    timer.reset();
    const above_threshold = par_iter(logs)
        .withPool(pool)
        .withContext(&threshold_ctx)
        .count(struct {
        fn aboveThreshold(ctx: *const ThresholdContext, entry: LogEntry) bool {
            return entry.response_time_us > ctx.response_time_threshold_us;
        }
    }.aboveThreshold);
    elapsed = timer.read();
    std.debug.print("Above 500ms threshold: {d:>10} ({d:.2}ms)\n", .{
        above_threshold,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const severe_logs = par_iter(logs)
        .withPool(pool)
        .withContext(&threshold_ctx)
        .count(struct {
        fn isSevere(ctx: *const ThresholdContext, entry: LogEntry) bool {
            return @intFromEnum(entry.level) >= @intFromEnum(ctx.min_log_level);
        }
    }.isSevere);
    elapsed = timer.read();
    std.debug.print("Severe (>=WARN):       {d:>10} ({d:.2}ms)\n\n", .{
        severe_logs,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // ========================================================================
    // 4. SHORT-CIRCUIT SEARCH with any() and all()
    // ========================================================================
    std.debug.print("--- 4. Short-Circuit Search (any / all) ---\n\n", .{});

    timer.reset();
    const has_critical = par_iter(logs).withPool(pool).any(struct {
        fn isCritical(entry: LogEntry) bool {
            return entry.isCritical();
        }
    }.isCritical);
    elapsed = timer.read();
    std.debug.print("Has critical errors: {s:>10} ({d:.2}ms)\n", .{
        if (has_critical) "YES" else "NO",
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const has_security = par_iter(logs).withPool(pool).any(struct {
        fn isSecurity(entry: LogEntry) bool {
            return entry.is_security_event;
        }
    }.isSecurity);
    elapsed = timer.read();
    std.debug.print("Has security events: {s:>10} ({d:.2}ms)\n", .{
        if (has_security) "YES" else "NO",
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const all_have_timestamp = par_iter(logs).withPool(pool).all(struct {
        fn hasTimestamp(entry: LogEntry) bool {
            return entry.timestamp > 0;
        }
    }.hasTimestamp);
    elapsed = timer.read();
    std.debug.print("All have timestamps: {s:>10} ({d:.2}ms)\n", .{
        if (all_have_timestamp) "YES" else "NO",
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const all_valid_thread = par_iter(logs).withPool(pool).all(struct {
        fn validThread(entry: LogEntry) bool {
            return entry.thread_id < 64;
        }
    }.validThread);
    elapsed = timer.read();
    std.debug.print("All valid thread_id: {s:>10} ({d:.2}ms)\n\n", .{
        if (all_valid_thread) "YES" else "NO",
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // ========================================================================
    // 5. FIND OPERATIONS with find()
    // ========================================================================
    std.debug.print("--- 5. Find Operations (find) ---\n\n", .{});

    timer.reset();
    const first_critical = par_iter(logs).withPool(pool).find(struct {
        fn isCritical(entry: LogEntry) bool {
            return entry.isCritical();
        }
    }.isCritical);
    elapsed = timer.read();
    if (first_critical) |entry| {
        std.debug.print("First critical: thread={d}, user={d} ({d:.2}ms)\n", .{
            entry.thread_id,
            entry.user_id,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    } else {
        std.debug.print("First critical: NOT FOUND ({d:.2}ms)\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }

    timer.reset();
    const first_security = par_iter(logs).withPool(pool).find(struct {
        fn isSecurity(entry: LogEntry) bool {
            return entry.is_security_event;
        }
    }.isSecurity);
    elapsed = timer.read();
    if (first_security) |entry| {
        std.debug.print("First security: thread={d}, user={d} ({d:.2}ms)\n", .{
            entry.thread_id,
            entry.user_id,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    } else {
        std.debug.print("First security: NOT FOUND ({d:.2}ms)\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }

    // Context-aware find
    timer.reset();
    const target_user_entry = par_iter(logs)
        .withPool(pool)
        .withContext(&threshold_ctx)
        .find(struct {
        fn isTargetUser(ctx: *const ThresholdContext, entry: LogEntry) bool {
            return entry.user_id == ctx.target_user_id;
        }
    }.isTargetUser);
    elapsed = timer.read();
    if (target_user_entry) |entry| {
        std.debug.print("Target user 12345: level={s}, response={d}us ({d:.2}ms)\n\n", .{
            entry.level.toString(),
            entry.response_time_us,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    } else {
        std.debug.print("Target user 12345: NOT FOUND ({d:.2}ms)\n\n", .{
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }

    // ========================================================================
    // 6. REDUCE for Aggregation (using map first, then reduce on u32)
    // ========================================================================
    std.debug.print("--- 6. Parallel Reduction (reduce) ---\n\n", .{});

    // First extract response times with map, then reduce to find max
    timer.reset();
    const response_times_for_reduce = try par_iter(logs).withPool(pool).map(u32, struct {
        fn extractResponseTime(entry: LogEntry) u32 {
            return entry.response_time_us;
        }
    }.extractResponseTime, allocator);
    defer allocator.free(response_times_for_reduce);

    const max_response = par_iter(response_times_for_reduce).withPool(pool).reduce(Reducer(u32).max());
    const min_response = par_iter(response_times_for_reduce).withPool(pool).reduce(Reducer(u32).min());
    const sum_response = par_iter(response_times_for_reduce).withPool(pool).reduce(Reducer(u32).sum());
    elapsed = timer.read();

    std.debug.print("Response Time Statistics ({d:.2}ms):\n", .{
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("  Max response:     {d:>12} us\n", .{max_response});
    std.debug.print("  Min response:     {d:>12} us\n", .{min_response});
    std.debug.print("  Sum response:     {d:>12} us\n", .{sum_response});
    std.debug.print("  Avg response:     {d:>12} us\n\n", .{
        sum_response / @as(u32, @intCast(response_times_for_reduce.len)),
    });

    // ========================================================================
    // 7. MAP Transformation
    // ========================================================================
    std.debug.print("--- 7. Parallel Map (map) ---\n\n", .{});

    timer.reset();
    const response_times = try par_iter(logs).withPool(pool).map(u32, struct {
        fn extractResponseTime(entry: LogEntry) u32 {
            return entry.response_time_us;
        }
    }.extractResponseTime, allocator);
    defer allocator.free(response_times);
    elapsed = timer.read();

    std.debug.print("Extracted {d}M response times: {d:.2}ms\n", .{
        response_times.len / 1_000_000,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Sample values: [{d}, {d}, {d}, ...]\n\n", .{
        response_times[0],
        response_times[1],
        response_times[2],
    });

    // ========================================================================
    // 8. FILTER Operation
    // ========================================================================
    std.debug.print("--- 8. Parallel Filter (filter) ---\n\n", .{});

    timer.reset();
    const critical_entries = try par_iter(logs).withPool(pool).filter(struct {
        fn isCritical(entry: LogEntry) bool {
            return entry.isCritical();
        }
    }.isCritical, allocator);
    defer allocator.free(critical_entries);
    elapsed = timer.read();

    std.debug.print("Filtered {d} critical entries: {d:.2}ms\n", .{
        critical_entries.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    if (critical_entries.len > 0) {
        std.debug.print("First critical: thread={d}, user={d}, response={d}us\n\n", .{
            critical_entries[0].thread_id,
            critical_entries[0].user_id,
            critical_entries[0].response_time_us,
        });
    } else {
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // 9. FOR_EACH with Mutation
    // ========================================================================
    std.debug.print("--- 9. Parallel forEach (mutation) ---\n\n", .{});

    // Create a copy for mutation demo
    const logs_copy = try allocator.alloc(LogEntry, 1_000_000);
    defer allocator.free(logs_copy);
    @memcpy(logs_copy, logs[0..1_000_000]);

    timer.reset();
    par_iter(logs_copy).withPool(pool).forEach(struct {
        fn markProcessed(entry: *LogEntry) void {
            // Mark all entries as processed by setting a flag in message_hash
            entry.message_hash |= 0x80000000;
        }
    }.markProcessed);
    elapsed = timer.read();

    const processed_count = par_iter(logs_copy).withPool(pool).count(struct {
        fn isProcessed(entry: LogEntry) bool {
            return (entry.message_hash & 0x80000000) != 0;
        }
    }.isProcessed);

    std.debug.print("Marked {d} entries as processed: {d:.2}ms\n", .{
        processed_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Verification: {d}/{d} processed\n\n", .{
        processed_count,
        logs_copy.len,
    });

    // ========================================================================
    // 10. FOR_EACH_INDEXED
    // ========================================================================
    std.debug.print("--- 10. Parallel forEachIndexed ---\n\n", .{});

    // Create sequence numbers array
    const seq_numbers = try allocator.alloc(u64, 1_000_000);
    defer allocator.free(seq_numbers);

    const IndexContext = struct {
        seq_numbers: []u64,
        base_timestamp: u64,
    };
    const idx_ctx = IndexContext{
        .seq_numbers = seq_numbers,
        .base_timestamp = 1700000000000,
    };

    timer.reset();
    par_iter(logs_copy)
        .withPool(pool)
        .withContext(&idx_ctx)
        .forEachIndexed(struct {
        fn assignSeq(ctx: *const IndexContext, idx: usize, entry: *LogEntry) void {
            // Assign sequence number based on index
            ctx.seq_numbers[idx] = ctx.base_timestamp + idx;
            // Also update entry timestamp
            entry.timestamp = ctx.base_timestamp + idx;
        }
    }.assignSeq);
    elapsed = timer.read();

    std.debug.print("Assigned {d} sequence numbers: {d:.2}ms\n", .{
        seq_numbers.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Sample: [{d}, {d}, {d}, ...]\n\n", .{
        seq_numbers[0],
        seq_numbers[1],
        seq_numbers[2],
    });

    // ========================================================================
    // 11. par_range().count() - Range Counting
    // ========================================================================
    std.debug.print("--- 11. Range Counting (par_range + count) ---\n\n", .{});

    timer.reset();
    const even_count = par_range(@as(usize, 0), @as(usize, 10_000_000))
        .withPool(pool)
        .count(struct {
        fn isEven(n: usize) bool {
            return n % 2 == 0;
        }
    }.isEven);
    elapsed = timer.read();

    std.debug.print("Even numbers in 0..10M: {d} ({d:.2}ms)\n", .{
        even_count,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    timer.reset();
    const divisible_by_7 = par_range(@as(usize, 0), @as(usize, 10_000_000))
        .withPool(pool)
        .count(struct {
        fn divBy7(n: usize) bool {
            return n % 7 == 0;
        }
    }.divBy7);
    elapsed = timer.read();

    std.debug.print("Divisible by 7:         {d} ({d:.2}ms)\n\n", .{
        divisible_by_7,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });

    // ========================================================================
    // 12. Context-aware MAP (withContext + map)
    // ========================================================================
    std.debug.print("--- 12. Context-aware Map (withContext + map) ---\n\n", .{});

    const MapContext = struct {
        severity_boost: u32,
    };
    const map_ctx = MapContext{ .severity_boost = 100 };

    timer.reset();
    const boosted_times = try par_iter(logs)
        .withPool(pool)
        .withContext(&map_ctx)
        .map(u32, struct {
        fn boostBySeverity(ctx: *const MapContext, entry: LogEntry) u32 {
            // Boost response time based on severity level
            const severity_factor = @intFromEnum(entry.level) + 1;
            return entry.response_time_us + (ctx.severity_boost * severity_factor);
        }
    }.boostBySeverity, allocator);
    defer allocator.free(boosted_times);
    elapsed = timer.read();

    std.debug.print("Mapped {d} entries with context: {d:.2}ms\n", .{
        boosted_times.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Sample boosted times: [{d}, {d}, {d}, ...]\n\n", .{
        boosted_times[0],
        boosted_times[1],
        boosted_times[2],
    });

    // ========================================================================
    // 13. Context-aware FILTER (withContext + filter)
    // ========================================================================
    std.debug.print("--- 13. Context-aware Filter (withContext + filter) ---\n\n", .{});

    const FilterContext = struct {
        min_level: LogLevel,
        max_response_us: u32,
    };
    const filter_ctx = FilterContext{
        .min_level = .warn,
        .max_response_us = 500_000, // < 500ms
    };

    timer.reset();
    const fast_severe = try par_iter(logs)
        .withPool(pool)
        .withContext(&filter_ctx)
        .filter(struct {
        fn isFastButSevere(ctx: *const FilterContext, entry: LogEntry) bool {
            // Find severe entries that are surprisingly fast
            return @intFromEnum(entry.level) >= @intFromEnum(ctx.min_level) and
                entry.response_time_us < ctx.max_response_us;
        }
    }.isFastButSevere, allocator);
    defer allocator.free(fast_severe);
    elapsed = timer.read();

    std.debug.print("Filtered {d} fast-but-severe entries: {d:.2}ms\n", .{
        fast_severe.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    if (fast_severe.len > 0) {
        std.debug.print("First match: level={s}, response={d}us\n\n", .{
            fast_severe[0].level.toString(),
            fast_severe[0].response_time_us,
        });
    } else {
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // 14. Context-aware mapIndexed (withContext + mapIndexed)
    // ========================================================================
    std.debug.print("--- 14. Context-aware MapIndexed (withContext + mapIndexed) ---\n\n", .{});

    const MapIdxContext = struct {
        base_offset: u32,
    };
    const map_idx_ctx = MapIdxContext{ .base_offset = 1000 };

    timer.reset();
    const indexed_times = try par_iter(logs)
        .withPool(pool)
        .withContext(&map_idx_ctx)
        .mapIndexed(u64, struct {
        fn transformWithIndex(ctx: *const MapIdxContext, idx: usize, entry: LogEntry) u64 {
            // Create unique ID: base_offset + index + response_time
            return @as(u64, ctx.base_offset) + @as(u64, idx) + @as(u64, entry.response_time_us);
        }
    }.transformWithIndex, allocator);
    defer allocator.free(indexed_times);
    elapsed = timer.read();

    std.debug.print("MapIndexed {d} entries with context: {d:.2}ms\n", .{
        indexed_times.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Sample indexed IDs: [{d}, {d}, {d}, ...]\n\n", .{
        indexed_times[0],
        indexed_times[1],
        indexed_times[2],
    });

    // ========================================================================
    // 15. Context-aware chunks (withContext + chunks)
    // ========================================================================
    std.debug.print("--- 15. Context-aware Chunks (withContext + chunks) ---\n\n", .{});

    var chunk_stats = std.atomic.Value(u64).init(0);
    const ChunkContext = struct {
        multiplier: u32,
        stats: *std.atomic.Value(u64),
    };
    const chunk_ctx = ChunkContext{
        .multiplier = 2,
        .stats = &chunk_stats,
    };

    // Make a mutable copy for chunks demo
    const mutable_times = try allocator.alloc(u32, @min(logs.len, 100_000));
    defer allocator.free(mutable_times);
    for (mutable_times, 0..) |*t, i| {
        t.* = logs[i].response_time_us;
    }

    timer.reset();
    par_iter(mutable_times)
        .withPool(pool)
        .withContext(&chunk_ctx)
        .chunks(struct {
        fn processChunk(ctx: *const ChunkContext, chunk_idx: usize, chunk: []u32) void {
            var local_sum: u64 = 0;
            for (chunk) |*val| {
                val.* *= ctx.multiplier;
                local_sum += val.*;
            }
            _ = ctx.stats.fetchAdd(local_sum + chunk_idx, .monotonic);
        }
    }.processChunk);
    elapsed = timer.read();

    std.debug.print("Processed {d} entries in chunks: {d:.2}ms\n", .{
        mutable_times.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Chunk stats sum: {d}\n\n", .{chunk_stats.load(.acquire)});

    // ========================================================================
    // 16. Context-aware chunksConst (withContext + chunksConst)
    // ========================================================================
    std.debug.print("--- 16. Context-aware ChunksConst (withContext + chunksConst) ---\n\n", .{});

    var const_chunk_sum = std.atomic.Value(u64).init(0);
    const ConstChunkContext = struct {
        weight: u32,
        sum: *std.atomic.Value(u64),
    };
    const const_chunk_ctx = ConstChunkContext{
        .weight = 3,
        .sum = &const_chunk_sum,
    };

    timer.reset();
    par_iter(logs)
        .withPool(pool)
        .withContext(&const_chunk_ctx)
        .chunksConst(struct {
        fn analyzeChunk(ctx: *const ConstChunkContext, chunk_idx: usize, chunk: []const LogEntry) void {
            var weighted_sum: u64 = 0;
            for (chunk) |entry| {
                weighted_sum += @as(u64, entry.response_time_us) * ctx.weight;
            }
            _ = ctx.sum.fetchAdd(weighted_sum + chunk_idx, .monotonic);
        }
    }.analyzeChunk);
    elapsed = timer.read();

    std.debug.print("Analyzed {d} entries in const chunks: {d:.2}ms\n", .{
        logs.len,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
    });
    std.debug.print("Weighted sum: {d}\n\n", .{const_chunk_sum.load(.acquire)});

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("================================================================\n", .{});
    std.debug.print("   Loom API Showcase Complete!\n", .{});
    std.debug.print("================================================================\n\n", .{});
    std.debug.print("Demonstrated APIs:\n", .{});
    std.debug.print("  - par_range().withContext().forEach()  [Data generation]\n", .{});
    std.debug.print("  - par_iter().count()                   [Parallel counting]\n", .{});
    std.debug.print("  - par_iter().withContext().count()     [Context counting]\n", .{});
    std.debug.print("  - par_iter().any()                     [Short-circuit any]\n", .{});
    std.debug.print("  - par_iter().all()                     [Short-circuit all]\n", .{});
    std.debug.print("  - par_iter().find()                    [Find first match]\n", .{});
    std.debug.print("  - par_iter().withContext().find()      [Context find]\n", .{});
    std.debug.print("  - par_iter().reduce()                  [Parallel reduction]\n", .{});
    std.debug.print("  - par_iter().map()                     [Parallel transform]\n", .{});
    std.debug.print("  - par_iter().withContext().map()       [Context transform]\n", .{});
    std.debug.print("  - par_iter().withContext().mapIndexed() [Indexed transform]\n", .{});
    std.debug.print("  - par_iter().filter()                  [Parallel filter]\n", .{});
    std.debug.print("  - par_iter().withContext().filter()    [Context filter]\n", .{});
    std.debug.print("  - par_iter().forEach()                 [Parallel mutation]\n", .{});
    std.debug.print("  - par_iter().withContext().forEachIndexed() [Indexed]\n", .{});
    std.debug.print("  - par_iter().withContext().chunks()    [Chunk processing]\n", .{});
    std.debug.print("  - par_iter().withContext().chunksConst() [Const chunks]\n", .{});
    std.debug.print("  - par_range().count()                  [Range counting]\n", .{});
    std.debug.print("\nTotal entries processed: {d}M\n", .{NUM_ENTRIES / 1_000_000});
    std.debug.print("Workers used: {d}\n\n", .{pool.numWorkers()});
}

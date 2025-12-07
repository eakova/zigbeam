// splitter.zig - Work Splitting Strategies
//
// Provides strategies for dividing work across parallel tasks.
// Different splitting modes optimize for different workloads.
//
// Usage:
// ```zig
// const splitter = Splitter.adaptive(1000);  // Min chunk size 1000
// items.par_iter().with_splitter(splitter).for_each(process);
// ```

const std = @import("std");

/// Splitting mode for parallel iteration
pub const SplitMode = enum {
    /// Fixed-size chunks (good for uniform work)
    fixed,

    /// Adaptive splitting based on available parallelism
    adaptive,

    /// Recursive binary splitting (good for divide-and-conquer)
    recursive,
};

/// Work splitting configuration
pub const Splitter = struct {
    /// Minimum elements per chunk (sequential threshold)
    min_chunk_size: usize,

    /// Splitting strategy
    mode: SplitMode,

    /// Target number of chunks (0 = auto based on thread count)
    target_chunks: usize,

    /// Create a splitter with fixed chunk size
    pub fn fixed(chunk_size: usize) Splitter {
        return Splitter{
            .min_chunk_size = chunk_size,
            .mode = .fixed,
            .target_chunks = 0,
        };
    }

    /// Create an adaptive splitter
    ///
    /// Automatically determines chunk sizes based on:
    /// - Available parallelism (thread count)
    /// - Total work size
    /// - Minimum sequential threshold
    pub fn adaptive(min_chunk: usize) Splitter {
        return Splitter{
            .min_chunk_size = min_chunk,
            .mode = .adaptive,
            .target_chunks = 0,
        };
    }

    /// Create a recursive splitter for divide-and-conquer
    pub fn recursive(threshold: usize) Splitter {
        return Splitter{
            .min_chunk_size = threshold,
            .mode = .recursive,
            .target_chunks = 0,
        };
    }

    /// Default splitter (adaptive with reasonable defaults)
    /// Issue 49/56 fix: Increased from 1024 to 2048 to avoid over-parallelizing
    /// small arrays (1K-4K elements showed 0.90x = slower than sequential)
    /// 2048 threshold balances parallelism vs overhead for typical workloads
    pub fn default() Splitter {
        return adaptive(2048);
    }

    /// Builder: Set target number of chunks (caps parallelism)
    ///
    /// Use this to limit parallelism for memory-bound workloads.
    /// Example: `.withTargetChunks(8)` limits to 8 chunks max.
    pub fn withTargetChunks(self: Splitter, target: usize) Splitter {
        var s = self;
        s.target_chunks = target;
        return s;
    }

    /// Builder: Set minimum chunk size
    ///
    /// Use lower values for CPU-heavy work (100-1000).
    /// Use higher values for memory-bound work (8192+).
    pub fn withMinChunk(self: Splitter, min_chunk: usize) Splitter {
        var s = self;
        s.min_chunk_size = min_chunk;
        return s;
    }

    /// Calculate chunk size for given total length and parallelism
    pub fn chunkSize(self: Splitter, total_len: usize, num_threads: usize) usize {
        if (total_len == 0) return 0;

        return switch (self.mode) {
            .fixed => self.min_chunk_size,

            .adaptive => blk: {
                // Target: 2x oversubscription for load balancing
                // Lower oversubscription reduces scheduling overhead
                const target = if (self.target_chunks > 0)
                    self.target_chunks
                else if (num_threads > 0)
                    num_threads * 2
                else
                    1; // Issue 36 fix: Prevent division by zero when num_threads == 0

                const ideal_chunk = @max(1, total_len / target);
                break :blk @max(self.min_chunk_size, ideal_chunk);
            },

            .recursive => self.min_chunk_size,
        };
    }

    /// Calculate number of chunks for given total length
    pub fn numChunks(self: Splitter, total_len: usize, num_threads: usize) usize {
        if (total_len == 0) return 0;

        const chunk_size = self.chunkSize(total_len, num_threads);
        // Issue 36 fix: Prevent division by zero if chunk_size is somehow 0
        if (chunk_size == 0) return 1;
        // Issue 28 fix: Use divCeil to avoid overflow when total_len is near maxInt
        return std.math.divCeil(usize, total_len, chunk_size) catch total_len;
    }

    /// Check if work should be split (or done sequentially)
    ///
    /// Thread-aware: only splits if each thread gets at least min_chunk_size items.
    /// This prevents over-parallelizing small workloads on many-core systems.
    pub fn shouldSplit(self: Splitter, len: usize, num_threads: usize) bool {
        // Only parallelize if total work justifies the overhead
        // Each thread should get at least min_chunk_size items
        // Issue 28 fix: Use saturating multiplication to prevent overflow
        const threshold = std.math.mulWide(usize, num_threads, self.min_chunk_size);
        return @as(u128, len) >= threshold;
    }
};

// ============================================================================
// Chunk Iterator
// ============================================================================

/// Iterator over chunks of a slice
pub fn ChunkIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        chunk_size: usize,
        index: usize,

        /// Create a chunk iterator
        pub fn init(data: []T, chunk_size: usize) Self {
            return Self{
                .data = data,
                .chunk_size = @max(1, chunk_size),
                .index = 0,
            };
        }

        /// Get next chunk, or null if exhausted
        pub fn next(self: *Self) ?[]T {
            if (self.index >= self.data.len) {
                return null;
            }

            const start = self.index;
            const end = @min(start + self.chunk_size, self.data.len);
            self.index = end;

            return self.data[start..end];
        }

        /// Reset iterator to beginning
        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        /// Count remaining chunks
        pub fn remaining(self: *const Self) usize {
            const remaining_items = self.data.len - self.index;
            // Issue 28 fix: Use divCeil to avoid overflow when remaining_items is near maxInt
            return std.math.divCeil(usize, remaining_items, self.chunk_size) catch remaining_items;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Splitter.fixed" {
    const s = Splitter.fixed(100);
    try std.testing.expectEqual(SplitMode.fixed, s.mode);
    try std.testing.expectEqual(@as(usize, 100), s.min_chunk_size);
    try std.testing.expectEqual(@as(usize, 100), s.chunkSize(1000, 8));
}

test "Splitter.adaptive" {
    const s = Splitter.adaptive(100);
    try std.testing.expectEqual(SplitMode.adaptive, s.mode);

    // With 1000 items and 8 threads, target is 16 chunks (2x oversubscription)
    // 1000 / 16 = 62.5, but min is 100, so chunk size = 100
    try std.testing.expectEqual(@as(usize, 100), s.chunkSize(1000, 8));

    // With 10000 items and 8 threads, target is 16 chunks
    // 10000 / 16 = 625, which is > 100
    try std.testing.expect(s.chunkSize(10000, 8) >= 100);
}

test "Splitter.shouldSplit" {
    const s = Splitter.adaptive(100);

    // With 4 threads, need at least 400 items to split (4 * 100)
    try std.testing.expect(!s.shouldSplit(50, 4));
    try std.testing.expect(!s.shouldSplit(399, 4));
    try std.testing.expect(s.shouldSplit(400, 4));
    try std.testing.expect(s.shouldSplit(1000, 4));

    // With 1 thread, need at least 100 items
    try std.testing.expect(!s.shouldSplit(50, 1));
    try std.testing.expect(s.shouldSplit(100, 1));
}

test "Splitter.withTargetChunks" {
    const s = Splitter.adaptive(100).withTargetChunks(4);
    try std.testing.expectEqual(@as(usize, 4), s.target_chunks);

    // With 10000 items and target 4 chunks: 10000 / 4 = 2500
    try std.testing.expectEqual(@as(usize, 2500), s.chunkSize(10000, 8));
}

test "Splitter.withMinChunk" {
    const s = Splitter.default().withMinChunk(100);
    try std.testing.expectEqual(@as(usize, 100), s.min_chunk_size);

    // CPU-heavy work: lower threshold means more parallelism for smaller arrays
    try std.testing.expect(s.shouldSplit(400, 4)); // 4 * 100 = 400, OK
    try std.testing.expect(!s.shouldSplit(399, 4)); // Below threshold
}

test "ChunkIterator" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var iter = ChunkIterator(i32).init(&data, 3);

    const chunk1 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 3), chunk1.len);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, chunk1);

    const chunk2 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 3), chunk2.len);

    const chunk3 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 3), chunk3.len);

    const chunk4 = iter.next().?;
    try std.testing.expectEqual(@as(usize, 1), chunk4.len);

    try std.testing.expectEqual(@as(?[]i32, null), iter.next());
}

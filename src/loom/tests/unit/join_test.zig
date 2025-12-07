// Join Unit Tests
//
// Tests for the binary fork-join functionality (Layer 3).
// These tests verify:
// - Basic join with same return types
// - Join with different return types
// - Join with void return types
// - JoinHandle functionality
// - Error handling when pool is full

const std = @import("std");
const testing = std.testing;

const zigparallel = @import("loom");
const join = zigparallel.join;
const joinOnPool = zigparallel.joinOnPool;
const JoinHandle = zigparallel.JoinHandle;
const ThreadPool = zigparallel.ThreadPool;

// ============================================================================
// Basic Join Tests
// ============================================================================

test "join: basic with same return types" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    const left, const right = joinOnPool(
        pool,
        struct {
            fn compute() i32 {
                return 10;
            }
        }.compute,
        .{},
        struct {
            fn compute() i32 {
                return 20;
            }
        }.compute,
        .{},
    );

    try testing.expectEqual(@as(i32, 10), left);
    try testing.expectEqual(@as(i32, 20), right);
}

test "join: with different return types" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    const left, const right = joinOnPool(
        pool,
        struct {
            fn compute() i32 {
                return 42;
            }
        }.compute,
        .{},
        struct {
            fn compute() f64 {
                return 3.14;
            }
        }.compute,
        .{},
    );

    try testing.expectEqual(@as(i32, 42), left);
    try testing.expectApproxEqAbs(@as(f64, 3.14), right, 0.001);
}

test "join: with void return types" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var left_executed = std.atomic.Value(bool).init(false);
    var right_executed = std.atomic.Value(bool).init(false);

    const LeftContext = struct {
        executed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.executed.store(true, .release);
        }
    };

    const RightContext = struct {
        executed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.executed.store(true, .release);
        }
    };

    var left_ctx = LeftContext{ .executed = &left_executed };
    var right_ctx = RightContext{ .executed = &right_executed };

    _ = joinOnPool(
        pool,
        LeftContext.run,
        .{&left_ctx},
        RightContext.run,
        .{&right_ctx},
    );

    try testing.expect(left_executed.load(.acquire));
    try testing.expect(right_executed.load(.acquire));
}

test "join: with arguments" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    const add = struct {
        fn compute(a: i32, b: i32) i32 {
            return a + b;
        }
    }.compute;

    const multiply = struct {
        fn compute(a: i32, b: i32) i32 {
            return a * b;
        }
    }.compute;

    const sum, const product = joinOnPool(pool, add, .{ 3, 4 }, multiply, .{ 5, 6 });

    try testing.expectEqual(@as(i32, 7), sum);
    try testing.expectEqual(@as(i32, 30), product);
}

// ============================================================================
// JoinHandle Tests
// ============================================================================

test "JoinHandle: basic completion" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var handle = JoinHandle(i32).init(pool);

    try testing.expect(!handle.isDone());
    try testing.expectEqual(@as(?i32, null), handle.tryGet());

    handle.complete(42);

    try testing.expect(handle.isDone());
    try testing.expectEqual(@as(i32, 42), handle.get());
}

test "JoinHandle: tryGet returns value when complete" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var handle = JoinHandle(i32).init(pool);
    handle.complete(123);

    try testing.expectEqual(@as(?i32, 123), handle.tryGet());
}

// ============================================================================
// CPU-Bound Work Tests
// ============================================================================

test "join: with CPU-bound work" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    const compute = struct {
        fn work(n: u64) u64 {
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                sum +%= i * i;
            }
            return sum;
        }
    }.work;

    const left, const right = joinOnPool(pool, compute, .{1000}, compute, .{2000});

    // Verify both computations ran
    try testing.expect(left > 0);
    try testing.expect(right > left); // More iterations = bigger result
}

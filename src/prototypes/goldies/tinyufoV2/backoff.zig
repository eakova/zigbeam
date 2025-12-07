const std = @import("std");

/// Adaptive backoff strategy for lock-free operations
/// Reduces CPU waste on high contention
pub const Backoff = struct {
    const Self = @This();

    state: u32,
    max_spins: u32,
    max_yields: u32,
    max_park: u64, // nanoseconds

    pub fn init() Self {
        return Self{
            .state = 0,
            .max_spins = 64,
            .max_yields = 32,
            .max_park = 100_000_000, // 100ms
        };
    }

    pub fn initCustom(max_spins: u32, max_yields: u32, max_park_ns: u64) Self {
        return Self{
            .state = 0,
            .max_spins = max_spins,
            .max_yields = max_yields,
            .max_park = max_park_ns,
        };
    }

    /// Perform backoff and return true if should retry, false if gave up
    pub fn backoff(self: *Self) bool {
        if (self.state < self.max_spins) {
            // Spin: busy wait with memory barrier
            std.atomic.spinLoopHint();
            self.state += 1;
            return true;
        } else if (self.state < self.max_spins + self.max_yields) {
            // Yield: let OS scheduler run other threads
            std.Thread.yield() catch {};
            self.state += 1;
            return true;
        } else if (self.state < self.max_spins + self.max_yields + 10) {
            // Small sleep: 1-10 microseconds
            const sleep_duration = (self.state - self.max_spins - self.max_yields) * 1_000;
            std.time.sleep(sleep_duration);
            self.state += 1;
            return true;
        } else {
            // Sleep more: exponential backoff
            const sleep_duration = std.math.min(
                1_000 * (1 << (self.state - self.max_spins - self.max_yields - 10)),
                self.max_park,
            );
            std.time.sleep(sleep_duration);
            self.state += 1;
            
            // Cap at reasonable maximum
            if (self.state > self.max_spins + self.max_yields + 20) {
                self.state = self.max_spins + self.max_yields + 15;
            }
            return true;
        }
    }

    pub fn reset(self: *Self) void {
        self.state = 0;
    }

    pub fn isBoundExceeded(self: *const Self) bool {
        return self.state > self.max_spins + self.max_yields + 50;
    }
};

/// Contention-aware retry helper
pub const ContentionAwareRetry = struct {
    const Self = @This();

    backoff: Backoff,
    attempts: u32,
    max_attempts: u32,
    success_count: std.atomic.Value(u32),
    failure_count: std.atomic.Value(u32),

    pub fn init(max_attempts: u32) Self {
        return Self{
            .backoff = Backoff.init(),
            .attempts = 0,
            .max_attempts = max_attempts,
            .success_count = std.atomic.Value(u32).init(0),
            .failure_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn shouldRetry(self: *Self) bool {
        if (self.attempts >= self.max_attempts) {
            return false;
        }

        if (!self.backoff.backoff()) {
            return false;
        }

        self.attempts += 1;
        return true;
    }

    pub fn recordSuccess(self: *Self) void {
        _ = self.success_count.fetchAdd(1, .release);
        self.backoff.reset();
    }

    pub fn recordFailure(self: *Self) void {
        _ = self.failure_count.fetchAdd(1, .release);
    }

    pub fn getStats(self: *const Self) struct { successes: u32, failures: u32, contention: f64 } {
        const s = self.success_count.load(.acquire);
        const f = self.failure_count.load(.acquire);
        const total = s + f;

        return .{
            .successes = s,
            .failures = f,
            .contention = if (total > 0) @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(total)) else 0.0,
        };
    }

    pub fn reset(self: *Self) void {
        self.backoff.reset();
        self.attempts = 0;
    }
};

/// Exponential backoff with jitter for thundering herd prevention
pub const ExponentialBackoffWithJitter = struct {
    const Self = @This();

    initial_delay_ns: u64,
    max_delay_ns: u64,
    current_delay_ns: u64,
    attempt: u32,
    prng: std.Random.DefaultPrng,

    pub fn init(initial_delay_ns: u64, max_delay_ns: u64, seed: u64) Self {
        return Self{
            .initial_delay_ns = initial_delay_ns,
            .max_delay_ns = max_delay_ns,
            .current_delay_ns = initial_delay_ns,
            .attempt = 0,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn wait(self: *Self) void {
        // Current delay with jitter: delay * (0.5 + 0.5 * random)
        const jitter_factor = 0.5 + 0.5 * @as(f64, @floatFromInt(self.prng.random().uintLessThan(u32, 100))) / 100.0;
        const actual_delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.current_delay_ns)) * jitter_factor));

        std.time.sleep(actual_delay);

        // Exponential increase: delay *= 2, capped at max
        self.current_delay_ns = std.math.min(
            self.current_delay_ns * 2,
            self.max_delay_ns,
        );

        self.attempt += 1;
    }

    pub fn reset(self: *Self) void {
        self.current_delay_ns = self.initial_delay_ns;
        self.attempt = 0;
    }
};

/// Lock-free backoff counter for statistics
pub const BackoffStats = struct {
    const Self = @This();

    spin_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    yield_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sleep_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    park_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_backoff_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordSpin(self: *Self) void {
        _ = self.spin_count.fetchAdd(1, .release);
    }

    pub fn recordYield(self: *Self) void {
        _ = self.yield_count.fetchAdd(1, .release);
    }

    pub fn recordSleep(self: *Self, duration_ns: u64) void {
        _ = self.sleep_count.fetchAdd(1, .release);
        _ = self.total_backoff_ns.fetchAdd(duration_ns, .release);
    }

    pub fn recordPark(self: *Self, duration_ns: u64) void {
        _ = self.park_count.fetchAdd(1, .release);
        _ = self.total_backoff_ns.fetchAdd(duration_ns, .release);
    }

    pub fn getStats(self: *const Self) struct {
        spins: u64,
        yields: u64,
        sleeps: u64,
        parks: u64,
        total_backoff_ns: u64,
    } {
        return .{
            .spins = self.spin_count.load(.acquire),
            .yields = self.yield_count.load(.acquire),
            .sleeps = self.sleep_count.load(.acquire),
            .parks = self.park_count.load(.acquire),
            .total_backoff_ns = self.total_backoff_ns.load(.acquire),
        };
    }

    pub fn reset(self: *Self) void {
        _ = self.spin_count.store(0, .release);
        _ = self.yield_count.store(0, .release);
        _ = self.sleep_count.store(0, .release);
        _ = self.park_count.store(0, .release);
        _ = self.total_backoff_ns.store(0, .release);
    }
};

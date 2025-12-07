// Thread-Local Storage - Port of seize's ThreadLocal
// Reference: refs/seize_rust/src/raw/tls/mod.rs

const std = @import("std");
const thread_id = @import("thread_id.zig");
const Thread = thread_id.Thread;
const BUCKETS = thread_id.BUCKETS;

/// Per-object thread-local storage with lock-free initialization
///
/// This provides efficient thread-local storage without using std.Thread.threadlocal:
/// - Lock-free bucket allocation via atomic CAS
/// - Power-of-2 bucket sizing for efficient indexing
/// - Lazy initialization of buckets and entries
/// - Safe iteration over all active threads
pub fn ThreadLocal(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Entry in a thread-local bucket
        const Entry = struct {
            /// Flag indicating if value is initialized
            present: std.atomic.Value(bool),
            /// The actual value (may be uninitialized)
            value: T,

            fn init() Entry {
                return .{
                    .present = std.atomic.Value(bool).init(false),
                    .value = undefined,
                };
            }
        };

        /// Atomic pointers to buckets (one per bucket level)
        buckets: [BUCKETS]std.atomic.Value(?[*]Entry),
        allocator: std.mem.Allocator,

        /// Create ThreadLocal with given initial capacity
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            var self = Self{
                .buckets = undefined,
                .allocator = allocator,
            };

            // Initialize all bucket pointers to null
            for (&self.buckets) |*bucket| {
                bucket.* = std.atomic.Value(?[*]Entry).init(null);
            }

            // Pre-allocate initial buckets based on capacity
            if (capacity > 0) {
                const initial_thread = Thread.fromId(capacity);
                const init_bucket = initial_thread.bucket;

                // Allocate buckets up to the initial capacity
                for (0..init_bucket + 1) |i| {
                    const bucket_size = Thread.bucket_capacity(i);
                    const bucket_ptr = try allocateBucket(allocator, bucket_size);
                    self.buckets[i].store(bucket_ptr, .release);
                }
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            // Free all allocated buckets
            for (&self.buckets, 0..) |bucket_atomic, i| {
                const bucket_ptr = bucket_atomic.load(.acquire);
                if (bucket_ptr) |ptr| {
                    const bucket_size = Thread.bucket_capacity(i);
                    const slice = ptr[0..bucket_size];

                    // Drop initialized entries
                    for (slice) |*entry| {
                        if (entry.present.load(.acquire)) {
                            // Value is initialized, nothing special to do in Zig
                            // (destructor will be called automatically if T has one)
                        }
                    }

                    self.allocator.free(slice);
                }
            }
        }

        /// Load the slot for the given thread, initializing with creation function if needed
        ///
        /// # Safety
        /// The current thread must have unique access to the slot for the provided thread.
        /// In practice, this means thread should be Thread.current() for the calling thread.
        pub fn loadOr(self: *Self, thread: Thread, create_fn: anytype) !*T {
            // Get bucket for this thread
            const bucket_atomic = &self.buckets[thread.bucket];
            var bucket_ptr = bucket_atomic.load(.acquire);

            // Initialize bucket if null
            if (bucket_ptr == null) {
                bucket_ptr = try self.initializeBucket(bucket_atomic, thread);
            }

            // Get entry within bucket
            const entry = &bucket_ptr.?[thread.entry];

            // Initialize entry if not present
            if (!entry.present.load(.monotonic)) {
                try self.writeEntry(entry, create_fn);
            }

            return &entry.value;
        }

        /// Load the slot for current thread with default value
        pub fn load(self: *Self, thread: Thread) !*T {
            const create_fn = struct {
                fn create() T {
                    return std.mem.zeroes(T);
                }
            }.create;
            return self.loadOr(thread, create_fn);
        }

        /// Initialize an entry with the creation function
        ///
        /// # Safety
        /// The current thread must have unique access to the uninitialized entry.
        fn writeEntry(self: *Self, entry: *Entry, create_fn: anytype) !void {
            _ = self;

            // Create and write the value
            entry.value = create_fn();

            // Release: Synchronize with iterator and other readers
            entry.present.store(true, .release);

            // TODO: Add SeqCst fence for synchronization with batch retirement
            // when we implement that phase. For now, .release is sufficient.
        }

        /// Initialize a bucket with lock-free CAS
        fn initializeBucket(self: *Self, bucket_atomic: *std.atomic.Value(?[*]Entry), thread: Thread) !?[*]Entry {
            const bucket_size = Thread.bucket_capacity(thread.bucket);
            const new_bucket = try allocateBucket(self.allocator, bucket_size);

            // Try to install our bucket via CAS
            if (bucket_atomic.cmpxchgStrong(
                null,
                new_bucket,
                .release, // Release if we win
                .acquire, // Acquire if we lose
            )) |other_bucket| {
                // Lost the race - another thread installed their bucket
                // Free our bucket and use theirs
                const slice = new_bucket[0..bucket_size];
                self.allocator.free(slice);
                return other_bucket;
            }

            // Won the race - our bucket is now installed
            return new_bucket;
        }

        /// Allocate a new bucket with given capacity
        fn allocateBucket(allocator: std.mem.Allocator, capacity: usize) ![*]Entry {
            const slice = try allocator.alloc(Entry, capacity);

            // Initialize all entries as unpresent
            for (slice) |*entry| {
                entry.* = Entry.init();
            }

            return slice.ptr;
        }

        /// Iterator over all active thread slots
        ///
        /// # Safety
        /// Values stored by other threads must be safe to access.
        /// In practice, this is used during collector cleanup when no threads are active.
        pub fn iter(self: *const Self) Iterator {
            return Iterator{
                .thread_local = self,
                .bucket = 0,
                .index = 0,
                .bucket_size = Thread.bucket_capacity(0),
            };
        }

        /// Iterator implementation
        pub const Iterator = struct {
            thread_local: *const Self,
            bucket: usize,
            index: usize,
            bucket_size: usize,

            pub fn next(self: *Iterator) ?*T {
                // Iterate through all buckets
                while (self.bucket < BUCKETS) {
                    const bucket_ptr = self.thread_local.buckets[self.bucket].load(.acquire);

                    if (bucket_ptr) |ptr| {
                        // Iterate through entries in this bucket
                        while (self.index < self.bucket_size) {
                            const entry = &ptr[self.index];
                            self.index += 1;

                            // Check if entry is initialized
                            if (entry.present.load(.acquire)) {
                                return @constCast(&entry.value);
                            }
                        }
                    }

                    // Move to next bucket
                    self.bucket += 1;
                    self.index = 0;
                    if (self.bucket < BUCKETS) {
                        self.bucket_size = Thread.bucket_capacity(self.bucket);
                    }
                }

                return null;
            }
        };
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "thread local basic" {
    const TL = ThreadLocal(usize);

    var tl = try TL.init(std.testing.allocator, 8);
    defer tl.deinit();

    // Use create() instead of current() to get sequential IDs that fit in BUCKETS
    const thread = Thread.create();
    defer Thread.free(thread.id);

    // First access creates entry
    const create_fn = struct {
        fn create() usize {
            return 42;
        }
    }.create;

    const val1 = try tl.loadOr(thread, create_fn);
    try std.testing.expectEqual(@as(usize, 42), val1.*);

    // Second access returns same entry
    const val2 = try tl.loadOr(thread, create_fn);
    try std.testing.expectEqual(@as(usize, 42), val2.*);
    try std.testing.expect(val1 == val2); // Same pointer
}

test "thread local multiple threads" {
    const TL = ThreadLocal(usize);

    var tl = try TL.init(std.testing.allocator, 16);
    defer tl.deinit();

    const TestContext = struct {
        tl: *TL,
    };

    const thread_fn = struct {
        fn run(ctx: *TestContext) !void {
            // Use create() to get sequential IDs that fit in BUCKETS
            const thread = Thread.create();
            defer Thread.free(thread.id);

            const create_fn = struct {
                fn create() usize {
                    return 999;
                }
            }.create;

            const val = try ctx.tl.loadOr(thread, create_fn);
            try std.testing.expectEqual(@as(usize, 999), val.*);
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    var contexts: [4]TestContext = undefined;

    for (&threads, 0..) |*t, i| {
        contexts[i] = .{ .tl = &tl };
        t.* = try std.Thread.spawn(.{}, thread_fn, .{&contexts[i]});
    }

    for (threads) |t| {
        t.join();
    }
}

test "thread local iterator" {
    const TL = ThreadLocal(usize);

    var tl = try TL.init(std.testing.allocator, 8);
    defer tl.deinit();

    // Insert values for several thread IDs
    for (0..5) |i| {
        const thread = Thread.fromId(i);
        const create_fn = struct {
            fn create() usize {
                return 123;
            }
        }.create;

        _ = try tl.loadOr(thread, create_fn);
    }

    // Iterate and count entries
    var it = tl.iter();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 5), count);
}

test "thread local zero capacity" {
    const TL = ThreadLocal(usize);

    var tl = try TL.init(std.testing.allocator, 0);
    defer tl.deinit();

    const thread = Thread.create();
    defer Thread.free(thread.id);

    const create_fn = struct {
        fn create() usize {
            return 123;
        }
    }.create;

    const val = try tl.loadOr(thread, create_fn);
    try std.testing.expectEqual(@as(usize, 123), val.*);
}

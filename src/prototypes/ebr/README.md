# Epoch-Based Reclamation (EBR)

A production-ready, lock-free memory reclamation scheme for Zig 0.15.2, following crossbeam-epoch semantics.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Detailed Usage](#detailed-usage)
- [API Reference](#api-reference)
- [Memory Model](#memory-model)
- [Performance](#performance)
- [Comparisons](#comparisons)
- [Testing](#testing)
- [Examples](#examples)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

Epoch-Based Reclamation (EBR) is a memory reclamation scheme that enables safe memory management in lock-free concurrent data structures. Instead of immediately freeing memory, objects are retired and freed only when it's provably safe—when no thread can possibly hold a reference.

### How It Works

1. **Global Epoch**: A monotonically increasing counter shared by all threads
2. **Pin**: Threads announce they're accessing shared data by pinning to the current epoch
3. **Retire**: Memory is marked for deletion but tagged with the current epoch
4. **Garbage Collection**: Memory is freed when all threads have moved past the retirement epoch

### Key Concepts

- **Lock-free**: No mutexes in critical paths
- **Safe**: Guaranteed no use-after-free
- **Scalable**: Per-thread retired lists eliminate contention
- **Efficient**: Sub-microsecond pin/unpin operations

---

## Features

- **Lock-free Design**: All operations use atomic primitives, no blocking
- **Thread-safe**: Correct synchronization via crossbeam-epoch semantics
- **Cache-efficient**: 64-byte aligned structures prevent false sharing
- **Zero-overhead Abstraction**: Minimal runtime cost for memory safety
- **Flexible API**: Optional struct parameter pattern for ergonomics
- **Comprehensive Testing**: Unit, integration, fuzz, and benchmark tests
- **Production-ready**: Extensively tested and benchmarked

---

## Architecture

### Components

```
epoch-based-reclamation/
├── ebr.zig                      # Main module (exports all components)
├── global.zig                   # Global state with epoch counter
├── thread_state.zig             # Thread-local state (use as threadlocal var)
├── guard.zig                    # RAII-style epoch protection
├── atomic_ptr.zig               # Lock-free atomic pointer wrapper
├── retired_list.zig             # Per-thread retired object list
├── _ebr_unit_tests.zig          # 15+ unit tests
├── _ebr_integration_tests.zig   # Multi-threaded integration tests
├── _ebr_samples.zig             # Usage examples
├── _ebr_fuzz_tests.zig          # Fuzz tests for edge cases
├── _ebr_benchmarks.zig          # Performance benchmarks
├── BENCHMARK_RESULTS.md         # Detailed benchmark results
└── README.md                    # This file
```

### Module Structure

```
┌─────────────────────────────────────┐
│          Application Code           │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│         ebr.zig (Main API)          │
│   - EpochBasedReclamation           │
│   - EBR (alias)                     │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌─────────────┐  ┌─────────────┐
│   Global    │  │ ThreadState │ (threadlocal var)
│  (shared)   │  │ (per-thread)│
└──────┬──────┘  └──────┬──────┘
       │                │
       └────────┬───────┘
                ▼
         ┌─────────────┐
         │    Guard    │ (RAII protection)
         └──────┬──────┘
                │
       ┌────────┴────────┐
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│  AtomicPtr  │   │ RetiredList │
│ (lock-free) │   │(per-thread) │
└─────────────┘   └─────────────┘
```

---

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .@"zig-beam" = .{
        .url = "https://github.com/eakova/zig-beam/archive/<commit-hash>.tar.gz",
        .hash = "<hash>",
    },
},
```

### Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/eakova/zig-beam.git
```

2. Add to your `build.zig`:
```zig
const ebr = b.dependency("zig-beam", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("epoch-based-reclamation", ebr.module("epoch-based-reclamation"));
```

---

## Quick Start

### Basic Usage

```zig
const std = @import("std");
const ebr = @import("epoch-based-reclamation");
const EBR = ebr.EpochBasedReclamation;

// Global state (one per application)
var global: EBR.Global = undefined;

// Thread-local state (one per thread, as threadlocal var)
threadlocal var thread_state: EBR.ThreadState = .{};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize global state
    global = try EBR.Global.init(.{ .allocator = allocator });
    defer global.deinit();

    // Initialize thread-local state
    try thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer thread_state.deinitThread();

    // Pin to access shared data
    var guard = EBR.pin(&thread_state, &global);
    defer guard.unpin();

    // Now it's safe to access shared lock-free data structures
    // ...
}
```

### With AtomicPtr

```zig
const IntPtr = EBR.AtomicPtr(u64);
var shared_ptr = IntPtr.init(.{});

// Write
{
    const new_value = try allocator.create(u64);
    new_value.* = 42;

    var guard = EBR.pin(&thread_state, &global);
    defer guard.unpin();

    const old = shared_ptr.swap(.{ .value = new_value });

    if (old) |old_ptr| {
        // Retire old value instead of immediately freeing
        guard.retire(.{
            .ptr = old_ptr,
            .deleter = myDeleter,
        });
    }
}

// Read
{
    var guard = EBR.pin(&thread_state, &global);
    defer guard.unpin();

    const value = shared_ptr.load(.{ .guard = &guard });
    if (value) |v| {
        std.debug.print("Value: {}\n", .{v.*});
    }
}
```

---

## Detailed Usage

### Initialization Pattern

#### 1. Declare Global State (Once per Application)

```zig
// At file scope or in your main struct
var global: EBR.Global = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    global = try EBR.Global.init(.{ .allocator = allocator });
}

pub fn deinit() void {
    global.deinit();
}
```

#### 2. Declare Thread-Local State (Per Thread)

```zig
// MUST be threadlocal var
threadlocal var thread_state: EBR.ThreadState = .{};

pub fn threadFunction() !void {
    // Ensure initialized once per thread
    try thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer thread_state.deinitThread();

    // ... use thread_state ...
}
```

#### 3. Pin/Unpin for Protected Access

```zig
pub fn accessSharedData() void {
    var guard = EBR.pin(&thread_state, &global);
    defer guard.unpin();

    // Protected: safe to access lock-free data structures
    // ...
}
```

### Retirement and Reclamation

#### Retiring Objects

```zig
const TestData = struct {
    value: u64,

    fn deleter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

var guard = EBR.pin(&thread_state, &global);
defer guard.unpin();

const data = try allocator.create(TestData);
data.* = TestData{ .value = 42 };

// Later, when removing from data structure
guard.retire(.{
    .ptr = data,
    .deleter = TestData.deleter,
});
```

#### Manual Garbage Collection

```zig
var guard = EBR.pin(&thread_state, &global);
defer guard.unpin();

// Force garbage collection
guard.flush();
```

### Lock-Free Stack Example

```zig
const Node = struct {
    value: u64,
    next: ?*@This(),
};

const Stack = struct {
    head: EBR.AtomicPtr(Node),

    fn push(self: *@This(), guard: *EBR.Guard, value: u64) !void {
        const node = try allocator.create(Node);
        node.* = Node{ .value = value, .next = null };

        while (true) {
            const old_head = self.head.load(.{ .guard = guard });
            node.next = old_head;

            const result = self.head.compareAndSwapWeak(.{
                .expected = old_head,
                .new = node,
            });

            if (result == null) break; // Success
        }
    }

    fn pop(self: *@This(), guard: *EBR.Guard) ?u64 {
        while (true) {
            const old_head = self.head.load(.{ .guard = guard }) orelse return null;
            const new_head = old_head.next;

            const result = self.head.compareAndSwapWeak(.{
                .expected = old_head,
                .new = new_head,
            });

            if (result == null) {
                const value = old_head.value;
                guard.retire(.{
                    .ptr = old_head,
                    .deleter = Node.deleter,
                });
                return value;
            }
        }
    }
};
```

---

## API Reference

### Global

```zig
pub const Global = struct {
    /// Initialize global EBR state
    pub fn init(opts: struct {
        allocator: std.mem.Allocator,
    }) !Global;

    /// Clean up global state
    pub fn deinit(self: *Global) void;
};
```

### ThreadState

```zig
pub const ThreadState = struct {
    /// Ensure thread is registered (idempotent)
    /// MUST be called on a threadlocal var
    pub fn ensureInitialized(self: *ThreadState, opts: struct {
        global: *Global,
        allocator: std.mem.Allocator,
    }) !void;

    /// Unregister thread and clean up
    pub fn deinitThread(self: *ThreadState) void;
};
```

### Guard

```zig
pub const Guard = struct {
    /// Unpin from epoch (call via defer)
    pub fn unpin(self: *Guard) void;

    /// Retire an object for later reclamation
    pub fn retire(self: *Guard, opts: struct {
        ptr: *anyopaque,
        deleter: *const fn (*anyopaque) void,
    }) void;

    /// Force garbage collection
    pub fn flush(self: *Guard) void;
};

/// Pin current thread to current epoch
pub fn pin(thread_state: *ThreadState, global: *Global) Guard;
```

### AtomicPtr

```zig
pub fn AtomicPtr(comptime T: type) type {
    return struct {
        /// Initialize with optional value
        pub fn init(opts: struct {
            value: ?*T = null,
        }) @This();

        /// Load pointer (requires guard)
        pub fn load(self: *const @This(), opts: struct {
            guard: *const Guard,
        }) ?*T;

        /// Store pointer
        pub fn store(self: *@This(), opts: struct {
            value: ?*T,
        }) void;

        /// Swap pointer atomically
        pub fn swap(self: *@This(), opts: struct {
            value: ?*T,
        }) ?*T;

        /// Compare-and-swap (weak)
        pub fn compareAndSwapWeak(self: *@This(), opts: struct {
            expected: ?*T,
            new: ?*T,
        }) ?*T; // null on success, actual value on failure

        /// Compare-and-swap (strong)
        pub fn compareAndSwapStrong(self: *@This(), opts: struct {
            expected: ?*T,
            new: ?*T,
        }) ?*T; // null on success, actual value on failure
    };
}
```

---

## Memory Model

### Ordering Guarantees

- **Global Epoch**: Acquire/Release ordering for epoch counter
- **Thread States**: Acquire/Release for registration and epoch updates
- **AtomicPtr Load**: Acquire ordering ensures visibility of writes
- **AtomicPtr Store**: Release ordering ensures visibility to other threads
- **AtomicPtr RMW**: Acq_Rel ordering for read-modify-write operations

### Cache-Line Alignment

All structures are 64-byte cache-line aligned to prevent false sharing:

```zig
// Global epoch counter
global_epoch: Atomic(u64) align(64)

// Thread-local epoch
local_epoch: Atomic(u64) align(64)
```

### Epoch Advancement

The global epoch advances when:
1. A thread unpins (every 256 unpins per thread)
2. All threads have moved past the current epoch

### Garbage Collection

Objects are reclaimed when:
1. Their retirement epoch is at least 2 epochs behind the global epoch
2. No thread is pinned to an epoch ≤ retirement epoch

---

## Performance

### Latency Characteristics

| Operation | p50 | p99 | p999 |
|-----------|-----|-----|------|
| Pin/Unpin | 150ns | 400ns | 800ns |
| Retire | 220ns | 600ns | 1.2μs |
| AtomicPtr Load | 180ns | 350ns | 700ns |
| AtomicPtr Swap | 1.5μs | 5μs | 12μs |

### Throughput

| Scenario | Threads | Throughput |
|----------|---------|------------|
| Pin/Unpin | 1 | 5.5M ops/sec |
| Pin/Unpin | 4 | 18M ops/sec |
| Pin/Unpin | 8 | 32M ops/sec |
| AtomicPtr | 4 | 470K ops/sec |
| AtomicPtr | 8 | 666K ops/sec |

See [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) for detailed performance analysis.

---

## Comparisons

### vs. Hazard Pointers

| Aspect | EBR | Hazard Pointers |
|--------|-----|-----------------|
| Pin Latency | ~200ns | ~300ns |
| Reclamation | Periodic (every 2 epochs) | Immediate (when safe) |
| Memory Overhead | Low (per-thread list) | Medium (per-pointer) |
| Complexity | Low | Medium |
| **Best For** | High throughput | Immediate reclamation |

### vs. Reference Counting

| Aspect | EBR | Reference Counting |
|--------|-----|-------------------|
| Pin Latency | ~200ns | ~500ns |
| Atomics per Access | 1 (load epoch) | 2 (inc/dec) |
| Cycles | No | Possible |
| Complexity | Low | High |
| **Best For** | Lock-free structures | General ownership |

### vs. Garbage Collection

| Aspect | EBR | Tracing GC |
|--------|-----|------------|
| Determinism | High | Low |
| Pause Times | None | Unpredictable |
| Memory Overhead | Low | High |
| Language Support | Any | Language-specific |
| **Best For** | Predictable latency | General memory management |

### vs. RCU (Read-Copy-Update)

| Aspect | EBR | RCU |
|--------|-----|-----|
| Pin/Unpin | Explicit | Implicit (scheduler) |
| Portability | Userspace, any OS | Linux kernel |
| Control | Fine-grained | Coarse-grained |
| Overhead | Predictable | Variable |
| **Best For** | Portable lock-free | Linux kernel |

**Recommendation**: Use EBR for lock-free data structures where predictable, low-latency performance is critical.

---

## Testing

### Unit Tests

```bash
zig build test --summary all
```

15+ unit tests covering:
- Global initialization
- ThreadState lifecycle
- Pin/unpin cycles
- Epoch advancement
- Retirement and collection
- AtomicPtr operations

### Integration Tests

Multi-threaded scenarios:
- Concurrent pin/unpin (4 threads)
- Concurrent retire and collect
- AtomicPtr concurrent updates
- Lock-free stack implementation
- Stress test (8 threads, 500 ops each)

### Fuzz Tests

Edge case testing:
- Random pin/unpin sequences
- Random retire with varying lifetimes
- AtomicPtr random operations
- Concurrent chaos (8 threads)
- Rapid thread creation/destruction
- Interleaved operations
- Epoch advancement stress

### Benchmarks

```bash
zig build benchmark-ebr
```

Comprehensive performance testing with:
- Latency percentiles (p50, p90, p95, p99, p999)
- Latency histograms
- Memory usage tracking
- Thread scalability analysis

---

## Examples

See [_ebr_samples.zig](_ebr_samples.zig) for complete working examples:

1. **Basic Pin/Unpin**: Simple guard usage
2. **AtomicPtr Operations**: Load, swap, retire
3. **Lock-Free Stack**: Complete data structure implementation
4. **Multi-Threaded**: 4 threads sharing data

Run samples:
```bash
zig build run-ebr-samples
```

---

## FAQ

### Q: When should I call `flush()`?

**A**: EBR automatically collects garbage periodically. Call `flush()` only when:
- You need immediate reclamation (e.g., before shutdown)
- You've retired many objects and want to free memory eagerly
- Testing/benchmarking scenarios

### Q: Can I use EBR in single-threaded code?

**A**: Yes, but it adds overhead. For single-threaded code, direct memory management is simpler.

### Q: What happens if I forget to `unpin()`?

**A**: The thread remains pinned to its epoch, blocking global epoch advancement and preventing garbage collection. Always use `defer guard.unpin()`.

### Q: Can the epoch counter overflow?

**A**: Yes, after 2^64 advancements, but this is not a practical concern (would take millions of years at typical advancement rates).

### Q: How many retired objects can accumulate?

**A**: Per-thread retired lists grow until garbage collection. Objects are freed when the global epoch advances by at least 2.

### Q: Is EBR suitable for real-time systems?

**A**: Yes, with caveats:
- Pin/unpin latency is bounded and predictable
- Garbage collection is deterministic but may be delayed
- No unpredictable pauses (unlike tracing GC)

### Q: Can I use EBR with custom allocators?

**A**: Yes, pass your allocator to `Global.init()` and `ThreadState.ensureInitialized()`.

### Q: What if two threads have different allocators?

**A**: Each thread can use its own allocator for thread-local state. Shared objects should use a shared allocator.

---

## Best Practices

1. **Always use `defer guard.unpin()`** immediately after pinning
2. **Declare ThreadState as `threadlocal var`** (not on stack)
3. **Call `ensureInitialized()` once per thread** (idempotent, but wasteful to repeat)
4. **Keep critical sections short** (minimize pinned duration)
5. **Use appropriate memory ordering** (EBR handles this internally)
6. **Profile before optimizing** (run benchmarks to identify bottlenecks)
7. **Test with ThreadSanitizer** (detect race conditions)

---

## Limitations

1. **Manual pin/unpin required**: Zig has no automatic destructors (must use `defer`)
2. **Delayed reclamation**: Objects not immediately freed (may increase memory usage)
3. **Pinned threads block GC**: Long-lived pins delay global epoch advancement
4. **Threadlocal requirement**: ThreadState MUST be `threadlocal var`
5. **No nested guards**: Each pin requires corresponding unpin

---

## Future Improvements

- [ ] Automatic epoch advancement heuristics
- [ ] Configurable GC thresholds
- [ ] Memory pressure callbacks
- [ ] Per-thread statistics/metrics
- [ ] Integration with custom allocators for retired objects
- [ ] Support for `@atomicRmw` on more architectures

---

## Contributing

Contributions welcome! Please:

1. Follow existing code style
2. Add tests for new features
3. Run benchmarks to verify performance
4. Update documentation
5. Submit PR with clear description

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for details.

---

## License

MIT License - see [LICENSE](../../LICENSE) for details.

---

## References

- [Crossbeam Epoch](https://docs.rs/crossbeam-epoch/) - Original Rust implementation
- [Keir Fraser's Epoch-Based Reclamation](https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-579.pdf)
- [The Art of Multiprocessor Programming](https://www.elsevier.com/books/the-art-of-multiprocessor-programming/herlihy/978-0-12-415950-1)
- [Memory Reclamation in Lock-Free Data Structures](https://www.research-collection.ethz.ch/handle/20.500.11850/69182)

---

## Acknowledgments

- Inspired by Rust's crossbeam-epoch
- Based on epoch-based reclamation research by Keir Fraser
- Zig implementation by zig-beam contributors

---

**Version**: 1.0.0
**Zig**: 0.15.2
**Status**: Production Ready
**Last Updated**: 2025-11-17

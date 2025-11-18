# beam-deque

High-performance work-stealing data structures for Zig.

## Overview

This module provides two lock-free, bounded concurrent data structures:

- **BeamDeque**: A Single-Producer, Multi-Consumer (SPMC) work-stealing deque
- **BeamDequeChannel**: A Multi-Producer, Multi-Consumer (MPMC) channel built on top of BeamDeque

Both are designed for high-throughput, low-latency concurrent systems like thread pools and work schedulers.

## Quick Start

### BeamDeque (SPMC Work-Stealing Deque)

```zig
const std = @import("std");
const BeamDeque = @import("beam_deque").BeamDeque;

// Initialize with power-of-2 capacity
const result = try BeamDeque(Task).init(allocator, 1024);
defer result.worker.deinit();

// Owner thread (single producer, single consumer)
try result.worker.push(task);           // LIFO push
if (result.worker.pop()) |task| { }     // LIFO pop

// Thief threads (many consumers, read-only)
// Pass result.stealer to other threads
if (result.stealer.steal()) |task| { }  // FIFO steal
```

**Performance**: ~5-15ns per operation (owner), ~20-50ns per steal (thieves)

### BeamDequeChannel (MPMC Channel)

```zig
const std = @import("std");
const BeamDequeChannel = @import("beam_deque_channel").BeamDequeChannel;

// Create channel with 8 workers
const Channel = BeamDequeChannel(Task, 256, 4096);
const result = try Channel.init(allocator, 8);
defer result.channel.deinit(&result.workers);

// CRITICAL: Each worker should be BOTH producer AND consumer
// Worker thread loop (correct pattern):
while (running) {
    // Send to own local deque (fast path: ~2.5ns)
    try result.workers[worker_id].send(task);

    // Receive from own deque, global queue, or steal (priority order)
    if (result.workers[worker_id].recv()) |task| {
        process(task);
    }
}
```

**Performance**: ~2.5ns per operation (local), scales to 1.95B ops/sec with 8 workers (4.8x), up to 3.37B ops/sec with adaptive backoff (7.1x)

## Architecture

### BeamDeque: The Foundation

Based on the Arora-Blumofe-Plaxton algorithm:

- **Owner**: Exclusive access to push/pop (LIFO stack for cache locality)
- **Thieves**: Concurrent steal access (FIFO queue, load balancing)
- **Cache-optimized**: Cache-line padding prevents false sharing
- **Memory ordering**: Carefully tuned acquire/release/seq_cst semantics

### BeamDequeChannel: The High-Level API

Built on BeamDeque with three-tier priority:

1. **Local deque** (LIFO, ~2.5ns): Each worker's private deque
2. **Global queue** (FIFO, ~30-60ns): Overflow buffer using DVyukovMPMCQueue
3. **Work-stealing** (FIFO, ~20-50ns): Steal from other workers' deques

**Key Design**: Workers are **both producers and consumers**, maximizing local deque usage.

## Performance Characteristics

### BeamDeque Benchmarks

- Owner push: ~75M ops/sec (13ns per op)
- Owner pop: ~75M ops/sec (13ns per op)
- Single thief steal: ~40M ops/sec (24ns per op)
- 8 concurrent thieves: ~8.8M ops/sec (113ns per op with backoff)

### BeamDequeChannel Benchmarks

**Correct Usage** (each worker is producer + consumer):

| Workers | Throughput | Per-op | Scaling |
|---------|------------|--------|---------|
| 1 | 405M ops/sec | 2.5ns | 1.0x |
| 4 | 1.72B ops/sec | 0.58ns | 4.25x |
| 8 | 1.95B ops/sec | 0.51ns | 4.8x |

*With adaptive backoff: 8 workers achieve 3.37B ops/sec (7.1x scaling)*

**Incorrect Usage** (dedicated producers/consumers): **30-60x slower!**
- 4P/4C: Only 28M items/sec (vs 861M items/sec correct usage)
- 8P/8C: Only 29M items/sec (vs 975M items/sec correct usage)

See [BENCHMARK_ANALYSIS.md](docs/BENCHMARK_ANALYSIS.md) for detailed analysis.

## Correct Usage Patterns

###  DO: Worker is Both Producer and Consumer

```zig
// Each worker sends to itself and receives from itself (or steals)
fn workerThread(worker: *Worker, worker_id: usize) void {
    while (running) {
        // Generate work (or receive from external source)
        const task = generateTask();

        // Send to OWN local deque (fast!)
        try worker.send(task);

        // Receive from OWN local deque first, steal if empty
        if (worker.recv()) |task| {
            process(task);
        }
    }
}
```

**Why this works**: Maximizes local deque usage (~2.5ns operations), work-stealing balances load automatically.

### L DON'T: Dedicated Producer/Consumer Threads

```zig
// WRONG: Dedicated producer threads
fn producerThread(worker: *Worker) void {
    while (running) {
        try worker.send(task);  // Always fills local � overflows to global
    }
}

// WRONG: Dedicated consumer threads
fn consumerThread(worker: *Worker) void {
    while (running) {
        if (worker.recv()) |task| {  // Always empty � always steals/global
            process(task);
        }
    }
}
```

**Why this fails**: Local deques never used effectively, every operation hits slow path (30-60x slower).

## API Reference

### BeamDeque

```zig
pub fn BeamDeque(comptime T: type) type

// Initialization
pub fn init(allocator: Allocator, capacity: usize) !InitResult
// Returns: { worker: Worker, stealer: Stealer }

// Worker (owner thread only)
pub fn push(item: T) !void           // Error: Full
pub fn pop() ?T                       // null if empty
pub fn size() usize                   // Approximate (racy)
pub fn isEmpty() bool                 // Approximate (racy)
pub fn deinit()                       // Cleanup

// Stealer (any thread, thread-safe)
pub fn steal() ?T                     // null if empty or lost race
pub fn size() usize                   // Approximate (racy)
pub fn isEmpty() bool                 // Approximate (racy)
```

### BeamDequeChannel

```zig
pub fn BeamDequeChannel(
    comptime T: type,
    comptime local_capacity: usize,   // Per-worker deque size (power of 2)
    comptime global_capacity: usize,  // Overflow queue size (power of 2)
) type

// Initialization
pub fn init(allocator: Allocator, num_workers: usize) !InitResult
// Returns: { channel: *Channel, workers: []Worker }

// Worker API (all thread-safe)
pub fn send(item: T) !void            // Error: Full (system saturated)
pub fn recv() ?T                      // null if no work available
pub fn size() usize                   // Local deque size
pub fn isEmpty() bool                 // Local deque empty
pub fn deinit()                       // Worker cleanup

// Channel cleanup
pub fn deinit(workers: []Worker)      // Full cleanup
```

## Compile-Time Validation

Types larger than 64 bytes (cache line size) must use pointers:

```zig
//  OK: Small type
const result = try BeamDeque(u64).init(allocator, 256);

//  OK: Pointer to large type
const LargeTask = struct { data: [256]u8 };
const result = try BeamDeque(*LargeTask).init(allocator, 256);

// L Compile error: Type too large
const result = try BeamDeque(LargeTask).init(allocator, 256);
// Error: Type 'LargeTask' (256 bytes) exceeds cache line size (64 bytes).
//        Use *LargeTask instead for better performance.
```

## Design Documentation

- [BEAM_DEQUE.md](docs/BEAM_DEQUE.md) - SPMC deque design and algorithm
- [BEAM_DEQUE_CHANNEL.md](docs/BEAM_DEQUE_CHANNEL.md) - MPMC channel architecture
- [BENCHMARK_ANALYSIS.md](docs/BENCHMARK_ANALYSIS.md) - Performance analysis and patterns

## Testing

```bash
# Run all tests
zig build test-beam-deque -Doptimize=ReleaseFast

# Run benchmarks
zig build bench-beam-deque
zig build bench-beam-deque-channel-v2

# Run race condition tests (thorough, takes time)
zig build test-beam-deque -Doptimize=ReleaseFast
```

## Implementation Notes

- **Bounded**: Both structures have fixed capacity with back-pressure semantics
- **Lock-free**: No mutexes or blocking operations
- **Memory ordering**: Carefully tuned for correctness and performance
- **Cache-aware**: Explicit cache-line padding prevents false sharing
- **Backoff**: Exponential backoff reduces CAS contention under load

## License

See repository root for license information.

# DVyukov MPMC Queue

A high-performance lock-free Multiple Producer Multiple Consumer (MPMC) queue implementation in Zig, based on Dmitry Vyukov's bounded MPMC queue algorithm.

## Overview

This library provides **two variants** optimized for different contention levels:

1. **DVyukovMPMCQueue** - Single queue for low-moderate contention
2. **ShardedDVyukovMPMCQueue** - Multiple queues for high contention (4+ producers AND 4+ consumers)

Both are production-ready, wait-free bounded queues using sequence numbers for synchronization instead of locks.

**Key Characteristics:**
- Lock-free with CAS-based synchronization
- Multiple concurrent producers and consumers
- Fixed capacity (power-of-2 required)
- Zero allocations during operations
- Cache-line aligned to prevent false sharing
- Comprehensive test coverage (68 tests)

## Choosing the Right Variant

| Scenario | Threads | Recommended | Throughput |
|----------|---------|-------------|------------|
| SPSC | 1P + 1C | DVyukovMPMCQueue | 70-100 Mops/s |
| Low contention | 2-4 total | DVyukovMPMCQueue | 40-80 Mops/s |
| Balanced MPMC | 4P + 4C | **ShardedDVyukovMPMCQueue** | 100-109 Mops/s ⭐ |
| High contention | 8P + 8C | **ShardedDVyukovMPMCQueue** | 120-133 Mops/s ⭐ |
| Very high contention | 16P + 16C | **ShardedDVyukovMPMCQueue** | 74-82 Mops/s ⭐ |

**Rule of thumb:** Use ShardedDVyukovMPMCQueue when you have **4+ producers AND 4+ consumers** with balanced workload.

## Quick Start

### DVyukovMPMCQueue (Single Queue)

```zig
const std = @import("std");
const DVyukovMPMCQueue = @import("dvyukov_mpmc_queue.zig").DVyukovMPMCQueue;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create queue with capacity of 256 (must be power of 2)
    var queue = try DVyukovMPMCQueue(u64, 256).init(allocator);
    defer queue.deinit();

    // Enqueue items
    try queue.enqueue(42);
    try queue.enqueue(99);

    // Dequeue items (FIFO order)
    const value1 = queue.dequeue(); // 42
    const value2 = queue.dequeue(); // 99
}
```

### ShardedDVyukovMPMCQueue (Multiple Queues)

```zig
const std = @import("std");
const ShardedDVyukovMPMCQueue = @import("sharded_dvyukov_mpmc_queue.zig").ShardedDVyukovMPMCQueue;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 4 shards, 512 capacity per shard (for 4P + 4C workload)
    var queue = try ShardedDVyukovMPMCQueue(u64, 4, 512).init(allocator);
    defer queue.deinit();

    // Each thread gets a shard ID (0-3 for 4 shards)
    const producer_shard_id: usize = 0; // Assign based on thread ID
    const consumer_shard_id: usize = 0; // Same shard for paired producer/consumer

    // Enqueue to specific shard
    try queue.enqueueToShard(producer_shard_id, 42);

    // Dequeue from specific shard
    if (queue.dequeueFromShard(consumer_shard_id)) |item| {
        // Process item
    }
}
```

## Architecture

### Component Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                     DVyukovMPMCQueue(T, N)                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐     │
│  │  Ring Buffer: []Cell                                   │     │
│  │  ┌──────┐  ┌──────┐  ┌──────┐       ┌──────┐           │     │
│  │  │Cell 0│  │Cell 1│  │Cell 2│  ...  │Cell N│           │     │
│  │  └──────┘  └──────┘  └──────┘       └──────┘           │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                 │
│  Producer Side (Cache-line aligned)                             │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ enqueue_pos: Atomic(u64)                                │    │
│  │ _padding1: [cache_line - 8]u8                           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Consumer Side (Cache-line aligned)                             │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ dequeue_pos: Atomic(u64)                                │    │
│  │ _padding2: [cache_line - 8]u8                           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Metadata                                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ mask: usize (N - 1, for fast modulo)                    │    │
│  │ allocator: Allocator                                    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Cell Structure

```
┌─────────────────────────────────────────────────────────┐
│                     Cell                                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  sequence: Atomic(u64) align(cache_line)                │
│  ↓                                                      │
│  Synchronization mechanism:                             │
│  - Even: Cell ready for enqueue                         │
│  - Odd: Cell contains data for dequeue                  │
│                                                         │
│  data: T                                                │
│  ↓                                                      │
│  User data (any type)                                   │
│                                                         │
│  _padding: [calculated]u8                               │
│  ↓                                                      │
│  Ensures total size is multiple of cache line           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Operation Flow

#### Enqueue Flow

```
Producer Thread
      │
      ▼
┌─────────────────────────────────────┐
│ 1. Load current enqueue_pos (CAS)   │
│    pos = enqueue_pos.load()         │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 2. Calculate cell index             │
│    idx = pos & mask                 │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 3. Check sequence number            │
│    seq = cell[idx].sequence.load()  │
│    if seq != pos: retry             │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 4. Try to claim position (CAS)      │
│    if !CAS(enqueue_pos, pos, pos+1) │
│       retry from step 1             │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 5. Write data                       │
│    cell[idx].data = item            │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 6. Publish (release sequence)       │
│    cell[idx].sequence.store(pos+1)  │
└─────────────┬───────────────────────┘
              │
              ▼
          Success
```

#### Dequeue Flow

```
Consumer Thread
      │
      ▼
┌─────────────────────────────────────┐
│ 1. Load current dequeue_pos (CAS)   │
│    pos = dequeue_pos.load()         │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 2. Calculate cell index             │
│    idx = pos & mask                 │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 3. Check sequence number            │
│    seq = cell[idx].sequence.load()  │
│    if seq != pos+1: return null     │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 4. Try to claim position (CAS)      │
│    if !CAS(dequeue_pos, pos, pos+1) │
│       retry from step 1             │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 5. Read data                        │
│    item = cell[idx].data            │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│ 6. Release cell (for reuse)         │
│    cell[idx].sequence.store(        │
│        pos + capacity)              │
└─────────────┬───────────────────────┘
              │
              ▼
       Success (item)
```

## Performance Characteristics

### DVyukovMPMCQueue (Single Queue)

Platform: ARM64 (Apple Silicon)

| Scenario | Threads | Throughput | Latency |
|----------|---------|------------|---------|
| Single-threaded | 1 | 548-580 Mops/s | ~1.7ns |
| SPSC | 2 (1P+1C) | 70-100 Mops/s | 10-14ns |
| MPSC | 8P+1C | 100 Mops/s | 9ns |
| SPMC | 1P+8C | 32 Mops/s | 31ns |
| MPMC (balanced) | 4P+4C | 40 Mops/s | 25ns |
| High contention | 8P+8C | 21 Mops/s | 48ns |

See [BENCHMARKS.md](BENCHMARKS.md) for detailed measurements.

### ShardedDVyukovMPMCQueue (Multiple Queues)

Platform: ARM64 (Apple Silicon)

| Scenario | Configuration | Throughput | Improvement |
|----------|---------------|------------|-------------|
| 4P+4C | 4 shards × 256 capacity ⭐ | 109 Mops/s | **2.7x faster** |
| 8P+8C | 8 shards × 2048 capacity ⭐ | 133 Mops/s | **6.3x faster** |
| 16P+16C | 16 shards × 2048 capacity ⭐ | 82 Mops/s | **~4x faster** |

⭐ = Optimal configuration (1 producer + 1 consumer per shard)

See [BENCHMARKS_SHARDED.md](BENCHMARKS_SHARDED.md) for detailed measurements.

### Optimization Guidelines

**Capacity Sizing:**
- Use 256-2048 for most workloads
- Larger queues reduce contention but increase memory usage
- Always use power-of-2 values

**Retry Strategy:**
```zig
// Short wait (recommended)
queue.enqueue(item) catch {
    std.atomic.spinLoopHint();
    continue;
};

// Longer wait (if fairness needed)
queue.enqueue(item) catch {
    std.Thread.yield() catch {};
    continue;
};
```

**Thread Placement:**
- Bind producer/consumer threads to different CPU cores
- Avoid hyperthreading siblings for best performance

## Testing

The implementation includes 68 tests across three categories:

### Unit Tests (35 tests)
```bash
zig test src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_unit_tests.zig
```

Tests basic operations, edge cases, and type support.

### Fuzz Tests (19 tests)
```bash
zig test src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_fuzz_tests.zig
```

Random operation sequences and stress testing.

### Integration Tests (14 tests)
```bash
zig test src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_integration_tests.zig
```

Multi-threaded correctness and contention scenarios.

### Benchmarks
```bash
zig build-exe src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_benchmarks.zig
./dvyukov_mpmc_queue_benchmarks
```

Results saved to `BENCHMARK_RESULTS.md`.

### Sample Code
```bash
zig run src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_samples.zig
```

## Use Cases

### DVyukovMPMCQueue (Single Queue)

**Ideal for:**
- Work-stealing thread pools (injector queue)
- Task distribution systems with low-moderate contention
- SPSC or low-contention MPMC scenarios
- Simpler code when sharding isn't needed

### ShardedDVyukovMPMCQueue (Multiple Queues)

**Ideal for:**
- High balanced contention (4+ producers AND 4+ consumers)
- Known thread count at initialization
- Static workload where threads maintain shard assignments
- Maximum throughput requirements (100+ Mops/s)

**Example workloads:**
- Multi-core event processing (one shard per core pair)
- Parallel task queues with dedicated producer/consumer pairs
- High-throughput message brokers

### Consider Alternatives For

**Both variants:**
- Unbounded queues (use linked-list based queue)
- Priority queues (use heap-based structure)
- SPSC only (specialized SPSC queues may be marginally faster)

**Sharded variant specifically:**
- Dynamic thread count (unknown at init time)
- Work stealing across arbitrary threads
- Very low contention (overhead not justified)

## Memory Ordering Guarantees

The implementation uses carefully chosen atomic orderings:

- **Producer sequence load:** `.monotonic` (sufficient for position check)
- **Consumer sequence load:** `.acquire` (ensures data visibility)
- **Sequence store:** `.release` (publishes data write)
- **Position CAS:** `.monotonic` (sufficient for ordering)

This ensures:
- All writes to `data` happen-before sequence publish
- All reads from `data` happen-after sequence acquire
- No data races or torn reads

## Comparison with Alternatives

| Feature | DVyukov MPMC | Sharded DVyukov | Mutex Queue | Zig std.atomic.Queue |
|---------|--------------|-----------------|-------------|----------------------|
| Lock-free | Yes | Yes | No | Yes (MPSC only) |
| MPMC support | Yes | Yes | Yes | No (MPSC) |
| Bounded | Yes | Yes | No | No |
| Allocation during ops | No | No | Yes | Yes (nodes) |
| Throughput (4P+4C) | 40 Mops/s | **109 Mops/s** | <10 Mops/s | N/A |
| Throughput (8P+8C) | 21 Mops/s | **133 Mops/s** | <5 Mops/s | N/A |
| Latency | 10-50ns | 7-13ns | >100ns | <50ns (SPSC) |
| Memory usage | O(capacity) | O(shards×capacity) | O(items) | O(items) |
| Complexity | Simple | Requires shard assignment | Simple | Simple |

## Sharded Variant Architecture

The `ShardedDVyukovMPMCQueue` distributes contention across multiple independent queues:

```
┌─────────────────────────────────────────────────────────────┐
│            ShardedDVyukovMPMCQueue(T, N, Cap)               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Shard 0: DVyukovMPMCQueue(T, Cap)                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Producer 0  ⟷  Consumer 0                          │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  Shard 1: DVyukovMPMCQueue(T, Cap)                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Producer 1  ⟷  Consumer 1                          │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ...                                                        │
│                                                             │
│  Shard N-1: DVyukovMPMCQueue(T, Cap)                        │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Producer N-1  ⟷  Consumer N-1                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Benefits:**
- Each shard acts as near-SPSC when paired (1 producer + 1 consumer)
- Eliminates contention on enqueue_pos/dequeue_pos atomics
- Linear scaling with thread count (when threads == shards)
- Simple thread-to-shard assignment (e.g., thread_id % num_shards)

## Additional Documentation

- [BENCHMARKS.md](BENCHMARKS.md) - DVyukovMPMCQueue performance data
- [BENCHMARKS_SHARDED.md](BENCHMARKS_SHARDED.md) - ShardedDVyukovMPMCQueue performance data

## References

- **Original Algorithm:** [Dmitry Vyukov's Bounded MPMC Queue](http://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue)
- **Paper:** "Correct and Efficient Bounded FIFO Queues" by Dmitry Vyukov

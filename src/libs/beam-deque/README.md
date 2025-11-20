# BeamDeque

High-performance bounded work-stealing deque for building task schedulers and thread pools in Zig.

## Overview

Work-stealing is a fundamental pattern in parallel computing where busy threads can "steal" work from idle threads. BeamDeque implements the Arora-Blumofe-Plaxton work-stealing algorithm with extreme performance optimizations.

```
┌─────────────────────────────────────────────────────────────────┐
│                    BeamDeque Architecture                       │
└─────────────────────────────────────────────────────────────────┘

    Owner Thread (Worker)          Thief Threads (Stealers)
         │                                    │
         │ push()                             │ steal()
         ▼                                    ▼
    ┌────────────────────────────────────────────┐
    │     [5]  [4]  [3]  [2]  [1]  [ ]  [ ]     │  Ring Buffer
    └────────────────────────────────────────────┘
         ▲                          ▲
         │                          │
       tail                       head
    (push/pop here)         (steal from here)
         │                          │
         │                          │
    LIFO for owner             FIFO for thieves
    (cache locality)          (work distribution)


    Owner operations:               Thief operations:
    ┌────────────┐                 ┌────────────┐
    │ push(item) │ ~2-5ns          │   steal()  │ ~20-50ns
    │   pop()    │ ~3-10ns         └────────────┘
    └────────────┘
```

## Usage

```zig
const BeamDeque = @import("beam_deque").BeamDeque;

// Initialize with power-of-two capacity
const result = try BeamDeque(*Task).init(allocator, 1024);
defer result.worker.deinit();

// Owner thread - push and pop (LIFO)
try result.worker.push(task);
if (result.worker.pop()) |task| {
    // Process task with cache locality
}

// Thief threads - steal work (FIFO)
// Pass result.stealer to other threads
if (stealer.steal()) |task| {
    // Got work from another thread
}
```

## Features

### Core API

**Initialization:**
- **`BeamDeque(T).init(allocator, capacity)`** - Create deque (capacity must be power-of-two)

**Worker (Owner Thread):**
- **`worker.push(item)`** - Push to bottom (~2-5ns, no CAS)
- **`worker.pop()`** - Pop from bottom (~3-10ns, LIFO for cache locality)
- **`worker.deinit()`** - Free resources
- **`worker.size()`** - Get approximate size (racy)
- **`worker.isEmpty()`** - Check if empty (racy)
- **`worker.capacity()`** - Get capacity

**Stealer (Thief Threads):**
- **`stealer.steal()`** - Steal from top (~20-50ns, FIFO work distribution)
- **`stealer.size()`** - Get approximate size (racy)
- **`stealer.isEmpty()`** - Check if empty (racy)

### Performance Characteristics

- **Owner push**: O(1), ~2-5ns - no CAS, just release store
- **Owner pop**: O(1), ~3-10ns - CAS only for last item race
- **Thief steal**: O(1), ~20-50ns - acquire loads + CAS
- **Cache-line aligned** - head/tail on separate cache lines (no false sharing)
- **Exponential backoff** - reduces contention between competing thieves

### Design Principles

- **SPMC pattern** - Single Producer, Multiple Consumers
- **Bounded capacity** - Fixed-size ring buffer (returns `error.Full`)
- **Arora-Blumofe-Plaxton** - Proven work-stealing algorithm
- **Type safety** - Compile-time error for large types (use pointers instead)
- **Zero allocation** - All operations are wait-free/lock-free

### Common Patterns

```zig
// Pattern 1: Thread pool task queue
const TaskDeque = BeamDeque(*Task);
var result = try TaskDeque.init(allocator, 256);

// Worker thread processes own tasks (LIFO - good for cache)
while (running) {
    if (result.worker.pop()) |task| {
        task.execute();
    } else {
        // No local work, try stealing
        std.Thread.yield();
    }
}

// Pattern 2: Recursive work splitting (divide-and-conquer)
fn processRecursive(deque: *Worker, work: Work) !void {
    if (work.size < THRESHOLD) {
        work.process();
        return;
    }

    // Split work
    const left, const right = work.split();

    // Push right half for potential stealing
    try deque.push(right);

    // Process left half immediately (cache-friendly)
    try processRecursive(deque, left);

    // Reclaim right half if not stolen
    if (deque.pop()) |right_work| {
        try processRecursive(deque, right_work);
    }
}

// Pattern 3: Multi-thief work stealing scheduler
fn thief_worker(stealer: Stealer, workers: []Stealer) void {
    while (running) {
        // Try stealing from all workers in round-robin
        for (workers) |other| {
            if (other.steal()) |task| {
                task.execute();
                break;
            }
        }
        std.Thread.yield();
    }
}
```

## BeamDequeChannel - MPMC Work-Stealing Channel

**BeamDequeChannel** is a higher-level abstraction built on BeamDeque that provides a simple MPMC (Multiple Producer, Multiple Consumer) channel with automatic work-stealing and load balancing.

### Architecture

```
┌────────────────────────────────────────────────────────────┐
│              BeamDequeChannel Architecture                 │
└────────────────────────────────────────────────────────────┘

Worker 0          Worker 1          Worker 2          Worker N
  │                 │                 │                 │
  │ send()          │ send()          │ send()          │ send()
  ▼                 ▼                 ▼                 ▼
┌──────┐        ┌──────┐        ┌──────┐        ┌──────┐
│Deque │        │Deque │        │Deque │   ...  │Deque │  Local
│ [5] │        │ [3] │        │ [8] │        │ [2] │  Deques
└──────┘        └──────┘        └──────┘        └──────┘  (Fast Path)
  │  ▲            │  ▲            │  ▲            │  ▲
  │  └────────────┼──┼────────────┼──┘  Steal    │  │
  │               │  │            │  ◄────────────┘  │
  │               │  │            │                  │
  └───────────────┴──┴────────────┴──────────────────┘
                     │
                     ▼
              ┌──────────────┐
              │Global Queue  │  Overflow
              │[items...]    │  (Safety Valve)
              └──────────────┘

recv() priority:
  1. Local deque (LIFO, cache-friendly)
  2. Global queue (FIFO, shared work)
  3. Steal from random worker (FIFO, load balancing)
```

### Key Features

- **Zero-contention fast path**: Each worker sends to its own local deque
- **Automatic load balancing**: Idle workers steal from busy workers
- **Back-pressure**: Bounded capacity with `error.Full` when saturated
- **Work-stealing**: Random victim selection distributes stealing load evenly

### Usage

```zig
const BeamDequeChannel = @import("beam_deque_channel").BeamDequeChannel;

// Create channel with 8 workers, local capacity 256, global capacity 4096
const Channel = BeamDequeChannel(*Task, 256, 4096);
var result = try Channel.init(allocator, 8);
defer result.channel.deinit(&result.workers);

// Producer thread (any worker can send)
try result.workers[0].send(task);

// Consumer thread (any worker can receive)
if (result.workers[1].recv()) |task| {
    // Process task with cache locality
}
```

### Performance Characteristics

- **Send fast path**: ~5-15ns (local deque push, no contention)
- **Send slow path**: ~50-100ns (batch offload to global queue when local is full)
- **Recv from local**: ~5-15ns (LIFO pop, excellent cache locality)
- **Recv from global**: ~30-60ns (FIFO dequeue from shared queue)
- **Recv via steal**: ~40-80ns (FIFO steal from random victim)

### Learn More

See [docs/BEAM_DEQUE_CHANNEL.md](docs/BEAM_DEQUE_CHANNEL.md) for detailed architecture and implementation design.

## Build Commands

```bash
# Run BeamDeque tests
zig build test-beam-deque

# Run BeamDeque benchmarks
zig build bench-beam-deque -Doptimize=ReleaseFast

# Run BeamDequeChannel tests
zig build test-beam-deque-channel

# Run BeamDequeChannel benchmarks
zig build bench-beam-deque-channel -Doptimize=ReleaseFast

# Run BeamDequeChannel V2 benchmarks (optimized usage patterns)
zig build bench-beam-deque-channel-v2 -Doptimize=ReleaseFast
```

## Requirements

- **Zig version**: 0.13.0 or later
- **Platform**: Any platform supported by Zig's standard library
- **Dependencies**: Part of [zig-beam](https://github.com/eakova/zig-beam)
- **Constraints**: Capacity must be power-of-two, types > 64 bytes must be pointers

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](../../../LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

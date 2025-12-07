# Zig-Beam Library Overview

A collection of lock-free, high-performance concurrent data structures and utilities for Zig. Each library ships with tests, benchmarks, and detailed implementation documentation.

---

## Library Index

### Parallelism

#### Loom
High-performance work-stealing thread pool with structured concurrency. Provides Rayon-like data parallelism with parallel iterators (`par_iter`, `par_range`), fork-join primitives (`join`, `scope`), and context API for shared state.

- [README](../src/libs/loom/README.md)
- [Implementation](../src/libs/loom/docs/LOOM_IMPLEMENTATION.md)
- Source: [`loom.zig`](../src/libs/loom/src/loom.zig)

---

### Concurrent Data Structures

#### Deque
Lock-free work-stealing deque based on Chase-Lev algorithm with acquire-release ordering. Owner pushes/pops from bottom; stealers steal from top with minimal contention.

- [README](../src/libs/deque/README.md)
- [Implementation](../src/libs/deque/docs/DEQUE_IMPLEMENTATION.md)
- Source: [`deque.zig`](../src/libs/deque/deque.zig)

#### DequeChannel
Multi-producer work-stealing channel combining injector queue with per-worker deques. Supports external task injection and stealing from other workers' deques.

- [README](../src/libs/deque/README.md)
- [Implementation](../src/libs/deque/docs/DEQUE_CHANNEL_IMPLEMENTATION.md)
- Source: [`deque_channel.zig`](../src/libs/deque/deque_channel.zig)

#### DVyukovMPMCQueue
Bounded, lock-free multi-producer multi-consumer queue using Vyukov's sequence-based algorithm. Achieves high throughput with power-of-two capacity and cache-line padding.

- [README](../src/libs/dvyukov-mpmc/README.md)
- [Implementation](../src/libs/dvyukov-mpmc/docs/DVYUKOVMPMCQUEUE_IMPLEMENTATION.md)
- Source: [`dvyukov_mpmc_queue.zig`](../src/libs/dvyukov-mpmc/dvyukov_mpmc_queue.zig)

#### ShardedDVyukovMPMCQueue
Thread-affinity sharded wrapper over DVyukovMPMCQueue for reduced cross-core contention. Each thread prefers its own shard with fallback stealing from other shards.

- [README](../src/libs/dvyukov-mpmc/README.md)
- [Implementation](../src/libs/dvyukov-mpmc/docs/SHARDEDDVYUKOVMPMCQUEUE_IMPLEMENTATION.md)
- Source: [`sharded_dvyukov_mpmc_queue.zig`](../src/libs/dvyukov-mpmc/sharded_dvyukov_mpmc_queue.zig)

#### SegmentedQueue
Unbounded MPMC queue built from linked DVyukovMPMCQueue segments with EBR-protected reclamation. Combines bounded queue performance with dynamic growth.

- [Implementation](../src/libs/segmented-queue/docs/SEGMENTEDQUEUE_IMPLEMENTATION.md)
- Source: [`segmented_queue.zig`](../src/libs/segmented-queue/segmented_queue.zig)

---

### Memory Management

#### Arc
Thread-safe atomic reference counting with Small Value Optimization (SVO) for values <= 6 bytes. Supports weak references, custom release callbacks, and optional cycle detection.

- [README](../src/libs/arc/README.md)
- [Implementation](../src/libs/arc/docs/ARC_IMPLEMENTATION.md)
- Source: [`arc.zig`](../src/libs/arc/arc.zig)

#### ArcPool
Multi-layer object pool (TLS cache + Treiber stack + allocator fallback) that recycles Arc inner blocks. Reduces allocation pressure for frequently created/destroyed Arc instances.

- [README](../src/libs/arc/arc-pool/README.md)
- [Implementation](../src/libs/arc/docs/ARC_POOL_IMPLEMENTATION.md)
- Source: [`arc_pool.zig`](../src/libs/arc/arc-pool/arc_pool.zig)

#### ArcCycleDetector
Debug-only tracing utility to detect reference cycles in Arc graphs. Tracks acquire/release events and identifies unreachable cycles via mark-and-sweep.

- [README](../src/libs/arc/cycle-detector/README.md)
- [Implementation](../src/libs/arc/docs/ARC_CYCLE_DETECTOR_IMPLEMENTATION.md)
- Source: [`arc_cycle_detector.zig`](../src/libs/arc/cycle-detector/arc_cycle_detector.zig)

#### ThreadLocalCache
Lock-free, per-thread L1/L2 cache hierarchy that reduces allocator contention. Three factory variants for different capacity and configuration needs.

- [README](../src/libs/thread-local-cache/README.md)
- [Implementation](../src/libs/thread-local-cache/docs/THREADLOCALCACHE_IMPLEMENTATION.md)
- Source: [`thread_local_cache.zig`](../src/libs/thread-local-cache/thread_local_cache.zig)

#### GlobalEpoch (EBR)
Epoch-Based Reclamation for safe memory deallocation in lock-free data structures. Defers destruction until all threads have advanced past the retirement epoch.

- [README](../src/libs/ebr/README.md)
- [Implementation](../src/libs/ebr/docs/EBR_IMPLEMENTATION.md)
- Source: [`ebr.zig`](../src/libs/ebr/ebr.zig)

---

### Threading

#### Task
Cancellable OS-thread abstraction with cooperative cancellation via CancellationToken. Worker functions can sleep interruptibly and check cancellation status.

- [README](../src/libs/task/README.md)
- [Implementation](../src/libs/task/docs/TASK_IMPLEMENTATION.md)
- Source: [`task.zig`](../src/libs/task/task.zig)

---

### Core Primitives

#### Backoff
Adaptive exponential backoff (Crossbeam-style) with spin-then-yield strategy for contention handling. Configurable spin/yield limits for tuning to different workloads.

- [Implementation](../src/libs/backoff/docs/BACKOFF_IMPLEMENTATION.md)
- Source: [`backoff.zig`](../src/libs/backoff/backoff.zig)

#### CachePadded
Align data to cache line boundaries to prevent false sharing between threads. Essential building block for all lock-free data structures in this library.

- [Implementation](../src/libs/cache-padded/docs/CACHE_PADDED_IMPLEMENTATION.md)
- Source: [`cache_padded.zig`](../src/libs/cache-padded/cache_padded.zig)

#### TaggedPointer
Pack a small tag (1-3 bits) into a pointer's unused alignment bits for zero-cost discriminators. Used internally by Arc for inline/heap representation flags.

- [README](../src/libs/tagged-pointer/README.md)
- [Implementation](../src/libs/tagged-pointer/docs/TAGGEDPOINTER_IMPLEMENTATION.md)
- Source: [`tagged_pointer.zig`](../src/libs/tagged-pointer/tagged_pointer.zig)

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zigbeam = .{
        .url = "https://github.com/eakova/zigbeam/archive/refs/heads/main.tar.gz",
        .hash = "<run: zig fetch <url> --save>",
    },
},
```

Wire in `build.zig`:

```zig
const dep = b.dependency("zigbeam", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigbeam", dep.module("zigbeam"));
```

### Usage

```zig
const beam = @import("zigbeam");

// Access libraries
const Loom = beam.Libs.Loom;
const Deque = beam.Libs.Deque;
const DVyukovMPMCQueue = beam.Libs.DVyukovMPMCQueue;
const Arc = beam.Libs.Arc;
const ThreadLocalCache = beam.Libs.ThreadLocalCache;
const Task = beam.Libs.Task;

// Parallel iteration with Loom
const loom = @import("loom");
loom.par_iter(data).for_each(process);
const sum = loom.par_iter(data).reduce(loom.Reducer(i64).sum());
```

---

## Commands

See [BUILD_COMMANDS.md](../BUILD_COMMANDS.md) for all available build, test, and benchmark commands.

---

## Compatibility

- **OS:** macOS, Linux, Windows
- **Zig:** 0.13.0 or later
- **Dependencies:** Standard library only (`std.Thread`, `std.atomic`, `std.time`)

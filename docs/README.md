# Zig-Beam Library Overview

A collection of lock-free, high-performance concurrent data structures and utilities for Zig. Each library ships with tests, benchmarks, and detailed implementation documentation.

---

## Library Index

### Core Primitives

#### TaggedPointer
Pack a small tag (1-3 bits) into a pointer's unused alignment bits for zero-cost discriminators. Used internally by Arc for inline/heap representation flags.

- [README](../src/libs/beam-tagged-pointer/README.md)
- [Implementation](../src/libs/beam-tagged-pointer/docs/TAGGEDPOINTER_IMPLEMENTATION.md)
- Source: [`tagged_pointer.zig`](../src/libs/beam-tagged-pointer/tagged_pointer.zig)

#### CachePadded
Align data to cache line boundaries to prevent false sharing between threads. Essential building block for all lock-free data structures in this library.

- [Implementation](../src/libs/beam-cache-padded/docs/CACHE_PADDED_IMPLEMENTATION.md)
- Source: [`cache_padded.zig`](../src/libs/beam-cache-padded/cache_padded.zig)

#### Backoff
Adaptive exponential backoff (Crossbeam-style) with spin-then-yield strategy for contention handling. Configurable spin/yield limits for tuning to different workloads.

- [Implementation](../src/libs/beam-backoff/docs/BACKOFF_IMPLEMENTATION.md)
- Source: [`backoff.zig`](../src/libs/beam-backoff/backoff.zig)

---

### Memory Management

#### Arc
Thread-safe atomic reference counting with Small Value Optimization (SVO) for values <= 6 bytes. Supports weak references, custom release callbacks, and optional cycle detection.

- [README](../src/libs/beam-arc/README.md)
- [Implementation](../src/libs/beam-arc/docs/ARC_IMPLEMENTATION.md)
- Source: [`arc.zig`](../src/libs/beam-arc/arc.zig)

#### ArcPool
Multi-layer object pool (TLS cache + Treiber stack + allocator fallback) that recycles Arc inner blocks. Reduces allocation pressure for frequently created/destroyed Arc instances.

- [README](../src/libs/beam-arc/arc-pool/README.md)
- [Implementation](../src/libs/beam-arc/docs/ARC_POOL_IMPLEMENTATION.md)
- Source: [`arc_pool.zig`](../src/libs/beam-arc/arc-pool/arc_pool.zig)

#### ArcCycleDetector
Debug-only tracing utility to detect reference cycles in Arc graphs. Tracks acquire/release events and identifies unreachable cycles via mark-and-sweep.

- [README](../src/libs/beam-arc/cycle-detector/README.md)
- [Implementation](../src/libs/beam-arc/docs/ARC_CYCLE_DETECTOR_IMPLEMENTATION.md)
- Source: [`arc_cycle_detector.zig`](../src/libs/beam-arc/cycle-detector/arc_cycle_detector.zig)

#### ThreadLocalCache
Lock-free, per-thread L1/L2 cache hierarchy that reduces allocator contention. Three factory variants for different capacity and configuration needs.

- [README](../src/libs/beam-thread-local-cache/README.md)
- [Implementation](../src/libs/beam-thread-local-cache/docs/THREADLOCALCACHE_IMPLEMENTATION.md)
- Source: [`thread_local_cache.zig`](../src/libs/beam-thread-local-cache/thread_local_cache.zig)

#### GlobalEpoch (EBR)
Epoch-Based Reclamation for safe memory deallocation in lock-free data structures. Defers destruction until all threads have advanced past the retirement epoch.

- [README](../src/libs/beam-ebr/README.md)
- [Implementation](../src/libs/beam-ebr/docs/GLOBALEPOCH_IMPLEMENTATION.md)
- Source: [`ebr.zig`](../src/libs/beam-ebr/ebr.zig)

---

### Concurrent Data Structures

#### Deque
Lock-free work-stealing deque based on Chase-Lev algorithm with acquire-release ordering. Owner pushes/pops from bottom; stealers steal from top with minimal contention.

- [README](../src/libs/beam-deque/README.md)
- [Implementation](../src/libs/beam-deque/docs/DEQUE_IMPLEMENTATION.md)
- Source: [`beam_deque.zig`](../src/libs/beam-deque/beam_deque.zig)

#### DequeChannel
Multi-producer work-stealing channel combining injector queue with per-worker deques. Supports external task injection and stealing from other workers' deques.

- [README](../src/libs/beam-deque/README.md)
- [Implementation](../src/libs/beam-deque/docs/DEQUE_CHANNEL_IMPLEMENTATION.md)
- Source: [`beam_deque_channel.zig`](../src/libs/beam-deque/beam_deque_channel.zig)

#### DVyukovMPMCQueue
Bounded, lock-free multi-producer multi-consumer queue using Vyukov's sequence-based algorithm. Achieves high throughput with power-of-two capacity and cache-line padding.

- [README](../src/libs/beam-dvyukov-mpmc-queue/README.md)
- [Implementation](../src/libs/beam-dvyukov-mpmc-queue/docs/DVYUKOVMPMCQUEUE_IMPLEMENTATION.md)
- Source: [`dvyukov_mpmc_queue.zig`](../src/libs/beam-dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig)

#### ShardedDVyukovMPMCQueue
Thread-affinity sharded wrapper over DVyukovMPMCQueue for reduced cross-core contention. Each thread prefers its own shard with fallback stealing from other shards.

- [README](../src/libs/beam-dvyukov-mpmc-queue/README.md)
- [Implementation](../src/libs/beam-dvyukov-mpmc-queue/docs/SHARDEDDVYUKOVMPMCQUEUE_IMPLEMENTATION.md)
- Source: [`sharded_dvyukov_mpmc_queue.zig`](../src/libs/beam-dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig)

#### SegmentedQueue
Unbounded MPMC queue built from linked DVyukovMPMCQueue segments with EBR-protected reclamation. Combines bounded queue performance with dynamic growth.

- [Implementation](../src/libs/beam-segmented-queue/docs/SEGMENTEDQUEUE_IMPLEMENTATION.md)
- Source: [`segmented_queue.zig`](../src/libs/beam-segmented-queue/segmented_queue.zig)

#### BoundedSPSCQueue
Ultra-fast single-producer single-consumer queue with zero CAS on the hot path. Achieves ~5-10ns per operation through strict role separation and cache-line isolation.

- [Implementation](../src/libs/spsc-queue/docs/BOUNDEDSPSCQUEUE_IMPLEMENTATION.md)
- Source: [`spsc_queue.zig`](../src/libs/spsc-queue/spsc_queue.zig)

---

### Threading

#### Task
Cancellable OS-thread abstraction with cooperative cancellation via CancellationToken. Worker functions can sleep interruptibly and check cancellation status.

- [README](../src/libs/beam-task/README.md)
- [Implementation](../src/libs/beam-task/docs/TASK_IMPLEMENTATION.md)
- Source: [`task.zig`](../src/libs/beam-task/task.zig)

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zigbeam = .{
        .url = "https://github.com/eakova/zig-beam/archive/refs/heads/main.tar.gz",
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
const Arc = beam.Libs.Arc;
const Deque = beam.Libs.Deque;
const DVyukovMPMCQueue = beam.Libs.DVyukovMPMCQueue;
const ThreadLocalCache = beam.Libs.ThreadLocalCache;
const Task = beam.Libs.Task;
```

---

## Commands

See [BUILD_COMMANDS.md](../BUILD_COMMANDS.md) for all available build, test, and benchmark commands.

---

## Compatibility

- **OS:** macOS, Linux, Windows
- **Zig:** 0.15.x
- **Dependencies:** Standard library only (`std.Thread`, `std.atomic`, `std.time`)

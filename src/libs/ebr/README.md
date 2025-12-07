# EBR (Epoch-Based Reclamation)

High-performance, lock-free memory reclamation for building concurrent data structures in Zig.

## Overview

Epoch-Based Reclamation (EBR) solves the fundamental problem in lock-free programming: safely reclaiming memory that might still be accessed by concurrent readers. EBR provides a simple, efficient solution with minimal overhead.

```
┌────────────────────────────────────────────────────────────┐
│                     EBR Architecture                       │
└────────────────────────────────────────────────────────────┘

                    Global Epoch: 2
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
   ┌─────────┐       ┌─────────┐       ┌─────────┐
   │Thread 1 │       │Thread 2 │       │Thread 3 │
   │ epoch=2 │       │ epoch=2 │       │  idle   │
   │ PINNED  │       │ PINNED  │       │         │
   └────┬────┘       └────┬────┘       └────┬────┘
        │                 │                 │
        ▼                 ▼                 ▼
   ┌─────────┐       ┌─────────┐       ┌─────────┐
   │ Garbage │       │ Garbage │       │ Garbage │
   │  Bag    │       │  Bag    │       │  Bag    │
   └─────────┘       └─────────┘       └─────────┘

   Safe Epoch: 0  (objects from epoch 0 can be reclaimed)


   Thread operations:          Collector operations:
   ───────────────────         ─────────────────────
   pin()    ~2-5ns             deferReclaim()  O(1)
   unpin()  ~2-3ns             collect()       O(n)
```

## Usage

```zig
const ebr = @import("ebr");

// Create a collector (one per application)
var collector = try ebr.Collector.init(allocator);
defer collector.deinit();

// Register thread (required before using EBR)
const handle = try collector.registerThread();
defer collector.unregisterThread(handle);

// Enter critical section
const guard = collector.pin();
defer guard.unpin();

// Safe to access shared data here - protected from reclamation
const data = shared_ptr.load(.acquire);
// ... use data safely ...
```

## Features

### Core API

**Collector (Central Coordinator):**
- **`Collector.init(allocator)`** - Create a collector
- **`collector.deinit()`** - Destroy collector (all threads must be unregistered)
- **`collector.registerThread()`** - Register calling thread (~50ns, once per thread)
- **`collector.unregisterThread(handle)`** - Unregister thread
- **`collector.pin()`** - Enter critical section (~2-5ns)
- **`collector.pinFast()`** - Ultra-fast pin, no nesting support (~1-2ns)
- **`collector.deferReclaim(ptr, dtor)`** - Defer destruction with custom destructor
- **`collector.deferDestroy(T, ptr)`** - Zero-allocation defer for types with `allocator` field
- **`collector.collect()`** - Trigger garbage collection
- **`collector.tryAdvanceEpoch()`** - Try to advance global epoch

**Guard (Critical Section):**
- **`guard.unpin()`** - Exit critical section (~2-3ns)
- **`guard.isValid()`** - Check if guard is valid

**FastGuard (Maximum Throughput):**
- **`fast_guard.unpin()`** - Ultra-fast unpin (~1ns, no nesting support)

### Performance Characteristics

- **pin()**: ~2-5ns - single atomic store + threadlocal read
- **unpin()**: ~2-3ns - single atomic store
- **pinFast()/unpinFast()**: ~1-2ns - eliminates threadlocal read
- **deferReclaim()**: O(1) amortized - epoch-bucketed garbage bag
- **Epoch advancement**: Lock-free CAS, probabilistic sampling reduces contention
- **Memory overhead**: <32 bytes per deferred object

### Configuration

```zig
// Default configuration (good for 8-16 threads)
var collector = try ebr.Collector.init(allocator);

// Custom configuration for high scalability (32+ threads)
const ScalableCollector = ebr.CollectorType(.{
    .epoch_advance_sample_rate = 8,  // 12.5% sampling (reduces contention)
    .batch_threshold = 128,           // larger batches (less frequent collection)
});
var collector = try ScalableCollector.init(allocator);
```

| Config Option | Default | Description |
|---------------|---------|-------------|
| `epoch_advance_sample_rate` | 4 | 1 in N collections try epoch advance |
| `batch_threshold` | 64 | Objects before triggering collection |

### Design Principles

- **Per-Collector epochs** - No global singleton, supports multiple isolated collectors
- **Combined epoch+active flag** - Single atomic eliminates SeqCst fence
- **Cache-line alignment** - Prevents false sharing between threads
- **Epoch-bucketed garbage** - O(1) reclamation of entire epochs
- **Probabilistic sampling** - Reduces mutex contention at scale
- **Zero-allocation defer** - `deferDestroy` for types with embedded allocator

### Common Patterns

```zig
// Pattern 1: Lock-free stack with safe reclamation
pub const LockFreeStack = struct {
    head: std.atomic.Value(?*Node),
    collector: *ebr.Collector,
    allocator: std.mem.Allocator,

    pub fn pop(self: *LockFreeStack) ?i32 {
        const guard = self.collector.pin();
        defer guard.unpin();

        var current = self.head.load(.acquire);
        while (current) |node| {
            const next = node.next.load(.acquire);
            if (self.head.cmpxchgWeak(current, next, .release, .monotonic)) |actual| {
                current = actual;
            } else {
                const value = node.value;
                // Safe deferred destruction
                self.collector.deferDestroy(Node, node);
                return value;
            }
        }
        return null;
    }
};

// Pattern 2: Read-heavy concurrent map
fn lookup(map: *ConcurrentMap, key: u64) ?*Value {
    const guard = map.collector.pin();
    defer guard.unpin();

    // Safe to traverse - nodes won't be freed while pinned
    var node = map.buckets[hash(key) % map.buckets.len].load(.acquire);
    while (node) |n| {
        if (n.key == key) return &n.value;
        node = n.next.load(.acquire);
    }
    return null;
}

// Pattern 3: Batch operations with single guard
fn processBatch(collector: *ebr.Collector, items: []Item) void {
    const guard = collector.pin();
    defer guard.unpin();

    for (items) |item| {
        // All operations protected by single guard
        processItem(item);
    }
}

// Pattern 4: Custom destructor
fn customDtor(ptr: *anyopaque) void {
    const node: *MyNode = @ptrCast(@alignCast(ptr));
    node.cleanup();  // Custom cleanup logic
    global_allocator.destroy(node);
}

collector.deferReclaim(@ptrCast(node), customDtor);
```

## How EBR Works

1. **Global Epoch**: A monotonically increasing counter shared by all threads
2. **Pin**: Thread records current epoch, marking itself as "active"
3. **Unpin**: Thread clears active flag, allowing epoch to advance
4. **Defer**: Objects are tagged with current epoch and added to garbage bag
5. **Reclaim**: Objects are freed when ALL threads have advanced past their epoch

**Safety Guarantee**: An object deferred at epoch N is only freed after the global epoch reaches N+2 AND all threads have unpinned from epochs ≤ N.

## Build Commands

```bash
# Run EBR unit tests
zig build test-ebr-unit

# Run EBR integration tests
zig build test-ebr-integration

# Run EBR stress tests
zig build test-ebr-stress

# Run all EBR tests
zig build test-ebr

# Run EBR benchmarks
zig build bench-ebr -Doptimize=ReleaseFast

# Run EBR samples
zig build samples-ebr
```

## Requirements

- **Zig version**: 0.13.0 or later
- **Platform**: Any platform supported by Zig's standard library
- **Dependencies**: Part of [zig-beam](https://github.com/eakova/zig-beam)
- **Constraints**: Types using `deferDestroy` must have an `allocator` field

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](../../../LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

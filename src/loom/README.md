# Loom

High-performance work-stealing thread pool with structured concurrency for building parallel applications in Zig.

## Overview

Loom provides Rayon-like data parallelism with a layered architecture: primitives (Deque, DequeChannel), thread pool infrastructure, fork-join primitives, and parallel iterators.

```
+---------------------------------------------------------------------+
|                        Loom Architecture                            |
+---------------------------------------------------------------------+

                    +---------------------------------------+
                    |         Global MPMC Queue             |
                    |  (overflow + external thread access)  |
                    +------------------+--------------------+
                                       |
        +------------------------------+------------------------------+
        |                              |                              |
        v                              v                              v
+---------------+              +---------------+              +---------------+
|   Worker 0    |              |   Worker 1    |              |   Worker N    |
| +-----------+ |              | +-----------+ |              | +-----------+ |
| |Local Deque| | <--steal-->  | |Local Deque| | <--steal-->  | |Local Deque| |
| |(push/pop) | |              | |(push/pop) | |              | |(push/pop) | |
| +-----------+ |              | +-----------+ |              | +-----------+ |
+---------------+              +---------------+              +---------------+

    Owner operations:               Thief operations:
    +----------------+              +------------------+
    | spawn() ~5-10ns|              | steal() ~20-50ns |
    | pop()   ~3-10ns|              +------------------+
    +----------------+


Layer 4: par_iter()    -> Parallel iterators (map, reduce, filter, for_each)
Layer 3: join/scope    -> Fork-join primitives (structured concurrency)
Layer 2: ThreadPool    -> Work-stealing thread pool
Layer 1: Deque/Channel -> Lock-free primitives (from beam libs)
```

## Usage

```zig
const loom = @import("loom");

// Binary fork-join (divide-and-conquer)
const left, const right = loom.join(
    computeLeft, .{data[0..mid]},
    computeRight, .{data[mid..]},
);

// Scoped spawning (structured concurrency)
loom.scope(struct {
    fn body(s: *loom.Scope) void {
        for (items) |item| {
            s.spawn(process, .{item});
        }
    }
}.body);

// Parallel iteration
loom.par_iter(items).for_each(process);
const sum = loom.par_iter(items).reduce(loom.Reducer(i64).sum());
```

## Features

### Core API

**ThreadPool:**
- **`ThreadPool.init(allocator, config)`** - Create pool with configurable threads/backoff
- **`pool.spawn(task)`** - Submit task (~5-10ns from worker, ~20-50ns external)
- **`pool.deinit()`** - Shutdown and free resources
- **`getGlobalPool()`** - Get/create default global pool

**Fork-Join:**
- **`join(fn_a, args_a, fn_b, args_b)`** - Binary fork-join
- **`joinOnPool(pool, ...)`** - Fork-join on specific pool
- **`scope(body_fn)`** - Structured concurrency container
- **`scopeOnPool(pool, body_fn)`** - Scope on specific pool

**Parallel Iterators:**
- **`par_iter(slice)`** - Parallel iterator over mutable slice
- **`par_iter_const(slice)`** - Parallel iterator over const slice
- **`par_range(start, end)`** - Zero-allocation range iterator

### Performance Characteristics

| Operation | Latency | Description |
|-----------|---------|-------------|
| Task spawn (worker) | ~5-10ns | Local deque push, no CAS |
| Task spawn (external) | ~20-50ns | Global queue enqueue |
| Task receive | ~10-50ns | Local pop -> global -> steal |
| join() | ~overhead + work | Spawn right, run left locally |
| scope.spawn() | ~50-100ns | Arena alloc + pool spawn |
| par_iter().for_each() | ~overhead + work | Chunk + parallel spawn |

### Design Principles

- **Work-stealing pattern** - Busy threads steal from idle threads
- **Steal-while-wait** - Waiting threads help execute other tasks
- **Type-erased tasks** - 24 bytes (fn ptr + context + scope)
- **Sharded arenas** - One arena per worker eliminates contention
- **Adaptive splitting** - 2x oversubscription with configurable min chunk
- **Cache locality** - LIFO for owner, FIFO for thieves

### Common Patterns

```zig
// Pattern 1: Parallel sum with reduction
const sum = loom.par_iter(numbers)
    .reduce(loom.Reducer(i64).sum());

// Pattern 2: Parallel transformation
const doubled = try loom.par_iter(numbers)
    .map(i64, struct {
        fn double(x: i64) i64 { return x * 2; }
    }.double, allocator);
defer allocator.free(doubled);

// Pattern 3: Divide-and-conquer (parallel quicksort)
fn parallelSort(data: []i32) void {
    if (data.len < 1000) {
        std.sort.pdq(i32, data, {}, std.sort.asc(i32));
        return;
    }
    const pivot = partition(data);
    loom.join(
        parallelSort, .{data[0..pivot]},
        parallelSort, .{data[pivot..]},
    );
}

// Pattern 4: Context-based parallel processing
const Context = struct {
    threshold: f64,
    counter: *std.atomic.Value(usize),
};

var count = std.atomic.Value(usize).init(0);
const ctx = Context{ .threshold = 100.0, .counter = &count };

loom.par_iter(data)
    .withContext(&ctx)
    .forEach(struct {
        fn check(c: *const Context, value: *f64) void {
            if (value.* > c.threshold) {
                _ = c.counter.fetchAdd(1, .monotonic);
            }
        }
    }.check);

// Pattern 5: Parallel file processing with par_range
loom.par_range(0, num_chunks)
    .withContext(&read_ctx)
    .forEach(struct {
        fn readChunk(ctx: *const ReadContext, chunk_idx: usize) void {
            const start = chunk_idx * ctx.chunk_size;
            _ = ctx.file_handle.pread(ctx.buffer[start..], start) catch {};
        }
    }.readChunk);
```

## Parallel Iterator API

### Methods

```zig
par_iter(slice)
    .withMinChunk(1000)      // Sequential threshold
    .withMaxChunks(8)        // Cap parallelism
    .withPool(custom_pool)   // Use specific pool
    .withContext(&ctx)       // Pass shared context
    .withAlloc(allocator)    // For filter/map

    // Terminal operations:
    .for_each(fn)            // Apply to each element
    .reduce(Reducer)         // Combine all elements
    .map(T, fn, allocator)   // Transform elements
    .filter(pred, allocator) // Select elements
    .find(pred)              // First match
    .all(pred)               // All match?
    .any(pred)               // Any match?
    .count(pred)             // Count matches
```

### Context-Aware Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `forEach` | `fn(Ctx, *T) void` | Apply to each element |
| `forEachIndexed` | `fn(Ctx, usize, *T) void` | Apply with index |
| `count` | `fn(Ctx, T) bool` | Count matching elements |
| `any` | `fn(Ctx, T) bool` | Check if any match |
| `all` | `fn(Ctx, T) bool` | Check if all match |
| `find` | `fn(Ctx, T) bool` | Find first match |
| `map` | `fn(Ctx, T) U` | Transform elements |
| `mapIndexed` | `fn(Ctx, usize, T) U` | Transform with index |
| `filter` | `fn(Ctx, T) bool` | Select matching |
| `chunks` | `fn(Ctx, usize, []T) void` | Process mutable chunks |
| `chunksConst` | `fn(Ctx, usize, []const T) void` | Process const chunks |

### Reducers

```zig
Reducer(i64).sum()      // Identity: 0, combine: +
Reducer(i64).product()  // Identity: 1, combine: *
Reducer(i32).min()      // Identity: maxInt, combine: @min
Reducer(i32).max()      // Identity: minInt, combine: @max
BoolReducer.all()       // Identity: true, combine: and
BoolReducer.any()       // Identity: false, combine: or
```

## Configuration

### Thread Pool

```zig
const pool = try ThreadPool.init(allocator, .{
    .num_threads = 8,              // null = CPU count
    .backoff_mode = .balanced,     // .low_latency, .balanced, .power_saving
});
defer pool.deinit();
```

### BackoffMode Presets

| Mode | Use Case | Spin | Sleep |
|------|----------|------|-------|
| `low_latency` | Real-time, gaming | 64 | 100us |
| `balanced` | General purpose | 32 | 1ms |
| `power_saving` | Background tasks | 8 | 10ms |

### Splitter Config

```zig
Splitter.default()        // adaptive(1024)
Splitter.fixed(100)       // Fixed chunk size
Splitter.adaptive(1000)   // Adaptive with min 1000
Splitter.recursive(256)   // For divide-and-conquer
```

## Thread Safety

Context is shared across all worker threads:

- **Read-only fields**: No synchronization needed
- **Counters**: Use `std.atomic.Value(T)` with `.monotonic`
- **Complex mutations**: Use mutexes
- **Best performance**: Thread-local accumulation with final merge

## Build Commands

```bash
# Run Loom tests
zig build test-loom

# Run Loom benchmarks
zig build bench-loom -Doptimize=ReleaseFast

# Run Loom samples (API showcase)
zig build samples-loom
```

## Requirements

- **Zig version**: 0.13.0 or later
- **Platform**: Any platform supported by Zig's standard library
- **Dependencies**: Part of [zig-beam](https://github.com/eakova/zig-beam)
- **Primitives**: Uses beam-deque and beam-deque-channel

## See Also

- [LOOM_IMPLEMENTATION.md](docs/LOOM_IMPLEMENTATION.md) - Architecture and design
- [loom_api_showcase.zig](samples/loom_api_showcase.zig) - Comprehensive API examples

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](../../../LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

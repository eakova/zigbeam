# Loom - Work-Stealing Thread Pool with Structured Concurrency

A high-performance work-stealing thread pool enabling Rayon-like data parallelism in Zig.

---

## 1. Architecture

### 1.1 Layered Design

| Layer | Components | Purpose |
|-------|------------|---------|
| **Layer 1** | `Deque`, `DequeChannel`, `Backoff` | Primitives (from beam libs) |
| **Layer 2** | `ThreadPool`, `Worker`, `Task` | Thread pool infrastructure |
| **Layer 3** | `join()`, `scope()`, `spawn()` | Fork-join primitives |
| **Layer 4** | `par_iter()`, `map()`, `reduce()`, `filter()` | Parallel iterators |

### 1.2 Core Components

| Component | Description |
|-----------|-------------|
| **Task** | Type-erased unit of work (24 bytes: fn ptr + context + scope) |
| **ThreadPool** | Fixed worker threads with work-stealing via DequeChannel |
| **Worker** | Thread with local deque, runs steal-while-wait loop |
| **JoinHandle** | Synchronization point for async task completion |
| **Scope** | Structured concurrency container with lifetime guarantees |
| **ParallelIterator** | Chunked parallel operations over slices |

### 1.3 Performance Guarantees

| Operation | Complexity | Latency |
|-----------|------------|---------|
| Task spawn (worker) | O(1) | ~5-20ns |
| Task receive | O(1) | ~10-50ns |
| Work stealing | O(1) | Cache-line isolated |

---

## 2. File Structure

```
src/libs/loom/src/
|
+-- loom.zig              # Library entry point
|
+-- pool/                 # Thread Pool Infrastructure
|   +-- thread_pool.zig   # Work-stealing thread pool
|   +-- task.zig          # Task struct
|   +-- scope.zig         # Scoped task execution
|
+-- iter/                 # Parallel Iterator Types
|   +-- par_iter.zig      # Core ParallelIterator
|   +-- par_range.zig     # RangeParallelIterator
|   +-- stepped_iter.zig  # SteppedIterator
|   +-- config.zig        # Constants
|   +-- contexts.zig      # Task context structs
|   +-- merge.zig         # Parallel merge helpers
|
+-- ops/                  # Standalone Parallel Operations
|   +-- ops.zig           # Index file
|   +-- for_each.zig      # forEach, forEachIndexed
|   +-- reduce.zig        # Parallel reduction
|   +-- map.zig           # map, mapIndexed
|   +-- filter.zig        # Parallel filter
|   +-- sort.zig          # Parallel merge sort
|   +-- predicates.zig    # any, all, find, position, count
|   +-- chunks.zig        # chunks, chunksConst
|
+-- util/                 # Shared Utilities
    +-- splitter.zig      # Work splitting strategies
    +-- reducer.zig       # Reduction helpers
    +-- join.zig          # Fork-join primitives
```

---

## 3. Design Decisions

### 3.1 Work Distribution via DequeChannel

- **Decision:** Use DequeChannel (Chase-Lev deque + global MPMC queue) per worker
- **Justification:** Combines fast local access (no contention) with global overflow handling and cross-worker stealing

### 3.2 Thread-Local Worker Context

- **Decision:** Store current worker ID and pool pointer in thread-local storage
- **Justification:** Enables fast-path task spawning from worker threads without locks

### 3.3 Steal-While-Wait Pattern

- **Decision:** Waiting threads help by executing other tasks
- **Justification:** Prevents deadlock in recursive fork-join, maximizes CPU utilization

### 3.4 Type-Erased Tasks (24 bytes)

- **Decision:** Tasks are `{execute_fn, context_ptr, scope_ptr}`
- **Justification:** Minimal size fits cache line, no allocation needed for task struct

### 3.5 Sharded Arena Allocation for Scopes

- **Decision:** One arena per worker + one for external threads
- **Justification:** Eliminates mutex contention on concurrent spawn operations

### 3.6 Configurable Backoff Modes

- **Decision:** Three preset modes - `low_latency`, `balanced`, `power_saving`
- **Justification:** Different workloads need different latency/power tradeoffs

### 3.7 Adaptive Work Splitting

- **Decision:** 2x oversubscription target with configurable minimum chunk size
- **Justification:** Balances load across workers while avoiding excessive scheduling overhead

---

## 4. Data Structures

```
Loom Architecture
|
+-- Layer 1: Primitives (beam libs)
|   +-- Deque - Chase-Lev work-stealing deque
|   +-- DequeChannel - Deque + global MPMC queue
|   +-- Backoff - 4-phase adaptive backoff
|
+-- Layer 2: ThreadPool
|   +-- Task (24 bytes)
|   |   +-- execute: *fn(*anyopaque) void
|   |   +-- context: *anyopaque
|   |   +-- scope: ?*anyopaque
|   |
|   +-- Worker
|   |   +-- id: usize
|   |   +-- thread: Thread
|   |   +-- channel_worker: DequeChannel.Worker
|   |   +-- shutdown: Atomic(bool)
|   |   +-- stats: WorkerStats
|   |
|   +-- ThreadPool
|       +-- workers: []Worker
|       +-- channel: *DequeChannel
|       +-- state: Atomic(PoolState)
|       +-- backoff_config: BackoffConfig
|
+-- Layer 3: Fork-Join
|   +-- JoinHandle(T)
|   |   +-- result: T
|   |   +-- completed: Atomic(bool)
|   |   +-- panic_payload: ?*anyopaque
|   |
|   +-- Scope
|       +-- pending: Atomic(usize)
|       +-- shards: []ArenaShard
|       +-- parent: ?*Scope
|       +-- pool: *ThreadPool
|
+-- Layer 4: ParallelIterator
    +-- Splitter (adaptive, fixed, recursive)
    +-- Reducer (sum, product, min, max)
    +-- ParallelIterator(T) with methods
```

---

## 5. Core Operations

| Operation | Thread | Mechanism | Latency |
|-----------|--------|-----------|---------|
| `pool.spawn(task)` | Worker | Local deque push | ~5-10ns |
| `pool.spawn(task)` | External | Global queue enqueue | ~20-50ns |
| `worker.recv()` | Worker | Local pop -> global -> steal | ~10-50ns |
| `join(a, b)` | Any | Spawn right, run left locally | ~overhead + work |
| `scope.spawn(fn)` | Any | Arena alloc + pool spawn | ~50-100ns |
| `par_iter().for_each()` | Any | Chunk + parallel spawn | ~overhead + work |

---

## 6. Algorithms

### 6.1 Worker Run Loop

```
1. Set thread-local worker context
2. Initialize backoff with pool config
3. Loop until shutdown:
   a. Try recv() (local pop -> global dequeue -> steal)
   b. If task: execute, reset backoff
   c. If no task: backoff.snooze()
4. Clear thread-local context
```

### 6.2 Binary Fork-Join

```
join(left_fn, right_fn):
1. Create JoinHandle for right result
2. Create context struct with handle + args
3. Spawn right task to pool
4. Execute left task locally (no scheduling overhead)
5. Steal-while-wait for right completion:
   a. Check completed flag (acquire)
   b. If not done: tryProcessOneTask(), backoff
6. Return (left_result, right_result)
```

### 6.3 Structured Concurrency

```
scope(body_fn):
1. Create Scope with sharded arenas
2. Set as current scope (thread-local)
3. Execute body (body spawns tasks via scope.spawn())
4. Wait for all tasks (pending.load == 0):
   a. Steal-while-wait to help
5. Check panic_payload, propagate if set
6. Free all arena allocations
```

### 6.4 Parallel Iteration

```
par_iter().for_each():
1. Calculate chunk size based on:
   - Data length
   - Thread count
   - Splitter config (min_chunk, mode)
2. If shouldSplit() is false: run sequentially
3. Create scope
4. For each chunk: spawn task to process chunk
5. Wait for scope completion
```

---

## 7. Flow Diagrams

### 7.1 Thread Pool Architecture

```
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
|               |              |               |              |               |
|  Run Loop:    |              |  Run Loop:    |              |  Run Loop:    |
|  1. local pop |              |  1. local pop |              |  1. local pop |
|  2. global    |              |  2. global    |              |  2. global    |
|  3. steal     |              |  3. steal     |              |  3. steal     |
|  4. execute   |              |  4. execute   |              |  4. execute   |
+---------------+              +---------------+              +---------------+
```

### 7.2 Fork-Join Execution

```
    join(taskA, taskB)
           |
           +----------------------+
           |                      |
           v                      v
    +-------------+        +-------------+
    |  Left Task  |        | Right Task  |
    |  (local)    |        | (spawned)   |
    |             |        |             |
    | No overhead |        | -> Pool ->  |
    | Just call   |        | Worker pick |
    +------+------+        +------+------+
           |                      |
           |    steal-while-wait  |
           |<---------------------+
           |
           v
    +-------------+
    |   Results   |
    | (left,right)|
    +-------------+
```

### 7.3 Scope Structured Concurrency

```
    scope(|s| { ... })
           |
           v
    +-------------------------------------+
    |             Scope                   |
    |  pending: Atomic(0)                 |
    |  shards: [arena0, arena1, ..., ext] |
    +-------------------------------------+
           |
           | body executes:
           |   s.spawn(fn1)  -> pending++, arena alloc, pool.spawn
           |   s.spawn(fn2)  -> pending++, arena alloc, pool.spawn
           |   s.spawn(fn3)  -> pending++, arena alloc, pool.spawn
           |
           v
    +-------------------------------------+
    |  Tasks execute (possibly stolen)    |
    |  Each task: work -> pending--       |
    +-------------------------------------+
           |
           | scope.wait():
           |   while pending > 0:
           |     tryProcessOneTask()  <- steal-while-wait
           |     backoff.snooze()
           |
           v
    +-------------------------------------+
    |  All tasks complete                 |
    |  Arena freed (all contexts at once) |
    +-------------------------------------+
```

### 7.4 Parallel Iterator Pipeline

```
    par_iter(data)
        |
        v
    +------------------------+
    |  Calculate chunks:     |
    |  - target = threads*2  |
    |  - chunk_size = max(   |
    |      min_chunk,        |
    |      len/target)       |
    +-----------+------------+
                |
                v
    +------------------------+
    |      shouldSplit?      |
    |  len >= threads*min    |
    +-----------+------------+
                |
        +-------+-------+
        | No            | Yes
        v               v
    Sequential      +------------------------+
    execution       |  scope(|s| {           |
                    |    for chunks |chunk|: |
                    |      s.spawn(process,  |
                    |              chunk)    |
                    |  })                    |
                    +------------------------+
```

---

## 8. Configuration

### 8.1 ThreadPool Config (Comptime)

```zig
const Config = struct {
    local_capacity: usize = 256,    // Per-worker deque
    global_capacity: usize = 4096,  // Global overflow queue
    enable_stats: bool = false,     // Performance monitoring
};

// Custom pool with large queues:
const LargePool = ThreadPoolFn(.{ .local_capacity = 512, .global_capacity = 8192 });
```

### 8.2 InitConfig (Runtime)

```zig
const InitConfig = struct {
    num_threads: ?usize = null,        // null = CPU count / 2
    stack_size: ?usize = null,         // null = system default
    backoff_mode: BackoffMode = .low_latency,
};
```

### 8.3 BackoffMode Presets

| Mode | spin | multi_spin | sleep_limit | sleep_ns |
|------|------|------------|-------------|----------|
| `low_latency` | 64 | 128 | 512 | 100us |
| `balanced` | 32 | 64 | 128 | 1ms |
| `power_saving` | 8 | 16 | 32 | 10ms |

### 8.4 Splitter Config

```zig
const Splitter = struct {
    min_chunk_size: usize,  // Sequential threshold
    mode: SplitMode,        // fixed, adaptive, recursive
    target_chunks: usize,   // 0 = auto (threads * 2)
};

// Presets:
Splitter.default()        // adaptive(1024)
Splitter.fixed(100)       // Fixed chunk size
Splitter.adaptive(1000)   // Adaptive with min 1000
Splitter.recursive(256)   // For divide-and-conquer
```

---

## 9. API Reference

### 9.1 Basic Usage

```zig
const loom = @import("loom");

// Binary fork-join
const left, const right = loom.join(
    computeLeft, .{data[0..mid]},
    computeRight, .{data[mid..]},
);

// Scoped spawning
loom.scope(struct {
    fn body(s: *loom.Scope) void {
        for (items) |item| {
            s.spawn(process, .{item});
        }
    }
}.body);

// Parallel iteration
loom.par_iter(items).for_each(process);
const sum = loom.par_iter(items).reduce(Reducer(i64).sum());
```

### 9.2 Custom Pool

```zig
// Create custom pool
const pool = try ThreadPool.init(allocator, .{
    .num_threads = 4,
    .backoff_mode = .balanced,
});
defer pool.deinit();

// Use with join/scope
loom.joinOnPool(pool, taskA, .{}, taskB, .{});
loom.scopeOnPool(pool, body);

// Use with parallel iterator
loom.par_iter(data).withPool(pool).for_each(process);
```

### 9.3 Parallel Iterator Methods

```zig
par_iter(slice)
    .withMinChunk(1000)      // Sequential threshold
    .withMaxChunks(8)        // Cap parallelism
    .withPool(custom_pool)   // Use specific pool
    .withAlloc(allocator)    // For filter/map

    // Terminal operations:
    .for_each(fn)            // Apply to each element
    .reduce(Reducer)         // Combine all elements
    .map(fn, allocator)      // Transform elements
    .filter(pred, allocator) // Select elements
    .find(pred)              // First match
    .all(pred)               // All match?
    .any(pred)               // Any match?
```

---

## 10. Context API

The Context API enables passing shared state to parallel operations.

### 10.1 Use Cases

- Shared configuration parameters
- Atomic counters for aggregation
- Output buffers with thread-safe access
- External resources (file handles, database connections)

### 10.2 Basic Context Usage

```zig
const Context = struct {
    threshold: f64,
    counter: *std.atomic.Value(usize),
};

var atomic_count = std.atomic.Value(usize).init(0);
const ctx = Context{
    .threshold = 100.0,
    .counter = &atomic_count,
};

par_iter(data)
    .withPool(pool)
    .withContext(&ctx)
    .forEach(struct {
        fn check(c: *const Context, value: *f64) void {
            if (value.* > c.threshold) {
                _ = c.counter.fetchAdd(1, .monotonic);
            }
        }
    }.check);

const above_threshold = atomic_count.load(.acquire);
```

### 10.3 Context-Aware Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `forEach` | `fn(Ctx, *T) void` | Apply function with context |
| `forEachIndexed` | `fn(Ctx, usize, *T) void` | Apply with index and context |
| `count` | `fn(Ctx, T) bool` | Count matching elements |
| `any` | `fn(Ctx, T) bool` | Check if any matches |
| `all` | `fn(Ctx, T) bool` | Check if all match |
| `find` | `fn(Ctx, T) bool` | Find first match |
| `map` | `fn(Ctx, T) U` | Transform elements |
| `mapIndexed` | `fn(Ctx, usize, T) U` | Transform with index |
| `filter` | `fn(Ctx, T) bool` | Select matching |
| `reduce` | `Reducer(T)` | Combine elements |
| `chunks` | `fn(Ctx, usize, []T) void` | Process mutable chunks |
| `chunksConst` | `fn(Ctx, usize, []const T) void` | Process const chunks |

### 10.4 Range Iteration with Context

```zig
par_range(0, num_chunks)
    .withPool(pool)
    .withContext(&read_ctx)
    .forEach(struct {
        fn readChunk(ctx: *const ReadContext, chunk_idx: usize) void {
            const start = chunk_idx * ctx.chunk_size;
            const end = @min(start + ctx.chunk_size, ctx.total_size);
            _ = std.posix.pread(ctx.file_handle, ctx.buffer[start..end], start) catch {};
        }
    }.readChunk);
```

### 10.5 Thread Safety Guidelines

**Lifetime Requirements:**
- Context must outlive the parallel operation
- Use pointers to stack-allocated or heap-allocated data

```zig
// Good - context lives on stack, outlives par_iter
const ctx = Context{ .threshold = 100.0 };
par_iter(data).withContext(&ctx).forEach(fn);

// Bad - temporary context
par_iter(data).withContext(&Context{ ... }).forEach(fn);  // May not work
```

**Thread Safety:**
- Context is shared across ALL worker threads
- Read-only fields: no synchronization needed
- Mutable counters: use `std.atomic.Value(T)`
- Complex mutations: use mutexes
- Best performance: thread-local accumulation with final merge

### 10.6 Performance Tips

| Aspect | Recommendation |
|--------|----------------|
| Context size | Keep small; use pointers to large data |
| Cache lines | Align frequently-accessed fields |
| Atomics | `.monotonic` for counters, `.release/.acquire` for flags |
| Mutexes | Minimize lock duration; batch updates |
| Chunk size | Larger chunks = fewer atomic operations |

---

## 11. Testing Strategy

### 11.1 Unit Tests

- ThreadPool init/deinit lifecycle
- Task execution basic flow
- JoinHandle completion signaling
- Scope pending count tracking
- Splitter chunk size calculations
- Reducer associativity verification

### 11.2 Integration Tests

- `join()` binary fork correctness
- `scope()` with nested spawns
- Parallel iterator operations
- Worker ID uniqueness verification
- Custom pool configurations

### 11.3 Stress Tests

- High spawn rate under contention
- Deep recursive fork-join (quicksort, mergesort)
- Mixed parallel iterator workloads
- Long-running pool stability
- Memory pressure with arena allocation

### 11.4 Benchmarks

- Task spawn latency (worker vs external)
- Fork-join overhead vs sequential
- Parallel iterator scaling (1-N threads)
- Work-stealing efficiency under imbalance
- Comparison: different backoff modes

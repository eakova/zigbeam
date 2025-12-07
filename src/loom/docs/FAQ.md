# Loom FAQ

## How many threads will Loom spawn?

By default, Loom spawns one worker thread per available CPU core (including logical cores with hyperthreading). You can customize this:

```zig
const pool = try ThreadPool.init(allocator, .{
    .num_threads = 4,  // Fixed thread count
});
```

Or leave it as `null` to use all available cores:

```zig
const pool = try ThreadPool.init(allocator, .{
    .num_threads = null,  // Default: CPU count
});
```

## How does Loom balance work between threads?

Loom uses **work stealing** based on the Chase-Lev deque algorithm. Here's how it works:

1. When you call `join(a, b)` from worker thread W, W places task `b` into its local deque
2. W immediately starts executing `a`
3. Other idle threads can "steal" `b` from W's deque (FIFO order)
4. If no one steals `b`, W executes it after completing `a`

This approach ensures:
- **Cache locality**: Threads prefer their own recent work (LIFO)
- **Load balancing**: Idle threads steal from busy ones
- **Low overhead**: ~5-10ns for local operations, ~20-50ns for steals

## How do I share state between parallel tasks?

Zig doesn't have Rust's borrow checker, so thread safety is your responsibility. Common patterns:

**Read-only data** — Pass by pointer, no synchronization needed:
```zig
const ctx = Context{ .threshold = 100.0, .lookup_table = &table };
loom.par_iter(data)
    .withContext(&ctx)
    .forEach(process);
```

**Counters** — Use `std.atomic.Value`:
```zig
var count = std.atomic.Value(usize).init(0);
loom.par_iter(data).for_each(struct {
    fn process(item: *Item) void {
        if (item.matches()) {
            _ = count.fetchAdd(1, .monotonic);
        }
    }
}.process);
```

**Complex mutations** — Use `std.Thread.Mutex`:
```zig
var mutex = std.Thread.Mutex{};
var results = std.ArrayList(Result).init(allocator);

loom.par_iter(data).for_each(struct {
    fn process(item: *Item) void {
        const result = compute(item);
        mutex.lock();
        defer mutex.unlock();
        results.append(result) catch {};
    }
}.process);
```

**Best performance** — Thread-local accumulation with final merge (use `reduce`):
```zig
const sum = loom.par_iter(data).reduce(Reducer(i64).sum());
```

## Does Loom guarantee data-race freedom?

**No.** Unlike Rust's Rayon, Loom cannot guarantee data-race freedom at compile time because Zig lacks a borrow checker.

However, Loom's API **encourages** race-free patterns:
- `map()`, `filter()`, `reduce()` operate on independent elements
- `reduce()` uses thread-local accumulators merged at the end
- Context is passed as a pointer, making shared state explicit

Safe usage is the programmer's responsibility. Follow the patterns above and you'll be fine.

## When should I NOT use Loom?

Parallel iteration adds overhead. Avoid it when:

1. **Small data sets** — Below ~1000 elements, sequential is faster
2. **Trivial operations** — If the per-element work is tiny (e.g., simple addition), overhead dominates
3. **I/O-bound work** — Disk/network operations don't benefit from CPU parallelism
4. **Already parallelized** — Don't nest `par_iter` inside `par_iter`

Use `.withMinChunk()` to control the sequential threshold:
```zig
loom.par_iter(data)
    .withMinChunk(1000)  // Don't parallelize below 1000 elements
    .for_each(process);
```

## How do I debug parallel code?

1. **Reduce threads** — Test with 1 thread to isolate concurrency bugs:
   ```zig
   const pool = try ThreadPool.init(allocator, .{ .num_threads = 1 });
   ```

2. **Add logging** — Use `std.debug.print` with thread ID:
   ```zig
   std.debug.print("Thread {d}: processing item {d}\n", .{
       std.Thread.getCurrentId(), item.id
   });
   ```

3. **Use sanitizers** — Build with thread sanitizer (when Zig supports it)

4. **Simplify** — Replace `par_iter` with regular `for` to verify sequential correctness first

## What's the difference between `join` and `scope`?

**`join(a, b)`** — Binary fork-join for exactly 2 tasks:
```zig
const left, const right = loom.join(
    computeLeft, .{data[0..mid]},
    computeRight, .{data[mid..]},
);
```

**`scope`** — Dynamic spawning for variable number of tasks:
```zig
loom.scope(struct {
    fn body(s: *loom.Scope) void {
        for (items) |item| {
            s.spawn(process, .{item});
        }
    }
}.body);
// All spawned tasks complete before scope exits
```

Use `join` for divide-and-conquer algorithms; use `scope` for task parallelism.

## Can I use Loom with async/await?

Not directly. Loom is designed for CPU-bound parallelism using OS threads, not async I/O. For I/O-bound workloads, consider Zig's `std.event` or other async solutions.

However, you can use Loom for the CPU-intensive parts of your application and async for I/O.

## How does Loom compare to Rayon?

| Feature | Loom (Zig) | Rayon (Rust) |
|---------|------------|--------------|
| Work stealing | Yes | Yes |
| Parallel iterators | Yes | Yes |
| Fork-join | Yes | Yes |
| Data-race freedom | No (programmer responsibility) | Yes (compiler enforced) |
| Async integration | No | Limited |
| Zero dependencies | Yes | Yes |

Loom brings Rayon's ergonomics to Zig, with the trade-off that safety is not compiler-enforced.

## Where can I learn more?

**Documentation:**
- [README.md](../README.md) — Quick start and API reference
- [LOOM_IMPLEMENTATION.md](LOOM_IMPLEMENTATION.md) — Architecture deep dive

**Samples:**

| Sample | Description |
|--------|-------------|
| [loom_api_showcase.zig](../samples/loom_api_showcase.zig) | Comprehensive API examples |
| [basic_join.zig](../samples/basic_join.zig) | Binary fork-join basics |
| [scope_spawn.zig](../samples/scope_spawn.zig) | Structured concurrency with scopes |
| [parallel_sum.zig](../samples/parallel_sum.zig) | Parallel reduction |
| [parallel_map.zig](../samples/parallel_map.zig) | Parallel transformation |
| [parallel_find.zig](../samples/parallel_find.zig) | Parallel search |
| [parallel_sort.zig](../samples/parallel_sort.zig) | Parallel sorting |
| [map_collect.zig](../samples/map_collect.zig) | Map and collect results |
| [vec_collect.zig](../samples/vec_collect.zig) | Vector collection |
| [chunks_pipeline.zig](../samples/chunks_pipeline.zig) | Chunk-based processing |
| [quicksort.zig](../samples/quicksort.zig) | Divide-and-conquer quicksort |
| [mergesort.zig](../samples/mergesort.zig) | Divide-and-conquer mergesort |
| [fibonacci.zig](../samples/fibonacci.zig) | Recursive parallelism |
| [factorial.zig](../samples/factorial.zig) | Parallel factorial |
| [matrix_multiply.zig](../samples/matrix_multiply.zig) | Matrix operations |
| [monte_carlo_pi.zig](../samples/monte_carlo_pi.zig) | Monte Carlo simulation |
| [prime_sieve.zig](../samples/prime_sieve.zig) | Prime number sieve |
| [pythagoras.zig](../samples/pythagoras.zig) | Pythagorean triples |
| [game_of_life.zig](../samples/game_of_life.zig) | Conway's Game of Life |
| [nbody_sim.zig](../samples/nbody_sim.zig) | N-body simulation |
| [tree_traverse.zig](../samples/tree_traverse.zig) | Parallel tree traversal |
| [tsp.zig](../samples/tsp.zig) | Traveling salesman problem |
| [word_count.zig](../samples/word_count.zig) | Parallel word counting |
| [csv_transform_mmap_with_loom.zig](../samples/csv_transform_mmap_with_loom.zig) | CSV processing (memory-mapped) |
| [csv_transform_in_mem_with_loom.zig](../samples/csv_transform_in_mem_with_loom.zig) | CSV processing (in-memory) |
| [image_processing.zig](../samples/image_processing.zig) | Image processing |
| [image_transform.zig](../samples/image_transform.zig) | Image transformation |
| [custom_pool_stats.zig](../samples/custom_pool_stats.zig) | Thread pool statistics |
| [join_microbench.zig](../samples/join_microbench.zig) | Join performance benchmark |
| [context_api_bench.zig](../samples/context_api_bench.zig) | Context API benchmark |
| [noop_bench.zig](../samples/noop_bench.zig) | No-op overhead benchmark |

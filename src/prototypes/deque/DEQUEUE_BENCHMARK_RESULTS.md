# Work-Stealing Deque & Thread Pool - Benchmark Results

Platform: ARM64 (Apple Silicon)
Build: ReleaseFast


# WorkStealingDeque Benchmarks

## Single-Threaded Push/Pop Performance

| Item Type | Operations/sec | ns/op | Notes |
|-----------|----------------|-------|-------|
| u64 | 275.97 M/s | 3.62 | Mixed push/pop |
| usize | 291.60 M/s | 3.43 | Mixed push/pop |

## Work-Stealing Performance (1 Owner + N Thieves)

| Thieves | Operations/sec | ns/op | Notes |
|---------|----------------|-------|-------|
| 2 | 79.35 M/s | 12.60 | Owner push, thieves steal |

## Distributed Work-Stealing Performance (Multiple Deques)

| Workers | Operations/sec | ns/op | Notes |
|---------|----------------|-------|-------|
| 2 | 44.04 M/s | 22.71 | Workers generate local work + cross-steal |
| 4 | 45.22 M/s | 22.11 | Workers generate local work + cross-steal |
| 8 | 47.79 M/s | 20.92 | Workers generate local work + cross-steal |

## Thread Pool Submit/Execute Performance (External Injection)

| Workers | Tasks | Operations/sec | ns/task | Notes |
|---------|-------|----------------|---------|-------|
| 2 | 10,000 | 3.62 M/s | 276.30 | All via Injector (bottleneck) |
| 2 | 50,000 | 3.76 M/s | 265.62 | All via Injector (bottleneck) |
| 2 | 100,000 | 4.09 M/s | 244.62 | All via Injector (bottleneck) |
| 4 | 10,000 | 2.48 M/s | 403.46 | All via Injector (bottleneck) |
| 4 | 50,000 | 2.40 M/s | 415.82 | All via Injector (bottleneck) |
| 4 | 100,000 | 2.56 M/s | 390.23 | All via Injector (bottleneck) |
| 8 | 10,000 | 638.25 K/s | 1,566.79 | All via Injector (bottleneck) |
| 8 | 50,000 | 707.07 K/s | 1,414.28 | All via Injector (bottleneck) |
| 8 | 100,000 | 733.55 K/s | 1,363.24 | All via Injector (bottleneck) |

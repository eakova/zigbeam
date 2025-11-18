# Work-Stealing Deque & Thread Pool - Benchmark Results

Platform: ARM64 (Apple Silicon)
Build: ReleaseFast


# WorkStealingDeque Benchmarks

## Single-Threaded Push/Pop Performance

| Item Type | Operations/sec | ns/op | Notes |
|-----------|----------------|-------|-------|
| u64 | 199.69 M/s | 5.01 | Mixed push/pop |
| usize | 194.05 M/s | 5.15 | Mixed push/pop |

## Work-Stealing Performance (1 Owner + N Thieves)

| Thieves | Operations/sec | ns/op | Notes |
|---------|----------------|-------|-------|

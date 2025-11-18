# Work-Stealing Deque & Thread Pool - Benchmark Results

Platform: ARM64 (Apple Silicon)
Build: ReleaseFast


# WorkStealingDeque Benchmarks

## Single-Threaded Push/Pop Performance

| Item Type | Operations/sec | ns/op | Notes |
|-----------|----------------|-------|-------|
| u64 | 254.20 M/s | 3.93 | Mixed push/pop |
| usize | 238.62 M/s | 4.19 | Mixed push/pop |

## Work-Stealing Performance (1 Owner + N Thieves)

| Thieves | Operations/sec | ns/op | Notes |
|---------|----------------|-------|-------|
| 2 | 81.31 M/s | 12.30 | Owner push, thieves steal |

## Distributed Work-Stealing Performance (Multiple Deques)

| Workers | Operations/sec | ns/op | Notes |
|---------|----------------|-------|-------|
| 2 | 146.37 M/s | 6.83 | Workers generate local work + cross-steal |
| 4 | 162.05 M/s | 6.17 | Workers generate local work + cross-steal |
| 8 | 174.95 M/s | 5.72 | Workers generate local work + cross-steal |

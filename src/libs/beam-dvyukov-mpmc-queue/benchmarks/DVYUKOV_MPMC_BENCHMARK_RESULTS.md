# DVyukov MPMC Queue - Benchmark Results

Performance measurements for the DVyukov bounded MPMC queue.

**Configuration:**
- Total iterations: 100,000,000
- Repeats per scenario: 3
- Statistics: Median of 3 runs

## Single-Threaded Performance

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 1.56 | 639.31 M/s |
| Capacity 256 | 100,000,000 | 1.55 | 644.26 M/s |
| Capacity 1024 | 100,000,000 | 1.56 | 641.01 M/s |
| Capacity 4096 | 100,000,000 | 1.66 | 603.13 M/s |

## SPSC (Single Producer, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 14.78 | 67.68 M/s |
| Capacity 256 | 100,000,000 | 13.86 | 72.15 M/s |
| Capacity 1024 | 100,000,000 | 13.70 | 73.00 M/s |
| Capacity 4096 | 100,000,000 | 9.95 | 100.52 M/s |

## MPSC (Multiple Producers, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/1C (cap=512) | 100,000,000 | 15.58 | 64.17 M/s |
| 4P/1C (cap=1024) | 100,000,000 | 16.36 | 61.12 M/s |
| 8P/1C (cap=2048) | 100,000,000 | 25.96 | 38.52 M/s |

## SPMC (Single Producer, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 1P/2C (cap=512) | 100,000,000 | 32.49 | 30.78 M/s |
| 1P/4C (cap=1024) | 100,000,000 | 46.70 | 21.41 M/s |
| 1P/8C (cap=2048) | 100,000,000 | 122.01 | 8.20 M/s |

## MPMC (Multiple Producers, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/2C (cap=512) | 100,000,000 | 35.06 | 28.52 M/s |
| 4P/4C (cap=2048) | 100,000,000 | 82.33 | 12.15 M/s |
| 8P/8C (cap=4096) | 100,000,000 | 92.80 | 10.78 M/s |

## Performance Recommendations

Based on benchmark results:

- **Low Latency (SPSC)**: Use capacity 256-512 for optimal single-threaded throughput
- **Balanced MPMC**: Use capacity 1024-2048 with 2-4 producers/consumers
- **High Contention**: Use capacity 2048-4096 for 8+ threads
- **Memory Constrained**: Minimum viable capacity is 64, but expect reduced throughput

## Notes

- All measurements use median of 3 runs for statistical stability
- Throughput includes both enqueue and dequeue operations
- ns/op = nanoseconds per operation (lower is better)
- Queue capacity must be power of 2

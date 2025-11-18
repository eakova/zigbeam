# DVyukov MPMC Queue - Benchmark Results

Performance measurements for the DVyukov bounded MPMC queue.

**Configuration:**
- Total iterations: 100,000,000
- Repeats per scenario: 3
- Statistics: Median of 3 runs

## Single-Threaded Performance

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 1.74 | 576.26 M/s |
| Capacity 256 | 100,000,000 | 1.73 | 579.26 M/s |
| Capacity 1024 | 100,000,000 | 1.72 | 580.56 M/s |
| Capacity 4096 | 100,000,000 | 1.82 | 548.23 M/s |

## SPSC (Single Producer, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 10.36 | 96.50 M/s |
| Capacity 256 | 100,000,000 | 10.03 | 99.74 M/s |
| Capacity 1024 | 100,000,000 | 12.47 | 80.22 M/s |
| Capacity 4096 | 100,000,000 | 14.18 | 70.50 M/s |

## MPSC (Multiple Producers, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/1C (cap=512) | 100,000,000 | 11.17 | 89.55 M/s |
| 4P/1C (cap=1024) | 100,000,000 | 12.68 | 78.89 M/s |
| 8P/1C (cap=2048) | 100,000,000 | 9.00 | 100.00 M/s |

## SPMC (Single Producer, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 1P/2C (cap=512) | 100,000,000 | 18.56 | 53.88 M/s |
| 1P/4C (cap=1024) | 100,000,000 | 24.40 | 40.98 M/s |
| 1P/8C (cap=2048) | 100,000,000 | 30.98 | 32.28 M/s |

## MPMC (Multiple Producers, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/2C (cap=512) | 100,000,000 | 17.31 | 57.76 M/s |
| 4P/4C (cap=2048) | 100,000,000 | 25.23 | 39.63 M/s |
| 8P/8C (cap=4096) | 100,000,000 | 47.93 | 20.86 M/s |

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

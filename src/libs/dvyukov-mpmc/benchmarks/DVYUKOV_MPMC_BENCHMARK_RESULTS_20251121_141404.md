# DVyukov MPMC Queue - Benchmark Results

Performance measurements for the DVyukov bounded MPMC queue.

**Configuration:**
- Total iterations: 100,000,000
- Repeats per scenario: 3
- Statistics: Median of 3 runs

## Single-Threaded Performance

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 12.96 | 77.14 M/s |
| Capacity 256 | 100,000,000 | 13.30 | 75.18 M/s |
| Capacity 1024 | 100,000,000 | 13.28 | 75.28 M/s |
| Capacity 4096 | 100,000,000 | 13.18 | 75.89 M/s |

## SPSC (Single Producer, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| Capacity 64 | 100,000,000 | 25.12 | 39.81 M/s |
| Capacity 256 | 100,000,000 | 25.32 | 39.49 M/s |
| Capacity 1024 | 100,000,000 | 25.06 | 39.90 M/s |
| Capacity 4096 | 100,000,000 | 25.12 | 39.81 M/s |

## MPSC (Multiple Producers, Single Consumer)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/1C (cap=512) | 100,000,000 | 32.51 | 30.76 M/s |
| 4P/1C (cap=1024) | 100,000,000 | 63.74 | 15.69 M/s |
| 8P/1C (cap=2048) | 100,000,000 | 115.43 | 8.66 M/s |

## SPMC (Single Producer, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 1P/2C (cap=512) | 100,000,000 | 33.80 | 29.58 M/s |
| 1P/4C (cap=1024) | 100,000,000 | 71.96 | 13.90 M/s |
| 1P/8C (cap=2048) | 100,000,000 | 131.02 | 7.63 M/s |

## MPMC (Multiple Producers, Multiple Consumers)

| Scenario | Iterations | ns/op (median) | Throughput |
|----------|------------|----------------|------------|
| 2P/2C (cap=512) | 100,000,000 | 55.70 | 17.95 M/s |
| 4P/4C (cap=2048) | 100,000,000 | 102.50 | 9.76 M/s |
| 8P/8C (cap=4096) | 100,000,000 | 194.38 | 5.14 M/s |

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

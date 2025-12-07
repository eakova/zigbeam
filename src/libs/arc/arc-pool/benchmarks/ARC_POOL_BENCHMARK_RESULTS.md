### ArcPool - Single-Threaded - Create + Recycle - ([64]u8)
| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 5,000,000 | 3.53 | 283.12 M/s |

### ArcPool - Multi-Threaded - Create + Recycle - ([64]u8)
| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 5,000,000 | 3.65 | 274.00 M/s |
| 4 | 5,000,000 | 0.96 | 1.04 G/s |
| 8 | 5,000,000 | 0.49 | 2.05 G/s |

### ArcPool - TLS Capacity - Single-Threaded
| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 16 | 5,000,000 | 3.53 | 283.26 M/s |
| 32 | 5,000,000 | 3.50 | 285.71 M/s |
| 64 | 5,000,000 | 3.52 | 284.02 M/s |

### ArcPool - In-place Init vs Copy - Single-Threaded - ([64]u8)
| Thread(s) | Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- | --- |
| 1 | copy 64B | 5,000,000 | 3.52 | 284.41 M/s |
| 1 | in-place (memset) | 5,000,000 | 2.69 | 372.38 M/s |


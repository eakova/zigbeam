### Arc - SVO- (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 3,120.12 G/s |
| 4 | 250,000,000 | <0.01 | 10,362.69 G/s |
| 8 | 250,000,000 | <0.01 | 11,650.67 G/s |

### Arc - Heap - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 3.70 | 270.54 M/s |
| 4 | 250,000,000 | 17.74 | 56.36 M/s |
| 8 | 250,000,000 | 52.99 | 18.87 M/s |

### Arc - SVO Clone Throughput - (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 3,120.12 G/s |
| 4 | 250,000,000 | <0.01 | 10,362.69 G/s |
| 8 | 250,000,000 | <0.01 | 11,650.67 G/s |

### Arc - Heap Clone Throughput - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 3.70 | 270.54 M/s |
| 4 | 250,000,000 | 17.74 | 56.36 M/s |
| 8 | 250,000,000 | 52.99 | 18.87 M/s |

### Arc - SVO Downgrade + Upgrade Throughput - (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 10,888.98 G/s |
| 4 | 250,000,000 | <0.01 | 15,706.48 G/s |
| 8 | 250,000,000 | <0.01 | 12,474.43 G/s |

### Arc - Heap Downgrade + Upgrade Throughput - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 7.70 | 129.90 M/s |
| 4 | 250,000,000 | 72.53 | 13.79 M/s |
| 8 | 250,000,000 | 177.39 | 5.64 M/s |


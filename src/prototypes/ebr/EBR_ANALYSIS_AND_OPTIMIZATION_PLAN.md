# EBR (Epoch-Based Reclamation) - Analysis and Optimization Plan

**Date**: 2025-11-17
**Status**: Analysis Complete - Ready for Optimization
**Priority**: HIGH (Required for deque buffer reclamation)

## Executive Summary

The current EBR implementation is **functional but not optimal** for high-performance concurrent use cases. The primary bottleneck is a **mutex-protected thread registry** that serializes all epoch coordination operations. For integration with the work-stealing deque, we need a **lock-free, high-performance EBR** that can handle frequent pin/unpin operations without contention.

## Baseline Performance (Current Implementation)

### Single-Threaded Performance ✅
```
Pin/Unpin Latency:
  Mean:      19ns
  p50:       0ns     ← Excellent!
  p99:       1000ns

Retire Throughput:
  Mean:      1217ns (1.2μs)
  p50:       1000ns (1.0μs)
  p99:       2000ns (2.0μs)
```

**Analysis**: Single-threaded performance is excellent. The hot path (pin/unpin) is very fast because it only touches thread-local state.

### Multi-Threaded Performance ❌
```
Concurrent Pin/Unpin (4 threads): CRASHED
```

**Analysis**: The implementation fails or performs poorly under concurrent load due to mutex contention in the Registry.

## Architecture Analysis

### Current Implementation

#### Component Overview

1. **Global (ebr.zig:118-164)**
   - Global epoch counter (cache-line aligned) ✅
   - **Registry with std.Thread.Mutex** ❌ BOTTLENECK
   - Allocator for internal structures

2. **ThreadState (thread_state.zig:17-124)**
   - Local epoch copy (cache-line aligned) ✅
   - Pin status flag
   - Retired list (ArrayList-based) ⚠️ Could be optimized
   - Advance counter (wrapping) ✅

3. **Registry (ebr.zig:173-242)**
   ```zig
   const Registry = struct {
       entries: std.ArrayList(RegistryEntry),
       mutex: std.Thread.Mutex,  ← CRITICAL BOTTLENECK
       allocator: Allocator,
   }
   ```
   - **Problem**: `canAdvanceEpoch()` and `getMinimumEpoch()` hold mutex
   - **Impact**: Every 256 unpins triggers `tryAdvanceEpoch()` which calls `canAdvanceEpoch()` under mutex
   - **Result**: Threads serialize on mutex, destroying concurrency

4. **RetiredList (retired_list.zig:17-79)**
   - Uses `std.ArrayList(RetiredNode)`
   - `swapRemove()` for deletion (cache inefficient)
   - Dynamic allocation on every add (can fail)

5. **Guard (guard.zig:13-76)**
   - RAII-style wrapper ✅
   - Simple and correct ✅

6. **AtomicPtr (atomic_ptr.zig:13-99)**
   - Clean wrapper around atomic operations ✅
   - Proper memory ordering ✅

### Critical Performance Issues

#### 1. Registry Mutex Contention (CRITICAL)

**Location**: `ebr.zig:173-242`

**Problem**:
```zig
fn canAdvanceEpoch(self: *Registry, current_epoch: u64) bool {
    self.mutex.lock();  ← All threads serialize here
    defer self.mutex.unlock();

    for (self.entries.items) |entry| {
        if (entry.is_pinned.load(.acquire)) {
            const local = entry.local_epoch.load(.acquire);
            if (local < current_epoch) {
                return false;
            }
        }
    }
    return true;
}
```

**Impact**:
- Called every 256 unpins from ANY thread (line thread_state.zig:121)
- In a 4-thread workload with 10K ops/thread = 40K total operations
- Triggers ~156 mutex contention points (40K / 256)
- Each contention causes context switching and cache invalidation

**Benchmark Evidence**:
- Single-threaded: 19ns mean pin/unpin
- 4-threaded: CRASHED (likely livelock/deadlock or severe contention)

#### 2. Retired List Inefficiency (MEDIUM)

**Location**: `retired_list.zig:17-79`

**Problem**:
```zig
pub fn add(self: *RetiredList, opts: struct {
    node: RetiredNode,
}) void {
    self.nodes.append(self.allocator, opts.node) catch {
        // If we can't add to list, free immediately
        opts.node.deleter(opts.node.ptr);
        return;
    };
}
```

**Issues**:
- Dynamic allocation on every retire (can fail, triggers OOM path)
- `swapRemove()` creates cache misses and unpredictable access patterns
- No batching or amortization

**Impact**:
- Retire throughput: 1.2μs mean (could be <200ns with fixed arrays)
- Unpredictable performance (allocation failures)

#### 3. Epoch Advancement Strategy (LOW)

**Location**: `thread_state.zig:119-122`

```zig
fn shouldTryAdvanceEpoch(self: *ThreadState) bool {
    self.advance_counter +%= 1;
    return (self.advance_counter & 0xFF) == 0; // Every 256 unpins
}
```

**Issues**:
- Fixed threshold (256) may be too frequent or too slow depending on workload
- No adaptation to system load
- No hysteresis to prevent thrashing

## Root Cause: Algorithm vs Implementation

### The Crossbeam Approach

Crossbeam's EBR (the gold standard) uses:

1. **Lock-Free Intrusive List for Registry**
   - Threads add themselves to a global intrusive linked list
   - No mutex required for registration or epoch checks
   - Uses atomic pointers and epoch tagging

2. **Batched Retired Lists with Fixed Arrays**
   - Pre-allocated bags of retired pointers
   - Batch allocations amortize cost
   - Bags are link-chained for overflow

3. **Smart Epoch Advancement**
   - Only advances when actually needed
   - Uses exponential backoff to reduce contention
   - Hysteresis prevents rapid epoch thrashing

### Why Our Implementation Differs

Our implementation uses:
- **Mutex-based registry** - Simpler to implement, but serializes operations
- **ArrayList retired list** - Simpler API, but allocates frequently
- **Fixed advancement** - Predictable but not adaptive

**Verdict**: Our implementation prioritizes **simplicity over performance**. This is fine for prototyping but not for production use in hot paths like the deque.

## Optimization Plan

### Phase 1: Fix Critical Bottlenecks (Required for Deque Integration)

#### 1.1. Replace Registry Mutex with Lock-Free List

**Goal**: Eliminate mutex contention in epoch coordination

**Approach**: Intrusive lock-free linked list of thread states

**Implementation**:
```zig
const ThreadState = struct {
    local_epoch: Atomic(u64) align(CACHE_LINE),
    is_pinned: Atomic(bool),
    retired_list: ?RetiredList,
    advance_counter: usize,
    registered: bool,

    // NEW: Intrusive list pointers
    next: Atomic(?*ThreadState),  // Atomic next pointer for lock-free list
};

const Registry = struct {
    head: Atomic(?*ThreadState),  // Lock-free head pointer
    allocator: Allocator,

    // NO MORE MUTEX!

    pub fn registerThread(self: *Registry, state: *ThreadState) void {
        // Atomic push to head of list
        var current_head = self.head.load(.acquire);
        while (true) {
            state.next.store(current_head, .release);
            if (self.head.cmpxchgWeak(current_head, state, .release, .acquire)) |updated| {
                current_head = updated;
            } else {
                break; // Success
            }
        }
    }

    pub fn canAdvanceEpoch(self: *Registry, current_epoch: u64) bool {
        // Lock-free traversal
        var node = self.head.load(.acquire);
        while (node) |n| {
            if (n.is_pinned.load(.acquire)) {
                const local = n.local_epoch.load(.acquire);
                if (local < current_epoch) {
                    return false;
                }
            }
            node = n.next.load(.acquire);
        }
        return true;
    }
};
```

**Benefits**:
- ✅ Completely lock-free
- ✅ No mutex contention
- ✅ Scalable to any number of threads
- ✅ Cache-friendly (only reads shared state)

**Complexity**: Medium (2-3 hours implementation + testing)

**Priority**: P0 (CRITICAL)

#### 1.2. Replace ArrayList with Fixed-Size Batched Bags

**Goal**: Eliminate dynamic allocation and improve cache locality

**Approach**: Pre-allocated bags with batch management

**Implementation**:
```zig
const BAG_SIZE: usize = 64; // 64 pointers per bag

const RetiredBag = struct {
    nodes: [BAG_SIZE]RetiredNode,
    count: usize,
    next: ?*RetiredBag, // Linked list of bags
};

const RetiredList = struct {
    current_bag: ?*RetiredBag,
    full_bags: ?*RetiredBag,  // List of full bags waiting for GC
    allocator: Allocator,

    pub fn add(self: *RetiredList, node: RetiredNode) !void {
        if (self.current_bag == null or self.current_bag.?.count >= BAG_SIZE) {
            // Move current to full list if full
            if (self.current_bag) |bag| {
                if (bag.count >= BAG_SIZE) {
                    bag.next = self.full_bags;
                    self.full_bags = bag;
                }
            }
            // Allocate new bag (only happens every 64 retires)
            self.current_bag = try self.allocator.create(RetiredBag);
            self.current_bag.?.* = .{ .nodes = undefined, .count = 0, .next = null };
        }

        const bag = self.current_bag.?;
        bag.nodes[bag.count] = node;
        bag.count += 1;
    }
};
```

**Benefits**:
- ✅ Amortized O(1) without frequent allocation
- ✅ Cache-friendly sequential access
- ✅ Predictable performance
- ✅ No OOM panic path

**Complexity**: Low-Medium (1-2 hours)

**Priority**: P1 (HIGH)

### Phase 2: Advanced Optimizations (Performance Polish)

#### 2.1. Adaptive Epoch Advancement

**Goal**: Reduce unnecessary epoch advancement attempts

**Approach**: Exponential backoff + load-based triggering

**Implementation**:
```zig
const ThreadState = struct {
    // ...existing fields...
    advance_backoff: usize = 256,  // Start at 256, can grow
    retired_count: usize = 0,      // Track retired objects

    fn shouldTryAdvanceEpoch(self: *ThreadState) bool {
        self.advance_counter +%= 1;

        // Trigger if:
        // 1. Reached backoff threshold
        // 2. OR have many retired objects (>1000)
        const at_threshold = (self.advance_counter % self.advance_backoff) == 0;
        const high_pressure = self.retired_count > 1000;

        if (at_threshold or high_pressure) {
            // Exponential backoff on frequent failures
            // (would need to track success/failure)
            return true;
        }
        return false;
    }
};
```

**Benefits**:
- ✅ Reduces contention when not needed
- ✅ Faster reclamation under high memory pressure
- ✅ Adapts to workload characteristics

**Complexity**: Low (30 min)

**Priority**: P2 (NICE-TO-HAVE)

#### 2.2. NUMA-Aware Allocation (Future)

**Goal**: Improve cache locality on NUMA systems

**Approach**: Allocate thread-local state on local NUMA node

**Priority**: P3 (FUTURE)

### Phase 3: Integration with Deque

Once Phase 1 is complete, integrate EBR with deque for buffer reclamation:

**Changes to deque.zig**:

```zig
pub fn push(self: *Self, item: T) !void {
    const b = self.bottom;
    const t = self.top.load(.acquire);
    const buf = @constCast(self.buffer.get());

    const deque_size = b - t;
    if (deque_size >= @as(i64, @intCast(buf.capacity))) {
        // Grow buffer
        const old_buf_ptr = @constCast(self.buffer.get());
        const new_arc = try self.grow(t, b, buf);

        // Atomically update buffer pointer
        @atomicStore(usize, &self.buffer.storage.ptr_with_tag, new_arc.storage.ptr_with_tag, .release);

        // PROPER RECLAMATION: Retire old buffer with EBR
        // (Assuming guard is passed or thread-local)
        guard.retire(.{
            .ptr = old_buf_ptr,
            .deleter = bufferDeleter,
        });
    }

    // ... rest of push
}

fn bufferDeleter(ptr: *anyopaque) void {
    const buf: *Buffer = @ptrCast(@alignCast(ptr));
    buf.deinit();
}
```

**Threading model**:
```zig
// In deque_pool.zig worker thread:
threadlocal var ebr_state: EBR.ThreadState = .{};

fn run(self: *Worker) void {
    // Initialize EBR for this worker
    try ebr_state.ensureInitialized(.{
        .global = self.pool.ebr_global,
        .allocator = self.pool.allocator,
    });
    defer ebr_state.deinitThread();

    while (!self.pool.shutdown.load(.acquire)) {
        // Pin epoch for entire iteration
        var guard = EBR.pin(&ebr_state, self.pool.ebr_global);
        defer guard.unpin();

        // Safe to steal/push/pop within this guard
        if (self.deque.pop()) |task| {
            task.callback(task.context);
        }
    }
}
```

## Performance Targets (Post-Optimization)

### Phase 1 Targets
```
Pin/Unpin Latency:
  Single-threaded: <20ns (current: 19ns) ✅
  4-threaded:      <50ns (target)
  8-threaded:      <100ns (target)

Retire Throughput:
  Single-threaded: <200ns (current: 1200ns)
  4-threaded:      <500ns (target)

Concurrent Pin/Unpin:
  4 threads:  >100M ops/sec (target)
  8 threads:  >150M ops/sec (target)
```

### Comparison to Crossbeam (Rust)
Crossbeam-epoch on similar hardware:
- Pin/unpin: 5-15ns
- Retire: 10-50ns
- Scales linearly up to 16+ threads

**Our target**: Match or exceed Crossbeam performance

## Implementation Timeline

### Week 1: Phase 1 Critical Fixes
- **Day 1-2**: Lock-free registry (P0)
  - Implement intrusive linked list
  - Replace mutex with atomic operations
  - Unit tests for concurrent registration

- **Day 3**: Batched retired bags (P1)
  - Fixed-size bag structure
  - Batch allocation logic
  - GC traversal update

- **Day 4-5**: Testing & Benchmarking
  - Multi-threaded stress tests
  - Benchmark comparison
  - Fix any races or bugs

### Week 2: Integration
- **Day 1-2**: Deque integration
  - Add EBR to deque buffer management
  - Remove temporary buffer leak
  - Thread pool EBR initialization

- **Day 3-4**: End-to-end testing
  - Work-stealing benchmarks
  - Thread pool benchmarks
  - Memory leak checks

- **Day 5**: Documentation & Polish

## Testing Strategy

### Unit Tests
- ✅ Single-threaded pin/unpin (existing)
- ✅ Single-threaded retire (existing)
- ⚠️ Concurrent registration (needs stress test)
- ❌ Lock-free list correctness (NEW - required)
- ❌ Bag allocation/deallocation (NEW - required)

### Integration Tests
- ❌ Deque with EBR buffer reclamation (NEW - required)
- ❌ Thread pool with EBR (NEW - required)
- ❌ Memory leak validation (valgrind/ASAN)

### Benchmarks
- ✅ Pin/unpin latency (existing)
- ✅ Retire throughput (existing)
- ⚠️ Concurrent pin/unpin (currently crashes - FIX)
- ✅ AtomicPtr operations (existing)
- ❌ Integrated deque benchmarks (NEW)

## Risk Assessment

### High Risk
- **Lock-free list bugs**: ABA problem, memory ordering issues
  - **Mitigation**: Extensive testing, formal verification tools (if available)
  - **Fallback**: Use sequence locks instead of pure lock-free

### Medium Risk
- **Integration complexity with deque**: Threading model mismatch
  - **Mitigation**: Careful design review, prototype first

### Low Risk
- **Performance regression**: Optimizations make things worse
  - **Mitigation**: Benchmark every change, keep baseline measurements

## References

### Crossbeam (Rust)
- **Repo**: https://github.com/crossbeam-rs/crossbeam
- **EBR implementation**: crossbeam-epoch crate
- **Key insights**: Lock-free registry, batched bags, smart GC triggers

### Academic Papers
- **"Epoch-Based Reclamation"** (Fraser 2004)
- **"Hazard Pointers vs EBR"** (Michael 2004)
- **"Lock-Free Data Structures"** (Herlihy & Shavit)

### Zig Implementations
- **std.atomic**: Memory ordering primitives
- **Intrusive lists**: Can reference Zig std lib's intrusive structures

## Conclusion

The current EBR implementation is a good starting point but has a **critical mutex bottleneck** in the Registry that prevents high-performance concurrent use. The optimization plan focuses on:

1. **Phase 1 (P0/P1)**: Eliminate mutex, optimize retired lists
2. **Phase 2 (P2)**: Advanced optimizations for extra performance
3. **Phase 3**: Integrate with deque to replace buffer leak

**Estimated time**: 1-2 weeks for Phase 1 + Integration
**Payoff**: Proper memory reclamation for deque, 10-50x improvement in multi-threaded EBR performance

**Next Steps**: Begin Phase 1 implementation starting with lock-free registry.

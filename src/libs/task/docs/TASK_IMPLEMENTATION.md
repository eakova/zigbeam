## Implementation Plan: `Task` - Cancellable OS-Thread Abstraction with Smart Sleep

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Graceful Thread Cancellation with Immediate Wake-Up**
The objective is to provide a simple, safe abstraction for spawning threads that can be cancelled gracefully, where sleeping threads wake up immediately on cancellation instead of waiting for their full sleep duration to expire.

**1.2. The Architectural Pattern: CancellationToken-Inspired Design**
*   **Context Injection:** Worker function receives a Context as its first parameter automatically.
*   **Cooperative Cancellation:** Workers check `ctx.cancelled()` periodically and exit voluntarily.
*   **Smart Sleep:** `ctx.sleep(ms)` uses condition variable to wake immediately on cancellation.
*   **Atomic Flag + Condition Variable:** Minimal synchronization for maximum efficiency.
*   **Idempotent Wait:** Safe to call `wait()` multiple times without double-join issues.

**1.3. The Core Components**
*   **Task:** Main struct holding thread handle, shared state, allocator, and joined flag.
*   **Task.Context:** Passed to worker function; provides `cancelled()` and `sleep()` methods.
*   **SharedState:** Internal struct with atomic cancellation flag, mutex, and condition variable.

**1.4. Safety Guarantees**
*   **No Double-Join:** `joined` flag prevents calling `thread.join()` twice.
*   **Memory Safety:** `wait()` frees SharedState exactly once.
*   **Acquire-Release Ordering:** Flag writes in `cancel()` are visible to `cancelled()` readers.
*   **No Missed Signals:** Mutex-protected condition variable prevents lost wake-ups.

---

### **Part 2: Core Design Decisions**

**2.1. Context as First Parameter**
*   **Decision:** Worker function must accept `Task.Context` as its first argument; spawn() auto-prepends it.
*   **Justification:** Type-safe contract ensures every worker has access to cancellation. Compile-time tuple manipulation avoids runtime overhead.

**2.2. Atomic Flag for Fast Polling**
*   **Decision:** Use `std.atomic.Value(bool)` for `is_cancelled` flag.
*   **Justification:** Polling `ctx.cancelled()` is O(1) with single atomic load. No mutex needed for the common check path.

**2.3. Condition Variable for Interruptible Sleep**
*   **Decision:** Use mutex + condition variable for `ctx.sleep()` implementation.
*   **Justification:** `timedWait()` allows sleeping with a timeout while `signal()` provides immediate wake-up on cancellation. This pattern is well-established and portable.

**2.4. Idempotent Wait**
*   **Decision:** Track `joined` flag to make `wait()` safe to call multiple times.
*   **Justification:** Common pattern to call `wait()` in both normal flow and defer block. Prevents panic from double-join.

**2.5. Heap-Allocated SharedState**
*   **Decision:** Allocate SharedState on heap via provided allocator.
*   **Justification:** Task struct can be moved/copied without invalidating pointers. Worker thread and Task both hold stable pointer to shared state.

**2.6. Sleep Returns Cancellation Status**
*   **Decision:** `ctx.sleep(ms)` returns `true` if woke due to cancellation, `false` if timeout expired.
*   **Justification:** Enables concise loop patterns: `if (ctx.sleep(100)) break;` without separate `cancelled()` check.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
Task
├── thread: std.Thread              ← OS thread handle
├── state: *SharedState             ← Pointer to shared state
├── allocator: std.mem.Allocator    ← For cleanup
└── joined: bool                    ← Prevents double-join

Task.Context
└── _state: *SharedState            ← Access to cancellation state

SharedState (heap-allocated)
├── is_cancelled: Atomic(bool)      ← Cancellation flag
├── mutex: std.Thread.Mutex         ← Protects condition variable
└── cond: std.Thread.Condition      ← For interruptible sleep
```

#### **Phase 2: Core Operations**

| Operation | Thread | Cost | Notes |
|-----------|--------|------|-------|
| `spawn()` | Caller | ~1-10μs | Allocate state, spawn OS thread |
| `cancel()` | Caller | ~10-100ns | Set flag, signal condition |
| `wait()` | Caller | Blocks | Join thread, free state |
| `ctx.cancelled()` | Worker | ~1-5ns | Single atomic load |
| `ctx.sleep(ms)` | Worker | 0-ms | timedWait or immediate wake |

#### **Phase 3: Key Algorithms**

**spawn(allocator, function, args) - Start Cancellable Thread:**
1. Allocate SharedState on heap
2. Initialize state: `is_cancelled=false`, default mutex/cond
3. Create Context pointing to state
4. Prepend Context to args tuple (comptime)
5. Spawn OS thread with function and prepended args
6. Return Task struct

**cancel() - Request Cancellation:**
1. Store `true` to `is_cancelled` (release ordering)
2. Lock mutex
3. Signal condition variable (wake sleeping thread)
4. Unlock mutex

**wait() - Join and Cleanup:**
1. If `joined == true`: return early (idempotent)
2. Call `thread.join()` (blocks until worker returns)
3. Destroy SharedState via allocator
4. Set `joined = true`

**ctx.cancelled() - Check Cancellation:**
1. Load `is_cancelled` with acquire ordering
2. Return value

**ctx.sleep(ms) - Interruptible Sleep:**
1. If `cancelled()`: return true (early exit)
2. Lock mutex
3. Re-check `is_cancelled` inside lock (avoid race)
4. If cancelled: unlock, return true
5. Call `cond.timedWait(mutex, ms * ns_per_ms)`
6. If timeout (error.Timeout): unlock, return `cancelled()`
7. If signaled (no error): unlock, return true

#### **Phase 4: Flow Diagrams**

**Task Lifecycle:**
```
┌─────────────────────────────────────────────────────────────────┐
│                      Task Lifecycle                             │
└─────────────────────────────────────────────────────────────────┘

      Caller Thread                       Worker Thread
           │                                    │
           ▼                                    │
    ┌─────────────┐                            │
    │Task.spawn() │                            │
    │ alloc state │                            │
    │ spawn thread│──────────────────────────► │
    └──────┬──────┘                            ▼
           │                          ┌────────────────┐
           │                          │ worker(ctx, ..)│
           │                          │                │
           │                          │ while !cancel: │
           │                          │   do work      │
           │                          │   ctx.sleep()  │
           │                          └───────┬────────┘
           │                                  │
    ┌──────▼──────┐                           │
    │task.cancel()│                           │
    │ flag = true │──────────────────────────►│ (wakes from sleep)
    │ cond.signal │                           │
    └──────┬──────┘                           │
           │                          ┌───────▼───────┐
           │                          │ cancelled()   │
           │                          │ returns true  │
           │                          │ worker exits  │
           │                          └───────┬───────┘
           │                                  │
    ┌──────▼──────┐                           │
    │ task.wait() │◄──────────────────────────┘ (join)
    │ free state  │
    └─────────────┘
```

**ctx.sleep() Flow:**
```
ctx.sleep(ms)
      │
      ▼
┌─────────────────┐
│ cancelled()?    │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
   yes        no
    │         │
    ▼         ▼
return    ┌─────────────────┐
 true     │ mutex.lock()    │
          └────────┬────────┘
                   │
                   ▼
          ┌─────────────────┐
          │ is_cancelled?   │
          │ (inside lock)   │
          └────────┬────────┘
                   │
             ┌─────┴─────┐
             │           │
            yes          no
             │           │
             ▼           ▼
         unlock      ┌─────────────────────┐
         return      │ cond.timedWait(ms)  │
         true        └─────────┬───────────┘
                               │
                         ┌─────┴─────┐
                         │           │
                     timeout     signaled
                         │           │
                         ▼           ▼
                    unlock       unlock
                    return       return
                  cancelled()    true
```

**Memory Ordering:**
```
    cancel()                           ctx.cancelled()
       │                                     │
       ▼                                     │
  is_cancelled.store(                        │
    true, RELEASE) ──────────────────► is_cancelled.load(ACQUIRE)
       │                                     │
       │                                     ▼
       │                              if true: exit loop
       ▼
  cond.signal() ─────────────────────► timedWait() returns

Key: RELEASE-ACQUIRE pair ensures flag write is visible
     before worker sees cancellation
```

**Comptime Args Prepending:**
```
spawn(allocator, worker, .{&counter, &flag})
                            │
                            ▼
              TuplePrepend(Context, .{*u64, *bool})
                            │
                            ▼
              Result: .{Context, *u64, *bool}
                            │
                            ▼
              thread_args = .{ctx, &counter, &flag}
                            │
                            ▼
              Thread.spawn(worker, thread_args)
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   spawn() creates thread that runs worker function.
*   ctx.cancelled() returns false initially.
*   ctx.cancelled() returns true after cancel().
*   ctx.sleep(ms) returns false after timeout (no cancellation).
*   ctx.sleep(ms) returns true immediately after cancel().
*   wait() blocks until worker exits.
*   wait() is idempotent (safe to call twice).
*   Context is correctly prepended to args.

**4.2. Integration Tests**
*   Cancellation during sleep: thread wakes immediately.
*   Polling loop with periodic sleep and cancellation.
*   Multiple tasks running concurrently.
*   Cancel before worker checks: immediate exit.
*   Long-running task with multiple sleep/cancel cycles.
*   Memory leak check: state freed after wait().

**4.3. Benchmarks**
*   spawn()/wait() latency (empty worker).
*   cancel() latency (signal delivery time).
*   ctx.cancelled() polling throughput.
*   ctx.sleep() wake-up latency on cancellation.
*   Multiple tasks spawn/cancel/wait throughput.


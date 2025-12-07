## Implementation Plan: `Backoff` - Exponential Backoff for Lock-Free Algorithms

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Efficient Spinning in Lock-Free Code**
The objective is to provide a lightweight backoff primitive for lock-free and spin-based algorithms. It reduces CPU waste during contention by progressively increasing wait times, then yielding to the OS scheduler when spinning becomes ineffective.

**1.2. The Architectural Pattern: Two-Phase Exponential Backoff**
*   **Phase 1 - Spinning:** Execute exponentially increasing CPU pause hints (1, 2, 4, 8... up to 2^spin_limit).
*   **Phase 2 - Yielding:** After spin_limit, yield the timeslice to the OS scheduler.
*   **Completion Signal:** After yield_limit, signal that blocking/parking is advisable.

**1.3. The Core Components**
*   **Backoff:** The main struct tracking backoff progression state.
*   **Options:** Configuration for spin_limit and yield_limit thresholds.

**1.4. Performance Guarantees**
*   **Zero Allocation:** Stack-only, no heap usage.
*   **Minimal Overhead:** Inline functions, simple arithmetic.
*   **CPU-Friendly:** Uses `spinLoopHint()` to reduce pipeline stalls.

---

### **Part 2: Core Design Decisions**

**2.1. Exponential Spin Count**
*   **Decision:** Spin count doubles each step: `1 << step` iterations, capped at `1 << spin_limit`.
*   **Justification:** Exponential growth balances quick recovery for short contention with reduced CPU waste for longer waits. Matches crossbeam-utils behavior.

**2.2. Default Limits**
*   **Decision:** `spin_limit = 6` (max 64 spins), `yield_limit = 10`.
*   **Justification:** 64 spins is enough for most short critical sections. 10 total steps before completion provides ~4 yield opportunities before suggesting blocking.

**2.3. Separate spin() and snooze() APIs**
*   **Decision:** `spin()` never yields; `snooze()` spins then yields.
*   **Justification:** `spin()` is for lock-free loops where progress is expected. `snooze()` is for blocking waits where the thread may need to wait longer.

**2.4. Per-Thread Instance Requirement**
*   **Decision:** Backoff is NOT thread-safe; each thread must own its instance.
*   **Justification:** Avoiding atomics keeps the implementation minimal and fast. Lock-free algorithms already require per-thread retry loops.

**2.5. Completion Detection**
*   **Decision:** `isCompleted()` returns true when `step > yield_limit`.
*   **Justification:** Signals when spinning/yielding is no longer productive and the caller should switch to a blocking primitive (mutex, futex, parking).

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
Backoff
├── step: u32          (current backoff progression, starts at 0)
├── spin_limit: u32    (max step for spin-only phase, default 6)
└── yield_limit: u32   (max step before completion, default 10)

Options
├── spin_limit: u32 = 6
└── yield_limit: u32 = 10
```

#### **Phase 2: Core Operations**

| Operation | Behavior | Step Increment | Use Case |
|-----------|----------|----------------|----------|
| `spin()` | Exponential pause hints only | Up to spin_limit | Lock-free CAS loops |
| `snooze()` | Spin, then yield to OS | Up to yield_limit | Blocking waits |
| `reset()` | Set step = 0 | N/A | Retry after success |
| `isCompleted()` | Check if step > yield_limit | N/A | Decide to park/block |

#### **Phase 3: Key Algorithms**

*   **`spin()` - Lock-Free Backoff:**
    1. Cap step at spin_limit
    2. Execute `1 << capped_step` spinLoopHint() calls
    3. Increment step if <= spin_limit

*   **`snooze()` - Blocking Backoff:**
    1. If step <= spin_limit: execute `1 << step` spinLoopHint() calls
    2. Else: yield timeslice to OS scheduler
    3. Increment step if <= yield_limit

#### **Phase 4: Flow Diagrams**

**Backoff Progression:**
```
  step:  0    1    2    3    4    5    6    7    8    9   10   11+
         │    │    │    │    │    │    │    │    │    │    │    │
 spins:  1    2    4    8   16   32   64   64   64   64   64   64
         │    │    │    │    │    │    │    │    │    │    │    │
         └────────────────────────────┴────────────────────────┴───>
              SPIN PHASE (0-6)           YIELD PHASE (7-10)    DONE
```

**spin() vs snooze() Behavior:**
```
  spin()                              snooze()
    │                                    │
    v                                    v
┌─────────┐                        ┌─────────┐
│ step <= │──yes──> spin N times   │ step <= │──yes──> spin N times
│ spin_   │                        │ spin_   │
│ limit?  │                        │ limit?  │
└────┬────┘                        └────┬────┘
     │no                                │no
     v                                  v
  spin 64                         ┌───────────┐
  (capped)                        │ Thread.   │
                                  │ yield()   │
                                  └───────────┘
```

**Typical Usage in CAS Loop:**
```
  ┌──────────────────────────────────────┐
  │  var backoff = Backoff.init(.{});    │
  └──────────────────────────────────────┘
                    │
                    v
            ┌──────────────┐
            │  CAS attempt │<─────────────┐
            └──────┬───────┘              │
                   │                      │
              success?                    │
              /      \                    │
           yes        no                  │
            │          │                  │
            v          v                  │
         [done]   backoff.spin() ─────────┘
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   **Progression:** Verify step increments correctly through spin/snooze cycles.
*   **Capping:** Confirm spin count caps at `1 << spin_limit`.
*   **Completion:** Test `isCompleted()` returns true after yield_limit.
*   **Reset:** Verify reset() sets step back to 0.

**4.2. Integration Tests**
*   **CAS loop integration:** Use in actual lock-free data structure under contention.
*   **Multi-threaded stress:** Verify each thread's backoff operates independently.

**4.3. Benchmarks**
*   **Spin overhead:** Measure latency of spin() at various step values.
*   **Contention reduction:** Compare CAS retry rates with/without backoff.
*   **Yield effectiveness:** Measure context switch overhead in snooze() phase.

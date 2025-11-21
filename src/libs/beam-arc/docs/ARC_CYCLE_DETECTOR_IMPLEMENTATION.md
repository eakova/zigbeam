## Implementation Plan: `ArcCycleDetector<T>` - Mark-and-Sweep Cycle Detection for Arc

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Detect Reference Cycles in Arc Graphs**
The objective is to provide a debugging tool that identifies groups of `Arc<T>` instances that reference each other in cycles but are no longer reachable from the main program. These "leaked islands" would never be deallocated by reference counting alone.

**1.2. The Architectural Pattern: Mark-and-Sweep GC**
*   **Track:** Register Arc instances that might participate in cycles.
*   **Mark:** Traverse from "roots" (externally-held Arcs) and mark all reachable nodes.
*   **Sweep:** Any tracked node not marked is part of a leaked cycle.

**1.3. The Core Components**
*   **ArcCycleDetector<T>:** The main detector managing tracked pointers and running detection.
*   **TraceFn:** User-provided function to discover child Arc references within T.
*   **CycleList:** Result container holding detected cycle members.

**1.4. Usage Guarantees**
*   **Debugging Only:** Not designed for production hot paths (O(N+M) complexity).
*   **Non-Invasive:** Does not modify Arc instances; only observes reference counts.
*   **User-Driven Tracing:** Correctness depends on accurate TraceFn implementation.

---

### **Part 2: Core Design Decisions**

**2.1. User-Provided Trace Function**
*   **Decision:** User must supply a `TraceFn` that enumerates child Arc pointers within T.
*   **Justification:** The detector cannot introspect arbitrary types. The trace function encodes domain knowledge about which fields contain Arc references.

**2.2. Root Heuristic: Strong > Weak**
*   **Decision:** An Arc is considered a "root" if `strong_count > weak_count`.
*   **Justification:** External references (not part of internal cycles) typically hold strong refs without corresponding weak refs. This heuristic avoids requiring manual root registration.

**2.3. HashMap for O(1) Duplicate Tracking**
*   **Decision:** Use `AutoHashMap` alongside the tracked list for O(1) `contains` checks.
*   **Justification:** Prevents duplicate tracking when the same Arc is registered multiple times.

**2.4. Inline Arcs (SVO) Ignored**
*   **Decision:** `track()` silently ignores inline/SVO Arcs.
*   **Justification:** SVO Arcs have no heap allocation and cannot participate in heap-based reference cycles.

**2.5. Prune Dead Arcs Before Detection**
*   **Decision:** `detectCycles()` first removes entries where both strong and weak counts are 0.
*   **Justification:** These Inner blocks have been fully deallocated and are no longer relevant.

**2.6. CycleList Owns Arc References**
*   **Decision:** Returned CycleList contains cloned Arcs that must be released by caller.
*   **Justification:** Ensures cycle members stay alive for inspection. Caller controls cleanup via `CycleList.deinit()`.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
ArcCycleDetector<T>
├── allocator: Allocator
├── tracked_arcs: ArrayList(*Inner)      (all registered Arc inner pointers)
├── tracked_set: HashMap(*Inner, void)   (O(1) duplicate check)
├── trace_fn: TraceFn                    (user-provided child enumerator)
└── trace_context: ?*anyopaque           (optional context for trace_fn)

TraceFn = fn(context, allocator, *const T, *ChildList) void
ChildList = ArrayList(*Inner)

CycleList
├── allocator: Allocator
└── list: ArrayList(Arc<T>)              (cloned refs to cycle members)
```

#### **Phase 2: Core Operations**

| Operation | Purpose | Complexity |
|-----------|---------|------------|
| `track(arc)` | Register Arc for cycle detection | O(1) amortized |
| `detectCycles()` | Run mark-and-sweep, return cycle members | O(N + M) |
| `CycleList.deinit()` | Release all Arc refs and free list | O(N) |
| `CycleList.releaseAll()` | Release refs without freeing list | O(N) |

#### **Phase 3: Key Algorithms**

*   **`track(arc)` - Register Arc:**
    1. If arc is inline (SVO), return early
    2. Get inner pointer from arc
    3. If already in tracked_set, return (no duplicates)
    4. Add to tracked_set and tracked_arcs list

*   **`detectCycles()` - Mark-and-Sweep:**
    1. **Prune:** Remove entries with strong=0 and weak=0
    2. **Find Roots:** Add arcs where `strong_count > weak_count` to worklist
    3. **Mark Phase:** BFS/DFS from roots, mark all reachable via trace_fn
    4. **Sweep Phase:** Collect unmarked arcs with strong_count > 0
    5. Return CycleList with cloned Arc references

*   **`pruneDeadArcs()` - Cleanup:**
    1. Iterate tracked_arcs
    2. If strong=0 AND weak=0: remove from set and list (swap-remove)
    3. Continue until all entries checked

#### **Phase 4: Flow Diagrams**

**detectCycles() Flow:**
```
  detectCycles()
       │
       v
  ┌─────────────┐
  │ pruneDeadArcs│  (remove fully deallocated)
  └──────┬──────┘
         │
         v
  ┌─────────────┐
  │ Find Roots  │  (strong > weak heuristic)
  │ → worklist  │
  └──────┬──────┘
         │
         v
  ┌─────────────┐
  │ MARK PHASE  │
  │ BFS traverse│──> call trace_fn for each
  │ mark reachable│    add children to worklist
  └──────┬──────┘
         │
         v
  ┌─────────────┐
  │ SWEEP PHASE │
  │ find unmarked│──> clone into CycleList
  │ with strong>0│
  └──────┬──────┘
         │
         v
    [CycleList]
```

**Mark-and-Sweep Visualization:**
```
  BEFORE (all tracked):

     Root A ──────> B ──────> C
     (strong=2)    (strong=1) (strong=1)
                      │
                      v
     D <───────────> E        (cycle: D ↔ E)
     (strong=1)    (strong=1)

  MARK PHASE:
     Start from Root A (strong > weak)
     Mark: A ✓ → B ✓ → C ✓
     D and E not reachable from any root

  SWEEP PHASE:
     Unmarked with strong > 0: D, E
     → CycleList = [D, E]
```

**track() Flow:**
```
  track(arc)
       │
       v
  ┌─────────────┐
  │ isInline?   │──yes──> return (SVO not tracked)
  └──────┬──────┘
         │no
         v
  ┌─────────────┐
  │ in tracked_ │──yes──> return (already tracked)
  │ set?        │
  └──────┬──────┘
         │no
         v
  ┌─────────────┐
  │ add to set  │
  │ add to list │
  └─────────────┘
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   **Simple cycle:** A → B → A, verify both detected.
*   **No cycle:** Linear chain with external root, verify empty result.
*   **Mixed graph:** Some cycles, some rooted chains, verify only cycles detected.
*   **SVO handling:** Verify inline Arcs silently ignored.
*   **Duplicate tracking:** Same Arc tracked twice, verify no duplicates.

**4.2. Integration Tests**
*   **Complex graph:** Multi-node interconnected cycles.
*   **Self-reference:** Arc containing weak ref to itself via newCyclic.
*   **Prune behavior:** Track, release all refs, detect → verify pruned.
*   **CycleList cleanup:** Verify `deinit()` releases all Arc refs.

**4.3. Diagnostic Usage**
*   **Memory leak debugging:** Periodic `detectCycles()` in test harness.
*   **TraceFn validation:** Verify trace function covers all Arc fields.
*   **False positive check:** Ensure externally-rooted graphs not flagged.

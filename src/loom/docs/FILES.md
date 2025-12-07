# Loom Library File Structure

## Directory Layout

```
src/libs/loom/src/
|
+-- loom.zig
|
+-- pool/
|   +-- thread_pool.zig
|   +-- task.zig
|   +-- scope.zig
|
+-- iter/
|   +-- par_iter.zig
|   +-- par_range.zig
|   +-- stepped_iter.zig
|   +-- config.zig
|   +-- contexts.zig
|   +-- merge.zig
|
+-- ops/
|   +-- ops.zig
|   +-- for_each.zig
|   +-- reduce.zig
|   +-- map.zig
|   +-- filter.zig
|   +-- sort.zig
|   +-- predicates.zig
|   +-- chunks.zig
|
+-- util/
    +-- splitter.zig
    +-- reducer.zig
    +-- join.zig
```

## File Descriptions

### Entry Point

loom.zig - Library entry point, exports public API

### pool/ - Thread Pool Infrastructure

- thread_pool.zig - Work-stealing thread pool
- task.zig - Task struct for thread pool
- scope.zig - Scoped task execution

### iter/ - Parallel Iterator Types

- par_iter.zig - Core ParallelIterator
- par_range.zig - RangeParallelIterator
- stepped_iter.zig - SteppedIterator
- config.zig - Constants
- contexts.zig - Task context structs
- merge.zig - Parallel merge helpers

### ops/ - Standalone Parallel Operations

- ops.zig - Index file
- for_each.zig - forEach, forEachIndexed
- reduce.zig - parallel reduction
- map.zig - map, mapIndexed
- filter.zig - parallel filter
- sort.zig - parallel merge sort
- predicates.zig - any, all, find, position, count
- chunks.zig - chunks, chunksConst

### util/ - Shared Utilities

- splitter.zig - Work splitting strategies
- reducer.zig - Reduction helpers
- join.zig - Fork-join primitives

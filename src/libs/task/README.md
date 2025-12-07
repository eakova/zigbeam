# Beam-Task

Cancellable OS-thread task abstraction for Zig, inspired by C#'s CancellationToken pattern.

## Overview

Managing thread cancellation is a common challenge in concurrent programming. Beam-Task provides a simple, safe abstraction for spawning threads that can be cancelled gracefully, with smart sleep that wakes up immediately on cancellation.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Beam-Task Flow                               │
└─────────────────────────────────────────────────────────────────┘

    Task.spawn()
         │
         ├──► Worker thread starts
         │
         ▼
    Context (CancellationToken-like)
         │
         ├──► ctx.cancelled() ──► Check cancellation
         │
         ├──► ctx.sleep(ms) ────► Smart sleep
         │                        (wakes on cancel)
         ▼
    Worker loop ◄────────┐
         │               │
         │               │ Periodic check
         ▼               │
    if cancelled ────────┘
         │
         ▼
    Return from worker
         │
         ▼
    task.wait() ──► Join & cleanup
```

## Usage

```zig
const Task = @import("task").Task;

fn worker(ctx: Task.Context, counter: *std.atomic.Value(u64)) void {
    while (!ctx.cancelled()) {
        _ = counter.fetchAdd(1, .monotonic);

        // Smart sleep: wakes immediately if cancelled
        if (ctx.sleep(100)) break; // 100ms
    }
}

var counter = std.atomic.Value(u64).init(0);
var task = try Task.spawn(allocator, worker, .{&counter});
defer task.wait();

// Let it run for a bit
std.time.sleep(500 * std.time.ns_per_ms);

// Request cancellation (wakes thread immediately)
task.cancel();

// Wait for thread to finish
task.wait();
```

## Features

### Core API

- **`Task.spawn(allocator, function, args)`** - Spawn a cancellable thread with automatic context injection
- **`task.cancel()`** - Request cancellation and wake sleeping thread immediately
- **`task.wait()`** - Join thread and free resources (idempotent)
- **`ctx.cancelled()`** - Check if cancellation has been requested
- **`ctx.sleep(ms)`** - Smart sleep that wakes on cancel, returns true if cancelled

### Key Characteristics

- **CancellationToken pattern** - Familiar API for C# developers
- **Immediate wake-up** - Sleeping threads wake instantly on cancellation
- **Idempotent wait** - Safe to call `wait()` multiple times
- **Zero overhead** - Only atomic flag + mutex/cond for sleeping threads
- **Type-safe** - Worker function signature enforces Context as first parameter

### Design Patterns

```zig
// Pattern 1: Polling with periodic sleep
fn pollingWorker(ctx: Task.Context) void {
    while (!ctx.cancelled()) {
        // Do work
        performTask();

        // Sleep with cancellation check
        if (ctx.sleep(1000)) break;
    }
}

// Pattern 2: Long-running operation with checks
fn longRunningWorker(ctx: Task.Context, items: []Item) void {
    for (items) |item| {
        if (ctx.cancelled()) break;
        processItem(item);
    }
}

// Pattern 3: Blocking operation replacement
fn networkWorker(ctx: Task.Context) void {
    while (!ctx.cancelled()) {
        // Instead of blocking read, poll with timeout
        if (ctx.sleep(50)) break; // 50ms poll interval

        // Try non-blocking operation
        tryReceiveData();
    }
}
```

## Build Commands

```bash
# Run Beam-Task tests
zig build test-beam-task
```

## Requirements

- **Zig version**: 0.13.0 or later
- **Platform**: Any platform supported by Zig's standard library
- **Dependencies**: Part of [zigbeam](https://github.com/eakova/zigbeam)

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](../../../LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

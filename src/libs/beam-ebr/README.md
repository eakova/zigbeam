# Beam-Ebr (epoch)

Epoch-based garbage collection for building lock-free concurrent data structures in Zig.

## Overview

When building concurrent data structures, a fundamental problem arises: when a thread removes an object from a shared data structure, other threads may still have pointers to it. Beam-Ebr enables those threads to safely defer destruction until all pointers to that object have been dropped.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Beam-Ebr Flow                              │
└─────────────────────────────────────────────────────────────────┘

    GlobalEpoch (singleton)
         │
         │ registerParticipant()
         ▼
    Participant (per-thread)
         │
         ├─────► setThreadParticipant() ──► TLS binding
         │
         │ pin() / pinFor()
         ▼
       Guard ────────────────┐
         │                   │
         │                   │ deferDestroy()
         ▼                   ▼
    Lock-free ops      Deferred memory
         │                   │
         │ deinit()          │
         ▼                   │
    Release guard ◄──────────┘
         │
         ▼
    Epoch advances ──► Safe reclamation
```

## Usage

```zig
const ebr = @import("beam-ebr");

// Each thread registers once
var participant = ebr.Participant.init(allocator);
const global = ebr.global();
try global.registerParticipant(&participant);
defer global.unregisterParticipant(&participant);

ebr.setThreadParticipant(&participant);

// Use guards to protect memory access
var guard = ebr.pin();
defer guard.deinit();

// Safe to read lock-free data structures while guard is active
const value = my_lock_free_structure.read(&guard);

// Defer destruction of removed nodes
guard.deferDestroy(.{
    .ptr = old_node,
    .destroy_fn = destroyNode,
    .epoch = 0,
});
```

## Features

### Core API

- **`ebr.Participant.init(allocator)`** - Create a participant for thread registration
- **`ebr.global()`** - Get the global epoch instance
- **`global.registerParticipant(participant)`** - Register a thread with EBR system
- **`global.unregisterParticipant(participant)`** - Unregister a thread from EBR system
- **`ebr.setThreadParticipant(participant)`** - Bind participant to current thread for TLS access
- **`ebr.pin()`** - Create guard using thread-local participant (requires setThreadParticipant)
- **`ebr.pinFor(participant, global)`** - Create guard with explicit participant (no TLS required)
- **`guard.deinit()`** - Release guard and allow epoch advancement
- **`guard.deferDestroy(garbage)`** - Defer destruction until safe (all guards released)
- **`participant.deinit(global)`** - Clean up participant resources

### Performance Patterns

- **Single guard for batches** - Amortize guard overhead across multiple operations (~250x faster)
- **Manual participant management** - Avoid TLS overhead when needed
- **Custom destroy functions** - Handle complex cleanup logic (trees, graphs, etc.)

### Learn More

- **[Usage Samples](_ebr_samples.zig)** - 9 progressive examples from quick start to advanced patterns

## Build Commands

```bash
# Run all EBR tests
zig build test

# Run EBR samples (quick start to advanced)
zig build samples-ebr -Doptimize=ReleaseFast

# Run EBR benchmarks
zig build bench-ebr -Doptimize=ReleaseFast

# Test EBR shutdown mechanism
zig build test-ebr-shutdown -Doptimize=ReleaseFast

# Measure EBR garbage queue pressure (diagnostic)
zig build ebr-queue-pressure -Doptimize=ReleaseFast
```

## Requirements

- **Zig version**: 0.13.0 or later
- **Platform**: Any platform supported by Zig's standard library
- **Dependencies**: Part of [zig-beam](https://github.com/eakova/zig-beam)

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](../../../LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

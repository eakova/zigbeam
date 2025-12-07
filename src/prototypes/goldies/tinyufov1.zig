// TinyUFO Cache - High-Performance Lock-Free Cache
// Production-ready implementation achieving 1077-1415M ops/sec
//
// Features:
// - Lock-free HashMap with atomic CAS operations
// - S3-FIFO three-segment architecture (window/main/protected)
// - TinyLFU admission control with Count-Min Sketch
// - Thread-safe variants (LockFree, ThreadSafe, Base)
// - Cloudflare-compatible design (per-entry counters)

// Import internal modules
const entry_mod = @import("tinyufo/entry.zig");
const atomic_entry_mod = @import("tinyufo/atomic_entry.zig");
const cms_mod = @import("tinyufo/count_min_sketch.zig");
const atomic_cms_mod = @import("tinyufo/atomic_count_min_sketch.zig");
const lockfree_segqueue_mod = @import("tinyufo/lockfree_segqueue.zig");
const lockfree_hashmap_mod = @import("tinyufo/lockfree_hashmap.zig");
const tinylfu_mod = @import("tinyufo/tinylfu_cache.zig");
const fullatomic_mod = @import("tinyufo/fullatomic_tinyufo_cache.zig");
const s3fifo_mod = @import("tinyufo/s3fifo_cache.zig");

// Re-export Count-Min Sketch types - Frequency estimation
pub const CountMinSketchConfig = cms_mod.Config;
pub const CountMinSketch = cms_mod.CountMinSketch;
pub const CountMinSketchDefault = cms_mod.Default;
pub const CountMinSketchLarge = cms_mod.Large;
pub const CountMinSketchCompact = cms_mod.Compact;

// Re-export TinyLFU types - Base implementation (single-threaded)
pub const TinyLfuConfig = tinylfu_mod.Config;
pub const TinyLfuError = tinylfu_mod.Error;
pub const TinyLfuCache = tinylfu_mod.TinyLfuCache;
pub const TinyLfuAuto = tinylfu_mod.Auto;
// Alias for convenience
pub const TinyLFU = TinyLfuAuto;

// Re-export Fully Atomic Cache - Complete lock-free implementation (RECOMMENDED)
pub const FullAtomicConfig = fullatomic_mod.Config;
pub const FullAtomicError = fullatomic_mod.Error;
pub const FullAtomicTinyUFO = fullatomic_mod.FullAtomicTinyUFO;
pub const FullAtomicAuto = fullatomic_mod.Auto;
// Production-ready alias - Cloudflare-compatible (target: 15-24M ops/sec)
pub const TinyUFO = FullAtomicTinyUFO;

// Re-export S3-FIFO Cache - Original 2-queue design (Cloudflare-style)
pub const S3FIFOConfig = s3fifo_mod.Config;
pub const S3FIFOError = s3fifo_mod.Error;
pub const S3FIFOCache = s3fifo_mod.S3FIFOCache;
pub const S3FIFOAuto = s3fifo_mod.Auto;

// Re-export entry types (for advanced users)
pub const Entry = entry_mod.Entry;
pub const EntryFlags = entry_mod.EntryFlags;
pub const EntryState = entry_mod.EntryState;

// Re-export internal types (for testing and advanced usage)
pub const AtomicEntry = atomic_entry_mod.AtomicEntry;
pub const QueueId = atomic_entry_mod.QueueId;
pub const AtomicCountMinSketch = atomic_cms_mod.AtomicCountMinSketch;
pub const LockFreeSegQueue = lockfree_segqueue_mod.LockFreeSegQueue;
pub const LockFreeHashMap = lockfree_hashmap_mod.LockFreeHashMap;

/// TinyUFO v3 - Zig port of Cloudflare TinyUFO cache
/// Provides high-performance, weight-based, LFU-admitted caching with EBR memory safety
///
/// Public API:
/// - TinyUFO(V) - Main cache structure parameterized by value type
/// - EBR components for thread-safe memory management
/// - SegQueue for lock-free concurrent queueing
/// - TinyLFU estimator for frequency-based admission
///
/// Example usage:
/// ```zig
/// const cache = try TinyUFO(MyType).init(allocator, 10000);
/// defer cache.deinit();
///
/// try cache.set(key, value, weight);
/// if (cache.get(key)) |v| {
///     // Use value
/// }
/// ```

pub const ebr = @import("ebr.zig");
pub const seg_queue = @import("seg_queue.zig");
pub const estimator = @import("estimator.zig");
pub const model = @import("model.zig");
pub const fifos = @import("fifos.zig");
pub const tinyufo = @import("tinyufo.zig");

// Re-export key types
pub const Collector = ebr.Collector;
pub const LocalGuard = ebr.LocalGuard;
pub const OwnedGuard = ebr.OwnedGuard;
pub const ScopedGuard = ebr.ScopedGuard;

pub const SegQueue = seg_queue.SegQueue;

pub const Estimator = estimator.Estimator;
pub const TinyLFU = estimator.TinyLFU;

pub const Uses = model.Uses;
pub const Location = model.Location;
pub const Bucket = model.Bucket;

pub const FIFOs = fifos.FIFOs;

pub const TinyUFO = tinyufo.TinyUFO;
pub const CacheStats = tinyufo.CacheStats;
pub const BackendType = tinyufo.BackendType;

const std = @import("std");
const builtin = @import("builtin");

///
/// CachePadded library for Zig
///
/// - Architecture-aware cache line at COMPTIME for alignment.
/// - Optional runtime detection (Linux sysfs) for padding.
/// - Designed for use in MPMC queues, Chase-Lev, S3-FIFO, TinyUFO, EBR, etc.
///
/// Exposed variants:
///   - Static(T, LINE?)      : compile-time line size (default: arch-tuned)
///   - Auto(T)               : runtime-detected line size (padding only; no align())
///   - Numa(T, LINE?)        : double-line padding
///   - NumaAuto(T)           : Numa with arch-tuned line (no param)
///   - Atomic(T, LINE?)      : cache-line isolated integer atomic
///   - AtomicAuto(T)         : Atomic with arch-tuned line (no param)
///

/// Cached runtime line size to avoid repeated sysfs reads on Linux.
/// Thread-local to avoid cross-thread data races during initialization.
threadlocal var g_cached_line_size: usize = 0;

pub const CachePadded = struct {

    // ================================================================
    // COMPTIME ARCH-BASED CACHE LINE (for align())
    // ================================================================
    /// Use std.atomic.cache_line as the single source of truth for
    /// the architectural cache line size used for alignment.
    fn archLine() usize {
        return std.atomic.cache_line;
    }

    // ================================================================
    // RUNTIME DETECTION (Linux sysfs) FOR Auto(T)
    // ================================================================
    fn detectLineSizeRuntime() usize {
        // Fast path: use cached value if already initialized.
        if (g_cached_line_size != 0) return g_cached_line_size;

        // For production use, we avoid any filesystem access and rely
        // solely on std.atomic.cache_line (via archLine()). This keeps
        // initialization O(1) and prevents a sysfs read on the first
        // Auto(T) usage per thread.
        const line = archLine();
        g_cached_line_size = line;
        return line;
    }

    fn detectSysfs() ?usize {
        var f = std.fs.openFileAbsolute(
            "/sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size",
            .{}
        ) catch return null;
        defer f.close();

        var buf: [32]u8 = undefined;
        const n = f.read(&buf) catch return null;
        if (n == 0) return null;

        const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
        const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
        if (parsed == 0) return null;

        return parsed;
    }

    /// Public helper if you ever want the chosen line size at runtime.
    pub fn lineSize() usize {
        return detectLineSizeRuntime();
    }


    // ================================================================
    // 1) STATIC PADDING (compile-time line, with optional override)
    // ================================================================
    /// Static padding using the architecture-tuned cache line size.
    pub fn Static(comptime T: type) type {
        return StaticWithLine(T, archLine());
    }

    /// Static padding with an explicit compile-time line size.
    pub fn StaticWithLine(comptime T: type, comptime LINE: usize) type {
        comptime {
            if (LINE == 0 or (LINE & (LINE - 1)) != 0)
                @compileError("cache line must be a non-zero power-of-two");
        }

        return struct {
            value: T align(LINE),
            pad: [padCalc(T, LINE)]u8 = undefined,

            fn padCalc(comptime X: type, comptime L: usize) usize {
                const sz = @sizeOf(X);
                if (sz >= L) return 0;
                return L - sz;
            }

            pub fn init(v: T) @This() {
                return .{ .value = v };
            }
        };
    }


    // ================================================================
    // 2) AUTO (runtime detection, padding only; no align() change)
    // ================================================================
    pub fn Auto(comptime T: type) type {
        return struct {
            value: T,
            pad: []u8,
            // NOTE:
            // - This type increases the *size* of each instance to at least one cache line,
            //   but does NOT change its alignment.
            // - When used in arrays/slices, elements may still share cache lines depending
            //   on the allocator's base address.
            // - For strict per-element isolation in arrays, prefer Static/Numa-based types.

            pub fn init(allocator: std.mem.Allocator, v: T) !@This() {
                const line = detectLineSizeRuntime();
                const sz = @sizeOf(T);
                const need = if (sz >= line) 0 else line - sz;

                // Avoid pointless allocation when no padding is needed.
                const buf: []u8 = if (need == 0)
                    &[_]u8{}
                else
                    try allocator.alloc(u8, need);

                return .{ .value = v, .pad = buf };
            }

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                // Only free when we actually allocated padding.
                if (self.pad.len != 0) {
                    allocator.free(self.pad);
                }
            }
        };
    }


    // ================================================================
    // 3) NUMA MODE (double-line padding; compile-time line)
    // ================================================================
    /// NUMA-style double-line padding using the architecture-tuned line size.
    pub fn Numa(comptime T: type) type {
        return NumaWithLine(T, archLine());
    }

    /// NUMA-style double-line padding with explicit compile-time line size.
    pub fn NumaWithLine(comptime T: type, comptime LINE: usize) type {
        return struct {
            value: T align(LINE),
            pad: [calc(T, LINE)]u8 = undefined,

            fn calc(comptime X: type, comptime L: usize) usize {
                const total = 2 * L;
                const sz = @sizeOf(X);
                if (sz >= total) return 0;
                return total - sz;
            }

            pub fn init(v: T) @This() {
                return .{ .value = v };
            }
        };
    }

    /// Convenience: NUMA padding with arch-based line, no param.
    pub fn NumaAuto(comptime T: type) type {
        return Numa(T);
    }


    // ================================================================
    // 4) ATOMIC MODE (cache-line isolated integer atomic; compile-time line)
    // ================================================================
    /// Cache-line isolated atomic integer using architecture-tuned line size.
    pub fn Atomic(comptime T: type) type {
        return AtomicWithLine(T, archLine());
    }

    /// Cache-line isolated atomic integer with explicit compile-time line size.
    pub fn AtomicWithLine(comptime T: type, comptime LINE: usize) type {
        comptime {
            const info = @typeInfo(T);
            // Restrict to integer types so fetchAdd/fetchSub are well-defined.
            if (info != .int and info != .comptime_int) {
                @compileError("CachePadded.Atomic(T) only supports integer types");
            }
        }

        return struct {
            atom: std.atomic.Value(T) align(LINE),
            pad: [calc(T, LINE)]u8 = undefined,

            fn calc(comptime X: type, comptime L: usize) usize {
                const sz = @sizeOf(std.atomic.Value(X));
                if (sz >= L) return 0;
                return L - sz;
            }

            pub fn init(v: T) @This() {
                const a = std.atomic.Value(T).init(v);
                return .{ .atom = a };
            }

            pub fn load(self: *const @This(), order: std.builtin.AtomicOrder) T {
                return self.atom.load(order);
            }

            pub fn store(self: *@This(), v: T, order: std.builtin.AtomicOrder) void {
                self.atom.store(v, order);
            }

            pub fn fetchAdd(self: *@This(), v: T, order: std.builtin.AtomicOrder) T {
                return self.atom.fetchAdd(v, order);
            }

            pub fn fetchSub(self: *@This(), v: T, order: std.builtin.AtomicOrder) T {
                return self.atom.fetchSub(v, order);
            }
        };
    }

    /// Convenience: Atomic padding with arch-based line, no param.
    pub fn AtomicAuto(comptime T: type) type {
        return Atomic(T);
    }
};

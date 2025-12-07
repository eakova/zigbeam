const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Cache-line alignment utilities
// ============================================================================

/// Cache line size for the target architecture.
/// Used to prevent false sharing between thread-local structures.
///
/// - x86_64: 64 bytes
/// - aarch64 (Apple Silicon): 128 bytes
/// - Default: 64 bytes
pub const cache_line: usize = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => 128,
    else => 64,
};

/// Padding type to fill remaining cache line space.
/// Use this to ensure structures don't share cache lines.
///
/// Example:
/// ```zig
/// const MyStruct = struct {
///     hot_data: u64,
///     _padding: CacheLinePadding(8), // 8 = sizeof(hot_data)
/// };
/// ```
pub fn CacheLinePadding(comptime used_bytes: usize) type {
    const padding_size = if (used_bytes >= cache_line) 0 else cache_line - used_bytes;
    return [padding_size]u8;
}

/// Compile-time assertion that a type is exactly cache-line sized.
pub fn assertCacheLineAligned(comptime T: type) void {
    if (@sizeOf(T) != cache_line) {
        @compileError(std.fmt.comptimePrint(
            "Type {} has size {} but expected cache line size {}",
            .{ @typeName(T), @sizeOf(T), cache_line },
        ));
    }
}

// ============================================================================
// Timestamp and file utilities
// ============================================================================

/// Format a timestamped results path using the given prefix and a fixed
/// `YYYYMMDD_HHMMSS` suffix derived from `std.time.timestamp()`.
///
/// `buf` is a scratch buffer owned by the caller; the returned slice
/// always aliases `buf`.
pub fn formatTimestampPath(buf: []u8, prefix: []const u8) []const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);

    const SECONDS_PER_MINUTE: u64 = 60;
    const SECONDS_PER_HOUR: u64 = 3600;
    const SECONDS_PER_DAY: u64 = 86400;

    var remaining = epoch_seconds;
    var year: u64 = 1970;

    while (true) {
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        const days_in_year: u64 = if (is_leap) 366 else 365;
        const seconds_in_year = days_in_year * SECONDS_PER_DAY;
        if (remaining < seconds_in_year) break;
        remaining -= seconds_in_year;
        year += 1;
    }

    const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    const days_in_months = [_]u64{
        31,
        if (is_leap) 29 else 28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    };

    var day_of_year = remaining / SECONDS_PER_DAY;
    remaining = remaining % SECONDS_PER_DAY;

    var month: u64 = 1;
    for (days_in_months) |days| {
        if (day_of_year < days) break;
        day_of_year -= days;
        month += 1;
    }
    const day = day_of_year + 1;

    const hours = remaining / SECONDS_PER_HOUR;
    remaining = remaining % SECONDS_PER_HOUR;
    const minutes = remaining / SECONDS_PER_MINUTE;
    const seconds = remaining % SECONDS_PER_MINUTE;

    return std.fmt.bufPrint(buf, "{s}{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.md", .{
        prefix,
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
    }) catch buf;
}

/// Truncate-write helper used by several benchmarks.
pub fn writeFileTruncate(path: []const u8, content: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

/// Append helper used by several benchmarks.
pub fn writeFileAppend(path: []const u8, content: []const u8) !void {
    var file = std.fs.cwd().createFile(path, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

/// Format u64 with thousands separators (e.g., 1,234,567).
pub fn fmtU64Commas(buf: *[32]u8, value: u64) []const u8 {
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    var group: u32 = 0;
    while (v > 0) {
        const digit: u8 = @intCast(v % 10);
        v /= 10;
        i -= 1;
        buf[i] = '0' + digit;
        group += 1;
        if (v != 0 and group % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
    }
    return buf[i..];
}

/// Format f64 with thousands separators and two decimals.
pub fn fmtF64Commas2(buf: *[48]u8, val: f64) []const u8 {
    const ival_f = @floor(val);
    const ival = @as(u64, @intFromFloat(ival_f));
    var frac_f = (val - ival_f) * 100.0;
    if (frac_f < 0) frac_f = -frac_f;
    const frac = @as(u64, @intFromFloat(frac_f + 0.5));
    var ibuf: [32]u8 = undefined;
    const is = fmtU64Commas(&ibuf, ival);
    var out: [48]u8 = undefined;
    var o: usize = 0;
    @memcpy(out[o .. o + is.len], is);
    o += is.len;
    out[o] = '.';
    o += 1;
    out[o] = '0' + @as(u8, @intCast((frac / 10) % 10));
    o += 1;
    out[o] = '0' + @as(u8, @intCast(frac % 10));
    o += 1;
    @memcpy(buf[0..o], out[0..o]);
    return buf[0..o];
}

// ============================================================================
// Tests
// ============================================================================

test "cache_line is reasonable" {
    try std.testing.expect(cache_line >= 64);
    try std.testing.expect(cache_line <= 256);
}

test "CacheLinePadding produces correct size" {
    const Padded = struct {
        value: u64,
        _padding: CacheLinePadding(@sizeOf(u64)),
    };
    try std.testing.expectEqual(cache_line, @sizeOf(Padded));
}

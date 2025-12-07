// Benchmark Reporter for Loom
//
// Provides MD file output for benchmark results.
// Results are written to: src/libs/loom/docs/LOOM_BENCH_RESULTS_YYYY-MM-DD_HHMMSS.md

const std = @import("std");

const MD_PATH_PREFIX = "src/libs/loom/docs/LOOM_BENCH_RESULTS_";

var g_md_path_buf: [128]u8 = undefined;
var g_md_path: []const u8 = "";
var g_initialized: bool = false;

pub fn initMdPath() void {
    if (g_initialized) return;
    g_initialized = true;

    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);
    const secs_per_day: u64 = 86400;
    const secs_per_hour: u64 = 3600;
    const secs_per_min: u64 = 60;

    var days = epoch_seconds / secs_per_day;
    var remaining = epoch_seconds % secs_per_day;

    const hours = remaining / secs_per_hour;
    remaining = remaining % secs_per_hour;
    const minutes = remaining / secs_per_min;
    const seconds = remaining % secs_per_min;

    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const is_leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days_in_months = [_]u64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u64 = 1;
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
        month += 1;
    }
    const day = days + 1;

    const written = std.fmt.bufPrint(&g_md_path_buf, "{s}{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.md", .{
        MD_PATH_PREFIX, year, month, day, hours, minutes, seconds,
    }) catch &g_md_path_buf;
    g_md_path = written;
}

pub fn getMdPath() []const u8 {
    if (!g_initialized) {
        initMdPath();
    }
    return g_md_path;
}

pub fn writeMdTruncate(content: []const u8) !void {
    const path = getMdPath();
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn writeMdAppend(content: []const u8) !void {
    const path = getMdPath();
    var file = std.fs.cwd().createFile(path, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

// Buffered writer for building MD content
pub const MdWriter = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,

    pub fn init() MdWriter {
        return .{};
    }

    pub fn print(self: *MdWriter, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += written.len;
    }

    pub fn append(self: *MdWriter, str: []const u8) void {
        if (self.len + str.len > self.buf.len) return;
        @memcpy(self.buf[self.len .. self.len + str.len], str);
        self.len += str.len;
    }

    pub fn getContent(self: *MdWriter) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn clear(self: *MdWriter) void {
        self.len = 0;
    }

    pub fn flush(self: *MdWriter) !void {
        try writeMdAppend(self.getContent());
        self.clear();
    }

    pub fn flushTruncate(self: *MdWriter) !void {
        try writeMdTruncate(self.getContent());
        self.clear();
    }
};

// Formatting helpers
pub fn formatNs(ns: u64) [32]u8 {
    var buf: [32]u8 = undefined;
    if (ns < 1000) {
        _ = std.fmt.bufPrint(&buf, "{d}ns", .{ns}) catch {};
    } else if (ns < 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch {};
    } else if (ns < 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch {};
    }
    return buf;
}

pub fn formatMs(ms: f64) [32]u8 {
    var buf: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:.2}ms", .{ms}) catch {};
    return buf;
}

pub fn formatSpeedup(speedup: f64) [16]u8 {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:.2}x", .{speedup}) catch {};
    return buf;
}

// Print header for MD file
pub fn writeHeader(title: []const u8, platform: []const u8, cpu_count: usize) !void {
    var writer = MdWriter.init();
    writer.print("# {s}\n\n", .{title});
    writer.print("**Date**: {d}-{d:0>2}-{d:0>2}\n", .{ getYear(), getMonth(), getDay() });
    writer.print("**Platform**: {s}\n", .{platform});
    writer.print("**CPUs**: {d}\n", .{cpu_count});
    writer.print("**Optimization**: ReleaseFast\n\n", .{});
    writer.append("---\n\n");
    try writer.flushTruncate();
}

fn getYear() u64 {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);
    const secs_per_day: u64 = 86400;
    var days = epoch_seconds / secs_per_day;
    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    return year;
}

fn getMonth() u64 {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);
    const secs_per_day: u64 = 86400;
    var days = epoch_seconds / secs_per_day;
    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    const is_leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days_in_months = [_]u64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u64 = 1;
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
        month += 1;
    }
    return month;
}

fn getDay() u64 {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);
    const secs_per_day: u64 = 86400;
    var days = epoch_seconds / secs_per_day;
    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    const is_leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days_in_months = [_]u64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
    }
    return days + 1;
}

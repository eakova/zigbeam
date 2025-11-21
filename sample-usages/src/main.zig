const std = @import("std");
const usage_sample = @import("usage_sample");
const beam = @import("zig_beam");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 1) Tagged pointer example (store a 1-bit tag in a pointer)
    const TaggedPointer = beam.Utils.TaggedPointer(*usize, 1);
    var x: usize = 42;
    var tagged = try TaggedPointer.new(&x, 1);
    std.debug.print("Tagged: tag={}, ptr={*}\n", .{ tagged.getTag(), tagged.getPtr() });

    // 2) Thread-local cache example (push/pop)
    const Cache = beam.Utils.ThreadLocalCache(*usize, null);
    var cache: Cache = .{};
    _ = cache.push(&x);
    const got = cache.pop().?;
    std.debug.print("Cache pop -> {}\n", .{got.*});

    // 3) Arc example (init, clone, release)
    const Arc = beam.Utils.Arc(u64);
    var a = try Arc.init(alloc, 123);
    defer a.release();
    const c = a.clone();
    defer c.release();
    std.debug.print("Arc value = {}\n", .{a.get().*});

    // 4) ArcPool example (create + recycle)
    const ArcPool = beam.Utils.ArcPool([64]u8, false);
    var pool = ArcPool.init(alloc, .{});
    defer pool.deinit();
    const payload = [_]u8{0} ** 64;
    const pooled = try pool.create(payload);
    pool.recycle(pooled);
    std.debug.print("ArcPool create+recycle ok (64B)\n", .{});

    // Keep original sample’s buffered print
    try usage_sample.bufferedPrint();
}

test "beam: tagged pointer roundtrip" {
    const TaggedPointer = beam.Utils.TaggedPointer(*usize, 1);
    var v: usize = 7;
    const bits = (try TaggedPointer.new(&v, 1)).toUnsigned();
    const tp = TaggedPointer.fromUnsigned(bits);
    try std.testing.expectEqual(@as(u1, 1), tp.getTag());
    try std.testing.expectEqual(&v, tp.getPtr());
}

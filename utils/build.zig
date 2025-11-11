const std = @import("std");

const ImportSpec = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const TestSpec = struct {
    name: []const u8,
    path: []const u8,
    imports: []const ImportSpec = &.{},
};

const BenchSpec = struct {
    name: []const u8,
    exe_name: []const u8,
    path: []const u8,
    imports: []const ImportSpec = &.{},
};

fn addTestRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: TestSpec,
) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path(spec.path),
        .target = target,
        .optimize = optimize,
    });
    for (spec.imports) |imp| {
        mod.addImport(imp.name, imp.module);
    }
    const test_exe = b.addTest(.{ .root_module = mod });
    return b.addRunArtifact(test_exe);
}

fn addBenchRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: BenchSpec,
) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path(spec.path),
        .target = target,
        .optimize = optimize,
    });
    for (spec.imports) |imp| {
        mod.addImport(imp.name, imp.module);
    }
    const exe = b.addExecutable(.{ .name = spec.exe_name, .root_module = mod });
    return b.addRunArtifact(exe);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const allocator = b.allocator;

    // Canonical modules exposed to the entire workspace.
    const tagged_ptr_mod = b.addModule("tagged_pointer", .{
        .root_source_file = b.path("src/tagged-pointer/tagged_pointer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tlc_mod = b.addModule("thread_local_cache", .{
        .root_source_file = b.path("src/thread-local-cache/thread_local_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    tlc_mod.addImport("tagged_pointer", tagged_ptr_mod);

    const arc_mod = b.addModule("arc_core", .{
        .root_source_file = b.path("src/arc/arc.zig"),
        .target = target,
        .optimize = optimize,
    });
    arc_mod.addImport("tagged_pointer", tagged_ptr_mod);

    const arc_pool_mod = b.addModule("arc_pool", .{
        .root_source_file = b.path("src/arc/arc-pool/arc_pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    arc_pool_mod.addImport("tagged_pointer", tagged_ptr_mod);
    arc_pool_mod.addImport("arc_core", arc_mod);
    arc_pool_mod.addImport("thread_local_cache", tlc_mod);

    const arc_cycle_mod = b.addModule("arc_cycle_detector", .{
        .root_source_file = b.path("src/arc/cycle-detector/arc_cycle_detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    arc_cycle_mod.addImport("arc_core", arc_mod);
    arc_cycle_mod.addImport("arc_pool", arc_pool_mod);
    arc_cycle_mod.addImport("tagged_pointer", tagged_ptr_mod);

    const root_mod = b.addModule("zig_beam_utils", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("tagged_pointer", tagged_ptr_mod);
    root_mod.addImport("thread_local_cache", tlc_mod);
    root_mod.addImport("arc_core", arc_mod);
    root_mod.addImport("arc_pool", arc_pool_mod);
    root_mod.addImport("arc_cycle_detector", arc_cycle_mod);

    const test_specs = [_]TestSpec{
        .{
            .name = "tlc-unit",
            .path = "src/thread-local-cache/_thread_local_cache_unit_tests.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "tlc-integration",
            .path = "src/thread-local-cache/_thread_local_cache_integration_test.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "tlc-fuzz",
            .path = "src/thread-local-cache/_thread_local_cache_fuzz_tests.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "tlc-samples",
            .path = "src/thread-local-cache/_thread_local_cache_samples.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "tagged-unit",
            .path = "src/tagged-pointer/_tagged_pointer_unit_tests.zig",
        },
        .{
            .name = "tagged-integration",
            .path = "src/tagged-pointer/_tagged_pointer_integration_tests.zig",
        },
        .{
            .name = "tagged-samples",
            .path = "src/tagged-pointer/_tagged_pointer_samples.zig",
        },
        .{
            .name = "arc-unit",
            .path = "src/arc/_arc_unit_tests.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "arc-samples",
            .path = "src/arc/_arc_samples.zig",
            .imports = &.{
                .{ .name = "tagged_pointer", .module = tagged_ptr_mod },
                .{ .name = "arc_core", .module = arc_mod },
                .{ .name = "arc_pool", .module = arc_pool_mod },
                .{ .name = "thread_local_cache", .module = tlc_mod },
            },
        },
        .{
            .name = "arc-cycle-unit",
            .path = "src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig",
            .imports = &.{
                .{ .name = "arc_cycle_detector", .module = arc_cycle_mod },
                .{ .name = "arc_core", .module = arc_mod },
            },
        },
        .{
            .name = "arc-cycle-integration",
            .path = "src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig",
            .imports = &.{
                .{ .name = "arc_cycle_detector", .module = arc_cycle_mod },
                .{ .name = "arc_core", .module = arc_mod },
                .{ .name = "arc_pool", .module = arc_pool_mod },
            },
        },
        .{
            .name = "arc-pool-unit",
            .path = "src/arc/arc-pool/_arc_pool_unit_tests.zig",
            .imports = &.{
                .{ .name = "arc_core", .module = arc_mod },
                .{ .name = "arc_pool", .module = arc_pool_mod },
            },
        },
        .{
            .name = "arc-pool-integration",
            .path = "src/arc/arc-pool/_arc_pool_integration_tests.zig",
            .imports = &.{
                .{ .name = "arc_core", .module = arc_mod },
                .{ .name = "arc_pool", .module = arc_pool_mod },
                .{ .name = "thread_local_cache", .module = tlc_mod },
            },
        },
    };

    const bench_specs = [_]BenchSpec{
        .{
            .name = "tlc-bench",
            .exe_name = "tlc_bench",
            .path = "src/thread-local-cache/_thread_local_cache_benchmarks.zig",
            .imports = &.{.{ .name = "tagged_pointer", .module = tagged_ptr_mod }},
        },
        .{
            .name = "arc-bench",
            .exe_name = "arc_bench",
            .path = "src/arc/_arc_benchmarks.zig",
            .imports = &.{
                .{ .name = "zig_beam_utils", .module = root_mod },
            },
        },
    };

    var tagged_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer tagged_runs.deinit(allocator);
    var tlc_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer tlc_runs.deinit(allocator);
    var arc_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer arc_runs.deinit(allocator);
    var arc_pool_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer arc_pool_runs.deinit(allocator);
    var arc_cycle_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer arc_cycle_runs.deinit(allocator);
    var tagged_sample_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer tagged_sample_runs.deinit(allocator);
    var tlc_sample_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer tlc_sample_runs.deinit(allocator);
    var arc_sample_runs = std.ArrayListUnmanaged(*std.Build.Step.Run){};
    defer arc_sample_runs.deinit(allocator);

    const test_step = b.step("test", "Run utils library tests");
    for (test_specs) |spec| {
        const run = addTestRun(b, target, optimize, spec);
        test_step.dependOn(&run.step);
        if (std.mem.startsWith(u8, spec.path, "src/tagged-pointer/_tagged_pointer_samples.zig")) {
            tagged_sample_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/tagged-pointer/")) {
            tagged_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/thread-local-cache/_thread_local_cache_samples.zig")) {
            tlc_sample_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/thread-local-cache/")) {
            tlc_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/arc/arc-pool/")) {
            arc_pool_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/arc/cycle-detector/")) {
            arc_cycle_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/arc/_arc_samples")) {
            arc_sample_runs.append(allocator, run) catch unreachable;
        } else if (std.mem.startsWith(u8, spec.path, "src/arc/")) {
            arc_runs.append(allocator, run) catch unreachable;
        }
    }

    const bench_step = b.step("bench-tlc", "Run thread-local cache benchmarks");
    const tlc_bench = addBenchRun(b, target, optimize, bench_specs[0]);
    bench_step.dependOn(&tlc_bench.step);

    const arc_bench_step = b.step("bench-arc", "Run ARC benchmarks");
    const arc_bench_run = addBenchRun(b, target, optimize, bench_specs[1]);
    arc_bench_step.dependOn(&arc_bench_run.step);

    const tagged_step = b.step("test-tagged", "Run tagged pointer tests");
    for (tagged_runs.items) |run| tagged_step.dependOn(&run.step);

    const tlc_step = b.step("test-tlc", "Run thread-local cache tests");
    for (tlc_runs.items) |run| tlc_step.dependOn(&run.step);

    const arc_step = b.step("test-arc", "Run ARC core tests");
    for (arc_runs.items) |run| arc_step.dependOn(&run.step);

    const arc_pool_step = b.step("test-arc-pool", "Run ARC pool tests");
    for (arc_pool_runs.items) |run| arc_pool_step.dependOn(&run.step);

    const arc_cycle_step = b.step("test-arc-cycle", "Run ARC cycle detector tests");
    for (arc_cycle_runs.items) |run| arc_cycle_step.dependOn(&run.step);

    const tagged_samples_step = b.step("samples-tagged", "Run tagged pointer samples");
    for (tagged_sample_runs.items) |run| tagged_samples_step.dependOn(&run.step);

    const tlc_samples_step = b.step("samples-tlc", "Run thread-local cache samples");
    for (tlc_sample_runs.items) |run| tlc_samples_step.dependOn(&run.step);

    const arc_samples_step = b.step("samples-arc", "Run ARC sample snippets");
    for (arc_sample_runs.items) |run| arc_samples_step.dependOn(&run.step);
}

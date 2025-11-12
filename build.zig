const std = @import("std");

const ImportSpec = struct { name: []const u8, module: *std.Build.Module };
const TestSpec = struct { name: []const u8, path: []const u8 };
const BenchSpec = struct { name: []const u8, exe_name: []const u8, path: []const u8, imports: []const ImportSpec = &.{} };

fn addTestRun(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spec: TestSpec, imports: []const ImportSpec) *std.Build.Step.Run {
    const mod = b.createModule(.{ .root_source_file = b.path(spec.path), .target = target, .optimize = optimize });
    for (imports) |imp| mod.addImport(imp.name, imp.module);
    const test_exe = b.addTest(.{ .root_module = mod });
    return b.addRunArtifact(test_exe);
}

fn addBenchRun(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spec: BenchSpec) *std.Build.Step.Run {
    const mod = b.createModule(.{ .root_source_file = b.path(spec.path), .target = target, .optimize = optimize });
    for (spec.imports) |imp| mod.addImport(imp.name, imp.module);
    const exe = b.addExecutable(.{ .name = spec.exe_name, .root_module = mod });
    return b.addRunArtifact(exe);
}

fn add_utils(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wrapper: *std.Build.Module) void {
    // Top-level steps defined once here
    const step_test = b.step("test", "Run all zig-beam.utils tests");
    const step_tagged = b.step("test-tagged", "Run tagged-pointer tests");
    const step_tlc = b.step("test-tlc", "Run thread-local cache tests");
    const step_arc = b.step("test-arc", "Run Arc core tests");
    const step_arc_pool = b.step("test-arc-pool", "Run ArcPool tests");
    const step_arc_cycle = b.step("test-arc-cycle", "Run cycle-detector tests");
    const step_samples_tagged = b.step("samples-tagged", "Run tagged-pointer samples");
    const step_samples_tlc = b.step("samples-tlc", "Run thread-local cache samples");
    const step_samples_arc = b.step("samples-arc", "Run Arc samples");
    const step_bench_tlc = b.step("bench-tlc", "Run Thread-Local Cache benchmarks");
    const step_bench_arc = b.step("bench-arc", "Run Arc benchmarks");
    const step_bench_arc_pool = b.step("bench-arc-pool", "Run ArcPool benchmarks");

    // Internal modules (not exported directly): use createModule
    const tagged_ptr_mod = b.createModule(.{ .root_source_file = b.path("src/utils/tagged-pointer/tagged_pointer.zig"), .target = target, .optimize = optimize });
    const tlc_mod = b.createModule(.{ .root_source_file = b.path("src/utils/thread-local-cache/thread_local_cache.zig"), .target = target, .optimize = optimize });
    tlc_mod.addImport("tagged_pointer", tagged_ptr_mod);
    const arc_mod = b.createModule(.{ .root_source_file = b.path("src/utils/arc/arc.zig"), .target = target, .optimize = optimize });
    arc_mod.addImport("tagged_pointer", tagged_ptr_mod);
    const arc_pool_mod = b.createModule(.{ .root_source_file = b.path("src/utils/arc/arc-pool/arc_pool.zig"), .target = target, .optimize = optimize });
    arc_pool_mod.addImport("tagged_pointer", tagged_ptr_mod);
    arc_pool_mod.addImport("arc_core", arc_mod);
    arc_pool_mod.addImport("thread_local_cache", tlc_mod);
    const arc_cycle_mod = b.createModule(.{ .root_source_file = b.path("src/utils/arc/cycle-detector/arc_cycle_detector.zig"), .target = target, .optimize = optimize });
    arc_cycle_mod.addImport("arc_core", arc_mod);
    arc_cycle_mod.addImport("arc_pool", arc_pool_mod);
    arc_cycle_mod.addImport("tagged_pointer", tagged_ptr_mod);
    // Wire internal modules into the public wrapper provided by build()
    wrapper.addImport("tagged_pointer", tagged_ptr_mod);
    wrapper.addImport("thread_local_cache", tlc_mod);
    wrapper.addImport("arc_core", arc_mod);
    wrapper.addImport("arc_pool", arc_pool_mod);
    wrapper.addImport("arc_cycle_detector", arc_cycle_mod);

    // Test specs (utils)
    const test_specs = [_]TestSpec{
        .{ .name = "tlc-unit", .path = "src/utils/thread-local-cache/_thread_local_cache_unit_tests.zig" },
        .{ .name = "tlc-integration", .path = "src/utils/thread-local-cache/_thread_local_cache_integration_test.zig" },
        .{ .name = "tlc-fuzz", .path = "src/utils/thread-local-cache/_thread_local_cache_fuzz_tests.zig" },
        .{ .name = "tlc-samples", .path = "src/utils/thread-local-cache/_thread_local_cache_samples.zig" },
        .{ .name = "tagged-unit", .path = "src/utils/tagged-pointer/_tagged_pointer_unit_tests.zig" },
        .{ .name = "tagged-integration", .path = "src/utils/tagged-pointer/_tagged_pointer_integration_tests.zig" },
        .{ .name = "tagged-samples", .path = "src/utils/tagged-pointer/_tagged_pointer_samples.zig" },
        .{ .name = "arc-unit", .path = "src/utils/arc/_arc_unit_tests.zig" },
        .{ .name = "arc-samples", .path = "src/utils/arc/_arc_samples.zig" },
        .{ .name = "arc-cycle-unit", .path = "src/utils/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig" },
        .{ .name = "arc-cycle-integration", .path = "src/utils/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig" },
        .{ .name = "arc-pool-unit", .path = "src/utils/arc/arc-pool/_arc_pool_unit_tests.zig" },
        .{ .name = "arc-pool-integration", .path = "src/utils/arc/arc-pool/_arc_pool_integration_tests.zig" },
    };

    const bench_specs = [_]BenchSpec{
        // For consistency, both benches import the wrapper module "zig_beam".
        .{ .name = "tlc-bench", .exe_name = "tlc_bench", .path = "src/utils/thread-local-cache/_thread_local_cache_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "arc-bench", .exe_name = "arc_bench", .path = "src/utils/arc/_arc_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "arcpool-bench", .exe_name = "arcpool_bench", .path = "src/utils/arc/arc-pool/_arc_pool_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
    };

    // Provide internal module names to tests (only for repo-internal builds)
    const all_imports = &[_]ImportSpec{
        .{ .name = "tagged_pointer", .module = tagged_ptr_mod },
        .{ .name = "thread_local_cache", .module = tlc_mod },
        .{ .name = "arc_core", .module = arc_mod },
        .{ .name = "arc_pool", .module = arc_pool_mod },
        .{ .name = "arc_cycle_detector", .module = arc_cycle_mod },
    };

    for (test_specs) |spec| {
        const run = addTestRun(b, target, optimize, spec, all_imports);
        step_test.dependOn(&run.step);
        if (std.mem.startsWith(u8, spec.path, "src/utils/tagged-pointer/_tagged_pointer_samples.zig")) {
            step_samples_tagged.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/tagged-pointer/")) {
            step_tagged.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/thread-local-cache/_thread_local_cache_samples.zig")) {
            step_samples_tlc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/thread-local-cache/")) {
            step_tlc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/arc/arc-pool/")) {
            step_arc_pool.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/arc/cycle-detector/")) {
            step_arc_cycle.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/arc/_arc_samples")) {
            step_samples_arc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/utils/arc/")) {
            step_arc.dependOn(&run.step);
        }
    }

    const tlc_bench = addBenchRun(b, target, optimize, bench_specs[0]);
    const arc_bench = addBenchRun(b, target, optimize, bench_specs[1]);
    const arcpool_bench = addBenchRun(b, target, optimize, bench_specs[2]);
    step_bench_tlc.dependOn(&tlc_bench.step);
    step_bench_arc.dependOn(&arc_bench.step);
    step_bench_arc_pool.dependOn(&arcpool_bench.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Public wrapper module must be defined at top-level build()
    const wrapper = b.addModule("zig_beam", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    add_utils(b, target, optimize, wrapper);
}

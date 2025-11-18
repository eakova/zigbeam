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

fn add_libs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wrapper: *std.Build.Module) void {
    // Top-level steps defined once here
    const step_test = b.step("test", "Run all zig-beam.libs tests");
    const step_tagged = b.step("test-tagged", "Run tagged-pointer tests");
    const step_tlc = b.step("test-tlc", "Run thread-local cache tests");
    const step_arc = b.step("test-arc", "Run Arc core tests");
    const step_arc_pool = b.step("test-arc-pool", "Run ArcPool tests");
    const step_arc_cycle = b.step("test-arc-cycle", "Run cycle-detector tests");
    const step_ebr = b.step("test-ebr", "Run EBR tests");
    const step_dvyukov = b.step("test-dvyukov", "Run DVyukov MPMC Queue tests");
    const step_samples_tagged = b.step("samples-tagged", "Run tagged-pointer samples");
    const step_samples_tlc = b.step("samples-tlc", "Run thread-local cache samples");
    const step_samples_arc = b.step("samples-arc", "Run Arc samples");
    const step_samples_ebr = b.step("samples-ebr", "Run EBR samples");
    const step_samples_dvyukov = b.step("samples-dvyukov", "Run DVyukov MPMC Queue samples");
    const step_bench_tlc = b.step("bench-tlc", "Run Thread-Local Cache benchmarks");
    const step_bench_arc = b.step("bench-arc", "Run Arc benchmarks");
    const step_bench_arc_pool = b.step("bench-arc-pool", "Run ArcPool benchmarks");
    const step_bench_ebr = b.step("bench-ebr", "Run EBR benchmarks");
    const step_bench_dvyukov = b.step("bench-dvyukov", "Run DVyukov MPMC Queue benchmarks");
    const step_bench_deque = b.step("bench-deque", "Run Work-Stealing Deque & Thread Pool benchmarks");
    const step_test_beam_deque = b.step("test-beam-deque", "Run BeamDeque tests");
    const step_bench_beam_deque = b.step("bench-beam-deque", "Run BeamDeque benchmarks");
    const step_test_beam_deque_channel = b.step("test-beam-deque-channel", "Run BeamDequeChannel tests");
    const step_bench_beam_deque_channel = b.step("bench-beam-deque-channel", "Run BeamDequeChannel benchmarks");
    const step_bench_beam_deque_channel_v2 = b.step("bench-beam-deque-channel-v2", "Run BeamDequeChannel V2 benchmarks (correct usage pattern)");

    // Internal modules (not exported directly): use createModule
    const tagged_ptr_mod = b.createModule(.{ .root_source_file = b.path("src/libs/tagged-pointer/tagged_pointer.zig"), .target = target, .optimize = optimize });
    const tlc_mod = b.createModule(.{ .root_source_file = b.path("src/libs/thread-local-cache/thread_local_cache.zig"), .target = target, .optimize = optimize });
    tlc_mod.addImport("tagged_pointer", tagged_ptr_mod);
    const arc_mod = b.createModule(.{ .root_source_file = b.path("src/libs/arc/arc.zig"), .target = target, .optimize = optimize });
    arc_mod.addImport("tagged_pointer", tagged_ptr_mod);
    const arc_pool_mod = b.createModule(.{ .root_source_file = b.path("src/libs/arc/arc-pool/arc_pool.zig"), .target = target, .optimize = optimize });
    arc_pool_mod.addImport("tagged_pointer", tagged_ptr_mod);
    arc_pool_mod.addImport("arc_core", arc_mod);
    arc_pool_mod.addImport("thread_local_cache", tlc_mod);
    const arc_cycle_mod = b.createModule(.{ .root_source_file = b.path("src/libs/arc/cycle-detector/arc_cycle_detector.zig"), .target = target, .optimize = optimize });
    arc_cycle_mod.addImport("arc_core", arc_mod);
    arc_cycle_mod.addImport("arc_pool", arc_pool_mod);
    arc_cycle_mod.addImport("tagged_pointer", tagged_ptr_mod);
    const ebr_mod = b.createModule(.{ .root_source_file = b.path("src/prototypes/ebr/ebr.zig"), .target = target, .optimize = optimize });

    // Backoff module
    const backoff_mod = b.createModule(.{ .root_source_file = b.path("src/libs/backoff/backoff.zig"), .target = target, .optimize = optimize });

    // DVyukov MPMC Queue modules
    const dvyukov_mpmc_mod = b.createModule(.{ .root_source_file = b.path("src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig"), .target = target, .optimize = optimize });
    const sharded_dvyukov_mpmc_mod = b.createModule(.{ .root_source_file = b.path("src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig"), .target = target, .optimize = optimize });
    sharded_dvyukov_mpmc_mod.addImport("dvyukov_mpmc", dvyukov_mpmc_mod);

    // Deque modules
    const task_mod = b.createModule(.{ .root_source_file = b.path("src/prototypes/deque/task.zig"), .target = target, .optimize = optimize });
    const deque_mod = b.createModule(.{ .root_source_file = b.path("src/prototypes/deque/deque.zig"), .target = target, .optimize = optimize });
    deque_mod.addImport("arc_core", arc_mod);
    deque_mod.addImport("backoff", backoff_mod);
    const deque_pool_mod = b.createModule(.{ .root_source_file = b.path("src/prototypes/deque/deque_pool.zig"), .target = target, .optimize = optimize });
    deque_pool_mod.addImport("deque", deque_mod);
    deque_pool_mod.addImport("task", task_mod);
    deque_pool_mod.addImport("dvyukov_mpmc", dvyukov_mpmc_mod);
    deque_pool_mod.addImport("sharded_dvyukov_mpmc", sharded_dvyukov_mpmc_mod);
    deque_pool_mod.addImport("backoff", backoff_mod);

    // BeamDeque module (bounded work-stealing deque)
    const beam_deque_mod = b.createModule(.{ .root_source_file = b.path("src/libs/beam-deque/beam_deque.zig"), .target = target, .optimize = optimize });
    beam_deque_mod.addImport("backoff", backoff_mod);

    // BeamDequeChannel module (MPMC channel with work-stealing)
    const beam_deque_channel_mod = b.createModule(.{ .root_source_file = b.path("src/libs/beam-deque/beam_deque_channel.zig"), .target = target, .optimize = optimize });
    beam_deque_channel_mod.addImport("beam_deque", beam_deque_mod);
    beam_deque_channel_mod.addImport("dvyukov_mpmc", dvyukov_mpmc_mod);

    // Wire internal modules into the public wrapper provided by build()
    wrapper.addImport("tagged_pointer", tagged_ptr_mod);
    wrapper.addImport("thread_local_cache", tlc_mod);
    wrapper.addImport("arc_core", arc_mod);
    wrapper.addImport("arc_pool", arc_pool_mod);
    wrapper.addImport("arc_cycle_detector", arc_cycle_mod);
    wrapper.addImport("epoch_based_reclamation", ebr_mod);
    wrapper.addImport("backoff", backoff_mod);
    wrapper.addImport("dvyukov_mpmc", dvyukov_mpmc_mod);
    wrapper.addImport("sharded_dvyukov_mpmc", sharded_dvyukov_mpmc_mod);
    wrapper.addImport("deque", deque_mod);
    wrapper.addImport("deque_pool", deque_pool_mod);
    wrapper.addImport("task", task_mod);
    wrapper.addImport("beam_deque", beam_deque_mod);
    wrapper.addImport("beam_deque_channel", beam_deque_channel_mod);

    // Test specs (libs)
    const test_specs = [_]TestSpec{
        .{ .name = "tlc-unit", .path = "src/libs/thread-local-cache/_thread_local_cache_unit_tests.zig" },
        .{ .name = "tlc-integration", .path = "src/libs/thread-local-cache/_thread_local_cache_integration_test.zig" },
        .{ .name = "tlc-fuzz", .path = "src/libs/thread-local-cache/_thread_local_cache_fuzz_tests.zig" },
        .{ .name = "tlc-samples", .path = "src/libs/thread-local-cache/_thread_local_cache_samples.zig" },
        .{ .name = "tagged-unit", .path = "src/libs/tagged-pointer/_tagged_pointer_unit_tests.zig" },
        .{ .name = "tagged-integration", .path = "src/libs/tagged-pointer/_tagged_pointer_integration_tests.zig" },
        .{ .name = "tagged-samples", .path = "src/libs/tagged-pointer/_tagged_pointer_samples.zig" },
        .{ .name = "arc-unit", .path = "src/libs/arc/_arc_unit_tests.zig" },
        .{ .name = "arc-samples", .path = "src/libs/arc/_arc_samples.zig" },
        .{ .name = "arc-cycle-unit", .path = "src/libs/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig" },
        .{ .name = "arc-cycle-integration", .path = "src/libs/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig" },
        .{ .name = "arc-pool-unit", .path = "src/libs/arc/arc-pool/_arc_pool_unit_tests.zig" },
        .{ .name = "arc-pool-integration", .path = "src/libs/arc/arc-pool/_arc_pool_integration_tests.zig" },
        .{ .name = "ebr-unit", .path = "src/prototypes/ebr/_ebr_unit_tests.zig" },
        .{ .name = "ebr-integration", .path = "src/prototypes/ebr/_ebr_integration_tests.zig" },
        .{ .name = "ebr-fuzz", .path = "src/prototypes/ebr/_ebr_fuzz_tests.zig" },
        .{ .name = "ebr-samples", .path = "src/prototypes/ebr/_ebr_samples.zig" },
        .{ .name = "dvyukov-unit", .path = "src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_unit_tests.zig" },
        .{ .name = "dvyukov-integration", .path = "src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_integration_tests.zig" },
        .{ .name = "dvyukov-fuzz", .path = "src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_fuzz_tests.zig" },
        .{ .name = "dvyukov-samples", .path = "src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_samples.zig" },
        .{ .name = "sharded-dvyukov-unit", .path = "src/libs/dvyukov-mpmc-queue/_sharded_dvyukov_mpmc_queue_unit_tests.zig" },
        .{ .name = "sharded-dvyukov-integration", .path = "src/libs/dvyukov-mpmc-queue/_sharded_dvyukov_mpmc_queue_integration_tests.zig" },
        .{ .name = "sharded-dvyukov-samples", .path = "src/libs/dvyukov-mpmc-queue/_sharded_dvyukov_mpmc_queue_samples.zig" },
        .{ .name = "beam-deque-unit", .path = "src/libs/beam-deque/_beam_deque_unit_tests.zig" },
        .{ .name = "beam-deque-race", .path = "src/libs/beam-deque/_beam_deque_race_tests.zig" },
        .{ .name = "beam-deque-channel", .path = "src/libs/beam-deque/_beam_deque_channel_tests.zig" },
        .{ .name = "fat-type-validation", .path = "src/libs/beam-deque/_test_fat_type_validation.zig" },
    };

    const bench_specs = [_]BenchSpec{
        // For consistency, both benches import the wrapper module "zig_beam".
        .{ .name = "tlc-bench", .exe_name = "tlc_bench", .path = "src/libs/thread-local-cache/_thread_local_cache_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "arc-bench", .exe_name = "arc_bench", .path = "src/libs/arc/_arc_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "arcpool-bench", .exe_name = "arcpool_bench", .path = "src/libs/arc/arc-pool/_arc_pool_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "ebr-bench", .exe_name = "ebr_bench", .path = "src/prototypes/ebr/_ebr_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "dvyukov-bench", .exe_name = "_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "sharded-dvyukov-bench", .exe_name = "_sharded_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/dvyukov-mpmc-queue/_sharded_dvyukov_mpmc_queue_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "deque-bench", .exe_name = "_deque_benchmarks", .path = "src/prototypes/deque/_deque_benchmarks.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
        .{ .name = "beam-deque-bench", .exe_name = "_beam_deque_benchmarks", .path = "src/libs/beam-deque/_beam_deque_benchmarks.zig", .imports = &.{ .{ .name = "beam_deque", .module = beam_deque_mod } } },
        .{ .name = "beam-deque-channel-bench", .exe_name = "_beam_deque_channel_benchmarks", .path = "src/libs/beam-deque/_beam_deque_channel_benchmarks.zig", .imports = &.{ .{ .name = "beam_deque", .module = beam_deque_mod }, .{ .name = "beam_deque_channel", .module = beam_deque_channel_mod }, .{ .name = "dvyukov_mpmc", .module = dvyukov_mpmc_mod } } },
        .{ .name = "beam-deque-channel-bench-v2", .exe_name = "_beam_deque_channel_benchmarks_v2", .path = "src/libs/beam-deque/_beam_deque_channel_benchmarks_v2.zig", .imports = &.{ .{ .name = "beam_deque", .module = beam_deque_mod }, .{ .name = "beam_deque_channel", .module = beam_deque_channel_mod }, .{ .name = "dvyukov_mpmc", .module = dvyukov_mpmc_mod } } },
        .{ .name = "queue-util", .exe_name = "test_queue_utilization", .path = "test_queue_utilization.zig", .imports = &.{.{ .name = "zig_beam", .module = wrapper }} },
    };

    // Provide internal module names to tests (only for repo-internal builds)
    const all_imports = &[_]ImportSpec{
        .{ .name = "tagged_pointer", .module = tagged_ptr_mod },
        .{ .name = "thread_local_cache", .module = tlc_mod },
        .{ .name = "arc_core", .module = arc_mod },
        .{ .name = "arc_pool", .module = arc_pool_mod },
        .{ .name = "arc_cycle_detector", .module = arc_cycle_mod },
        .{ .name = "epoch_based_reclamation", .module = ebr_mod },
        .{ .name = "backoff", .module = backoff_mod },
        .{ .name = "dvyukov_mpmc", .module = dvyukov_mpmc_mod },
        .{ .name = "beam_deque", .module = beam_deque_mod },
        .{ .name = "beam_deque_channel", .module = beam_deque_channel_mod },
    };

    for (test_specs) |spec| {
        const run = addTestRun(b, target, optimize, spec, all_imports);
        step_test.dependOn(&run.step);
        if (std.mem.startsWith(u8, spec.path, "src/libs/tagged-pointer/_tagged_pointer_samples.zig")) {
            step_samples_tagged.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/tagged-pointer/")) {
            step_tagged.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/thread-local-cache/_thread_local_cache_samples.zig")) {
            step_samples_tlc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/thread-local-cache/")) {
            step_tlc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/arc/arc-pool/")) {
            step_arc_pool.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/arc/cycle-detector/")) {
            step_arc_cycle.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/arc/_arc_samples")) {
            step_samples_arc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/arc/")) {
            step_arc.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/prototypes/ebr/_ebr_samples")) {
            step_samples_ebr.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/prototypes/ebr/")) {
            step_ebr.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/dvyukov-mpmc-queue/") and std.mem.containsAtLeast(u8, spec.path, 1, "samples")) {
            step_samples_dvyukov.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/dvyukov-mpmc-queue/")) {
            step_dvyukov.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/beam-deque/_beam_deque_channel")) {
            step_test_beam_deque_channel.dependOn(&run.step);
        } else if (std.mem.startsWith(u8, spec.path, "src/libs/beam-deque/")) {
            step_test_beam_deque.dependOn(&run.step);
        }
    }

    const tlc_bench = addBenchRun(b, target, optimize, bench_specs[0]);
    const arc_bench = addBenchRun(b, target, optimize, bench_specs[1]);
    const arcpool_bench = addBenchRun(b, target, optimize, bench_specs[2]);
    const ebr_bench = addBenchRun(b, target, optimize, bench_specs[3]);
    const dvyukov_bench = addBenchRun(b, target, optimize, bench_specs[4]);
    const sharded_dvyukov_bench = addBenchRun(b, target, optimize, bench_specs[5]);
    const deque_bench = addBenchRun(b, target, optimize, bench_specs[6]);
    const beam_deque_bench = addBenchRun(b, target, optimize, bench_specs[7]);
    const beam_deque_channel_bench = addBenchRun(b, target, optimize, bench_specs[8]);
    const beam_deque_channel_bench_v2 = addBenchRun(b, target, optimize, bench_specs[9]);
    const queue_util = addBenchRun(b, target, optimize, bench_specs[10]);
    const step_queue_util = b.step("queue-util", "Run queue utilization diagnostic");
    step_bench_tlc.dependOn(&tlc_bench.step);
    step_bench_arc.dependOn(&arc_bench.step);
    step_bench_arc_pool.dependOn(&arcpool_bench.step);
    step_bench_ebr.dependOn(&ebr_bench.step);
    step_bench_dvyukov.dependOn(&dvyukov_bench.step);
    step_bench_dvyukov.dependOn(&sharded_dvyukov_bench.step);
    step_bench_deque.dependOn(&deque_bench.step);
    step_bench_beam_deque.dependOn(&beam_deque_bench.step);
    step_bench_beam_deque_channel.dependOn(&beam_deque_channel_bench.step);
    step_bench_beam_deque_channel_v2.dependOn(&beam_deque_channel_bench_v2.step);
    step_queue_util.dependOn(&queue_util.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Public wrapper module must be defined at top-level build()
    const wrapper = b.addModule("zig_beam", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    add_libs(b, target, optimize, wrapper);
}

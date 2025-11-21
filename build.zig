const std = @import("std");

const ImportSpec = struct { name: []const u8, module: *std.Build.Module };
const TestSpec = struct { name: []const u8, path: []const u8, category: TestCategory };
const BenchSpec = struct { name: []const u8, exe_name: []const u8, path: []const u8, category: BenchCategory, imports: []const ImportSpec = &.{} };

const BuildSteps = struct {
    all_tests: *std.Build.Step,
    tagged: *std.Build.Step,
    tlc: *std.Build.Step,
    arc: *std.Build.Step,
    arc_pool: *std.Build.Step,
    arc_cycle: *std.Build.Step,
    dvyukov: *std.Build.Step,
    samples_tagged: *std.Build.Step,
    samples_tlc: *std.Build.Step,
    samples_arc: *std.Build.Step,
    samples_dvyukov: *std.Build.Step,
    samples_ebr: *std.Build.Step,
    bench_tlc: *std.Build.Step,
    bench_arc: *std.Build.Step,
    bench_arc_pool: *std.Build.Step,
    bench_ebr: *std.Build.Step,
    bench_dvyukov: *std.Build.Step,
    test_beam_deque: *std.Build.Step,
    bench_beam_deque: *std.Build.Step,
    test_beam_deque_channel: *std.Build.Step,
    bench_beam_deque_channel: *std.Build.Step,
    bench_beam_deque_channel_v2: *std.Build.Step,
    test_beam_task: *std.Build.Step,
    test_spsc_queue: *std.Build.Step,
    bench_spsc_queue: *std.Build.Step,
    test_segmented_queue: *std.Build.Step,
    test_segmented_queue_ebr: *std.Build.Step,
    test_segmented_queue_integration: *std.Build.Step,
    bench_segmented_queue: *std.Build.Step,
    bench_segmented_queue_guard_api: *std.Build.Step,
    bench_ebr_shutdown: *std.Build.Step,
    bench_queue_util: *std.Build.Step,
    bench_ebr_queue_pressure: *std.Build.Step,
};

const Modules = struct {
    tagged_ptr: *std.Build.Module,
    tlc: *std.Build.Module,
    arc: *std.Build.Module,
    arc_pool: *std.Build.Module,
    arc_cycle: *std.Build.Module,
    backoff: *std.Build.Module,
    dvyukov_mpmc: *std.Build.Module,
    sharded_dvyukov_mpmc: *std.Build.Module,
    beam_deque: *std.Build.Module,
    beam_deque_channel: *std.Build.Module,
    beam_task: *std.Build.Module,
    spsc_queue: *std.Build.Module,
    cache_padded: *std.Build.Module,
    lock_free_segmented_list: *std.Build.Module,
    segmented_queue_ebr: *std.Build.Module,
    segmented_queue: *std.Build.Module,
    helpers: *std.Build.Module,
};

const TestCategory = enum {
    tagged_pointer_general,
    tagged_pointer_samples,
    thread_local_cache_general,
    thread_local_cache_samples,
    arc_general,
    arc_samples,
    arc_pool,
    arc_cycle,
    dvyukov_general,
    dvyukov_samples,
    beam_deque_general,
    beam_deque_channel,
    beam_task,
    spsc_queue,
    segmented_queue_ebr_unit,
    segmented_queue_ebr_fuzz,
    segmented_queue_integration,
    cache_padded,
};

const BenchCategory = enum {
    bench_tlc,
    bench_arc,
    bench_arc_pool,
    bench_ebr,
    samples_ebr,
    bench_dvyukov,
    bench_beam_deque,
    bench_beam_deque_channel,
    bench_beam_deque_channel_v2,
    bench_spsc_queue,
    bench_segmented_queue,
    bench_segmented_queue_guard_api,
    bench_ebr_shutdown,
    bench_queue_util,
    bench_ebr_queue_pressure,
};

const ModuleBuilder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn create(self: ModuleBuilder, path: []const u8) *std.Build.Module {
        return self.b.createModule(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
        });
    }
};

// Helper function to create import specs
fn imp(name: []const u8, module: *std.Build.Module) ImportSpec {
    return .{ .name = name, .module = module };
}

fn addTestRun(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spec: TestSpec, imports: []const ImportSpec) *std.Build.Step.Run {
    const mod = b.createModule(.{ .root_source_file = b.path(spec.path), .target = target, .optimize = optimize });
    for (imports) |import_spec| mod.addImport(import_spec.name, import_spec.module);
    const test_exe = b.addTest(.{ .root_module = mod });
    return b.addRunArtifact(test_exe);
}

fn addBenchRun(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spec: BenchSpec) *std.Build.Step.Run {
    const mod = b.createModule(.{ .root_source_file = b.path(spec.path), .target = target, .optimize = optimize });
    for (spec.imports) |import_spec| mod.addImport(import_spec.name, import_spec.module);
    const exe = b.addExecutable(.{ .name = spec.exe_name, .root_module = mod });
    return b.addRunArtifact(exe);
}

fn createBuildSteps(b: *std.Build) BuildSteps {
    return .{
        .all_tests = b.step("test", "Run all zig-beam.libs tests"),
        .tagged = b.step("test-tagged", "Run tagged-pointer tests"),
        .tlc = b.step("test-tlc", "Run thread-local cache tests"),
        .arc = b.step("test-arc", "Run Arc core tests"),
        .arc_pool = b.step("test-arc-pool", "Run ArcPool tests"),
        .arc_cycle = b.step("test-arc-cycle", "Run cycle-detector tests"),
        .dvyukov = b.step("test-dvyukov", "Run DVyukov MPMC Queue tests"),
        .samples_tagged = b.step("samples-tagged", "Run tagged-pointer samples"),
        .samples_tlc = b.step("samples-tlc", "Run thread-local cache samples"),
        .samples_arc = b.step("samples-arc", "Run Arc samples"),
        .samples_dvyukov = b.step("samples-dvyukov", "Run DVyukov MPMC Queue samples"),
        .samples_ebr = b.step("samples-ebr", "Run EBR usage samples (quick start to advanced)"),
        .bench_tlc = b.step("bench-tlc", "Run Thread-Local Cache benchmarks"),
        .bench_arc = b.step("bench-arc", "Run Arc benchmarks"),
        .bench_arc_pool = b.step("bench-arc-pool", "Run ArcPool benchmarks"),
        .bench_ebr = b.step("bench-ebr", "Run EBR benchmarks"),
        .bench_dvyukov = b.step("bench-dvyukov", "Run DVyukov MPMC Queue benchmarks"),
        .test_beam_deque = b.step("test-beam-deque", "Run BeamDeque tests"),
        .bench_beam_deque = b.step("bench-beam-deque", "Run BeamDeque benchmarks"),
        .test_beam_deque_channel = b.step("test-beam-deque-channel", "Run BeamDequeChannel tests"),
        .bench_beam_deque_channel = b.step("bench-beam-deque-channel", "Run BeamDequeChannel benchmarks"),
        .bench_beam_deque_channel_v2 = b.step("bench-beam-deque-channel-v2", "Run BeamDequeChannel V2 benchmarks (correct usage pattern)"),
        .test_beam_task = b.step("test-beam-task", "Run Beam-Task tests"),
        .test_spsc_queue = b.step("test-spsc-queue", "Run BoundedSPSCQueue tests"),
        .bench_spsc_queue = b.step("bench-spsc-queue", "Run BoundedSPSCQueue benchmarks"),
        .test_segmented_queue = b.step("test-segmented-queue", "Run all SegmentedQueue tests"),
        .test_segmented_queue_ebr = b.step("test-segmented-queue-ebr-unit", "Run SegmentedQueue EBR unit tests"),
        .test_segmented_queue_integration = b.step("test-segmented-queue-integration", "Run SegmentedQueue integration tests"),
        .bench_segmented_queue = b.step("bench-segmented-queue", "Run SegmentedQueue benchmarks"),
        .bench_segmented_queue_guard_api = b.step("bench-segmented-queue-guard-api", "Compare Simple vs Optimized Guard API performance"),
        .bench_ebr_shutdown = b.step("bench-ebr-shutdown", "Run EBR shutdown benchmark/diagnostic"),
        .bench_queue_util = b.step("bench-queue-util", "Run queue utilization benchmark"),
        .bench_ebr_queue_pressure = b.step("bench-ebr-queue-pressure", "Run EBR garbage queue pressure benchmark"),
    };
}

fn createModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const mb = ModuleBuilder{ .b = b, .target = target, .optimize = optimize };

    // Create all base modules
    const tagged_ptr = mb.create("src/libs/beam-tagged-pointer/tagged_pointer.zig");
    const tlc = mb.create("src/libs/beam-thread-local-cache/thread_local_cache.zig");
    const arc = mb.create("src/libs/beam-arc/arc.zig");
    const arc_pool = mb.create("src/libs/beam-arc/arc-pool/arc_pool.zig");
    const arc_cycle = mb.create("src/libs/beam-arc/cycle-detector/arc_cycle_detector.zig");
    const backoff = mb.create("src/libs/beam-backoff/backoff.zig");
    const dvyukov_mpmc = mb.create("src/libs/beam-dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig");
    const sharded_dvyukov_mpmc = mb.create("src/libs/beam-dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig");
    const beam_deque = mb.create("src/libs/beam-deque/deque.zig");
    const beam_deque_channel = mb.create("src/libs/beam-deque/deque_channel.zig");
    const beam_task = mb.create("src/libs/beam-task/task.zig");
    const spsc_queue = mb.create("src/libs/spsc-queue/spsc_queue.zig");
    const cache_padded = mb.create("src/libs/beam-cache-padded/cache_padded.zig");
    const lock_free_segmented_list = mb.create("src/libs/beam-segmented-queue/lock_free_segmented_list.zig");
    const segmented_queue_ebr = mb.create("src/libs/beam-ebr/ebr.zig");
    const segmented_queue = mb.create("src/libs/beam-segmented-queue/segmented_queue.zig");
    const helpers_mod = mb.create("src/libs/helpers/helpers.zig");

    // Wire dependencies
    tlc.addImport("beam-tagged-pointer", tagged_ptr);
    arc.addImport("beam-tagged-pointer", tagged_ptr);
    arc_pool.addImport("beam-tagged-pointer", tagged_ptr);
    arc_pool.addImport("beam-arc", arc);
    arc_pool.addImport("beam-thread-local-cache", tlc);
    arc_cycle.addImport("beam-arc", arc);
    arc_cycle.addImport("beam-arc-pool", arc_pool);
    arc_cycle.addImport("beam-tagged-pointer", tagged_ptr);
    sharded_dvyukov_mpmc.addImport("beam-dvyukov-mpmc", dvyukov_mpmc);
    beam_deque.addImport("beam-backoff", backoff);
    beam_deque_channel.addImport("beam-deque", beam_deque);
    beam_deque_channel.addImport("beam-dvyukov-mpmc", dvyukov_mpmc);
    segmented_queue_ebr.addImport("beam-lock-free-segmented-list", lock_free_segmented_list);
    segmented_queue_ebr.addImport("beam-dvyukov-mpmc", dvyukov_mpmc);
    segmented_queue_ebr.addImport("beam-cache-padded", cache_padded);
    segmented_queue.addImport("beam-dvyukov-mpmc", dvyukov_mpmc);
    segmented_queue.addImport("beam-backoff", backoff);
    segmented_queue.addImport("beam-ebr", segmented_queue_ebr);

    return .{
        .tagged_ptr = tagged_ptr,
        .tlc = tlc,
        .arc = arc,
        .arc_pool = arc_pool,
        .arc_cycle = arc_cycle,
        .backoff = backoff,
        .dvyukov_mpmc = dvyukov_mpmc,
        .sharded_dvyukov_mpmc = sharded_dvyukov_mpmc,
        .beam_deque = beam_deque,
        .beam_deque_channel = beam_deque_channel,
        .beam_task = beam_task,
        .spsc_queue = spsc_queue,
        .cache_padded = cache_padded,
        .lock_free_segmented_list = lock_free_segmented_list,
        .segmented_queue_ebr = segmented_queue_ebr,
        .segmented_queue = segmented_queue,
        .helpers = helpers_mod,
    };
}

fn wireTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, steps: BuildSteps, modules: Modules, test_specs: []const TestSpec) void {
    const all_imports = &[_]ImportSpec{
        .{ .name = "beam-tagged-pointer", .module = modules.tagged_ptr },
        .{ .name = "beam-thread-local-cache", .module = modules.tlc },
        .{ .name = "beam-arc", .module = modules.arc },
        .{ .name = "beam-arc-pool", .module = modules.arc_pool },
        .{ .name = "beam-arc-cycle-detector", .module = modules.arc_cycle },
        .{ .name = "beam-backoff", .module = modules.backoff },
        .{ .name = "beam-dvyukov-mpmc", .module = modules.dvyukov_mpmc },
        .{ .name = "beam-sharded-dvyukov-mpmc", .module = modules.sharded_dvyukov_mpmc },
        .{ .name = "beam-deque", .module = modules.beam_deque },
        .{ .name = "beam-deque-channel", .module = modules.beam_deque_channel },
        .{ .name = "spsc-queue", .module = modules.spsc_queue },
        .{ .name = "beam-segmented-queue", .module = modules.segmented_queue },
        .{ .name = "beam-cache-padded", .module = modules.cache_padded },
        .{ .name = "beam-lock-free-segmented-list", .module = modules.lock_free_segmented_list },
        .{ .name = "beam-ebr", .module = modules.segmented_queue_ebr },
        .{ .name = "beam-task", .module = modules.beam_task },
        .{ .name = "helpers", .module = modules.helpers },
    };

    for (test_specs) |spec| {
        const run = addTestRun(b, target, optimize, spec, all_imports);
        steps.all_tests.dependOn(&run.step);

        switch (spec.category) {
            .tagged_pointer_general => steps.tagged.dependOn(&run.step),
            .tagged_pointer_samples => steps.samples_tagged.dependOn(&run.step),
            .thread_local_cache_general => steps.tlc.dependOn(&run.step),
            .thread_local_cache_samples => steps.samples_tlc.dependOn(&run.step),
            .arc_general => steps.arc.dependOn(&run.step),
            .arc_samples => steps.samples_arc.dependOn(&run.step),
            .arc_pool => steps.arc_pool.dependOn(&run.step),
            .arc_cycle => steps.arc_cycle.dependOn(&run.step),
            .dvyukov_general => steps.dvyukov.dependOn(&run.step),
            .dvyukov_samples => steps.samples_dvyukov.dependOn(&run.step),
            .beam_deque_general => steps.test_beam_deque.dependOn(&run.step),
            .beam_deque_channel => steps.test_beam_deque_channel.dependOn(&run.step),
            .beam_task => steps.test_beam_task.dependOn(&run.step),
            .spsc_queue => steps.test_spsc_queue.dependOn(&run.step),
            .segmented_queue_ebr_unit => {
                steps.test_segmented_queue_ebr.dependOn(&run.step);
                steps.test_segmented_queue.dependOn(&run.step);
            },
            .segmented_queue_ebr_fuzz => steps.test_segmented_queue.dependOn(&run.step),
            .segmented_queue_integration => {
                steps.test_segmented_queue_integration.dependOn(&run.step);
                steps.test_segmented_queue.dependOn(&run.step);
            },
            .cache_padded => {},
        }
    }
}

fn wireBenchmarks(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, steps: BuildSteps, bench_specs: []const BenchSpec) void {
    for (bench_specs) |spec| {
        const run = addBenchRun(b, target, optimize, spec);

        switch (spec.category) {
            .bench_tlc => steps.bench_tlc.dependOn(&run.step),
            .bench_arc => steps.bench_arc.dependOn(&run.step),
            .bench_arc_pool => steps.bench_arc_pool.dependOn(&run.step),
            .bench_ebr => steps.bench_ebr.dependOn(&run.step),
            .samples_ebr => steps.samples_ebr.dependOn(&run.step),
            .bench_dvyukov => steps.bench_dvyukov.dependOn(&run.step),
            .bench_beam_deque => steps.bench_beam_deque.dependOn(&run.step),
            .bench_beam_deque_channel => steps.bench_beam_deque_channel.dependOn(&run.step),
            .bench_beam_deque_channel_v2 => steps.bench_beam_deque_channel_v2.dependOn(&run.step),
            .bench_spsc_queue => steps.bench_spsc_queue.dependOn(&run.step),
            .bench_segmented_queue => steps.bench_segmented_queue.dependOn(&run.step),
            .bench_segmented_queue_guard_api => steps.bench_segmented_queue_guard_api.dependOn(&run.step),
            .bench_ebr_shutdown => steps.bench_ebr_shutdown.dependOn(&run.step),
            .bench_queue_util => steps.bench_queue_util.dependOn(&run.step),
            .bench_ebr_queue_pressure => steps.bench_ebr_queue_pressure.dependOn(&run.step),
        }
    }
}

fn add_libs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wrapper: *std.Build.Module) void {
    const steps = createBuildSteps(b);
    const modules = createModules(b, target, optimize);

    // Wire internal modules into the public wrapper provided by build()
    wrapper.addImport("beam-tagged-pointer", modules.tagged_ptr);
    wrapper.addImport("beam-thread-local-cache", modules.tlc);
    wrapper.addImport("beam-arc", modules.arc);
    wrapper.addImport("beam-arc-pool", modules.arc_pool);
    wrapper.addImport("beam-arc-cycle-detector", modules.arc_cycle);
    // NOTE: prototype EBR module is intentionally not wired into the
    // public wrapper to keep production usage on the segmented-queue
    // EBR implementation.
    wrapper.addImport("beam-backoff", modules.backoff);
    wrapper.addImport("beam-dvyukov-mpmc", modules.dvyukov_mpmc);
    wrapper.addImport("beam-sharded-dvyukov-mpmc", modules.sharded_dvyukov_mpmc);
    wrapper.addImport("beam-task", modules.beam_task);
    wrapper.addImport("beam-deque", modules.beam_deque);
    wrapper.addImport("beam-deque-channel", modules.beam_deque_channel);
    wrapper.addImport("spsc-queue", modules.spsc_queue);
    wrapper.addImport("beam-segmented-queue", modules.segmented_queue);
    wrapper.addImport("beam-cache-padded", modules.cache_padded);

    // Test specs (libs)
    const test_specs = [_]TestSpec{
        .{ .name = "tlc-unit", .path = "src/libs/beam-thread-local-cache/tests/_thread_local_cache_unit_tests.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-integration", .path = "src/libs/beam-thread-local-cache/tests/_thread_local_cache_integration_test.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-fuzz", .path = "src/libs/beam-thread-local-cache/tests/_thread_local_cache_fuzz_tests.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-samples", .path = "src/libs/beam-thread-local-cache/samples/_thread_local_cache_samples.zig", .category = .thread_local_cache_samples },
        .{ .name = "tagged-unit", .path = "src/libs/beam-tagged-pointer/tests/_tagged_pointer_unit_tests.zig", .category = .tagged_pointer_general },
        .{ .name = "tagged-integration", .path = "src/libs/beam-tagged-pointer/tests/_tagged_pointer_integration_tests.zig", .category = .tagged_pointer_general },
        .{ .name = "tagged-samples", .path = "src/libs/beam-tagged-pointer/samples/_tagged_pointer_samples.zig", .category = .tagged_pointer_samples },
        .{ .name = "arc-unit", .path = "src/libs/beam-arc/tests/_arc_unit_tests.zig", .category = .arc_general },
        .{ .name = "arc-samples", .path = "src/libs/beam-arc/samples/_arc_samples.zig", .category = .arc_samples },
        .{ .name = "arc-cycle-unit", .path = "src/libs/beam-arc/cycle-detector/tests/_arc_cycle_detector_unit_tests.zig", .category = .arc_cycle },
        .{ .name = "arc-cycle-integration", .path = "src/libs/beam-arc/cycle-detector/tests/_arc_cycle_detector_integration_tests.zig", .category = .arc_cycle },
        .{ .name = "arc-pool-unit", .path = "src/libs/beam-arc/arc-pool/tests/_arc_pool_unit_tests.zig", .category = .arc_pool },
        .{ .name = "arc-pool-integration", .path = "src/libs/beam-arc/arc-pool/tests/_arc_pool_integration_tests.zig", .category = .arc_pool },
        // Prototype EBR tests are intentionally excluded from the
        // default test matrix; the production implementation lives
        // under src/libs/segmented-queue.
        .{ .name = "dvyukov-unit", .path = "src/libs/beam-dvyukov-mpmc-queue/tests/_dvyukov_mpmc_queue_unit_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-integration", .path = "src/libs/beam-dvyukov-mpmc-queue/tests/_dvyukov_mpmc_queue_integration_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-fuzz", .path = "src/libs/beam-dvyukov-mpmc-queue/tests/_dvyukov_mpmc_queue_fuzz_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-samples", .path = "src/libs/beam-dvyukov-mpmc-queue/samples/_dvyukov_mpmc_queue_samples.zig", .category = .dvyukov_samples },
        .{ .name = "sharded-dvyukov-unit", .path = "src/libs/beam-dvyukov-mpmc-queue/tests/_sharded_dvyukov_mpmc_queue_unit_tests.zig", .category = .dvyukov_general },
        .{ .name = "sharded-dvyukov-integration", .path = "src/libs/beam-dvyukov-mpmc-queue/tests/_sharded_dvyukov_mpmc_queue_integration_tests.zig", .category = .dvyukov_general },
        .{ .name = "sharded-dvyukov-samples", .path = "src/libs/beam-dvyukov-mpmc-queue/samples/_sharded_dvyukov_mpmc_queue_samples.zig", .category = .dvyukov_samples },
        .{ .name = "beam-deque-unit", .path = "src/libs/beam-deque/tests/_beam_deque_unit_tests.zig", .category = .beam_deque_general },
        .{ .name = "beam-deque-race", .path = "src/libs/beam-deque/tests/_beam_deque_race_tests.zig", .category = .beam_deque_general },
        .{ .name = "beam-deque-channel", .path = "src/libs/beam-deque/tests/_beam_deque_channel_tests.zig", .category = .beam_deque_channel },
        .{ .name = "fat-type-validation", .path = "src/libs/beam-deque/tests/_test_fat_type_validation.zig", .category = .beam_deque_general },
        .{ .name = "spsc-queue-tests", .path = "src/libs/spsc-queue/tests/_spsc_queue_tests.zig", .category = .spsc_queue },
        .{ .name = "segmented-queue-ebr-unit", .path = "src/libs/beam-ebr/tests/_ebr_unit_tests.zig", .category = .segmented_queue_ebr_unit },
        .{ .name = "segmented-queue-ebr-fuzz", .path = "src/libs/beam-ebr/tests/_ebr_fuzz_tests.zig", .category = .segmented_queue_ebr_fuzz },
        .{ .name = "segmented-queue-integration", .path = "src/libs/beam-segmented-queue/tests/_segmented_queue_integration_tests.zig", .category = .segmented_queue_integration },
        .{ .name = "cache-padded-unit", .path = "src/libs/beam-cache-padded/tests/_cache_padded_unit_tests.zig", .category = .cache_padded },
        .{ .name = "cache-padded-samples", .path = "src/libs/beam-cache-padded/samples/_cache_padded_samples.zig", .category = .cache_padded },
        .{ .name = "beam-task-tests", .path = "src/libs/beam-task/tests/_task_tests.zig", .category = .beam_task },
    };

    // Individual import specs (each defined exactly once, then reused)
    const wrapper_import = imp("zig_beam", wrapper);
    const ebr_import = imp("beam-ebr", modules.segmented_queue_ebr);
    const beam_deque_import = imp("beam-deque", modules.beam_deque);
    const beam_deque_channel_import = imp("beam-deque-channel", modules.beam_deque_channel);
    const dvyukov_mpmc_import = imp("beam-dvyukov-mpmc", modules.dvyukov_mpmc);
    const sharded_dvyukov_mpmc_import = imp("beam-sharded-dvyukov-mpmc", modules.sharded_dvyukov_mpmc);
    const spsc_queue_import = imp("spsc-queue", modules.spsc_queue);
    const segmented_queue_import = imp("beam-segmented-queue", modules.segmented_queue);
    const backoff_import = imp("beam-backoff", modules.backoff);
    const lock_free_segmented_list_import = imp("beam-lock-free-segmented-list", modules.lock_free_segmented_list);
    const cache_padded_import = imp("beam-cache-padded", modules.cache_padded);
    const helpers_import = imp("helpers", modules.helpers);

    const bench_specs = [_]BenchSpec{
        // Benchmarks using wrapper module
        .{ .name = "tlc-bench", .exe_name = "tlc_bench", .path = "src/libs/beam-thread-local-cache/benchmarks/_thread_local_cache_benchmarks.zig", .category = .bench_tlc, .imports = &[_]ImportSpec{wrapper_import, helpers_import} },
        .{ .name = "arc-bench", .exe_name = "arc_bench", .path = "src/libs/beam-arc/benchmarks/_arc_benchmarks.zig", .category = .bench_arc, .imports = &[_]ImportSpec{wrapper_import, helpers_import} },
        .{ .name = "arcpool-bench", .exe_name = "arcpool_bench", .path = "src/libs/beam-arc/arc-pool/benchmarks/_arc_pool_benchmarks.zig", .category = .bench_arc_pool, .imports = &[_]ImportSpec{wrapper_import, helpers_import} },
        .{ .name = "dvyukov-bench", .exe_name = "_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/beam-dvyukov-mpmc-queue/benchmarks/_dvyukov_mpmc_queue_benchmarks.zig", .category = .bench_dvyukov, .imports = &[_]ImportSpec{wrapper_import, helpers_import, dvyukov_mpmc_import} },
        .{ .name = "sharded-dvyukov-bench", .exe_name = "_sharded_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/beam-dvyukov-mpmc-queue/benchmarks/_sharded_dvyukov_mpmc_queue_benchmarks.zig", .category = .bench_dvyukov, .imports = &[_]ImportSpec{wrapper_import, helpers_import, dvyukov_mpmc_import, sharded_dvyukov_mpmc_import} },
        .{ .name = "queue-util-bench", .exe_name = "test_queue_utilization", .path = "test_queue_utilization.zig", .category = .bench_queue_util, .imports = &[_]ImportSpec{wrapper_import} },

        // EBR-specific benchmarks
        .{ .name = "ebr-bench", .exe_name = "ebr_bench", .path = "src/libs/beam-ebr/benchmarks/_ebr_benchmarks.zig", .category = .bench_ebr, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-samples", .exe_name = "_ebr_samples", .path = "src/libs/beam-ebr/samples/_ebr_samples.zig", .category = .samples_ebr, .imports = &[_]ImportSpec{ebr_import} },

        // BeamDeque benchmarks
        .{ .name = "beam-deque-bench", .exe_name = "_beam_deque_benchmarks", .path = "src/libs/beam-deque/benchmarks/_beam_deque_benchmarks.zig", .category = .bench_beam_deque, .imports = &[_]ImportSpec{beam_deque_import} },
        .{ .name = "beam-deque-channel-bench", .exe_name = "_beam_deque_channel_benchmarks", .path = "src/libs/beam-deque/benchmarks/_beam_deque_channel_benchmarks.zig", .category = .bench_beam_deque_channel, .imports = &[_]ImportSpec{ beam_deque_import, beam_deque_channel_import, dvyukov_mpmc_import } },
        .{ .name = "beam-deque-channel-bench-v2", .exe_name = "_beam_deque_channel_benchmarks_v2", .path = "src/libs/beam-deque/benchmarks/_beam_deque_channel_benchmarks_v2.zig", .category = .bench_beam_deque_channel_v2, .imports = &[_]ImportSpec{ beam_deque_import, beam_deque_channel_import, dvyukov_mpmc_import } },

        // SPSC Queue benchmarks
        .{ .name = "spsc-queue-bench", .exe_name = "_spsc_queue_benchmarks", .path = "src/libs/spsc-queue/benchmarks/_spsc_queue_benchmarks.zig", .category = .bench_spsc_queue, .imports = &[_]ImportSpec{spsc_queue_import} },

        // SegmentedQueue benchmarks
        .{ .name = "segmented-queue-bench", .exe_name = "_segmented_queue_benchmarks", .path = "src/libs/beam-segmented-queue/benchmarks/_segmented_queue_benchmarks.zig", .category = .bench_segmented_queue, .imports = &[_]ImportSpec{ segmented_queue_import, dvyukov_mpmc_import, backoff_import, ebr_import } },
        .{ .name = "segmented-queue-guard-api-bench", .exe_name = "_guard_api_comparison_bench", .path = "src/libs/beam-segmented-queue/benchmarks/_guard_api_comparison_bench.zig", .category = .bench_segmented_queue_guard_api, .imports = &[_]ImportSpec{ segmented_queue_import, dvyukov_mpmc_import, backoff_import, ebr_import } },

        // EBR diagnostics
        .{ .name = "ebr-shutdown-bench", .exe_name = "_ebr_shutdown_test", .path = "src/libs/beam-ebr/benchmarks/_ebr_shutdown_test.zig", .category = .bench_ebr_shutdown, .imports = &[_]ImportSpec{ ebr_import, dvyukov_mpmc_import, lock_free_segmented_list_import, cache_padded_import } },
        .{ .name = "ebr-queue-pressure-bench", .exe_name = "_ebr_queue_pressure_diagnostic", .path = "src/libs/beam-ebr/benchmarks/_ebr_queue_pressure_diagnostic.zig", .category = .bench_ebr_queue_pressure, .imports = &[_]ImportSpec{ segmented_queue_import, ebr_import, dvyukov_mpmc_import, backoff_import } },
    };

    wireTests(b, target, optimize, steps, modules, &test_specs);
    wireBenchmarks(b, target, optimize, steps, &bench_specs);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Public wrapper module must be defined at top-level build()
    const wrapper = b.addModule("zig_beam", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    add_libs(b, target, optimize, wrapper);
}

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
    test_deque: *std.Build.Step,
    bench_deque: *std.Build.Step,
    test_deque_channel: *std.Build.Step,
    bench_deque_channel: *std.Build.Step,
    test_task: *std.Build.Step,
    test_loom: *std.Build.Step,
    test_spsc_queue: *std.Build.Step,
    bench_spsc_queue: *std.Build.Step,
    test_segmented_queue: *std.Build.Step,
    test_segmented_queue_integration: *std.Build.Step,
    bench_segmented_queue: *std.Build.Step,
    bench_segmented_queue_guard_api: *std.Build.Step,
    bench_queue_util: *std.Build.Step,
    bench_loom: *std.Build.Step,
    samples_loom: *std.Build.Step,
    // EBR-specific steps
    test_ebr: *std.Build.Step,
    test_ebr_unit: *std.Build.Step,
    test_ebr_integration: *std.Build.Step,
    test_ebr_stress: *std.Build.Step,
    test_ebr_fuzz: *std.Build.Step,
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
    deque: *std.Build.Module,
    deque_channel: *std.Build.Module,
    task: *std.Build.Module,
    loom: *std.Build.Module,
    spsc_queue: *std.Build.Module,
    cache_padded: *std.Build.Module,
    lock_free_segmented_list: *std.Build.Module,
    ebr: *std.Build.Module,
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
    deque_general,
    deque_channel,
    task,
    loom_unit,
    loom_integration,
    spsc_queue,
    ebr_unit,
    ebr_integration,
    ebr_stress,
    ebr_fuzz,
    segmented_queue_integration,
    cache_padded,
};

const BenchCategory = enum {
    bench_tlc,
    bench_arc,
    bench_arc_pool,
    bench_ebr,
    bench_ebr_pin_unpin,
    bench_ebr_pure_pin,
    bench_ebr_throughput,
    samples_ebr,
    bench_dvyukov,
    bench_deque,
    bench_deque_channel,
    bench_spsc_queue,
    bench_segmented_queue,
    bench_segmented_queue_guard_api,
    bench_queue_util,
    bench_loom,
    samples_loom,
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
        .samples_ebr = b.step("samples-ebr", "Run EBR usage samples (basic, lock_free_stack, multi_threaded, custom_config)"),
        .bench_tlc = b.step("bench-tlc", "Run Thread-Local Cache benchmarks"),
        .bench_arc = b.step("bench-arc", "Run Arc benchmarks"),
        .bench_arc_pool = b.step("bench-arc-pool", "Run ArcPool benchmarks"),
        .bench_ebr = b.step("bench-ebr", "Run all EBR benchmarks"),
        .bench_dvyukov = b.step("bench-dvyukov", "Run DVyukov MPMC Queue benchmarks"),
        .test_deque = b.step("test-deque", "Run Deque tests"),
        .bench_deque = b.step("bench-deque", "Run Deque benchmarks"),
        .test_deque_channel = b.step("test-deque-channel", "Run DequeChannel tests"),
        .bench_deque_channel = b.step("bench-deque-channel", "Run DequeChannel benchmarks"),
        .test_task = b.step("test-task", "Run Task tests"),
        .test_loom = b.step("test-loom", "Run Loom (work-stealing thread pool) tests"),
        .test_spsc_queue = b.step("test-spsc-queue", "Run BoundedSPSCQueue tests"),
        .bench_spsc_queue = b.step("bench-spsc-queue", "Run BoundedSPSCQueue benchmarks"),
        .test_segmented_queue = b.step("test-segmented-queue", "Run all SegmentedQueue tests"),
        .test_segmented_queue_integration = b.step("test-segmented-queue-integration", "Run SegmentedQueue integration tests"),
        .bench_segmented_queue = b.step("bench-segmented-queue", "Run SegmentedQueue benchmarks"),
        .bench_segmented_queue_guard_api = b.step("bench-segmented-queue-guard-api", "Compare Simple vs Optimized Guard API performance"),
        .bench_queue_util = b.step("bench-queue-util", "Run queue utilization benchmark"),
        .bench_loom = b.step("bench-loom", "Run Loom (work-stealing thread pool) benchmarks"),
        .samples_loom = b.step("samples-loom", "Run Loom samples (image_transform, etc)"),
        // EBR-specific steps
        .test_ebr = b.step("test-ebr", "Run all EBR tests (unit, integration, stress, fuzz)"),
        .test_ebr_unit = b.step("test-ebr-unit", "Run EBR unit tests"),
        .test_ebr_integration = b.step("test-ebr-integration", "Run EBR integration tests"),
        .test_ebr_stress = b.step("test-ebr-stress", "Run EBR stress tests"),
        .test_ebr_fuzz = b.step("test-ebr-fuzz", "Run EBR fuzz tests"),
    };
}

fn createModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const mb = ModuleBuilder{ .b = b, .target = target, .optimize = optimize };

    // Create all base modules
    const tagged_ptr = mb.create("src/libs/tagged-pointer/tagged_pointer.zig");
    const tlc = mb.create("src/libs/thread-local-cache/thread_local_cache.zig");
    const arc = mb.create("src/libs/arc/arc.zig");
    const arc_pool = mb.create("src/libs/arc/arc-pool/arc_pool.zig");
    const arc_cycle = mb.create("src/libs/arc/cycle-detector/arc_cycle_detector.zig");
    const backoff = mb.create("src/libs/backoff/backoff.zig");
    const dvyukov_mpmc = mb.create("src/libs/dvyukov-mpmc/dvyukov_mpmc_queue.zig");
    const sharded_dvyukov_mpmc = mb.create("src/libs/dvyukov-mpmc/sharded_dvyukov_mpmc_queue.zig");
    const deque = mb.create("src/libs/deque/deque.zig");
    const deque_channel = mb.create("src/libs/deque/deque_channel.zig");
    const task = mb.create("src/libs/task/task.zig");
    const loom = mb.create("src/loom/loom.zig");
    const spsc_queue = mb.create("src/libs/spsc-queue/spsc_queue.zig");
    const cache_padded = mb.create("src/libs/cache-padded/cache_padded.zig");
    const lock_free_segmented_list = mb.create("src/libs/segmented-queue/lock_free_segmented_list.zig");
    const helpers_mod = mb.create("src/libs/helpers/helpers.zig");

    // EBR internal modules (with proper dependency wiring)
    const ebr_reclaim = mb.create("src/libs/ebr/reclaim.zig");
    const ebr_epoch = mb.create("src/libs/ebr/epoch.zig");
    const ebr_thread_local = mb.create("src/libs/ebr/thread_local.zig");
    const ebr_guard = mb.create("src/libs/ebr/guard.zig");
    const ebr_collector = mb.create("src/libs/ebr/ebr.zig");
    const ebr = mb.create("src/libs/ebr/root.zig");

    // Wire EBR internal dependencies (using helpers for cache-line utilities)
    ebr_epoch.addImport("helpers", helpers_mod);
    ebr_thread_local.addImport("helpers", helpers_mod);
    ebr_thread_local.addImport("reclaim", ebr_reclaim);
    ebr_guard.addImport("thread_local", ebr_thread_local);
    ebr_guard.addImport("ebr", ebr_collector);
    ebr_collector.addImport("epoch", ebr_epoch);
    ebr_collector.addImport("guard", ebr_guard);
    ebr_collector.addImport("thread_local", ebr_thread_local);
    ebr_collector.addImport("reclaim", ebr_reclaim);
    // Wire root.zig to all internal modules
    ebr.addImport("helpers", helpers_mod);
    ebr.addImport("epoch", ebr_epoch);
    ebr.addImport("guard", ebr_guard);
    ebr.addImport("thread_local", ebr_thread_local);
    ebr.addImport("reclaim", ebr_reclaim);
    ebr.addImport("ebr", ebr_collector);

    const segmented_queue = mb.create("src/libs/segmented-queue/segmented_queue.zig");

    // Wire dependencies
    tlc.addImport("tagged-pointer", tagged_ptr);
    arc.addImport("tagged-pointer", tagged_ptr);
    arc_pool.addImport("tagged-pointer", tagged_ptr);
    arc_pool.addImport("arc", arc);
    arc_pool.addImport("thread-local-cache", tlc);
    arc_cycle.addImport("arc", arc);
    arc_cycle.addImport("arc-pool", arc_pool);
    arc_cycle.addImport("tagged-pointer", tagged_ptr);
    sharded_dvyukov_mpmc.addImport("dvyukov-mpmc", dvyukov_mpmc);
    deque.addImport("backoff", backoff);
    deque_channel.addImport("deque", deque);
    deque_channel.addImport("dvyukov-mpmc", dvyukov_mpmc);
    loom.addImport("backoff", backoff);
    loom.addImport("deque-channel", deque_channel);
    segmented_queue.addImport("dvyukov-mpmc", dvyukov_mpmc);
    segmented_queue.addImport("backoff", backoff);
    segmented_queue.addImport("ebr", ebr);

    return .{
        .tagged_ptr = tagged_ptr,
        .tlc = tlc,
        .arc = arc,
        .arc_pool = arc_pool,
        .arc_cycle = arc_cycle,
        .backoff = backoff,
        .dvyukov_mpmc = dvyukov_mpmc,
        .sharded_dvyukov_mpmc = sharded_dvyukov_mpmc,
        .deque = deque,
        .deque_channel = deque_channel,
        .task = task,
        .loom = loom,
        .spsc_queue = spsc_queue,
        .cache_padded = cache_padded,
        .lock_free_segmented_list = lock_free_segmented_list,
        .ebr = ebr,
        .segmented_queue = segmented_queue,
        .helpers = helpers_mod,
    };
}

fn wireTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, steps: BuildSteps, modules: Modules, test_specs: []const TestSpec) void {
    const all_imports = &[_]ImportSpec{
        .{ .name = "tagged-pointer", .module = modules.tagged_ptr },
        .{ .name = "thread-local-cache", .module = modules.tlc },
        .{ .name = "arc", .module = modules.arc },
        .{ .name = "arc-pool", .module = modules.arc_pool },
        .{ .name = "arc-cycle", .module = modules.arc_cycle },
        .{ .name = "backoff", .module = modules.backoff },
        .{ .name = "dvyukov-mpmc", .module = modules.dvyukov_mpmc },
        .{ .name = "sharded-dvyukov-mpmc", .module = modules.sharded_dvyukov_mpmc },
        .{ .name = "deque", .module = modules.deque },
        .{ .name = "deque-channel", .module = modules.deque_channel },
        .{ .name = "spsc-queue", .module = modules.spsc_queue },
        .{ .name = "segmented-queue", .module = modules.segmented_queue },
        .{ .name = "cache-padded", .module = modules.cache_padded },
        .{ .name = "lock-free-segmented-list", .module = modules.lock_free_segmented_list },
        .{ .name = "ebr", .module = modules.ebr },
        .{ .name = "task", .module = modules.task },
        .{ .name = "loom", .module = modules.loom },
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
            .deque_general => steps.test_deque.dependOn(&run.step),
            .deque_channel => steps.test_deque_channel.dependOn(&run.step),
            .task => steps.test_task.dependOn(&run.step),
            .loom_unit, .loom_integration => steps.test_loom.dependOn(&run.step),
            .spsc_queue => steps.test_spsc_queue.dependOn(&run.step),
            .ebr_unit => {
                steps.test_ebr_unit.dependOn(&run.step);
                steps.test_ebr.dependOn(&run.step);
            },
            .ebr_integration => {
                steps.test_ebr_integration.dependOn(&run.step);
                steps.test_ebr.dependOn(&run.step);
            },
            .ebr_stress => {
                steps.test_ebr_stress.dependOn(&run.step);
                steps.test_ebr.dependOn(&run.step);
            },
            .ebr_fuzz => {
                steps.test_ebr_fuzz.dependOn(&run.step);
                steps.test_ebr.dependOn(&run.step);
            },
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
            .bench_ebr, .bench_ebr_pin_unpin, .bench_ebr_pure_pin, .bench_ebr_throughput => steps.bench_ebr.dependOn(&run.step),
            .samples_ebr => steps.samples_ebr.dependOn(&run.step),
            .bench_dvyukov => steps.bench_dvyukov.dependOn(&run.step),
            .bench_deque => steps.bench_deque.dependOn(&run.step),
            .bench_deque_channel => steps.bench_deque_channel.dependOn(&run.step),
            .bench_spsc_queue => steps.bench_spsc_queue.dependOn(&run.step),
            .bench_segmented_queue => steps.bench_segmented_queue.dependOn(&run.step),
            .bench_segmented_queue_guard_api => steps.bench_segmented_queue_guard_api.dependOn(&run.step),
            .bench_queue_util => steps.bench_queue_util.dependOn(&run.step),
            .bench_loom => steps.bench_loom.dependOn(&run.step),
            .samples_loom => steps.samples_loom.dependOn(&run.step),
        }
    }
}

fn add_libs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wrapper: *std.Build.Module) void {
    const steps = createBuildSteps(b);
    const modules = createModules(b, target, optimize);

    // Wire internal modules into the public wrapper provided by build()
    wrapper.addImport("tagged-pointer", modules.tagged_ptr);
    wrapper.addImport("thread-local-cache", modules.tlc);
    wrapper.addImport("arc", modules.arc);
    wrapper.addImport("arc-pool", modules.arc_pool);
    wrapper.addImport("arc-cycle", modules.arc_cycle);
    wrapper.addImport("backoff", modules.backoff);
    wrapper.addImport("dvyukov-mpmc", modules.dvyukov_mpmc);
    wrapper.addImport("sharded-dvyukov-mpmc", modules.sharded_dvyukov_mpmc);
    wrapper.addImport("task", modules.task);
    wrapper.addImport("loom", modules.loom);
    wrapper.addImport("deque", modules.deque);
    wrapper.addImport("deque-channel", modules.deque_channel);
    wrapper.addImport("spsc-queue", modules.spsc_queue);
    wrapper.addImport("segmented-queue", modules.segmented_queue);
    wrapper.addImport("cache-padded", modules.cache_padded);
    wrapper.addImport("ebr", modules.ebr);

    // Test specs (libs)
    const test_specs = [_]TestSpec{
        .{ .name = "tlc-unit", .path = "src/libs/thread-local-cache/tests/_thread_local_cache_unit_tests.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-integration", .path = "src/libs/thread-local-cache/tests/_thread_local_cache_integration_test.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-fuzz", .path = "src/libs/thread-local-cache/tests/_thread_local_cache_fuzz_tests.zig", .category = .thread_local_cache_general },
        .{ .name = "tlc-samples", .path = "src/libs/thread-local-cache/samples/_thread_local_cache_samples.zig", .category = .thread_local_cache_samples },
        .{ .name = "tagged-unit", .path = "src/libs/tagged-pointer/tests/_tagged_pointer_unit_tests.zig", .category = .tagged_pointer_general },
        .{ .name = "tagged-integration", .path = "src/libs/tagged-pointer/tests/_tagged_pointer_integration_tests.zig", .category = .tagged_pointer_general },
        .{ .name = "tagged-samples", .path = "src/libs/tagged-pointer/samples/_tagged_pointer_samples.zig", .category = .tagged_pointer_samples },
        .{ .name = "arc-unit", .path = "src/libs/arc/tests/_arc_unit_tests.zig", .category = .arc_general },
        .{ .name = "arc-samples", .path = "src/libs/arc/samples/_arc_samples.zig", .category = .arc_samples },
        .{ .name = "arc-cycle-unit", .path = "src/libs/arc/cycle-detector/tests/_arc_cycle_detector_unit_tests.zig", .category = .arc_cycle },
        .{ .name = "arc-cycle-integration", .path = "src/libs/arc/cycle-detector/tests/_arc_cycle_detector_integration_tests.zig", .category = .arc_cycle },
        .{ .name = "arc-pool-unit", .path = "src/libs/arc/arc-pool/tests/_arc_pool_unit_tests.zig", .category = .arc_pool },
        .{ .name = "arc-pool-integration", .path = "src/libs/arc/arc-pool/tests/_arc_pool_integration_tests.zig", .category = .arc_pool },
        .{ .name = "dvyukov-unit", .path = "src/libs/dvyukov-mpmc/tests/_dvyukov_mpmc_queue_unit_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-integration", .path = "src/libs/dvyukov-mpmc/tests/_dvyukov_mpmc_queue_integration_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-fuzz", .path = "src/libs/dvyukov-mpmc/tests/_dvyukov_mpmc_queue_fuzz_tests.zig", .category = .dvyukov_general },
        .{ .name = "dvyukov-samples", .path = "src/libs/dvyukov-mpmc/samples/_dvyukov_mpmc_queue_samples.zig", .category = .dvyukov_samples },
        .{ .name = "sharded-dvyukov-unit", .path = "src/libs/dvyukov-mpmc/tests/_sharded_dvyukov_mpmc_queue_unit_tests.zig", .category = .dvyukov_general },
        .{ .name = "sharded-dvyukov-integration", .path = "src/libs/dvyukov-mpmc/tests/_sharded_dvyukov_mpmc_queue_integration_tests.zig", .category = .dvyukov_general },
        .{ .name = "sharded-dvyukov-samples", .path = "src/libs/dvyukov-mpmc/samples/_sharded_dvyukov_mpmc_queue_samples.zig", .category = .dvyukov_samples },
        .{ .name = "deque-unit", .path = "src/libs/deque/tests/_beam_deque_unit_tests.zig", .category = .deque_general },
        .{ .name = "deque-race", .path = "src/libs/deque/tests/_beam_deque_race_tests.zig", .category = .deque_general },
        .{ .name = "deque-channel", .path = "src/libs/deque/tests/_beam_deque_channel_tests.zig", .category = .deque_channel },
        .{ .name = "fat-type-validation", .path = "src/libs/deque/tests/_test_fat_type_validation.zig", .category = .deque_general },
        .{ .name = "spsc-queue-tests", .path = "src/libs/spsc-queue/tests/_spsc_queue_tests.zig", .category = .spsc_queue },
        // EBR unit tests
        .{ .name = "ebr-collector-unit", .path = "src/libs/ebr/tests/unit/collector_test.zig", .category = .ebr_unit },
        .{ .name = "ebr-epoch-unit", .path = "src/libs/ebr/tests/unit/epoch_test.zig", .category = .ebr_unit },
        // EBR integration tests
        .{ .name = "ebr-lockfree-queue", .path = "src/libs/ebr/tests/integration/lockfree_queue_test.zig", .category = .ebr_integration },
        .{ .name = "ebr-quickstart", .path = "src/libs/ebr/tests/integration/quickstart_examples_test.zig", .category = .ebr_integration },
        // EBR stress tests
        .{ .name = "ebr-contention", .path = "src/libs/ebr/tests/stress/contention_test.zig", .category = .ebr_stress },
        .{ .name = "ebr-full-stress", .path = "src/libs/ebr/tests/stress/full_stress_test.zig", .category = .ebr_stress },
        .{ .name = "ebr-memory-pressure", .path = "src/libs/ebr/tests/stress/memory_pressure_test.zig", .category = .ebr_stress },
        .{ .name = "ebr-thread-stress", .path = "src/libs/ebr/tests/stress/thread_stress_test.zig", .category = .ebr_stress },
        // EBR fuzz tests
        .{ .name = "ebr-fuzz", .path = "src/libs/ebr/tests/fuzz/ebr_fuzz.zig", .category = .ebr_fuzz },
        .{ .name = "segmented-queue-integration", .path = "src/libs/segmented-queue/tests/_segmented_queue_integration_tests.zig", .category = .segmented_queue_integration },
        .{ .name = "cache-padded-unit", .path = "src/libs/cache-padded/tests/_cache_padded_unit_tests.zig", .category = .cache_padded },
        .{ .name = "cache-padded-samples", .path = "src/libs/cache-padded/samples/_cache_padded_samples.zig", .category = .cache_padded },
        .{ .name = "task-tests", .path = "src/libs/task/tests/_task_tests.zig", .category = .task },
        // Loom tests
        .{ .name = "loom-thread-pool", .path = "src/loom/tests/unit/thread_pool_test.zig", .category = .loom_unit },
        .{ .name = "loom-join", .path = "src/loom/tests/unit/join_test.zig", .category = .loom_unit },
        .{ .name = "loom-scope", .path = "src/loom/tests/unit/scope_test.zig", .category = .loom_unit },
        .{ .name = "loom-parallel-iter", .path = "src/loom/tests/unit/parallel_iter_test.zig", .category = .loom_unit },
        .{ .name = "loom-worker-id", .path = "src/loom/tests/unit/worker_id_test.zig", .category = .loom_unit },
        .{ .name = "loom-iterator-parity", .path = "src/loom/tests/unit/iterator_parity_test.zig", .category = .loom_unit },
        .{ .name = "loom-custom-pool", .path = "src/loom/tests/integration/custom_pool_test.zig", .category = .loom_integration },
        .{ .name = "loom-context-api", .path = "src/loom/tests/integration/context_api_test.zig", .category = .loom_integration },
    };

    // Individual import specs (each defined exactly once, then reused)
    const wrapper_import = imp("zigbeam", wrapper);
    const ebr_import = imp("ebr", modules.ebr);
    const deque_import = imp("deque", modules.deque);
    const deque_channel_import = imp("deque-channel", modules.deque_channel);
    const dvyukov_mpmc_import = imp("dvyukov-mpmc", modules.dvyukov_mpmc);
    const loom_import = imp("loom", modules.loom);
    const sharded_dvyukov_mpmc_import = imp("sharded-dvyukov-mpmc", modules.sharded_dvyukov_mpmc);
    const spsc_queue_import = imp("spsc-queue", modules.spsc_queue);
    const segmented_queue_import = imp("segmented-queue", modules.segmented_queue);
    const backoff_import = imp("backoff", modules.backoff);
    const helpers_import = imp("helpers", modules.helpers);

    // Loom bench reporter module
    const loom_bench_reporter = b.createModule(.{
        .root_source_file = b.path("src/loom/bench/bench_reporter.zig"),
        .target = target,
        .optimize = optimize,
    });
    const loom_bench_reporter_import = imp("bench-reporter", loom_bench_reporter);

    const bench_specs = [_]BenchSpec{
        // Benchmarks using wrapper module
        .{ .name = "tlc-bench", .exe_name = "tlc_bench", .path = "src/libs/thread-local-cache/benchmarks/_thread_local_cache_benchmarks.zig", .category = .bench_tlc, .imports = &[_]ImportSpec{ wrapper_import, helpers_import } },
        .{ .name = "arc-bench", .exe_name = "arc_bench", .path = "src/libs/arc/benchmarks/_arc_benchmarks.zig", .category = .bench_arc, .imports = &[_]ImportSpec{ wrapper_import, helpers_import } },
        .{ .name = "arcpool-bench", .exe_name = "arcpool_bench", .path = "src/libs/arc/arc-pool/benchmarks/_arc_pool_benchmarks.zig", .category = .bench_arc_pool, .imports = &[_]ImportSpec{ wrapper_import, helpers_import } },
        .{ .name = "dvyukov-bench", .exe_name = "_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/dvyukov-mpmc/benchmarks/_dvyukov_mpmc_queue_benchmarks.zig", .category = .bench_dvyukov, .imports = &[_]ImportSpec{ wrapper_import, helpers_import, dvyukov_mpmc_import } },
        .{ .name = "sharded-dvyukov-bench", .exe_name = "_sharded_dvyukov_mpmc_queue_benchmarks", .path = "src/libs/dvyukov-mpmc/benchmarks/_sharded_dvyukov_mpmc_queue_benchmarks.zig", .category = .bench_dvyukov, .imports = &[_]ImportSpec{ wrapper_import, helpers_import, dvyukov_mpmc_import, sharded_dvyukov_mpmc_import } },
        .{ .name = "queue-util-bench", .exe_name = "test_queue_utilization", .path = "test_queue_utilization.zig", .category = .bench_queue_util, .imports = &[_]ImportSpec{wrapper_import} },

        // EBR benchmarks (new structure)
        .{ .name = "ebr-bench", .exe_name = "ebr_bench", .path = "src/libs/ebr/bench/ebr_benchmarks.zig", .category = .bench_ebr, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-pin-unpin-bench", .exe_name = "ebr_pin_unpin_bench", .path = "src/libs/ebr/bench/pin_unpin_bench.zig", .category = .bench_ebr_pin_unpin, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-pure-pin-bench", .exe_name = "ebr_pure_pin_bench", .path = "src/libs/ebr/bench/pure_pin_bench.zig", .category = .bench_ebr_pure_pin, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-throughput-bench", .exe_name = "ebr_throughput_bench", .path = "src/libs/ebr/bench/throughput_bench.zig", .category = .bench_ebr_throughput, .imports = &[_]ImportSpec{ebr_import} },
        // EBR samples (new structure)
        .{ .name = "ebr-sample-basic", .exe_name = "ebr_sample_basic", .path = "src/libs/ebr/samples/basic.zig", .category = .samples_ebr, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-sample-custom-config", .exe_name = "ebr_sample_custom_config", .path = "src/libs/ebr/samples/custom_config.zig", .category = .samples_ebr, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-sample-lock-free-stack", .exe_name = "ebr_sample_lock_free_stack", .path = "src/libs/ebr/samples/lock_free_stack.zig", .category = .samples_ebr, .imports = &[_]ImportSpec{ebr_import} },
        .{ .name = "ebr-sample-multi-threaded", .exe_name = "ebr_sample_multi_threaded", .path = "src/libs/ebr/samples/multi_threaded.zig", .category = .samples_ebr, .imports = &[_]ImportSpec{ebr_import} },

        // Deque benchmarks
        .{ .name = "deque-bench", .exe_name = "_deque_benchmarks", .path = "src/libs/deque/benchmarks/_beam_deque_benchmarks.zig", .category = .bench_deque, .imports = &[_]ImportSpec{deque_import} },
        .{ .name = "deque-channel-bench", .exe_name = "_deque_channel_benchmarks", .path = "src/libs/deque/benchmarks/_beam_deque_channel_benchmarks.zig", .category = .bench_deque_channel, .imports = &[_]ImportSpec{ deque_import, deque_channel_import, dvyukov_mpmc_import } },

        // SPSC Queue benchmarks
        .{ .name = "spsc-queue-bench", .exe_name = "_spsc_queue_benchmarks", .path = "src/libs/spsc-queue/benchmarks/_spsc_queue_benchmarks.zig", .category = .bench_spsc_queue, .imports = &[_]ImportSpec{spsc_queue_import} },

        // SegmentedQueue benchmarks
        .{ .name = "segmented-queue-bench", .exe_name = "_segmented_queue_benchmarks", .path = "src/libs/segmented-queue/benchmarks/_segmented_queue_benchmarks.zig", .category = .bench_segmented_queue, .imports = &[_]ImportSpec{ segmented_queue_import, dvyukov_mpmc_import, backoff_import, ebr_import } },
        .{ .name = "segmented-queue-guard-api-bench", .exe_name = "_guard_api_comparison_bench", .path = "src/libs/segmented-queue/benchmarks/_guard_api_comparison_bench.zig", .category = .bench_segmented_queue_guard_api, .imports = &[_]ImportSpec{ segmented_queue_import, dvyukov_mpmc_import, backoff_import, ebr_import } },

        // Loom benchmarks
        .{ .name = "loom-throughput-bench", .exe_name = "loom_throughput_bench", .path = "src/loom/bench/throughput_bench.zig", .category = .bench_loom, .imports = &[_]ImportSpec{ loom_import, loom_bench_reporter_import } },
        .{ .name = "loom-join-bench", .exe_name = "loom_join_bench", .path = "src/loom/bench/join_bench.zig", .category = .bench_loom, .imports = &[_]ImportSpec{ loom_import, loom_bench_reporter_import } },
        .{ .name = "loom-parallel-iter-bench", .exe_name = "loom_parallel_iter_bench", .path = "src/loom/bench/parallel_iter_bench.zig", .category = .bench_loom, .imports = &[_]ImportSpec{ loom_import, loom_bench_reporter_import } },
        .{ .name = "loom-api-bench", .exe_name = "loom_api_bench", .path = "src/loom/bench/api_bench.zig", .category = .bench_loom, .imports = &[_]ImportSpec{ loom_import, loom_bench_reporter_import } },
        .{ .name = "loom-work-stealing-bench", .exe_name = "loom_work_stealing_bench", .path = "src/loom/bench/work_stealing_bench.zig", .category = .bench_loom, .imports = &[_]ImportSpec{ loom_import, loom_bench_reporter_import } },

        // Loom samples
        .{ .name = "loom-sample-image-transform", .exe_name = "loom_image_transform", .path = "src/loom/samples/image_transform.zig", .category = .samples_loom, .imports = &[_]ImportSpec{loom_import} },
        .{ .name = "loom-sample-csv-transform-mmap", .exe_name = "loom_csv_transform_mmap", .path = "src/loom/samples/csv_transform_mmap_with_loom.zig", .category = .samples_loom, .imports = &[_]ImportSpec{loom_import} },
        .{ .name = "loom-sample-csv-transform-inmem", .exe_name = "loom_csv_transform_inmem", .path = "src/loom/samples/csv_transform_in_mem_with_loom.zig", .category = .samples_loom, .imports = &[_]ImportSpec{loom_import} },
        .{ .name = "loom-sample-api-showcase", .exe_name = "loom_api_showcase", .path = "src/loom/samples/loom_api_showcase.zig", .category = .samples_loom, .imports = &[_]ImportSpec{loom_import} },
        .{ .name = "loom-sample-context-api-bench", .exe_name = "context_api_bench", .path = "src/loom/samples/context_api_bench.zig", .category = .samples_loom, .imports = &[_]ImportSpec{loom_import} },
    };

    wireTests(b, target, optimize, steps, modules, &test_specs);
    wireBenchmarks(b, target, optimize, steps, &bench_specs);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Public wrapper module must be defined at top-level build()
    const wrapper = b.addModule("zigbeam", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    add_libs(b, target, optimize, wrapper);
}

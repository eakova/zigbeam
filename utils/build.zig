const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zig_beam_utils", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    _ = mod; // Exposed to consumers; not used directly in this build.
    // Library-focused build: add tests for submodules and a benchmark runner.
    // Thread-local cache unit tests
    const tlc_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/thread-local-cache/_thread_local_cache_unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tlc_unit = b.addRunArtifact(tlc_unit);

    // Thread-local cache integration tests
    const tlc_integ = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/thread-local-cache/_thread_local_cache_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tlc_integ = b.addRunArtifact(tlc_integ);

    // Thread-local cache fuzz tests
    const tlc_fuzz = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/thread-local-cache/_thread_local_cache_fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tlc_fuzz = b.addRunArtifact(tlc_fuzz);

    // Benchmarks for thread-local cache
    const tlc_bench = b.addExecutable(.{
        .name = "tlc_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/thread-local-cache/_thread_local_cache_benchmarks.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tlc_bench = b.addRunArtifact(tlc_bench);

    // Top-level steps
    const test_step = b.step("test", "Run utils library tests");
    test_step.dependOn(&run_tlc_unit.step);
    test_step.dependOn(&run_tlc_integ.step);
    test_step.dependOn(&run_tlc_fuzz.step);

    const bench_step = b.step("bench", "Run utils benchmarks");
    bench_step.dependOn(&run_tlc_bench.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

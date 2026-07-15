const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("zvm_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zvm",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ============================================================================
    // Phase 1: BEAM Disassembler
    // ============================================================================

    // Create shared modules for Phase 1 components
    const beam_file_mod = b.createModule(.{
        .root_source_file = b.path("src/beam_file.zig"),
        .target = target,
        .optimize = optimize,
    });

    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/term.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Beam file module needs term module
    beam_file_mod.addImport("term", term_mod);

    // Create module for the disassembler
    const disasm_mod = b.createModule(.{
        .root_source_file = b.path("src/disasm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports for disassembler dependencies
    disasm_mod.addImport("beam_file", beam_file_mod);
    disasm_mod.addImport("term", term_mod);

    // Create the disassembler executable
    const disasm_exe = b.addExecutable(.{
        .name = "zvm-disasm",
        .root_module = disasm_mod,
    });

    // Install the disassembler
    b.installArtifact(disasm_exe);

    // Create run step for disassembler
    const run_disasm_cmd = b.addRunArtifact(disasm_exe);
    run_disasm_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to disassembler
    if (b.args) |args| {
        run_disasm_cmd.addArgs(args);
    }

    // Create 'disasm' build step
    const disasm_step = b.step("disasm", "Run the BEAM disassembler");
    disasm_step.dependOn(&run_disasm_cmd.step);

    // ============================================================================
    // Phase 2: BEAM VM Execution
    // ============================================================================

    // Create additional modules for Phase 2
    const compact_term_mod = b.createModule(.{
        .root_source_file = b.path("src/compact_term.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executor_mod = b.createModule(.{
        .root_source_file = b.path("src/executor.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set up module dependencies
    compact_term_mod.addImport("term", term_mod);
    vm_mod.addImport("term", term_mod);
    vm_mod.addImport("beam_file", beam_file_mod);
    vm_mod.addImport("control_flow", b.createModule(.{
        .root_source_file = b.path("src/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    }));
    executor_mod.addImport("beam_file", beam_file_mod);
    executor_mod.addImport("compact_term", compact_term_mod);
    executor_mod.addImport("vm", vm_mod);
    executor_mod.addImport("bif", b.createModule(.{
        .root_source_file = b.path("src/bif.zig"),
        .target = target,
        .optimize = optimize,
    }));
    executor_mod.addImport("control_flow", b.createModule(.{
        .root_source_file = b.path("src/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    }));

    // Create main executable for BEAM execution
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports for main program dependencies
    main_mod.addImport("beam_file", beam_file_mod);
    main_mod.addImport("vm", vm_mod);
    main_mod.addImport("executor", executor_mod);
    main_mod.addImport("control_flow", b.createModule(.{
        .root_source_file = b.path("src/control_flow.zig"),
        .target = target,
        .optimize = optimize,
    }));

    // Create the zvm executable
    const zvm_exe = b.addExecutable(.{
        .name = "zvm",
        .root_module = main_mod,
    });

    // Install the zvm executable
    b.installArtifact(zvm_exe);

    // Create run step for zvm
    const run_zvm_cmd = b.addRunArtifact(zvm_exe);
    run_zvm_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to zvm
    if (b.args) |args| {
        run_zvm_cmd.addArgs(args);
    }

    // Create 'exec' build step for zvm
    const zvm_run_step = b.step("exec", "Execute BEAM files with zvm");
    zvm_run_step.dependOn(&run_zvm_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

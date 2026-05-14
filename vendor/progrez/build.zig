const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // --- Static library (Zig core + C FFI) ---
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "progrez",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // --- Shared library (for LuaJIT FFI, Python ctypes, etc.) ---
    const dylib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const dylib = b.addLibrary(.{
        .name = "progrez_shared",
        .linkage = .dynamic,
        .root_module = dylib_module,
    });
    b.installArtifact(dylib);

    // Install C header for downstream C/FFI consumers
    b.installFile("include/progrez.h", "include/progrez.h");

    // Expose module for downstream Zig consumers (full lib including FFI)
    _ = b.addModule("progrez", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Pure-logic module for downstream Zig consumers (no FFI, no C symbols)
    _ = b.addModule("progrez_core", .{
        .root_source_file = b.path("src/core_lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- C demo executable ---
    const demo = b.addExecutable(.{
        .name = "progrez-demo",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    demo.root_module.addCSourceFile(.{
        .file = b.path("examples/demo.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    demo.root_module.addIncludePath(b.path("include"));
    demo.root_module.linkLibrary(lib);
    b.installArtifact(demo);

    // Demo run step
    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    const demo_step = b.step("demo", "Build and run the demo");
    demo_step.dependOn(&run_demo.step);

    // --- Unit tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

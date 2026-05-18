const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	const lib_mod = b.addModule("bzip2z", .{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});

	const lib = b.addLibrary(.{
		.name = "bzip2z",
		.root_module = lib_mod,
		.linkage = .static,
	});
	b.installArtifact(lib);

	const ffi_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	const ffi_lib = b.addLibrary(.{
		.name = "bzip2z_ffi",
		.root_module = ffi_mod,
		.linkage = .static,
	});
	b.installArtifact(ffi_lib);

	const is_windows = target.result.os.tag == .windows;

	const progrez_dep = b.dependency("progrez", .{
		.target = target,
		.optimize = optimize,
	});
	const progrez_lib = if (!is_windows) progrez_dep.artifact("progrez") else null;

	const cli_c_flags: []const []const u8 = if (!is_windows)
		&.{ "-std=c11", "-DHAVE_PROGREZ=1" }
	else
		&.{ "-std=c11" };

	const cli_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	cli_mod.addIncludePath(b.path("c/include"));
	cli_mod.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	cli_mod.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		cli_mod.linkLibrary(pl);
		cli_mod.addIncludePath(progrez_dep.path("include"));
	}
	const cli = b.addExecutable(.{
		.name = "bzip2z",
		.root_module = cli_mod,
	});
	b.installArtifact(cli);

	const bunzip2_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	bunzip2_mod.addIncludePath(b.path("c/include"));
	bunzip2_mod.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	bunzip2_mod.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		bunzip2_mod.linkLibrary(pl);
		bunzip2_mod.addIncludePath(progrez_dep.path("include"));
	}
	const bunzip2 = b.addExecutable(.{
		.name = "bunzip2z",
		.root_module = bunzip2_mod,
	});
	b.installArtifact(bunzip2);

	const bzcat_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	bzcat_mod.addIncludePath(b.path("c/include"));
	bzcat_mod.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	bzcat_mod.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		bzcat_mod.linkLibrary(pl);
		bzcat_mod.addIncludePath(progrez_dep.path("include"));
	}
	const bzcat = b.addExecutable(.{
		.name = "bzcatz",
		.root_module = bzcat_mod,
	});
	b.installArtifact(bzcat);

	const run_cli = b.addRunArtifact(cli);
	run_cli.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cli.addArgs(args);
	}
	const run_step = b.step("run", "Run bzip2z CLI");
	run_step.dependOn(&run_cli.step);

	const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this text");
	var test_filters: []const []const u8 = &.{};
	if (test_filter) |filter| {
		test_filters = &.{filter};
	}

	const lib_tests = b.addTest(.{
		.root_module = lib_mod,
		.filters = test_filters,
	});
	const run_lib_tests = b.addRunArtifact(lib_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_lib_tests.step);

	const install_lib_tests = b.addInstallArtifact(lib_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "lib_tests",
	});

	// Builds (but does not run) all test binaries so CI can patchelf the
	// FHS dynamic-linker path that Zig bakes into libc-linked exes.
	const test_compile_step = b.step("test-compile", "Compile test binaries without running them");
	test_compile_step.dependOn(&install_lib_tests.step);

	const bench_mod = b.createModule(.{
		.root_source_file = b.path("bench/bench_bzip2.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
		.imports = &.{
			.{ .name = "bzip2z", .module = lib_mod },
		},
	});
	const bench = b.addExecutable(.{
		.name = "bench-bzip2",
		.root_module = bench_mod,
	});
	const install_bench = b.addInstallArtifact(bench, .{});
	const bench_step = b.step("bench", "Build benchmarks");
	bench_step.dependOn(&install_bench.step);

	const bench_tests = b.addTest(.{
		.root_module = bench_mod,
		.filters = test_filters,
	});
	const run_bench_tests = b.addRunArtifact(bench_tests);
	test_step.dependOn(&run_bench_tests.step);
	test_compile_step.dependOn(&b.addInstallArtifact(bench_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "bench_tests",
	}).step);

	const fuzz_mod = b.createModule(.{
		.root_source_file = b.path("fuzz/fuzz_stream_bzip2.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{
			.{ .name = "bzip2z", .module = lib_mod },
		},
	});
	const fuzz = b.addExecutable(.{
		.name = "fuzz-stream-bzip2",
		.root_module = fuzz_mod,
	});
	const install_fuzz = b.addInstallArtifact(fuzz, .{});
	const fuzz_step = b.step("fuzz", "Build fuzzers");
	fuzz_step.dependOn(&install_fuzz.step);
}

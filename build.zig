const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	const lib_mod = b.addModule("bzip2z", .{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
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
	});
	const ffi_lib = b.addLibrary(.{
		.name = "bzip2z_ffi",
		.root_module = ffi_mod,
		.linkage = .static,
	});
	ffi_lib.linkLibC();
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

	const cli = b.addExecutable(.{
		.name = "bzip2z",
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
		}),
	});
	cli.linkLibC();
	cli.addIncludePath(b.path("c/include"));
	cli.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	cli.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		cli.linkLibrary(pl);
		cli.root_module.addIncludePath(progrez_dep.path("include"));
	}
	b.installArtifact(cli);

	const bunzip2 = b.addExecutable(.{
		.name = "bunzip2z",
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
		}),
	});
	bunzip2.linkLibC();
	bunzip2.addIncludePath(b.path("c/include"));
	bunzip2.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	bunzip2.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		bunzip2.linkLibrary(pl);
		bunzip2.root_module.addIncludePath(progrez_dep.path("include"));
	}
	b.installArtifact(bunzip2);

	const bzcat = b.addExecutable(.{
		.name = "bzcatz",
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
		}),
	});
	bzcat.linkLibC();
	bzcat.addIncludePath(b.path("c/include"));
	bzcat.addCSourceFile(.{
		.file = b.path("c/cli.c"),
		.flags = cli_c_flags,
	});
	bzcat.linkLibrary(ffi_lib);
	if (progrez_lib) |pl| {
		bzcat.linkLibrary(pl);
		bzcat.root_module.addIncludePath(progrez_dep.path("include"));
	}
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

	const bench_mod = b.createModule(.{
		.root_source_file = b.path("bench/bench_bzip2.zig"),
		.target = target,
		.optimize = optimize,
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

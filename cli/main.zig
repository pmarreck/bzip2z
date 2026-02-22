const std = @import("std");
const bzip2 = @import("bzip2z").bzip2;

const Mode = enum {
	compress,
	decompress,
	@"test",
};

const CliOptions = struct {
	mode: Mode = .compress,
	stdout: bool = false,
	keep: bool = false,
	force: bool = false,
	quiet: bool = false,
	verbose: u8 = 0,
	small: bool = false,
	level: u8 = 9,
	threads: usize = 0,
	pbzip2: bool = false,
	about: bool = false,
	show_version: bool = false,
	show_license: bool = false,
};

fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
	var buf: [4096]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&buf);
	const stdout = &stdout_writer.interface;
	stdout.print(fmt, args) catch return;
	stdout.flush() catch return;
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
	var buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&buf);
	const stderr = &stderr_writer.interface;
	stderr.print(fmt, args) catch return;
	stderr.flush() catch return;
}

fn isStdinTty() bool {
	return std.posix.isatty(std.posix.STDIN_FILENO);
}

fn defaultModeFromProgramName(program: []const u8) Mode {
	const base = std.fs.path.basename(program);
	if (std.mem.eql(u8, base, "bunzip2")) return .decompress;
	if (std.mem.eql(u8, base, "bzcat")) return .decompress;
	return .compress;
}

fn usage(program: []const u8) void {
	stdoutPrint(
		\\bzip2z - clean-room block-sorting compressor in Zig
		\\
		\\usage: {s} [options] [files...]
		\\
		\\ -h, --help          show this help
		\\ -d, --decompress    decompress input
		\\ -z, --compress      compress input
		\\ -k, --keep          keep source files
		\\ -f, --force         overwrite output paths
		\\ -t, --test          verify archive integrity only
		\\ -c, --stdout        write payload bytes to stdout
		\\ -q, --quiet         suppress non-fatal diagnostics
		\\ -v, --verbose       increase logging (repeat for more detail)
		\\ -L, --license       print version and license notice
		\\ -V, --version       print version and license notice
		\\ -s, --small         reduced-memory mode (max 2500k)
		\\ -1 .. -9            block size from 100k to 900k
		\\ --fast              same as -1
		\\ --best              same as -9
		\\ -j N                pbzip2-style multi-stream compression and parallel decode using N threads
		\\ --about             show implementation summary
		\\
		\\Default mode depends on executable name:
		\\  bzip2   => compress
		\\  bunzip2 => decompress
		\\  bzcat   => decompress to stdout
		\\
		\\With no files, input is read from stdin.
		\\Short options can be combined (example: -v4).
		\\
	, .{program});
}

fn versionInfo() void {
	stdoutPrint(
		\\bzip2z {s}
		\\Clean-room Zig bzip2 implementation (SA-IS BWT)
		\\Original bzip2: Julian R Seward <jseward@bzip.org>
		\\This reimplementation: Peter Marreck
		\\
	, .{bzip2zVersion()});
}

fn licenseInfo() void {
	versionInfo();
	stdoutPrint(
		\\
		\\Original bzip2 license:
		\\  bzip2/libbzip2 version 1.0.6 of 6 September 2010
		\\  Copyright (C) 1996-2010 Julian R Seward <jseward@bzip.org>
		\\  Redistribution and use in source and binary forms, with or without
		\\  modification, are permitted provided that the following conditions are met:
		\\  1. Redistributions of source code must retain the above copyright notice.
		\\  2. The origin of this software must not be misrepresented; you must not
		\\     claim that you wrote the original software.
		\\  3. Altered source versions must be plainly marked as such.
		\\  4. The name of the author may not be used to endorse or promote products
		\\     derived from this software without specific prior written permission.
		\\
	, .{});
}

fn bzip2zVersion() []const u8 {
	return @import("bzip2z").getVersion();
}

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]u8, program: []const u8) !struct {
	opts: CliOptions,
	files: [][]const u8,
} {
	var opts = CliOptions{};
	opts.mode = defaultModeFromProgramName(program);
	if (std.mem.eql(u8, std.fs.path.basename(program), "bzcat")) {
		opts.stdout = true;
		opts.mode = .decompress;
	}

	var files: std.ArrayListUnmanaged([]const u8) = .{};
	defer files.deinit(allocator);

	var i: usize = 1;
	while (i < args.len) : (i += 1) {
		const arg_z = args[i];
		const arg = arg_z[0..arg_z.len];
		if (arg.len == 0) continue;

		if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			usage(program);
			return error.HelpRequested;
		}
		if (std.mem.eql(u8, arg, "--about") or std.mem.eql(u8, arg, "-a")) {
			opts.about = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--license") or std.mem.eql(u8, arg, "-L")) {
			opts.show_license = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
			opts.show_version = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--decompress") or std.mem.eql(u8, arg, "-d")) {
			opts.mode = .decompress;
			continue;
		}
		if (std.mem.eql(u8, arg, "--compress") or std.mem.eql(u8, arg, "-z")) {
			opts.mode = .compress;
			continue;
		}
		if (std.mem.eql(u8, arg, "--test") or std.mem.eql(u8, arg, "-t")) {
			opts.mode = .@"test";
			continue;
		}
		if (std.mem.eql(u8, arg, "--keep") or std.mem.eql(u8, arg, "-k")) {
			opts.keep = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
			opts.force = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--stdout") or std.mem.eql(u8, arg, "-c")) {
			opts.stdout = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
			opts.quiet = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--small") or std.mem.eql(u8, arg, "-s")) {
			opts.small = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--fast")) {
			opts.level = 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--best")) {
			opts.level = 9;
			continue;
		}
		if (std.mem.eql(u8, arg, "-j")) {
			if (i + 1 >= args.len) return error.InvalidArgs;
			i += 1;
			opts.threads = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArgs;
			opts.pbzip2 = true;
			continue;
		}

		if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
			var j: usize = 1;
			while (j < arg.len) : (j += 1) {
				const flag = arg[j];
				if (flag >= '1' and flag <= '9') {
					opts.level = flag - '0';
					continue;
				}
				switch (flag) {
					'd' => opts.mode = .decompress,
					'z' => opts.mode = .compress,
					't' => opts.mode = .@"test",
					'k' => opts.keep = true,
					'f' => opts.force = true,
					'c' => opts.stdout = true,
					'q' => opts.quiet = true,
					'v' => opts.verbose += 1,
					's' => opts.small = true,
					'L' => opts.show_license = true,
					'V' => opts.show_version = true,
					else => return error.InvalidArgs,
				}
			}
			continue;
		}

		try files.append(allocator, arg);
	}

	const files_slice = try files.toOwnedSlice(allocator);
	return .{ .opts = opts, .files = files_slice };
}

fn hasBz2Suffix(path: []const u8) bool {
	return std.mem.endsWith(u8, path, ".bz2");
}

fn outputPath(allocator: std.mem.Allocator, input_path: []const u8, mode: Mode) ![]u8 {
	if (mode == .compress) {
		return try std.fmt.allocPrint(allocator, "{s}.bz2", .{input_path});
	}
	if (hasBz2Suffix(input_path)) {
		return try allocator.dupe(u8, input_path[0 .. input_path.len - 4]);
	}
	return error.InvalidArgs;
}

fn compressFile(allocator: std.mem.Allocator, input_path: []const u8, opts: CliOptions) !void {
	const input = try std.fs.cwd().openFile(input_path, .{});
	defer input.close();
	var input_buf: [64 * 1024]u8 = undefined;
	var input_reader = input.reader(&input_buf);
	const input_stream = &input_reader.interface;

	var out_path: ?[]u8 = null;
	var output_file: ?std.fs.File = null;
	defer if (output_file) |file| file.close();
	defer if (out_path) |path| allocator.free(path);

	if (opts.stdout) {
		const stdout_file = std.fs.File.stdout();
		var stdout_buf: [64 * 1024]u8 = undefined;
		var stdout_writer = stdout_file.writer(&stdout_buf);
		const stdout = &stdout_writer.interface;
		try bzip2.compressStreamWithOptions(allocator, input_stream, stdout, .{
			.level = opts.level,
			.threads = opts.threads,
			.multi_stream = opts.pbzip2,
		});
		try stdout.flush();
		return;
	}

	out_path = try outputPath(allocator, input_path, .compress);
	if (!opts.force) {
		if (std.fs.cwd().openFile(out_path.?, .{})) |_| {
			return error.OutputExists;
		} else |_| {}
	}

	output_file = try std.fs.cwd().createFile(out_path.?, .{});
	var out_buf: [64 * 1024]u8 = undefined;
	var out_writer = output_file.?.writer(&out_buf);
	const out_stream = &out_writer.interface;
	try bzip2.compressStreamWithOptions(allocator, input_stream, out_stream, .{
		.level = opts.level,
		.threads = opts.threads,
		.multi_stream = opts.pbzip2,
	});
	try out_stream.flush();

	if (!opts.keep) {
		std.fs.cwd().deleteFile(input_path) catch {};
	}
}

fn decompressFile(allocator: std.mem.Allocator, input_path: []const u8, opts: CliOptions) !void {
	const input = try std.fs.cwd().openFile(input_path, .{});
	defer input.close();
	var input_buf: [64 * 1024]u8 = undefined;
	var input_reader = input.reader(&input_buf);
	const input_stream = &input_reader.interface;

	var out_path: ?[]u8 = null;
	var output_file: ?std.fs.File = null;
	defer if (output_file) |file| file.close();
	defer if (out_path) |path| allocator.free(path);

	if (opts.stdout) {
		const stdout_file = std.fs.File.stdout();
		var stdout_buf: [64 * 1024]u8 = undefined;
		var stdout_writer = stdout_file.writer(&stdout_buf);
		const stdout = &stdout_writer.interface;
		if (opts.pbzip2 and opts.threads > 1) {
			try bzip2.decompressFileToWriterWithOptions(allocator, input_path, stdout, .{
				.threads = opts.threads,
				.parallel = true,
			});
		} else {
			var decompressor = try bzip2.Decompressor.init(allocator);
			defer decompressor.deinit();
			try decompressor.decompress(input_stream, stdout);
		}
		try stdout.flush();
		return;
	}

	out_path = try outputPath(allocator, input_path, .decompress);
	if (!opts.force) {
		if (std.fs.cwd().openFile(out_path.?, .{})) |_| {
			return error.OutputExists;
		} else |_| {}
	}

	output_file = try std.fs.cwd().createFile(out_path.?, .{});
	var out_buf: [64 * 1024]u8 = undefined;
	var out_writer = output_file.?.writer(&out_buf);
	const out_stream = &out_writer.interface;
	if (opts.pbzip2 and opts.threads > 1) {
		try bzip2.decompressFileToWriterWithOptions(allocator, input_path, out_stream, .{
			.threads = opts.threads,
			.parallel = true,
		});
	} else {
		var decompressor = try bzip2.Decompressor.init(allocator);
		defer decompressor.deinit();
		try decompressor.decompress(input_stream, out_stream);
	}
	try out_stream.flush();
	if (!opts.keep) {
		std.fs.cwd().deleteFile(input_path) catch {};
	}
}

fn testFile(allocator: std.mem.Allocator, input_path: []const u8) !void {
	const input = try std.fs.cwd().openFile(input_path, .{});
	defer input.close();
	var input_buf: [64 * 1024]u8 = undefined;
	var input_reader = input.reader(&input_buf);
	const input_stream = &input_reader.interface;

	var decompressor = try bzip2.Decompressor.init(allocator);
	defer decompressor.deinit();
	const sink = std.io.null_writer;
	try decompressor.decompress(input_stream, sink);
}

pub fn main() !u8 {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);
	const program = args[0][0..args[0].len];

	const parsed = parseArgs(allocator, args, program) catch |err| switch (err) {
		error.HelpRequested => return 0,
		else => {
			stderrPrint("bzip2z: invalid arguments\n", .{});
			usage(program);
			return 2;
		},
	};
	defer allocator.free(parsed.files);
	var opts = parsed.opts;

	if (opts.about) {
		versionInfo();
		return 0;
	}
	if (opts.show_version) {
		versionInfo();
		return 0;
	}
	if (opts.show_license) {
		licenseInfo();
		return 0;
	}

	if (opts.threads == 0) {
		opts.threads = std.Thread.getCpuCount() catch 1;
	}

	if (parsed.files.len == 0) {
		if (isStdinTty()) {
			usage(program);
			return 2;
		}
		const stdin = std.fs.File.stdin();
		var stdin_buf: [64 * 1024]u8 = undefined;
		var stdin_reader = stdin.reader(&stdin_buf);
		const stdin_stream = &stdin_reader.interface;
		const stdout_file = std.fs.File.stdout();
		var stdout_buf: [64 * 1024]u8 = undefined;
		var stdout_writer = stdout_file.writer(&stdout_buf);
		const stdout = &stdout_writer.interface;

		if (opts.mode == .compress) {
			try bzip2.compressStreamWithOptions(allocator, stdin_stream, stdout, .{
				.level = opts.level,
				.threads = opts.threads,
				.multi_stream = opts.pbzip2,
			});
			try stdout.flush();
			return 0;
		}

		var decompressor = try bzip2.Decompressor.init(allocator);
		defer decompressor.deinit();
		try decompressor.decompress(stdin_stream, stdout);
		try stdout.flush();
		return 0;
	}

	var exit_code: u8 = 0;
	for (parsed.files) |path| {
		const result = switch (opts.mode) {
			.compress => compressFile(allocator, path, opts),
			.decompress => decompressFile(allocator, path, opts),
			.@"test" => testFile(allocator, path),
		};
		if (result) |_| {
			if (opts.verbose > 0) {
				stdoutPrint("{s}: ok\n", .{path});
			}
		} else |err| {
			exit_code = 1;
			if (!opts.quiet) {
				stderrPrint("{s}: {s}\n", .{ path, @errorName(err) });
			}
		}
	}

	return exit_code;
}

//! Shared helpers for test and benchmark builds.
//!
//! These were previously duplicated in `src/bzip2_test.zig` and
//! `bench/bench_bzip2.zig`. They are only ever pulled into test/bench artifacts
//! (never the production library), so they live in their own module rather than
//! in `lib.zig`.

const std = @import("std");

var tmp_counter = std.atomic.Value(usize).init(0);

/// I/O for the file helpers below. In test builds this is std.testing.io: the
/// global single-threaded Io has a failing allocator, so anything that
/// allocates through it (such as spawning a child process) fails.
pub fn io() std.Io {
	if (@import("builtin").is_test) return std.testing.io;
	return std.Io.Threaded.global_single_threaded.io();
}

/// Write all bytes to a file (post-0.16 replacement for `file.writeAll`).
pub fn fileWriteAll(file: std.Io.File, data: []const u8) !void {
	var buf: [4096]u8 = undefined;
	var w = file.writer(io(), &buf);
	try w.interface.writeAll(data);
	try w.interface.flush();
}

/// Lightweight env lookup via libc, returning an allocator-owned copy or null.
pub fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
	const c_val = std.c.getenv(key) orelse return null;
	const slice = std.mem.span(c_val);
	return allocator.dupe(u8, slice) catch null;
}

/// Build a unique temp path under $TMPDIR (or /tmp); caller owns the result.
///
/// The counter keeps paths distinct within one process; the process id keeps
/// them distinct across processes that share $TMPDIR (two concurrent test
/// runs, or two test binaries run in parallel by `zig build test`), which
/// would otherwise race on the same files mid-test.
pub fn tmpPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
	const tmpdir_owned = getEnvOwned(allocator, "TMPDIR");
	defer if (tmpdir_owned) |value| allocator.free(value);
	const tmpdir = if (tmpdir_owned) |value| value else "/tmp";

	const pid = std.c.getpid();
	const id = tmp_counter.fetchAdd(1, .seq_cst);
	return try std.fmt.allocPrint(allocator, "{s}/{s}-{d}-{d}", .{ tmpdir, name, pid, id });
}

test "tmpPath: process id and counter keep paths distinct within and across processes" {
	const allocator = std.testing.allocator;
	const a = try tmpPath(allocator, "helpers_probe");
	defer allocator.free(a);
	const b = try tmpPath(allocator, "helpers_probe");
	defer allocator.free(b);
	try std.testing.expect(!std.mem.eql(u8, a, b));

	const pid_part = try std.fmt.allocPrint(allocator, "/helpers_probe-{d}-", .{std.c.getpid()});
	defer allocator.free(pid_part);
	try std.testing.expect(std.mem.indexOf(u8, a, pid_part) != null);
	try std.testing.expect(std.mem.indexOf(u8, b, pid_part) != null);
}

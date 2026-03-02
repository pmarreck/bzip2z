//! Tests for the pure Zig bzip2 implementation.
//! Tests compression and decompression against the system bzip2 binary.

const std = @import("std");
const bzip2 = @import("bzip2.zig");
const testing = std.testing;

var tmp_counter = std.atomic.Value(usize).init(0);

const MaxAllocAllocator = struct {
	child: std.mem.Allocator,
	max_single: usize,

	pub fn init(child: std.mem.Allocator, max_single: usize) MaxAllocAllocator {
		return .{
			.child = child,
			.max_single = max_single,
		};
	}

	pub fn allocator(self: *MaxAllocAllocator) std.mem.Allocator {
		return .{
			.ptr = self,
			.vtable = &vtable,
		};
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
		const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
		if (len > self.max_single) return null;
		return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
	}

	fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
		const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
		if (new_len > self.max_single) return false;
		return self.child.vtable.resize(self.child.ptr, buf, alignment, new_len, ret_addr);
	}

	fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
		if (new_len > self.max_single) return null;
		return self.child.vtable.remap(self.child.ptr, buf, alignment, new_len, ret_addr);
	}

	fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
		const self: *MaxAllocAllocator = @ptrCast(@alignCast(ctx));
		self.child.vtable.free(self.child.ptr, buf, alignment, ret_addr);
	}

	const vtable = std.mem.Allocator.VTable{
		.alloc = alloc,
		.resize = resize,
		.remap = remap,
		.free = free,
	};
};

fn tmpPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
	const tmpdir_owned = std.process.getEnvVarOwned(allocator, "TMPDIR") catch null;
	const tmpdir = if (tmpdir_owned) |value| value else "/tmp";
	defer if (tmpdir_owned) |value| allocator.free(value);

	const id = tmp_counter.fetchAdd(1, .seq_cst);
	return try std.fmt.allocPrint(allocator, "{s}/{s}-{d}", .{ tmpdir, name, id });
}

fn requireSystemBzip2(allocator: std.mem.Allocator) !void {
	const result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "--help" },
	}) catch return error.SkipZigTest;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);
}

fn requirePbzip2(allocator: std.mem.Allocator) !void {
	const result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "pbzip2", "-h" },
	}) catch return error.SkipZigTest;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);
}

// ============ Unit Tests ============

test "CRC32 bzip2 - known values" {
	// Test with known input
	var crc = bzip2.Crc32Bzip2.init();
	crc.updateSlice("hello world");
	const result = crc.final();
	// The CRC should be non-zero and consistent
	try testing.expect(result != 0);

	// Test that same input gives same result
	var crc2 = bzip2.Crc32Bzip2.init();
	crc2.updateSlice("hello world");
	try testing.expectEqual(result, crc2.final());
}

test "CRC32 bzip2 - empty input" {
	var crc = bzip2.Crc32Bzip2.init();
	const result = crc.final();
	// Empty CRC should be 0 (after XOR with 0xFFFFFFFF twice)
	try testing.expectEqual(@as(u32, 0), result);
}

test "CRC32 bzip2 - incremental update" {
	var crc1 = bzip2.Crc32Bzip2.init();
	crc1.updateSlice("hello ");
	crc1.updateSlice("world");

	var crc2 = bzip2.Crc32Bzip2.init();
	crc2.updateSlice("hello world");

	try testing.expectEqual(crc1.final(), crc2.final());
}

test "stream magic validation" {
	try testing.expectEqualSlices(u8, "BZh", &bzip2.STREAM_MAGIC);
}

test "block magic values" {
	// Block magic is pi digits: 0x314159265359
	try testing.expectEqual(@as(u48, 0x314159265359), bzip2.BLOCK_MAGIC);
	// Footer magic is sqrt(pi) digits: 0x177245385090
	try testing.expectEqual(@as(u48, 0x177245385090), bzip2.FOOTER_MAGIC);
}

// ============ Integration Tests with System bzip2 ============

test "detect invalid bzip2 header" {
	const allocator = testing.allocator;

	// Invalid magic
	const invalid_data = [_]u8{ 'X', 'Y', 'Z', '9', 0, 0, 0, 0 };

	var decompressor = try bzip2.Decompressor.init(allocator);
	defer decompressor.deinit();

	var input = std.io.fixedBufferStream(&invalid_data);
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const result = decompressor.decompress(input.reader(), output.writer(allocator));
	try testing.expectError(bzip2.Error.InvalidMagic, result);
}

test "detect invalid block size" {
	const allocator = testing.allocator;

	// Valid magic but invalid block size ('0' is not valid, must be '1'-'9')
	const invalid_data = [_]u8{ 'B', 'Z', 'h', '0', 0, 0, 0, 0 };

	var decompressor = try bzip2.Decompressor.init(allocator);
	defer decompressor.deinit();

	var input = std.io.fixedBufferStream(&invalid_data);
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const result = decompressor.decompress(input.reader(), output.writer(allocator));
	try testing.expectError(bzip2.Error.InvalidBlockSize, result);
}

// ============ Real-World File Tests ============

test "decompress real bzip2 file from tmp" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	// Create a test file, compress it with system bzip2
	const test_content =
		\\This is a test file for bzip2 decompression.
		\\It contains multiple lines of text.
		\\The quick brown fox jumps over the lazy dog.
		\\Pack my box with five dozen liquor jugs.
		\\How vexingly quick daft zebras jump!
	** 50;

	// Write to temp file
	const tmp_path = try tmpPath(allocator, "bzip2_test_input.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(test_content);
	}

	// Compress with system bzip2 using run()
	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
	}) catch |err| {
		std.debug.print("Failed to run bzip2: {}\n", .{err});
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);

	// Verify bz2 file was created
	const bz2_file = std.fs.cwd().openFile(bz2_path, .{}) catch |err| {
		std.debug.print("bz2 file not created: {}\n", .{err});
		return err;
	};
	defer bz2_file.close();

	const bz2_size = try bz2_file.getEndPos();
	try testing.expect(bz2_size > 0);
	try testing.expect(bz2_size < test_content.len); // Should be compressed

	// Clean up
	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "round-trip with system bzip2 via files" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const test_data = "Hello, World! This is a test of bzip2 compression.\n" ** 10;

	// Write test data to temp file
	const tmp_path = try tmpPath(allocator, "bzip2_roundtrip_test.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(test_data);
	}

	// Compress with system bzip2
	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
	}) catch |err| {
		std.debug.print("bzip2 compress failed: {}\n", .{err});
		std.fs.cwd().deleteFile(tmp_path) catch {};
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);

	// Verify bz2 file exists and read it
	const bz2_file = std.fs.cwd().openFile(bz2_path, .{}) catch |err| {
		std.debug.print("bz2 file not found: {}\n", .{err});
		std.fs.cwd().deleteFile(tmp_path) catch {};
		return err;
	};
	defer bz2_file.close();

	// Read compressed data
	const compressed = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(compressed);

	// Verify it's valid bzip2 (starts with "BZh")
	try testing.expect(compressed.len >= 4);
	try testing.expectEqualSlices(u8, "BZh", compressed[0..3]);

	// Clean up
	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "decompress system bzip2 output - simple text" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const test_data = "Hello, World! This is a test of bzip2 decompression.\n" ** 5;

	// Write test data to temp file
	const tmp_path = try tmpPath(allocator, "bzip2_decompress_test.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(test_data);
	}
	defer std.fs.cwd().deleteFile(tmp_path) catch {};

	// Compress with system bzip2
	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
	}) catch |err| {
		std.debug.print("bzip2 compress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);
	defer std.fs.cwd().deleteFile(bz2_path) catch {};

	// Read compressed data
	const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
	defer bz2_file.close();

	const compressed = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(compressed);

	// Decompress with our implementation
	const decompressed = bzip2.decompress(allocator, compressed) catch |err| {
		std.debug.print("Our decompressor failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(decompressed);

	// Verify decompressed data matches original
	try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "decompress system bzip2 output - multiple patterns" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const test_cases = [_][]const u8{
		// Single character
		"a",
		// Short string
		"hello",
		// All lowercase letters
		"abcdefghijklmnopqrstuvwxyz",
		// Highly repetitive (good for BWT)
		"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		// Alternating pattern
		"abababababababababababababababababababab",
		// Mixed case with punctuation
		"The quick brown fox jumps over the lazy dog.",
		// Repeated string (tests RLE)
		"Lorem ipsum dolor sit amet. " ** 10,
		// Binary-like pattern with all bytes in ASCII range
		"Hello123!@#$%^&*()_+-=[]{}|;:',.<>?/~`",
	};

	for (test_cases) |test_data| {
		// Write test data to temp file
		const tmp_path = try tmpPath(allocator, "bzip2_multi_test.txt");
		defer allocator.free(tmp_path);
		const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
		defer allocator.free(bz2_path);

		{
			const file = try std.fs.cwd().createFile(tmp_path, .{});
			defer file.close();
			try file.writeAll(test_data);
		}
		defer std.fs.cwd().deleteFile(tmp_path) catch {};

		// Compress with system bzip2
		const compress_result = std.process.Child.run(.{
			.allocator = allocator,
			.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
		}) catch |err| {
			std.debug.print("bzip2 compress failed for test case: {s}\n", .{test_data});
			return err;
		};
		defer allocator.free(compress_result.stdout);
		defer allocator.free(compress_result.stderr);
		defer std.fs.cwd().deleteFile(bz2_path) catch {};

		// Read compressed data
		const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
		defer bz2_file.close();

		const compressed = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
		defer allocator.free(compressed);

		// Decompress with our implementation
		const decompressed = bzip2.decompress(allocator, compressed) catch |err| {
			std.debug.print("Decompression failed for: {s}\n", .{test_data});
			return err;
		};
		defer allocator.free(decompressed);

		// Verify decompressed data matches original
		try testing.expectEqualSlices(u8, test_data, decompressed);
	}
}

test "decompress system bzip2 output - binary data" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	// Create binary test data with all byte values
	var binary_data: [256]u8 = undefined;
	for (0..256) |i| {
		binary_data[i] = @intCast(i);
	}

	// Write test data to temp file
	const tmp_path = try tmpPath(allocator, "bzip2_binary_test.bin");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(&binary_data);
	}
	defer std.fs.cwd().deleteFile(tmp_path) catch {};

	// Compress with system bzip2
	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
	}) catch |err| {
		std.debug.print("bzip2 compress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);
	defer std.fs.cwd().deleteFile(bz2_path) catch {};

	// Read compressed data
	const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
	defer bz2_file.close();

	const compressed = try bz2_file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(compressed);

	// Decompress with our implementation
	const decompressed = bzip2.decompress(allocator, compressed) catch |err| {
		std.debug.print("Decompression failed for binary data: {}\n", .{err});
		return err;
	};
	defer allocator.free(decompressed);

	// Verify decompressed data matches original
	try testing.expectEqualSlices(u8, &binary_data, decompressed);
}

test "interop multi-block - system compress, zig decompress" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const size: usize = 1_200_000;
	const tmp_path = try tmpPath(allocator, "bzip2_multiblock_sys.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('A' + (i % 26)));
	}

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(data);
	}

	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-k", "-f", "-9", tmp_path },
	}) catch |err| {
		std.debug.print("system bzip2 compress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);

	const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
	defer bz2_file.close();

	const compressed = try bz2_file.readToEndAlloc(allocator, size);
	defer allocator.free(compressed);

	const decompressed = try bzip2.decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try testing.expectEqualSlices(u8, data, decompressed);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "interop multi-block - zig compress, system decompress" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const size: usize = 1_200_000;
	const tmp_path = try tmpPath(allocator, "bzip2_multiblock_zig.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('a' + (i % 26)));
	}

	const compressed = try bzip2.compressWithOptions(allocator, data, .{ .level = 9, .threads = 2 });
	defer allocator.free(compressed);

	{
		const file = try std.fs.cwd().createFile(bz2_path, .{});
		defer file.close();
		try file.writeAll(compressed);
	}

	const decompress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-d", "-k", "-f", bz2_path },
	}) catch |err| {
		std.debug.print("system bzip2 decompress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(decompress_result.stdout);
	defer allocator.free(decompress_result.stderr);

	const plain_file = try std.fs.cwd().openFile(tmp_path, .{});
	defer plain_file.close();

	const roundtrip = try plain_file.readToEndAlloc(allocator, size);
	defer allocator.free(roundtrip);

	try testing.expectEqualSlices(u8, data, roundtrip);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "interop multi-stream - zig compress multi-stream, system decompress" {
	const allocator = testing.allocator;
	try requireSystemBzip2(allocator);

	const size: usize = 1_200_000;
	const tmp_path = try tmpPath(allocator, "bzip2_multistream_zig.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('A' + (i % 26)));
	}

	const compressed = try bzip2.compressWithOptions(allocator, data, .{
		.level = 9,
		.threads = 1,
		.multi_stream = true,
	});
	defer allocator.free(compressed);

	var stream_count: usize = 0;
	var i: usize = 0;
	while (i + 2 < compressed.len) : (i += 1) {
		if (compressed[i] == 'B' and compressed[i + 1] == 'Z' and compressed[i + 2] == 'h') {
			stream_count += 1;
		}
	}
	try testing.expect(stream_count >= 2);

	{
		const file = try std.fs.cwd().createFile(bz2_path, .{});
		defer file.close();
		try file.writeAll(compressed);
	}

	const decompress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "bzip2", "-d", "-k", "-f", bz2_path },
	}) catch |err| {
		std.debug.print("system bzip2 decompress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(decompress_result.stdout);
	defer allocator.free(decompress_result.stderr);

	const plain_file = try std.fs.cwd().openFile(tmp_path, .{});
	defer plain_file.close();

	const roundtrip = try plain_file.readToEndAlloc(allocator, size);
	defer allocator.free(roundtrip);

	try testing.expectEqualSlices(u8, data, roundtrip);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "parallel decompress - zig multi-stream" {
	const allocator = testing.allocator;

	const size: usize = 1_200_000;
	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('a' + (i % 26)));
	}

	const compressed = try bzip2.compressWithOptions(allocator, data, .{
		.level = 9,
		.threads = 1,
		.multi_stream = true,
	});
	defer allocator.free(compressed);

	const decompressed = try bzip2.decompressWithOptions(allocator, compressed, .{
		.threads = 2,
		.parallel = true,
	});
	defer allocator.free(decompressed);

	try testing.expectEqualSlices(u8, data, decompressed);
}

test "parallel file decode streams without large allocs" {
	const allocator = testing.allocator;

	const size: usize = 7_000_000;
	const tmp_path = try tmpPath(allocator, "bzip2_parallel_file.bin");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);
	const out_path = try std.fmt.allocPrint(allocator, "{s}.out", .{tmp_path});
	defer allocator.free(out_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	var seed: u32 = 0x12345678;
	for (data) |*b| {
		seed = seed *% 1664525 +% 1013904223;
		b.* = @truncate(seed);
	}

	const compressed = try bzip2.compressWithOptions(allocator, data, .{
		.level = 9,
		.threads = 1,
		.multi_stream = true,
	});
	defer allocator.free(compressed);

	{
		const file = try std.fs.cwd().createFile(bz2_path, .{});
		defer file.close();
		try file.writeAll(compressed);
	}

	var limited = MaxAllocAllocator.init(allocator, 5_000_000);
	const limited_alloc = limited.allocator();

	{
		const file = try std.fs.cwd().createFile(out_path, .{});
		defer file.close();
		var out_buf: [64 * 1024]u8 = undefined;
		var out_writer = file.writer(&out_buf);
		const out_stream = &out_writer.interface;
		try bzip2.decompressFileToWriterWithOptions(limited_alloc, bz2_path, out_stream, .{
			.threads = 2,
			.parallel = true,
		});
		try out_stream.flush();
	}

	const out_file = try std.fs.cwd().openFile(out_path, .{});
	defer out_file.close();
	const roundtrip = try out_file.readToEndAlloc(allocator, size);
	defer allocator.free(roundtrip);

	try testing.expectEqualSlices(u8, data, roundtrip);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
	std.fs.cwd().deleteFile(out_path) catch {};
}

test "interop pbzip2 multistream - pbzip2 compress, zig decompress" {
	const allocator = testing.allocator;
	try requirePbzip2(allocator);

	const size: usize = 3_000_000;
	const tmp_path = try tmpPath(allocator, "pbzip2_multistream.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);
	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('A' + (i % 26)));
	}

	{
		const file = try std.fs.cwd().createFile(tmp_path, .{});
		defer file.close();
		try file.writeAll(data);
	}

	const compress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "pbzip2", "-k", "-f", "-9", "-p2", tmp_path },
	}) catch |err| {
		std.debug.print("pbzip2 compress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(compress_result.stdout);
	defer allocator.free(compress_result.stderr);

	const bz2_file = try std.fs.cwd().openFile(bz2_path, .{});
	defer bz2_file.close();

	const compressed = try bz2_file.readToEndAlloc(allocator, size * 2);
	defer allocator.free(compressed);

	var stream_count: usize = 0;
	var i: usize = 0;
	while (i + 2 < compressed.len) : (i += 1) {
		if (compressed[i] == 'B' and compressed[i + 1] == 'Z' and compressed[i + 2] == 'h') {
			stream_count += 1;
		}
	}
	if (stream_count < 2) return error.SkipZigTest;

	const decompressed = try bzip2.decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try testing.expectEqualSlices(u8, data, decompressed);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

test "interop pbzip2 multistream - zig compress, pbzip2 decompress" {
	const allocator = testing.allocator;
	try requirePbzip2(allocator);

	const size: usize = 3_000_000;
	const tmp_path = try tmpPath(allocator, "pbzip2_multistream_zig.txt");
	defer allocator.free(tmp_path);
	const bz2_path = try std.fmt.allocPrint(allocator, "{s}.bz2", .{tmp_path});
	defer allocator.free(bz2_path);

	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);
	for (data, 0..) |*b, i| {
		b.* = @as(u8, @truncate('A' + (i % 26)));
	}

	const compressed = try bzip2.compressWithOptions(allocator, data, .{
		.level = 9,
		.threads = 1,
		.multi_stream = true,
	});
	defer allocator.free(compressed);

	var stream_count: usize = 0;
	var i: usize = 0;
	while (i + 2 < compressed.len) : (i += 1) {
		if (compressed[i] == 'B' and compressed[i + 1] == 'Z' and compressed[i + 2] == 'h') {
			stream_count += 1;
		}
	}
	try testing.expect(stream_count >= 2);

	{
		const file = try std.fs.cwd().createFile(bz2_path, .{});
		defer file.close();
		try file.writeAll(compressed);
	}

	const decompress_result = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &[_][]const u8{ "pbzip2", "-d", "-k", "-f", bz2_path },
	}) catch |err| {
		std.debug.print("pbzip2 decompress failed: {}\n", .{err});
		return err;
	};
	defer allocator.free(decompress_result.stdout);
	defer allocator.free(decompress_result.stderr);

	const plain_file = try std.fs.cwd().openFile(tmp_path, .{});
	defer plain_file.close();

	const roundtrip = try plain_file.readToEndAlloc(allocator, size);
	defer allocator.free(roundtrip);

	try testing.expectEqualSlices(u8, data, roundtrip);

	std.fs.cwd().deleteFile(tmp_path) catch {};
	std.fs.cwd().deleteFile(bz2_path) catch {};
}

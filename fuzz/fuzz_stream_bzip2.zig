const std = @import("std");
const bzip2 = @import("bzip2z").bzip2;

fn fuzzIo() std.Io {
	return std.Io.Threaded.global_single_threaded.io();
}

pub fn main() !void {
	// Use GPA for memory safety checks
	var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	// Read input from stdin (AFL/honggfuzz style)
	const stdin = std.Io.File.stdin();
	// Limit to reasonable size for round-trip testing (1MB)
	var stdin_buf: [64 * 1024]u8 = undefined;
	var stdin_reader = stdin.readerStreaming(fuzzIo(), &stdin_buf);
	const input = try stdin_reader.interface.readAlloc(allocator, 1 * 1024 * 1024);
	defer allocator.free(input);

	// 1. Compression
	const compressed = bzip2.compress(allocator, input) catch |err| {
		// OOM is acceptable
		if (err == error.OutOfMemory) return;
		std.debug.print("Compression failed: {}\n", .{err});
		return;
	};
	defer allocator.free(compressed);

	// 2. Decompression
	var decompressor = try bzip2.Decompressor.init(allocator);
	defer decompressor.deinit();

	// Pre-allocating to give the writer reasonable initial capacity
	var decompressed: std.ArrayListUnmanaged(u8) = .{};
	defer decompressed.deinit(allocator);
	try decompressed.ensureTotalCapacity(allocator, input.len);

	var fbs: std.Io.Reader = .fixed(compressed);
	var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &decompressed);
	decompressor.decompress(&fbs, &aw.writer) catch |err| {
		decompressed = aw.toArrayList();
		std.debug.print("Round-trip Decompression failed: {}\n", .{err});
		@panic("Decompression failed on valid inputs!");
	};
	decompressed = aw.toArrayList();

	// 3. Verification
	if (!std.mem.eql(u8, input, decompressed.items)) {
		std.debug.print("Mismatch! Input len={}, Output len={}\n", .{ input.len, decompressed.items.len });
		const min_len = @min(input.len, decompressed.items.len);
		for (0..min_len) |i| {
			if (input[i] != decompressed.items[i]) {
				std.debug.print("First mismatch at index {}: input={X:0>2}, output={X:0>2}\n", .{ i, input[i], decompressed.items[i] });
				break;
			}
		}
		@panic("Data mismatch after round-trip!");
	}
}

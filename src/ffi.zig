const std = @import("std");
const core = @import("core.zig");
const lib = @import("lib.zig");

pub const Bzip2zStatus = enum(c_int) {
	ok = 0,
	invalid_argument = 1,
	invalid_data = 2,
	crc_mismatch = 3,
	out_of_memory = 4,
	internal_error = 5,
};

pub const Bzip2zBuffer = extern struct {
	ptr: ?[*]u8,
	len: usize,
};

pub const Bzip2zProgressFn = ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void;

/// C layout of the decoder's failure report (see bzip2z_diagnostics_t in
/// c/include/bzip2z.h): where an error was detected, which stream, block and
/// decode phase, and the bit window that holds the damage.
pub const Bzip2zDiagnostics = extern struct {
	bit_offset: u64,
	stream_start_bit: u64,
	block_start_bit: u64,
	window_start_bit: u64,
	phase: u32,
	stream_index: u32,
	block_index: u32,
	stored_crc: u32,
	computed_crc: u32,
	streams: u32,
	blocks: u32,
	valid: u8,
	has_block_start: u8,
	has_crc: u8,
	reserved: u8,

	fn fromCore(d: core.Diagnostics) Bzip2zDiagnostics {
		return .{
			.bit_offset = d.bit_offset,
			.stream_start_bit = d.stream_start_bit,
			.block_start_bit = d.block_start_bit orelse 0,
			.window_start_bit = d.window_start_bit,
			.phase = @intFromEnum(d.phase),
			.stream_index = d.stream_index,
			.block_index = d.block_index,
			.stored_crc = d.stored_crc orelse 0,
			.computed_crc = d.computed_crc orelse 0,
			.streams = d.streams,
			.blocks = d.blocks,
			.valid = 1,
			.has_block_start = @intFromBool(d.block_start_bit != null),
			.has_crc = @intFromBool(d.stored_crc != null and d.computed_crc != null),
			.reserved = 0,
		};
	}
};

pub const Bzip2zCompressOptions = extern struct {
	level: u8,
	threads: usize,
	multi_stream: u8,
	on_progress: Bzip2zProgressFn,
	progress_userdata: ?*anyopaque,
	progress_bytes_total: u64,
};

pub const Bzip2zDecompressOptions = extern struct {
	threads: usize,
	parallel: u8,
	check_crc: u8,
	on_progress: Bzip2zProgressFn,
	progress_userdata: ?*anyopaque,
	progress_bytes_total: u64,
	diagnostics: ?*Bzip2zDiagnostics,
};

fn mapError(err: anyerror) Bzip2zStatus {
	return switch (err) {
		error.OutOfMemory => .out_of_memory,
		error.BlockCrcMismatch, error.StreamCrcMismatch => .crc_mismatch,
		error.InvalidMagic,
		error.InvalidBlockSize,
		error.InvalidBlockHeader,
		error.InvalidFooter,
		error.CorruptData,
		error.HuffmanOverflow,
		error.InvalidSelector,
		error.UnexpectedEof,
		error.OutputOverflow,
		error.InvalidBwtIndex,
		=> .invalid_data,
		else => .internal_error,
	};
}

fn compressOptionsFromC(options: ?*const Bzip2zCompressOptions) core.CompressOptions {
	if (options) |opt| {
		return .{
			.level = if (opt.level == 0) 9 else opt.level,
			.threads = opt.threads,
			.multi_stream = opt.multi_stream != 0,
			.on_progress = opt.on_progress,
			.progress_userdata = opt.progress_userdata,
			.progress_bytes_total = opt.progress_bytes_total,
		};
	}
	return .{};
}

fn decompressOptionsFromC(options: ?*const Bzip2zDecompressOptions) core.DecompressOptions {
	if (options) |opt| {
		return .{
			.threads = opt.threads,
			.parallel = opt.parallel != 0,
			.on_progress = opt.on_progress,
			.progress_userdata = opt.progress_userdata,
			.progress_bytes_total = opt.progress_bytes_total,
		};
	}
	return .{};
}

fn toInputSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
	if (len == 0) return &.{};
	if (ptr == null) return null;
	return ptr.?[0..len];
}

/// C ABI compressor entrypoint used by external adapters.
/// It accepts in-memory buffers only and returns allocator-owned output.
export fn bzip2z_compress(
	input_ptr: ?[*]const u8,
	input_len: usize,
	options: ?*const Bzip2zCompressOptions,
	out_buffer: ?*Bzip2zBuffer,
) c_int {
	if (out_buffer == null) {
		return @intFromEnum(Bzip2zStatus.invalid_argument);
	}

	out_buffer.?.* = .{ .ptr = null, .len = 0 };
	const input = toInputSlice(input_ptr, input_len) orelse {
		return @intFromEnum(Bzip2zStatus.invalid_argument);
	};

	const compressed = core.compress(std.heap.c_allocator, input, compressOptionsFromC(options)) catch |err| {
		return @intFromEnum(mapError(err));
	};
	out_buffer.?.* = .{ .ptr = compressed.ptr, .len = compressed.len };
	return @intFromEnum(Bzip2zStatus.ok);
}

/// C ABI decompressor entrypoint used by external adapters.
/// It supports CRC-enabled and CRC-disabled decode paths. With
/// options.diagnostics set, a CRC-checked decode that fails as invalid data or
/// a CRC mismatch also fills a failure report (see bzip2z_diagnostics_t).
export fn bzip2z_decompress(
	input_ptr: ?[*]const u8,
	input_len: usize,
	options: ?*const Bzip2zDecompressOptions,
	out_buffer: ?*Bzip2zBuffer,
) c_int {
	const diagnostics = if (options) |o| o.diagnostics else null;
	if (diagnostics) |d| d.* = std.mem.zeroes(Bzip2zDiagnostics);
	if (out_buffer == null) {
		return @intFromEnum(Bzip2zStatus.invalid_argument);
	}

	out_buffer.?.* = .{ .ptr = null, .len = 0 };
	const input = toInputSlice(input_ptr, input_len) orelse {
		return @intFromEnum(Bzip2zStatus.invalid_argument);
	};

	const dec_options = decompressOptionsFromC(options);
	const decoded = blk: {
		if (options != null and options.?.check_crc == 0) {
			const value = core.decompressNoCrc(std.heap.c_allocator, input) catch |err| {
				return @intFromEnum(mapError(err));
			};
			break :blk value;
		}
		const value = core.decompress(std.heap.c_allocator, input, dec_options) catch |err| {
			const status = mapError(err);
			if (diagnostics) |d| {
				// The fast path may be parallel and keeps no positions; locate the
				// failure with a sequential re-decode, paid only on failure.
				if (status == .invalid_data or status == .crc_mismatch) {
					if (core.diagnose(std.heap.c_allocator, input)) |found| d.* = .fromCore(found);
				}
			}
			return @intFromEnum(status);
		};
		break :blk value;
	};

	out_buffer.?.* = .{ .ptr = decoded.ptr, .len = decoded.len };
	return @intFromEnum(Bzip2zStatus.ok);
}

/// Phase name for bzip2z_diagnostics_t.phase as pointer plus byte length
/// (static, also NUL-terminated); null and length 0 for a value that is not a
/// phase. Names come from the Zig enum, so they cannot drift from it.
export fn bzip2z_phase_name(phase: u32, out_len: ?*usize) ?[*]const u8 {
	inline for (std.meta.fields(core.Diagnostics.Phase)) |field| {
		if (phase == field.value) {
			if (out_len) |len| len.* = field.name.len;
			return field.name.ptr;
		}
	}
	if (out_len) |len| len.* = 0;
	return null;
}

/// Frees a buffer returned by bzip2z_compress / bzip2z_decompress.
export fn bzip2z_free(ptr: ?[*]u8, len: usize) void {
	if (ptr == null) return;
	std.heap.c_allocator.free(ptr.?[0..len]);
}

/// Stable C ABI version string pointer for adapter diagnostics.
export fn bzip2z_version_string() [*]const u8 {
	return lib.getVersion().ptr;
}

/// Returns byte length of the version string returned by bzip2z_version_string().
export fn bzip2z_version_string_len() usize {
	return lib.getVersion().len;
}

// ============ tests (through the exported C ABI) ============

const bzip2 = @import("bzip2.zig");

const SECOND_STREAM_TEXT = "a second, much smaller stream";

/// Two concatenated level-1 streams (the first spans two blocks), so both the
/// sequential and the parallel decode paths are reachable.
fn twoStreamInput(allocator: std.mem.Allocator) ![]u8 {
	const big = try allocator.alloc(u8, 101_000);
	defer allocator.free(big);
	for (big, 0..) |*b, i| b.* = @truncate((i * 7) % 251 + (i / 5000));
	const first = try bzip2.compressWithOptions(allocator, big, .{ .level = 1 });
	defer allocator.free(first);
	const second = try bzip2.compress(allocator, SECOND_STREAM_TEXT);
	defer allocator.free(second);
	return std.mem.concat(allocator, u8, &.{ first, second });
}

fn decodeWithDiagnostics(input: []const u8, parallel: bool, check_crc: bool, diag: *Bzip2zDiagnostics) c_int {
	var out: Bzip2zBuffer = .{ .ptr = null, .len = 0 };
	const options: Bzip2zDecompressOptions = .{
		.threads = if (parallel) 2 else 1,
		.parallel = @intFromBool(parallel),
		.check_crc = @intFromBool(check_crc),
		.on_progress = null,
		.progress_userdata = null,
		.progress_bytes_total = 0,
		.diagnostics = diag,
	};
	const status = bzip2z_decompress(input.ptr, input.len, &options, &out);
	bzip2z_free(out.ptr, out.len);
	return status;
}

test "ffi diagnostics: a flipped bit lies in [window_start_bit, bit_offset) on both decode paths" {
	// Oracle independent of the decoder: we know which bit we flipped.
	const allocator = std.testing.allocator;
	const input = try twoStreamInput(allocator);
	defer allocator.free(input);
	// Probes the format must catch: a bit of the first block's stored CRC
	// (after the 32-bit stream header and 48-bit block magic), and a bit of
	// the second stream's block magic, which the parallel path decodes as its
	// own stream. The encoder is deterministic, so the second stream's length
	// locates it.
	const second = try bzip2.compress(allocator, SECOND_STREAM_TEXT);
	defer allocator.free(second);
	const second_start_bit = @as(u64, input.len - second.len) * 8;
	const probe_bits = [_]u64{ 32 + 48 + 5, second_start_bit + 32 + 10 };
	for (probe_bits) |bit| {
		input[bit / 8] ^= @as(u8, 0x80) >> @intCast(bit % 8);
		defer input[bit / 8] ^= @as(u8, 0x80) >> @intCast(bit % 8);
		for ([_]bool{ false, true }) |parallel| {
			var diag: Bzip2zDiagnostics = undefined;
			const status = decodeWithDiagnostics(input, parallel, true, &diag);
			const rejected = status == @intFromEnum(Bzip2zStatus.invalid_data) or status == @intFromEnum(Bzip2zStatus.crc_mismatch);
			const brackets = diag.window_start_bit <= bit and bit < diag.bit_offset;
			if (!rejected or diag.valid != 1 or !brackets or bzip2z_phase_name(diag.phase, null) == null) {
				std.debug.print("bit {d} of {d} parallel {}: status {d} valid {d} phase {d} window [{d}, {d})\n", .{ bit, input.len * 8, parallel, status, diag.valid, diag.phase, diag.window_start_bit, diag.bit_offset });
				return error.TestExpectedLocatedFailure;
			}
		}
	}
}

test "ffi diagnostics: CRC mismatch reports stored and computed values" {
	const allocator = std.testing.allocator;
	const input = try bzip2.compress(allocator, "checksummed payload");
	defer allocator.free(input);
	var diag: Bzip2zDiagnostics = undefined;
	// The first block's stored CRC follows the 32-bit stream header and the
	// 48-bit block magic; flip its bit 5 (counted from the most significant).
	input[(32 + 48 + 5) / 8] ^= @as(u8, 0x80) >> @intCast((32 + 48 + 5) % 8);
	const status = decodeWithDiagnostics(input, false, true, &diag);
	try std.testing.expectEqual(@intFromEnum(Bzip2zStatus.crc_mismatch), status);
	try std.testing.expectEqual(@as(u8, 1), diag.valid);
	try std.testing.expectEqual(@as(u8, 1), diag.has_crc);
	try std.testing.expect(diag.stored_crc != diag.computed_crc);
	try std.testing.expectEqual(diag.stored_crc ^ diag.computed_crc, @as(u32, 1) << (31 - 5));
}

test "ffi diagnostics: not valid on success or without CRC checking" {
	const allocator = std.testing.allocator;
	const input = try twoStreamInput(allocator);
	defer allocator.free(input);
	var diag: Bzip2zDiagnostics = undefined;
	try std.testing.expectEqual(@intFromEnum(Bzip2zStatus.ok), decodeWithDiagnostics(input, false, true, &diag));
	try std.testing.expectEqual(@as(u8, 0), diag.valid);
	input[40] ^= 0x10;
	diag = undefined;
	const status = decodeWithDiagnostics(input, false, false, &diag);
	try std.testing.expect(status != @intFromEnum(Bzip2zStatus.ok));
	try std.testing.expectEqual(@as(u8, 0), diag.valid);
}

test "ffi diagnostics: phase names cover every phase, length-delimited" {
	inline for (std.meta.fields(bzip2.Diagnostics.Phase)) |field| {
		var len: usize = 0;
		const ptr = bzip2z_phase_name(field.value, &len) orelse return error.TestExpectedName;
		try std.testing.expectEqualStrings(field.name, ptr[0..len]);
	}
	try std.testing.expect(bzip2z_phase_name(std.meta.fields(bzip2.Diagnostics.Phase).len, null) == null);
	try std.testing.expect(bzip2z_phase_name(std.math.maxInt(u32), null) == null);
}

test "ffi diagnostics: public header matches the exported layout and phase numbering" {
	const h = @import("bzip2z_h");
	try std.testing.expectEqual(@sizeOf(h.bzip2z_diagnostics_t), @sizeOf(Bzip2zDiagnostics));
	inline for (std.meta.fields(Bzip2zDiagnostics)) |field| {
		try std.testing.expectEqual(@offsetOf(h.bzip2z_diagnostics_t, field.name), @offsetOf(Bzip2zDiagnostics, field.name));
	}
	try std.testing.expectEqual(@sizeOf(h.bzip2z_decompress_options_t), @sizeOf(Bzip2zDecompressOptions));
	inline for (std.meta.fields(Bzip2zDecompressOptions)) |field| {
		try std.testing.expectEqual(@offsetOf(h.bzip2z_decompress_options_t, field.name), @offsetOf(Bzip2zDecompressOptions, field.name));
	}
	const Phase = bzip2.Diagnostics.Phase;
	const pairs = .{
		.{ h.BZIP2Z_PHASE_STREAM_HEADER, Phase.stream_header },
		.{ h.BZIP2Z_PHASE_BLOCK_HEADER, Phase.block_header },
		.{ h.BZIP2Z_PHASE_SYMBOL_MAP, Phase.symbol_map },
		.{ h.BZIP2Z_PHASE_SELECTORS, Phase.selectors },
		.{ h.BZIP2Z_PHASE_HUFFMAN_TABLES, Phase.huffman_tables },
		.{ h.BZIP2Z_PHASE_SYMBOL_DATA, Phase.symbol_data },
		.{ h.BZIP2Z_PHASE_BLOCK_RECONSTRUCT, Phase.block_reconstruct },
		.{ h.BZIP2Z_PHASE_BLOCK_CRC, Phase.block_crc },
		.{ h.BZIP2Z_PHASE_STREAM_FOOTER, Phase.stream_footer },
	};
	inline for (pairs) |pair| try std.testing.expectEqual(@as(u32, @intCast(pair[0])), @intFromEnum(pair[1]));
	// Every Zig phase has a header constant above.
	try std.testing.expectEqual(std.meta.fields(Phase).len, pairs.len);
}

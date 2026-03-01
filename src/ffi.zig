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
/// It supports CRC-enabled and CRC-disabled decode paths for diagnostics.
export fn bzip2z_decompress(
	input_ptr: ?[*]const u8,
	input_len: usize,
	options: ?*const Bzip2zDecompressOptions,
	out_buffer: ?*Bzip2zBuffer,
) c_int {
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
			return @intFromEnum(mapError(err));
		};
		break :blk value;
	};

	out_buffer.?.* = .{ .ptr = decoded.ptr, .len = decoded.len };
	return @intFromEnum(Bzip2zStatus.ok);
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

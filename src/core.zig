const std = @import("std");
const bzip2 = @import("bzip2.zig");

pub const Error = bzip2.Error;
pub const CompressOptions = bzip2.CompressOptions;
pub const DecompressOptions = bzip2.DecompressOptions;

/// Compresses bytes entirely in memory using the bzip2 pipeline (BWT/MTF/Huffman).
/// This core API intentionally excludes file and stream I/O so adapters can compose it safely.
pub fn compress(allocator: std.mem.Allocator, input: []const u8, options: CompressOptions) ![]u8 {
	return bzip2.compressWithOptions(allocator, input, options);
}

/// Decompresses bytes entirely in memory with optional parallel concatenated-stream handling.
/// The caller owns the returned buffer and must free it with the same allocator.
pub fn decompress(allocator: std.mem.Allocator, input: []const u8, options: DecompressOptions) ![]u8 {
	return bzip2.decompressWithOptions(allocator, input, options);
}

/// Decompresses without CRC verification for diagnostics and corruption triage workflows.
/// This is intentionally separate from normal decode to keep integrity checks explicit.
pub fn decompressNoCrc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
	return bzip2.decompressNoCrc(allocator, input);
}

pub const Diagnostics = bzip2.Diagnostics;

/// Locates the first failure in a stream for error reporting: decodes
/// sequentially with every CRC checked, discarding output, and returns the
/// streaming decoder's Diagnostics (failure phase, bit offset, damage window).
/// Returns null when the input decodes cleanly or memory runs out.
pub fn diagnose(allocator: std.mem.Allocator, input: []const u8) ?Diagnostics {
	var reader: std.Io.Reader = .fixed(input);
	var discard: std.Io.Writer.Discarding = .init(&.{});
	var diag: Diagnostics = .{};
	bzip2.decompressStream(allocator, &reader, &discard.writer, .{ .diagnostics = &diag }) catch |err| switch (err) {
		error.OutOfMemory => return null,
		else => return diag,
	};
	return null;
}

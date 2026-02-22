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

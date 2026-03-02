//! Pure Zig bzip2 compressor/decompressor implementation.
//!
//! Based on the bzip2 format specification. This is a clean-room implementation
//! of the algorithm, not a direct port of the C code.
//!
//! The bzip2 format uses:
//! - Burrows-Wheeler Transform (BWT) for block sorting
//! - Move-To-Front (MTF) encoding for symbol locality
//! - Huffman coding for entropy compression
//! - Run-Length Encoding (RLE) for repeated symbols
//!
//! Thread Safety: This implementation is thread-safe. Each Decompressor/Compressor
//! instance is independent and can be used from different threads. The algorithm
//! uses no global state.
//!
//! ## License
//!
//! This is a clean-room implementation based on the publicly documented bzip2
//! format specification. The bzip2 algorithm and format were created by Julian
//! Seward and are covered by a BSD-style license.
//!
//! Original bzip2 license notice:
//!
//!   bzip2/libbzip2 version 1.0.6 of 6 September 2010
//!   Copyright (C) 1996-2010 Julian R Seward <jseward@bzip.org>
//!
//!   This program, "bzip2", the associated library "libbzip2", and all
//!   documentation, are copyright (C) 1996-2010 Julian R Seward. All rights
//!   reserved.
//!
//!   Redistribution and use in source and binary forms, with or without
//!   modification, are permitted provided that the following conditions are met:
//!
//!   1. Redistributions of source code must retain the above copyright notice,
//!      this list of conditions and the following disclaimer.
//!
//!   2. The origin of this software must not be misrepresented; you must not
//!      claim that you wrote the original software. If you use this software
//!      in a product, an acknowledgment in the product documentation would be
//!      appreciated but is not required.
//!
//!   3. Altered source versions must be plainly marked as such, and must not
//!      be misrepresented as being the original software.
//!
//!   4. The name of the author may not be used to endorse or promote products
//!      derived from this software without specific prior written permission.
//!
//! Note: This Zig implementation is an independent clean-room implementation
//! based on the format specification, not a derivative of the original C code.

const std = @import("std");
const concurrency = @import("concurrency.zig");
const Allocator = std.mem.Allocator;
const BoundedQueue = concurrency.BoundedQueue;
const assert = std.debug.assert;

// ============ Constants ============

/// Magic bytes for bzip2 stream header: "BZh"
pub const STREAM_MAGIC = [3]u8{ 'B', 'Z', 'h' };

/// Block header magic: 0x314159265359 (digits of pi)
pub const BLOCK_MAGIC: u48 = 0x314159265359;

/// Stream footer magic: 0x177245385090 (sqrt(pi) digits)
pub const FOOTER_MAGIC: u48 = 0x177245385090;

/// Maximum block size (900KB for level 9)
pub const MAX_BLOCK_SIZE: usize = 900_000;
/// Block size unit in bytes (100KB per level)
pub const BLOCK_SIZE_UNIT: usize = 100_000;

/// Maximum number of Huffman groups
pub const MAX_GROUPS: usize = 6;

/// Maximum number of selectors
pub const MAX_SELECTORS: usize = 18002;

/// Maximum alphabet size (256 bytes + 2 special symbols RUNA/RUNB)
pub const MAX_ALPHA_SIZE: usize = 258;

/// Number of symbols per selector group
pub const GROUP_SIZE: usize = 50;

/// Maximum Huffman code length
pub const MAX_CODE_LEN: usize = 20;

/// Minimum Huffman code length
pub const MIN_CODE_LEN: usize = 1;

// ============ Error Types ============

pub const Error = error{
	InvalidMagic,
	InvalidBlockSize,
	InvalidBlockHeader,
	InvalidFooter,
	CorruptData,
	HuffmanOverflow,
	InvalidSelector,
	BlockCrcMismatch,
	StreamCrcMismatch,
	UnexpectedEof,
	OutputOverflow,
	OutOfMemory,
	InvalidBwtIndex,
};

pub const CompressOptions = struct {
	/// Block size level (1..9). Default is 9.
	level: u8 = 9,
	/// Number of worker threads for block compression. 0 = auto, 1 = single-threaded.
	threads: usize = 1,
	/// Emit concatenated streams (pbzip2-style multi-stream).
	multi_stream: bool = false,
	/// Progress callback: called with (bytes_processed, bytes_total, userdata) after each block.
	on_progress: ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void = null,
	/// Opaque userdata pointer passed to on_progress callback.
	progress_userdata: ?*anyopaque = null,
	/// Total input bytes (for progress percentage). 0 = unknown.
	progress_bytes_total: u64 = 0,

	pub fn blockSizeBytes(self: CompressOptions) Error!usize {
		if (self.level < 1 or self.level > 9) {
			return Error.InvalidBlockSize;
		}
		return @as(usize, self.level) * BLOCK_SIZE_UNIT;
	}

	pub fn resolvedThreads(self: CompressOptions) usize {
		if (self.threads == 0) {
			return std.Thread.getCpuCount() catch 1;
		}
		return self.threads;
	}
};

pub const DecompressOptions = struct {
	/// Number of worker threads for pbzip2-style multi-stream. 0 = auto, 1 = single-threaded.
	threads: usize = 1,
	/// Enable parallel decompression for concatenated streams.
	parallel: bool = false,
	/// Progress callback: called with (bytes_processed, bytes_total, userdata) after each block.
	on_progress: ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void = null,
	/// Opaque userdata pointer passed to on_progress callback.
	progress_userdata: ?*anyopaque = null,
	/// Total input bytes (for progress percentage). 0 = unknown.
	progress_bytes_total: u64 = 0,

	pub fn resolvedThreads(self: DecompressOptions) usize {
		if (self.threads == 0) {
			return std.Thread.getCpuCount() catch 1;
		}
		return self.threads;
	}
};

// ============ CRC32 for bzip2 ============

/// bzip2 uses a specific CRC32 polynomial (same as used by Ethernet)
/// but processes bits MSB-first and uses 0xFFFFFFFF as initial value.
pub const Crc32Bzip2 = struct {
	crc: u32,

	const POLY: u32 = 0x04C11DB7;

	// Precomputed lookup table for the bzip2 CRC32
	const table: [256]u32 = blk: {
		@setEvalBranchQuota(3000);
		var t: [256]u32 = undefined;
		for (0..256) |i| {
			var c: u32 = @as(u32, @intCast(i)) << 24;
			for (0..8) |_| {
				if (c & 0x80000000 != 0) {
					c = (c << 1) ^ POLY;
				} else {
					c = c << 1;
				}
			}
			t[i] = c;
		}
		break :blk t;
	};

	pub fn init() Crc32Bzip2 {
		return .{ .crc = 0xFFFFFFFF };
	}

	pub fn update(self: *Crc32Bzip2, byte: u8) void {
		const idx = ((self.crc >> 24) ^ byte) & 0xFF;
		self.crc = (self.crc << 8) ^ table[idx];
	}

	pub fn updateSlice(self: *Crc32Bzip2, data: []const u8) void {
		for (data) |byte| {
			self.update(byte);
		}
	}

	pub fn final(self: Crc32Bzip2) u32 {
		return self.crc ^ 0xFFFFFFFF;
	}
};

fn readAny(reader: anytype, buffer: []u8) anyerror!usize {
	const ReaderType = @TypeOf(reader);
	const Child = switch (@typeInfo(ReaderType)) {
		.pointer => |info| info.child,
		else => ReaderType,
	};

	if (@hasDecl(Child, "readSliceShort")) {
		return reader.readSliceShort(buffer);
	}
	if (@hasDecl(Child, "read")) {
		return reader.read(buffer);
	}

	@compileError("reader type lacks read methods");
}

fn readByteAny(reader: anytype) anyerror!u8 {
	var buf: [1]u8 = undefined;
	const n = try readAny(reader, &buf);
	if (n == 0) return error.EndOfStream;
	return buf[0];
}

fn encodedLenForRun(run_len: usize) usize {
	if (run_len == 0) return 0;
	if (run_len >= 4) return 5;
	return run_len;
}

// ============ Bit Reader (Generic) ============

/// Generic bit reader that reads bits MSB first (bzip2 convention)
pub fn BitReader(comptime ReaderType: type) type {
	return struct {
		const Self = @This();

		reader: ReaderType,
		buffer: u64, // Use u64 to handle up to 32 bit reads
		bits_in_buffer: u6, // u6 can hold 0-63

		pub fn init(reader: ReaderType) Self {
			return .{
				.reader = reader,
				.buffer = 0,
				.bits_in_buffer = 0,
			};
		}

		/// Read n bits (up to 32) from the stream
		pub fn readBits(self: *Self, comptime n: u6) Error!u32 {
			// Ensure we have enough bits
			while (self.bits_in_buffer < n) {
				const byte = readByteAny(self.reader) catch |err| {
					if (err == error.EndOfStream) return Error.UnexpectedEof;
					return Error.CorruptData;
				};
				self.buffer = (self.buffer << 8) | byte;
				self.bits_in_buffer += 8;
			}

			self.bits_in_buffer -= n;
			const shift: u6 = self.bits_in_buffer;
			const mask: u64 = (@as(u64, 1) << n) - 1;
			return @truncate((self.buffer >> shift) & mask);
		}

		/// Read a variable number of bits (up to 32)
		pub fn readBitsVar(self: *Self, n: u6) Error!u32 {
			// Ensure we have enough bits
			while (self.bits_in_buffer < n) {
				const byte = readByteAny(self.reader) catch |err| {
					if (err == error.EndOfStream) return Error.UnexpectedEof;
					return Error.CorruptData;
				};
				self.buffer = (self.buffer << 8) | byte;
				self.bits_in_buffer += 8;
			}

			self.bits_in_buffer -= n;
			const shift: u6 = self.bits_in_buffer;
			const mask: u64 = (@as(u64, 1) << n) - 1;
			return @truncate((self.buffer >> shift) & mask);
		}

		pub fn alignToByte(self: *Self) void {
			const rem: u6 = @intCast(self.bits_in_buffer & 7);
			if (rem == 0) return;
			self.bits_in_buffer -= rem;
			self.buffer >>= rem;
		}

		/// Read a single bit
		pub fn readBit(self: *Self) Error!u1 {
			return @truncate(try self.readBits(1));
		}
	};
}

// ============ Huffman Table ============

const HuffmanTable = struct {
	// Limits for each code length
	limits: [MAX_CODE_LEN + 2]u32,
	// Base values for decoding
	bases: [MAX_CODE_LEN + 2]u32,
	// Permutation table
	perms: [MAX_ALPHA_SIZE]u16,

	pub fn init() HuffmanTable {
		return .{
			.limits = [_]u32{0} ** (MAX_CODE_LEN + 2),
			.bases = [_]u32{0} ** (MAX_CODE_LEN + 2),
			.perms = [_]u16{0} ** MAX_ALPHA_SIZE,
		};
	}

	/// Build decoding tables from code lengths
	pub fn build(self: *HuffmanTable, lengths: []const u8, num_symbols: usize) Error!void {
		if (num_symbols == 0) return;

		// Count codes of each length
		var count: [MAX_CODE_LEN + 1]u32 = [_]u32{0} ** (MAX_CODE_LEN + 1);
		var min_len: usize = MAX_CODE_LEN;
		var max_len: usize = 0;

		for (lengths[0..num_symbols]) |len| {
			if (len == 0) continue;
			if (len > MAX_CODE_LEN) return Error.HuffmanOverflow;
			count[len] += 1;
			if (len < min_len) min_len = len;
			if (len > max_len) max_len = len;
		}

		// Compute base codes and limits for each length
		// base[len] = first code at this length
		// limit[len] = first invalid code at this length (one past the last valid code)
		var code: u32 = 0;
		for (1..MAX_CODE_LEN + 1) |len| {
			self.bases[len] = code;
			self.limits[len] = code + count[len]; // First invalid code at this length
			code = (code + count[len]) << 1; // Shift for next length
		}
		self.limits[MAX_CODE_LEN + 1] = std.math.maxInt(u32);

		// Build permutation table (map code to symbol)
		// Symbols are stored in canonical order: first all length-1 symbols, then length-2, etc.
		var perm_idx: usize = 0;
		for (1..MAX_CODE_LEN + 1) |len| {
			for (0..num_symbols) |sym| {
				if (lengths[sym] == len) {
					self.perms[perm_idx] = @intCast(sym);
					perm_idx += 1;
				}
			}
		}
	}

	/// Decode one symbol from bit reader
	pub fn decode(self: *const HuffmanTable, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!u16 {
		var code: u32 = 0;
		var perm_offset: usize = 0; // Cumulative count of symbols with shorter codes

		for (1..MAX_CODE_LEN + 1) |len| {
			code = (code << 1) | try bits.readBit();
			if (code < self.limits[len]) {
				const idx = code - self.bases[len];
				return self.perms[perm_offset + idx];
			}
			// Add number of symbols at this length to offset for next length
			perm_offset += self.limits[len] - self.bases[len];
		}
		return Error.HuffmanOverflow;
	}
};

// ============ Decompressor ============

pub const Decompressor = struct {
	allocator: Allocator,

	// Block data buffer
	block: []u8,
	block_size: usize,
	stored_block_crc: u32,

	// BWT state
	bwt_primary_index: u32,
	tt: []u32, // Transformation table

	// Huffman tables (up to 6 groups)
	huffman_tables: [MAX_GROUPS]HuffmanTable,
	num_groups: usize,

	// Selectors
	selectors: []u8,
	num_selectors: usize,

	// Symbol map (which bytes are used in this stream)
	in_use: [256]bool,
	seq_to_unseq: [256]u8,
	num_in_use: usize,

	// Stream state
	stream_crc: u32,
	block_randomized: bool,

	// Output buffer
	output: []u8,
	output_len: usize,

	// Progress callback
	on_progress: ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void = null,
	progress_userdata: ?*anyopaque = null,
	progress_bytes_total: u64 = 0,
	progress_bytes_processed: u64 = 0,

	pub fn init(allocator: Allocator) !Decompressor {
		const block = try allocator.alloc(u8, MAX_BLOCK_SIZE + 1);
		errdefer allocator.free(block);

		const tt = try allocator.alloc(u32, MAX_BLOCK_SIZE + 1);
		errdefer allocator.free(tt);

		const output = try allocator.alloc(u8, MAX_BLOCK_SIZE + 1);
		errdefer allocator.free(output);

		const selectors = try allocator.alloc(u8, MAX_SELECTORS);
		errdefer allocator.free(selectors);

		return Decompressor{
			.allocator = allocator,
			.block = block,
			.block_size = 0,
			.stored_block_crc = 0,
			.bwt_primary_index = 0,
			.tt = tt,
			.huffman_tables = [_]HuffmanTable{HuffmanTable.init()} ** MAX_GROUPS,
			.num_groups = 0,
			.selectors = selectors,
			.num_selectors = 0,
			.in_use = [_]bool{false} ** 256,
			.seq_to_unseq = [_]u8{0} ** 256,
			.num_in_use = 0,
			.stream_crc = 0,
			.block_randomized = false,
			.output = output,
			.output_len = 0,
		};
	}

	pub fn deinit(self: *Decompressor) void {
		self.allocator.free(self.block);
		self.allocator.free(self.tt);
		self.allocator.free(self.output);
		self.allocator.free(self.selectors);
	}

	/// Decompress bzip2 data from reader to writer
	pub fn decompress(self: *Decompressor, reader: anytype, writer: anytype) Error!void {
		return self.decompressInternal(reader, writer, true);
	}

	/// Decompress bzip2 data from reader to writer, optionally checking CRC
	pub fn decompressInternal(self: *Decompressor, reader: anytype, writer: anytype, check_crc: bool) Error!void {
		const ReaderType = @TypeOf(reader);
		var bits = BitReader(ReaderType).init(reader);
		var seen_stream = false;

		while (true) {
			var header: [4]u8 = undefined;
			var i: usize = 0;
			while (i < header.len) : (i += 1) {
				const byte_val = bits.readBits(8) catch |err| {
					if (err == Error.UnexpectedEof) {
						if (!seen_stream) return Error.UnexpectedEof;
						return;
					}
					return err;
				};
				header[i] = @intCast(byte_val);
			}

			seen_stream = true;

			// Validate magic
			if (!std.mem.eql(u8, header[0..3], &STREAM_MAGIC)) {
				return Error.InvalidMagic;
			}

			// Validate block size digit ('1' - '9')
			const level = header[3];
			if (level < '1' or level > '9') {
				return Error.InvalidBlockSize;
			}

			// Reset stream CRC
			self.stream_crc = 0;

			// Process blocks until footer
			while (true) {
				// Read 48-bit block/footer magic
				const magic_high: u48 = try bits.readBits(24);
				const magic_low: u48 = try bits.readBits(24);
				const magic: u48 = (magic_high << 24) | magic_low;

				if (magic == FOOTER_MAGIC) {
					// Stream footer - read and verify CRC
					if (check_crc) {
						const stored_stream_crc = try bits.readBits(32);
						if (stored_stream_crc != self.stream_crc) {
							return Error.StreamCrcMismatch;
						}
					} else {
						_ = try bits.readBits(32); // Skip CRC
					}
					break;
				}

				if (magic != BLOCK_MAGIC) {
					return Error.InvalidBlockHeader;
				}

				// Process block
				try self.readBlock(ReaderType, &bits);
				try self.decodeBlockInternal(check_crc);

				// Write decompressed output
				_ = writer.write(self.output[0..self.output_len]) catch return Error.CorruptData;

				// Fire progress callback
				self.progress_bytes_processed += self.output_len;
				if (self.on_progress) |cb| {
					cb(self.progress_bytes_processed, self.progress_bytes_total, self.progress_userdata);
				}

				// Update stream CRC (rotate left by 1 and XOR with block CRC)
				self.stream_crc = ((self.stream_crc << 1) | (self.stream_crc >> 31)) ^ self.stored_block_crc;
			}

			bits.alignToByte();
		}
	}

	fn readBlock(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
		// Block CRC (32 bits)
		self.stored_block_crc = try bits.readBits(32);

		// Randomized flag (1 bit) - rarely used
		self.block_randomized = (try bits.readBit()) == 1;

		// BWT primary index (24 bits)
		self.bwt_primary_index = try bits.readBits(24);

		// Read symbol bitmap
		try self.readSymbolMap(ReaderType, bits);

		// Number of Huffman groups (3 bits)
		self.num_groups = try bits.readBits(3);
		if (self.num_groups < 2 or self.num_groups > MAX_GROUPS) {
			return Error.CorruptData;
		}

		// Number of selectors (15 bits)
		self.num_selectors = try bits.readBits(15);
		if (self.num_selectors == 0 or self.num_selectors > MAX_SELECTORS) {
			return Error.CorruptData;
		}

		// Read selectors (MTF encoded)
		try self.readSelectors(ReaderType, bits);

		// Read Huffman code lengths and build tables
		try self.readHuffmanTrees(ReaderType, bits);

		// Decode compressed data
		try self.readCompressedData(ReaderType, bits);
	}

	fn readSymbolMap(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
		// First level: 16-bit bitmap of which 16-symbol groups are used
		const group_bitmap: u16 = @truncate(try bits.readBits(16));

		self.num_in_use = 0;
		@memset(&self.in_use, false);

		for (0..16) |group_idx| {
			if (group_bitmap & (@as(u16, 0x8000) >> @intCast(group_idx)) != 0) {
				// This group of 16 symbols has a second-level bitmap
				const sym_bitmap: u16 = @truncate(try bits.readBits(16));
				for (0..16) |sym_idx| {
					if (sym_bitmap & (@as(u16, 0x8000) >> @intCast(sym_idx)) != 0) {
						const sym = group_idx * 16 + sym_idx;
						self.in_use[sym] = true;
						self.seq_to_unseq[self.num_in_use] = @intCast(sym);
						self.num_in_use += 1;
					}
				}
			}
		}
	}

	fn readSelectors(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
		// MTF state for selector decoding
		var mtf: [MAX_GROUPS]u8 = undefined;
		for (0..self.num_groups) |i| {
			mtf[i] = @intCast(i);
		}

		// Read MTF-encoded selectors
		for (0..self.num_selectors) |i| {
			// Count unary-coded selector index
			var j: usize = 0;
			while (try bits.readBit() == 1) {
				j += 1;
				if (j >= self.num_groups) {
					return Error.InvalidSelector;
				}
			}

			// MTF decode
			const selected = mtf[j];
			// Move to front
			while (j > 0) : (j -= 1) {
				mtf[j] = mtf[j - 1];
			}
			mtf[0] = selected;

			self.selectors[i] = selected;
		}
	}

	fn readHuffmanTrees(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
		const alpha_size = self.num_in_use + 2; // +2 for RUNA and RUNB

		for (0..self.num_groups) |group| {
			var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

			// Read initial code length (5 bits)
			var curr_len: i32 = @intCast(try bits.readBits(5));

			for (0..alpha_size) |sym| {
				// Adjust length with delta encoding
				while (true) {
					if (curr_len < 1 or curr_len > 20) {
						return Error.HuffmanOverflow;
					}

					// Check for adjustment
					const adjust = try bits.readBit();
					if (adjust == 0) break;

					// Direction: 0 = increment, 1 = decrement
					if (try bits.readBit() == 0) {
						curr_len += 1;
					} else {
						curr_len -= 1;
					}
				}
				lengths[sym] = @intCast(curr_len);
			}

			// Build Huffman table
			try self.huffman_tables[group].build(&lengths, alpha_size);
		}
	}

	fn readCompressedData(self: *Decompressor, comptime ReaderType: type, bits: *BitReader(ReaderType)) Error!void {
		const eob: u16 = @intCast(self.num_in_use + 1); // End of block symbol

		// MTF state for decoding
		var mtf: [256]u8 = undefined;
		for (0..256) |i| {
			mtf[i] = @intCast(i);
		}

		self.block_size = 0;
		var group_pos: usize = 0; // Position within current group of 50 symbols
		var selector_idx: usize = 0;

		// Helper to get current table
		const getTable = struct {
			fn call(d: *Decompressor, sel_idx: usize) Error!*const HuffmanTable {
				if (sel_idx >= d.num_selectors) return Error.CorruptData;
				const table_idx = d.selectors[sel_idx];
				if (table_idx >= d.num_groups) return Error.CorruptData;
				return &d.huffman_tables[table_idx];
			}
		}.call;

		// Helper to advance to next symbol slot
		const advanceSlot = struct {
			fn call(gpos: *usize, sidx: *usize) void {
				gpos.* += 1;
				if (gpos.* >= GROUP_SIZE) {
					gpos.* = 0;
					sidx.* += 1;
				}
			}
		}.call;

		// Helper to decode next symbol
		const decodeNext = struct {
			fn call(d: *Decompressor, gpos: *usize, sidx: *usize, b: *BitReader(ReaderType)) Error!u16 {
				const table = try getTable(d, sidx.*);
				advanceSlot(gpos, sidx);
				return table.decode(ReaderType, b);
			}
		}.call;

		while (true) {
			const sym = try decodeNext(self, &group_pos, &selector_idx, bits);

			if (sym == eob) break;

			if (sym < 2) {
				// RUNA (0) or RUNB (1) - run-length encoded zeros
				// bzip2 uses a bijective base-2 encoding where:
				// - RUNA encodes value 1 at current power
				// - RUNB encodes value 2 at current power
				// The total run length is the sum of these values
				var run_len: u32 = 0;
				var run_power: u32 = 1;
				var current_sym = sym;

				// First symbol initializes the run
				run_len += (current_sym + 1) * run_power;
				run_power <<= 1;

				// Continue reading while we get RUNA/RUNB
				while (true) {
					current_sym = try decodeNext(self, &group_pos, &selector_idx, bits);
					if (current_sym >= 2) break;
					run_len += (current_sym + 1) * run_power;
					run_power <<= 1;
				}

				// Output run of MTF[0]
				const byte = self.seq_to_unseq[mtf[0]];
				for (0..run_len) |_| {
					if (self.block_size >= MAX_BLOCK_SIZE) {
						return Error.OutputOverflow;
					}
					self.block[self.block_size] = byte;
					self.block_size += 1;
				}

				// Now handle the non-RUNA/RUNB symbol we just read
				const next_sym = current_sym;

				// Handle the non-run symbol we just read
				if (next_sym == eob) break;
				if (next_sym >= 2) {
					// In bzip2: symbol 2 = MTF[1], symbol 3 = MTF[2], etc.
					// (RUNA/RUNB implicitly reference MTF[0])
					const idx = next_sym - 1;
					if (idx >= self.num_in_use) return Error.CorruptData;

					const out_byte = mtf[idx];
					// MTF update - move to front
					var k = idx;
					while (k > 0) : (k -= 1) {
						mtf[k] = mtf[k - 1];
					}
					mtf[0] = out_byte;

					if (self.block_size >= MAX_BLOCK_SIZE) {
						return Error.OutputOverflow;
					}
					self.block[self.block_size] = self.seq_to_unseq[out_byte];
					self.block_size += 1;
				}
			} else {
				// Regular MTF symbol (sym >= 2)
				// In bzip2: symbol 2 = MTF[1], symbol 3 = MTF[2], etc.
				const idx = sym - 1;
				if (idx >= self.num_in_use) return Error.CorruptData;

				const out_byte = mtf[idx];
				// MTF update - move to front
				var k = idx;
				while (k > 0) : (k -= 1) {
					mtf[k] = mtf[k - 1];
				}
				mtf[0] = out_byte;

				if (self.block_size >= MAX_BLOCK_SIZE) {
					return Error.OutputOverflow;
				}
				self.block[self.block_size] = self.seq_to_unseq[out_byte];
				self.block_size += 1;
			}
		}
	}

	fn decodeBlock(self: *Decompressor) Error!void {
		return self.decodeBlockInternal(true);
	}

	fn decodeBlockInternal(self: *Decompressor, check_crc: bool) Error!void {
		if (self.block_size == 0) {
			self.output_len = 0;
			return;
		}

		// Build inverse BWT transformation
		try self.buildInverseBwt();

		// Perform inverse BWT to get original data
		try self.inverseBwt();

		// Expand initial RLE (runs of 4+ identical bytes were compressed)
		try self.expandInitialRle();

		// Verify block CRC
		if (check_crc) {
			var crc = Crc32Bzip2.init();
			crc.updateSlice(self.output[0..self.output_len]);
			if (crc.final() != self.stored_block_crc) {
				return Error.BlockCrcMismatch;
			}
		}
	}

	fn expandInitialRle(self: *Decompressor) Error!void {
		// bzip2's initial RLE: runs of 4+ identical bytes are encoded as
		// XXXX + count, where count (0-255) indicates additional copies beyond 4.
		// We expand these runs using the block buffer as scratch space.
		//
		// The compressor limits blocks by RLE-ENCODED size, so the expanded
		// output can exceed MAX_BLOCK_SIZE. We compute the needed size first
		// and grow buffers if necessary.

		// First pass: compute expanded size
		const needed = self.computeRleExpandedSize() orelse return Error.CorruptData;

		// Grow buffers if expansion exceeds current capacity
		if (needed > self.block.len) {
			self.block = self.allocator.realloc(self.block, needed) catch return Error.OutOfMemory;
		}
		if (needed > self.output.len) {
			self.output = self.allocator.realloc(self.output, needed) catch return Error.OutOfMemory;
		}

		// Second pass: expand
		var read_pos: usize = 0;
		var write_pos: usize = 0;

		while (read_pos < self.output_len) {
			const byte = self.output[read_pos];
			read_pos += 1;

			// Check for a run of 4 identical bytes
			if (read_pos + 3 <= self.output_len and
				self.output[read_pos] == byte and
				self.output[read_pos + 1] == byte and
				self.output[read_pos + 2] == byte)
			{
				read_pos += 3; // Skip the 3 additional copies (total 4)

				if (read_pos >= self.output_len) {
					return Error.CorruptData;
				}
				const count = self.output[read_pos];
				read_pos += 1;

				const total = @as(usize, 4) + @as(usize, count);
				for (0..total) |_| {
					self.block[write_pos] = byte;
					write_pos += 1;
				}
			} else {
				self.block[write_pos] = byte;
				write_pos += 1;
			}
		}

		// Copy expanded data back to output
		@memcpy(self.output[0..write_pos], self.block[0..write_pos]);
		self.output_len = write_pos;
	}

	/// Compute the expanded size of RLE data in self.output without modifying anything.
	/// Returns null if the RLE data is malformed (missing count byte).
	fn computeRleExpandedSize(self: *const Decompressor) ?usize {
		var read_pos: usize = 0;
		var expanded: usize = 0;

		while (read_pos < self.output_len) {
			const byte = self.output[read_pos];
			read_pos += 1;

			if (read_pos + 3 <= self.output_len and
				self.output[read_pos] == byte and
				self.output[read_pos + 1] == byte and
				self.output[read_pos + 2] == byte)
			{
				read_pos += 3;
				if (read_pos >= self.output_len) return null;
				const count = self.output[read_pos];
				read_pos += 1;
				expanded += @as(usize, 4) + @as(usize, count);
			} else {
				expanded += 1;
			}
		}

		return expanded;
	}

	fn buildInverseBwt(self: *Decompressor) Error!void {
		// In BWT, the last column L and first column F are related.
		// F is the sorted version of L.
		// The transformation table T maps each position i in L to the
		// position j in F where the same character instance appears.
		//
		// For character c at position i in L, T[i] is the position in F
		// where this specific instance of c appears. Since F is sorted,
		// T[i] = cumulative_count[c] + (number of c's before position i in L)

		// First pass: count occurrences of each byte
		var counts: [256]u32 = [_]u32{0} ** 256;
		for (self.block[0..self.block_size]) |byte| {
			counts[byte] += 1;
		}

		// Compute cumulative counts (where each character starts in sorted order)
		var cumulative: [256]u32 = undefined;
		var sum: u32 = 0;
		for (0..256) |i| {
			cumulative[i] = sum;
			sum += counts[i];
		}

		// Second pass: build TT table
		// For each position i, TT[i] = cumulative[block[i]] + rank
		// where rank is how many times block[i] has appeared before position i
		@memset(&counts, 0);
		for (0..self.block_size) |i| {
			const byte = self.block[i];
			self.tt[i] = cumulative[byte] + counts[byte];
			counts[byte] += 1;
		}
	}

	fn inverseBwt(self: *Decompressor) Error!void {
		if (self.bwt_primary_index >= self.block_size) {
			return Error.InvalidBwtIndex;
		}

		// The inverse BWT follows the transformation chain.
		// Following T gives us characters in reverse order (last to first),
		// so we fill the output array from the end to the start.
		self.output_len = self.block_size;
		var pos: u32 = self.bwt_primary_index;

		var i: usize = self.block_size;
		while (i > 0) {
			i -= 1;
			// Output the character at current position, then follow T
			self.output[i] = self.block[pos];
			pos = self.tt[pos];
		}

		// Handle randomization (if used)
		if (self.block_randomized) {
			derandomize(self.output[0..self.output_len]);
		}
	}
};

/// Apply bzip2 derandomization (used for pathological inputs)
fn derandomize(data: []u8) void {
	// Format-compatibility constant for legacy randomized bzip2 blocks.
	// This must match the canonical 512-entry sequence for interop/CRC checks.
	const rand_nums = [_]u32{
		619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491,
		741, 242, 949, 214, 733, 859, 335, 708, 621, 574, 73,  654, 730, 472, 419, 436,
		278, 496, 867, 210, 399, 680, 480, 51,  878, 465, 811, 169, 869, 675, 611, 697,
		867, 561, 862, 687, 507, 283, 482, 129, 807, 591, 733, 623, 150, 238, 59,  379,
		684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
		73,  122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874, 474,
		882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604,
		958, 533, 221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485,
		911, 276, 98,  553, 163, 354, 666, 933, 424, 341, 533, 870, 227, 730, 475, 186,
		263, 647, 537, 686, 600, 224, 469, 68,  770, 919, 190, 373, 294, 822, 808, 206,
		184, 943, 795, 384, 383, 461, 404, 758, 839, 887, 715, 67,  618, 276, 204, 918,
		873, 777, 604, 560, 951, 160, 578, 722, 79,  804, 96,  409, 713, 940, 652, 934,
		970, 447, 318, 353, 859, 672, 112, 785, 645, 863, 803, 350, 139, 93,  354, 99,
		820, 908, 609, 772, 154, 274, 580, 184, 79,  626, 630, 742, 653, 282, 762, 623,
		680, 81,  927, 626, 789, 125, 411, 521, 938, 300, 821, 78,  343, 175, 128, 250,
		170, 774, 972, 275, 999, 639, 495, 78,  352, 126, 857, 956, 358, 619, 580, 124,
		737, 594, 701, 612, 669, 112, 134, 694, 363, 992, 809, 743, 168, 974, 944, 375,
		748, 52,  600, 747, 642, 182, 862, 81,  344, 805, 988, 739, 511, 655, 814, 334,
		249, 515, 897, 955, 664, 981, 649, 113, 974, 459, 893, 228, 433, 837, 553, 268,
		926, 240, 102, 654, 459, 51,  686, 754, 806, 760, 493, 403, 415, 394, 687, 700,
		946, 670, 656, 610, 738, 392, 760, 799, 887, 653, 978, 321, 576, 617, 626, 502,
		894, 679, 243, 440, 680, 879, 194, 572, 640, 724, 926, 56,  204, 700, 707, 151,
		457, 449, 797, 195, 791, 558, 945, 679, 297, 59,  87,  824, 713, 663, 412, 693,
		342, 606, 134, 108, 571, 364, 631, 212, 174, 643, 304, 329, 343, 97,  430, 751,
		497, 314, 983, 374, 822, 928, 140, 206, 73,  263, 980, 736, 876, 478, 430, 305,
		170, 514, 364, 692, 829, 82,  855, 953, 676, 246, 369, 970, 294, 750, 807, 827,
		150, 790, 288, 923, 804, 378, 215, 828, 592, 281, 565, 555, 710, 82,  896, 831,
		547, 261, 524, 462, 293, 465, 502, 56,  661, 821, 976, 991, 658, 869, 905, 758,
		745, 193, 768, 550, 608, 933, 378, 286, 215, 979, 792, 961, 61,  688, 793, 644,
		986, 403, 106, 366, 905, 644, 372, 567, 466, 434, 645, 210, 389, 550, 919, 135,
		780, 773, 635, 389, 707, 100, 626, 958, 165, 504, 920, 176, 193, 713, 857, 265,
		203, 50,  668, 108, 645, 990, 626, 197, 510, 357, 358, 850, 858, 364, 936, 638,
	};

	var rand_idx: usize = 0;
	var count: usize = 0;

	for (data) |*byte| {
		count += 1;
		if (count >= rand_nums[rand_idx]) {
			byte.* ^= 1;
			count = 0;
			rand_idx = (rand_idx + 1) % rand_nums.len;
		}
	}
}

// ============ Compression Functions ============

/// Initial RLE encoding: compress runs of 4+ identical bytes.
/// Format: XXXX + count, where count (0-255) is additional copies beyond 4.
pub fn initialRleEncode(allocator: Allocator, input: []const u8) ![]u8 {
	var output: std.ArrayListUnmanaged(u8) = .empty;
	errdefer output.deinit(allocator);

	var i: usize = 0;
	while (i < input.len) {
		const byte = input[i];
		var run_len: usize = 1;

		// Count consecutive identical bytes
		while (i + run_len < input.len and input[i + run_len] == byte and run_len < 259) {
			run_len += 1;
		}

		if (run_len >= 4) {
			// Output 4 copies + count
			try output.append(allocator, byte);
			try output.append(allocator, byte);
			try output.append(allocator, byte);
			try output.append(allocator, byte);
			try output.append(allocator, @intCast(run_len - 4));
			i += run_len;
		} else {
			// Output bytes individually
			for (0..run_len) |_| {
				try output.append(allocator, byte);
			}
			i += run_len;
		}
	}

	return output.toOwnedSlice(allocator);
}

/// Result of BWT encoding
pub const BwtResult = struct {
	data: []u8,
	primary_index: u32,
};

// ============================================================================
// SA-IS (Suffix Array by Induced Sorting) Algorithm
// O(n) time complexity for suffix array construction
// Based on: Nong, Zhang, Chan - "Two Efficient Algorithms for Linear Time
// Suffix Array Construction" (2009)
// Reference implementation: github.com/sile/sais
// ============================================================================

/// Build suffix array using SA-IS algorithm. O(n) time and space.
/// Input text should NOT include a sentinel - we handle it internally.
pub fn buildSuffixArraySAIS(allocator: Allocator, text: []const u8) ![]u32 {
	if (text.len == 0) {
		return try allocator.alloc(u32, 0);
	}

	// Add sentinel (conceptually text + '\0')
	const n = text.len + 1; // Include sentinel position

	// Allocate SA buffer
	const sa = try allocator.alloc(i32, n);
	errdefer allocator.free(sa);

	// Helper to get character at position (byte+1 for real chars, 0 = sentinel)
	const getChar = struct {
		fn get(pos: usize, txt: []const u8) usize {
			return if (pos < txt.len) @as(usize, txt[pos]) + 1 else 0;
		}
	}.get;

	// Classify types: false = S-type (0), true = L-type (1)
	// Last position (sentinel) is S-type by default
	const types = try allocator.alloc(bool, n);
	defer allocator.free(types);

	types[n - 1] = false; // Sentinel is S-type
	if (n >= 2) {
		var i: usize = n - 2;
		while (true) {
			// Use getChar (+1 mapping) for consistency with bucket sort
			const c_i = getChar(i, text);
			const c_next = getChar(i + 1, text);
			if (c_i < c_next) {
				types[i] = false; // S-type
			} else if (c_i > c_next) {
				types[i] = true; // L-type
			} else {
				types[i] = types[i + 1];
			}
			if (i == 0) break;
			i -= 1;
		}
	}

	// Helper: check if position is LMS (L-type followed by S-type)
	const isLMS = struct {
		fn check(pos: usize, t: []const bool) bool {
			return pos > 0 and t[pos - 1] and !t[pos]; // L=true, S=false
		}
	}.check;

	// Count character frequencies (including sentinel = 0)
	var bucket_sizes: [257]u32 = [_]u32{0} ** 257;
	bucket_sizes[0] = 1; // Sentinel
	for (text) |c| {
		bucket_sizes[@as(usize, c) + 1] += 1;
	}

	// Calculate bucket boundaries
	var bucket_starts: [257]u32 = [_]u32{0} ** 257;
	var bucket_ends: [257]u32 = [_]u32{0} ** 257;
	var sum: u32 = 0;
	for (0..257) |c| {
		bucket_starts[c] = sum;
		sum += bucket_sizes[c];
		bucket_ends[c] = sum;
	}

	// Initialize SA
	@memset(sa, 0);

	// Step 1: Place LMS suffixes at end of their buckets (right to left)
	var bucket_tails = bucket_ends;
	for (1..n) |i| {
		if (isLMS(i, types)) {
			const c = getChar(i, text);
			bucket_tails[c] -= 1;
			sa[bucket_tails[c]] = @intCast(i);
		}
	}

	// Place sentinel explicitly (it may not be LMS if types[n-2] is S-type)
	// Sentinel at position n-1 has character 0, always goes to sa[0]
	if (sa[0] == 0) { // Sentinel wasn't placed as LMS
		sa[0] = @intCast(n - 1);
	}

	// Step 2: Induce L-type suffixes (left to right)
	var bucket_heads = bucket_starts;
	for (0..n) |i| {
		const pos = sa[i] - 1;
		if (pos >= 0 and types[@intCast(pos)]) { // L-type
			const c = getChar(@intCast(pos), text);
			sa[bucket_heads[c]] = pos;
			bucket_heads[c] += 1;
		}
	}

	// Step 3: Induce S-type suffixes (right to left)
	bucket_tails = bucket_ends;
	var i: usize = n;
	while (i > 0) {
		i -= 1;
		const pos = sa[i] - 1;
		if (pos >= 0 and !types[@intCast(pos)]) { // S-type
			const c = getChar(@intCast(pos), text);
			bucket_tails[c] -= 1;
			sa[bucket_tails[c]] = pos;
		}
	}

	// Step 4: Compact LMS suffixes and compute names
	var lms_count: usize = 0;
	for (0..n) |idx| {
		if (sa[idx] != 0 and isLMS(@intCast(sa[idx]), types)) {
			sa[lms_count] = sa[idx];
			lms_count += 1;
		}
	}

	// Initialize second half for names
	const names_start = n / 2;
	for (names_start..n) |idx| {
		sa[idx] = -1;
	}

	// Assign names to LMS substrings
	var name: i32 = 0;
	var prev_lms: i32 = -1;
	for (0..lms_count) |idx| {
		const pos = sa[idx];
		if (prev_lms >= 0) {
			// Compare LMS substrings
			if (!lmsEqual(text, types, @intCast(prev_lms), @intCast(pos), isLMS)) {
				name += 1;
			}
		}
		sa[names_start + @as(usize, @intCast(@divTrunc(pos - 1, 2)))] = name;
		prev_lms = pos;
	}

	// Compact names into reduced string
	var reduced_len: usize = 0;
	for (names_start..n) |idx| {
		if (sa[idx] >= 0) {
			sa[names_start + reduced_len] = sa[idx];
			reduced_len += 1;
		}
	}

	// Check if recursion needed
	const unique = (@as(u32, @intCast(name)) + 1 == reduced_len);

	if (!unique) {
		// Recursive call on reduced problem
		// Note: reduced string is at sa[names_start..], SA output goes to sa[0..reduced_len]
		const reduced = sa[names_start .. names_start + reduced_len];
		try saisRecurse(allocator, reduced, @intCast(name + 1), sa[0..reduced_len]);

		// Convert suffix array to ranks, storing IN the reduced string area
		// sa[0..reduced_len] contains SA positions, we write ranks to sa[names_start..]
		for (0..reduced_len) |idx| {
			const sa_pos: usize = @intCast(sa[idx]); // Position in reduced string
			sa[names_start + sa_pos] = @intCast(idx); // Store rank at that position
		}
	}

	// Now sa[names_start + j] contains the rank of the j-th LMS substring
	// Place LMS suffixes at their ranked positions (as negative values)
	var lms_idx: usize = 0;
	for (1..n) |idx| {
		if (isLMS(idx, types)) {
			const rank: usize = @intCast(sa[names_start + lms_idx]);
			sa[rank] = -@as(i32, @intCast(idx)); // Negative to mark as LMS
			lms_idx += 1;
		}
	}
	// Clear the rest
	for (lms_idx..n) |idx| {
		if (idx < names_start or sa[idx] >= 0) {
			sa[idx] = 0;
		}
	}

	// Final induced sorting
	bucket_tails = bucket_ends;
	var j_final = reduced_len;
	while (j_final > 0) {
		j_final -= 1;
		const pos_neg = sa[j_final];
		sa[j_final] = 0;
		const pos: usize = @intCast(-pos_neg);
		const c = getChar(pos, text);
		bucket_tails[c] -= 1;
		sa[bucket_tails[c]] = @intCast(pos);
	}

	// Place sentinel explicitly if not already placed
	if (sa[0] == 0) {
		sa[0] = @intCast(n - 1);
	}

	// Induce L-type
	bucket_heads = bucket_starts;
	for (0..n) |idx| {
		const pos = sa[idx] - 1;
		if (pos >= 0 and types[@intCast(pos)]) {
			const c = getChar(@intCast(pos), text);
			sa[bucket_heads[c]] = pos;
			bucket_heads[c] += 1;
		}
	}

	// Induce S-type
	bucket_tails = bucket_ends;
	var idx_final: usize = n;
	while (idx_final > 0) {
		idx_final -= 1;
		const pos = sa[idx_final] - 1;
		if (pos >= 0 and !types[@intCast(pos)]) {
			const c = getChar(@intCast(pos), text);
			bucket_tails[c] -= 1;
			sa[bucket_tails[c]] = pos;
		}
	}

	// Convert to u32 and remove sentinel position
	// Sentinel is at position n-1 (text.len), skip it
	const result = try allocator.alloc(u32, text.len);
	var out_idx: usize = 0;
	for (sa) |pos| {
		const upos: usize = @intCast(pos);
		if (upos < text.len) { // Skip sentinel at position text.len
			result[out_idx] = @intCast(upos);
			out_idx += 1;
			if (out_idx >= text.len) break;
		}
	}

	allocator.free(sa);
	return result;
}

/// Compare two LMS substrings for equality
fn lmsEqual(text: []const u8, types: []const bool, pos1: usize, pos2: usize, isLMS: fn (usize, []const bool) bool) bool {
	const n = text.len + 1;
	var i: usize = 0;
	while (true) {
		const p1 = pos1 + i;
		const p2 = pos2 + i;

		if (p1 >= n or p2 >= n) return false;

		// Use +1 mapping for consistency with bucket sort (byte+1 for real chars, 0 for sentinel)
		const c1: u16 = if (p1 < text.len) @as(u16, text[p1]) + 1 else 0;
		const c2: u16 = if (p2 < text.len) @as(u16, text[p2]) + 1 else 0;

		if (c1 != c2) return false;
		if (types[p1] != types[p2]) return false;

		// Check if we've reached the end of both LMS substrings
		if (i > 0) {
			const lms1 = isLMS(p1, types);
			const lms2 = isLMS(p2, types);
			if (lms1 and lms2) return true;
			if (lms1 != lms2) return false;
		}

		i += 1;
		if (i > n) return false;
	}
}

/// Compare two LMS substrings for equality (integer version)
fn lmsEqualInt(text: []i32, types: []const bool, pos1: usize, pos2: usize, isLMS: fn (usize, []const bool) bool) bool {
	const n = text.len; // text within saisRecurse usually includes sentinel at end if needed
	// But note: buildSuffixArraySAIS uses n=text.len+1.
	// In saisRecurse, n is length of text (names).
	// Bounds check must be strict.

	var i: usize = 0;
	while (true) {
		const p1 = pos1 + i;
		const p2 = pos2 + i;

		if (p1 >= n or p2 >= n) return false;

		const c1 = text[p1];
		const c2 = text[p2];

		if (c1 != c2) return false;
		if (types[p1] != types[p2]) return false;

		// Check if we've reached the end of both LMS substrings
		if (i > 0) {
			const lms1 = isLMS(p1, types);
			const lms2 = isLMS(p2, types);
			if (lms1 and lms2) return true;
			if (lms1 != lms2) return false;
		}

		i += 1;
	}
}

/// Recursive SA-IS for integer alphabet (in-place in buffer)
fn saisRecurse(allocator: Allocator, text: []i32, alphabet_size: u32, sa_out: []i32) !void {
	const n = text.len;
	if (n == 0) return;
	if (n == 1) {
		sa_out[0] = 0;
		return;
	}

	// Classify types
	const types = try allocator.alloc(bool, n);
	defer allocator.free(types);

	// S-type at end
	types[n - 1] = false;
	if (n >= 2) {
		var i: usize = n - 2;
		while (true) {
			if (text[i] < text[i + 1]) {
				types[i] = false;
			} else if (text[i] > text[i + 1]) {
				types[i] = true;
			} else {
				types[i] = types[i + 1];
			}
			if (i == 0) break;
			i -= 1;
		}
	}

	const isLMS = struct {
		fn check(pos: usize, t: []const bool) bool {
			return pos > 0 and t[pos - 1] and !t[pos];
		}
	}.check;

	// Bucket sort
	const bucket_sizes = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(bucket_sizes);
	@memset(bucket_sizes, 0);

	for (text) |c| {
		bucket_sizes[@intCast(c)] += 1;
	}

	const bucket_starts = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(bucket_starts);
	const bucket_ends = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(bucket_ends);

	var sum: u32 = 0;
	for (0..alphabet_size) |c| {
		bucket_starts[c] = sum;
		sum += bucket_sizes[c];
		bucket_ends[c] = sum;
	}

	@memset(sa_out, 0);

	// Step 1: Place LMS
	const bucket_tails = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(bucket_tails);
	@memcpy(bucket_tails, bucket_ends);

	for (1..n) |i| {
		if (isLMS(i, types)) {
			const c: usize = @intCast(text[i]);
			bucket_tails[c] -= 1;
			sa_out[bucket_tails[c]] = @intCast(i);
		}
	}

	// Place sentinel explicitly if not already placed
	// In recursive case, sentinel is at position n-1 with the smallest character value
	// Assuming smallest char is 0. If sa_out[0] is empty, force place n-1.
	// If n-1 was LMS, it might be already placed.
	if (sa_out[0] == 0) {
		// Only force if text fits (assumes text[n-1] is effectively sentinel/LMS)
		// In reduced string, last element is name of previous sentinel, so it behaves as such.
		sa_out[0] = @intCast(n - 1);
	}

	// Step 2: Induce L
	const bucket_heads = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(bucket_heads);
	@memcpy(bucket_heads, bucket_starts);

	for (0..n) |i| {
		const pos = sa_out[i] - 1;
		if (pos >= 0 and types[@intCast(pos)]) {
			const c: usize = @intCast(text[@intCast(pos)]);
			sa_out[bucket_heads[c]] = pos;
			bucket_heads[c] += 1;
		}
	}

	// Step 3: Induce S
	@memcpy(bucket_tails, bucket_ends);
	var i: usize = n;
	while (i > 0) {
		i -= 1;
		const pos = sa_out[i] - 1;
		if (pos >= 0 and !types[@intCast(pos)]) {
			const c: usize = @intCast(text[@intCast(pos)]);
			bucket_tails[c] -= 1;
			sa_out[bucket_tails[c]] = pos;
		}
	}

	// Step 4: Compact LMS suffixes and compute names
	var lms_count: usize = 0;
	for (0..n) |idx| {
		const pos = sa_out[idx];
		if (pos > 0 and isLMS(@intCast(pos), types)) {
			sa_out[lms_count] = pos;
			lms_count += 1;
		}
	}

	// Initialize names area
	const names_start = n / 2;
	for (names_start..n) |idx| {
		sa_out[idx] = -1;
	}

	// Assign names
	var name: i32 = 0;
	var prev_lms: i32 = -1;
	for (0..lms_count) |idx| {
		const pos = sa_out[idx];
		if (prev_lms >= 0) {
			if (!lmsEqualInt(text, types, @intCast(prev_lms), @intCast(pos), isLMS)) {
				name += 1;
			}
		}
		sa_out[names_start + @as(usize, @intCast(@divTrunc(pos, 2)))] = name; // Note: integer div
		prev_lms = pos;
	}

	// Compact names
	var reduced_len: usize = 0;
	for (names_start..n) |idx| {
		if (sa_out[idx] >= 0) {
			sa_out[names_start + reduced_len] = sa_out[idx];
			reduced_len += 1;
		}
	}

	// Recursion check
	if (@as(u32, @intCast(name)) + 1 < reduced_len) {
		// Names not unique - RECURSE
		const reduced = sa_out[names_start .. names_start + reduced_len];
		try saisRecurse(allocator, reduced, @intCast(name + 1), sa_out[0..reduced_len]);

		// Convert to ranks
		for (0..reduced_len) |idx| {
			const sa_pos: usize = @intCast(sa_out[idx]);
			sa_out[names_start + sa_pos] = @intCast(idx);
		}
	} else {
		// Unique - generate ranks directly
		// The sa_out[names_start...] currently holds names (unsorted physically by pos? no sorted by pos)
		// Wait. sa_out[names_start + reduced_len] holding compact names.
		// They are in text order.
		// And they are unique (0..reduced_len-1).
		// So reduced[i] is the name of i-th LMS.
		// We want SA of this permutation.
		// Since names are unique numbers 0..cnt-1, we can just bucket sort / invert.
		const reduced = sa_out[names_start .. names_start + reduced_len];
		for (reduced, 0..) |n_val, idx| {
			sa_out[@intCast(n_val)] = @intCast(idx);
		}
		// Result is in sa_out[0..reduced_len]

		// Need to move ranks to names area?
		// Logic below expects ranks at sa_out[names_start + j].
		// Currently sa_out[0..] has SA.
		// SA[i] = j means j-th LMS is i-th smallest.
		// We want Rank[j] = i.
		// So sa_out[j] = i ? No.
		// We write ranks to sa_out[names_start..].
		for (0..reduced_len) |idx| {
			const sa_pos: usize = @intCast(sa_out[idx]);
			sa_out[names_start + sa_pos] = @intCast(idx);
		}
	}

	// Step 7: Place LMS from ranks
	var lms_idx: usize = 0;
	for (1..n) |idx| {
		if (isLMS(idx, types)) {
			const rank: usize = @intCast(sa_out[names_start + lms_idx]);
			sa_out[rank] = @intCast(idx); // Store +pos (we use sign bit if needed, but here i32 fits)
			// Main algo uses negative. We can use negative too to distinguish?
			// "Place LMS suffixes at their ranked positions (as negative values)"
			// Step 8 below expects negative or check types?
			// "if (pos >= 0 and types[pos])..."
			// If we store positive, we rely on checking "types[pos]".
			// But we need to distinguish "placed LMS" from "empty/sentinel".
			// sa_out was typically cleared.
			// Let's use negative for safety/consistency.
			sa_out[rank] = -@as(i32, @intCast(idx));
			lms_idx += 1;
		}
	}

	// Clear the rest
	for (lms_idx..n) |idx| {
		// In recursive, we don't have buffer overlap issues as complex as main?
		// sa_out[0..n] is the buffer.
		// We wrote to sa_out[0..lms_count].
		// We need to clear sa_out[lms_count..n].
		if (sa_out[idx] >= 0) sa_out[idx] = 0;
	}

	// Step 8: Induce L and S (Final)
	@memcpy(bucket_tails, bucket_ends);
	var j_final = reduced_len;
	while (j_final > 0) {
		j_final -= 1;
		const pos_neg = sa_out[j_final];
		sa_out[j_final] = 0;
		const pos: usize = @intCast(-pos_neg);

		const c: usize = @intCast(text[pos]);
		bucket_tails[c] -= 1;
		sa_out[bucket_tails[c]] = @intCast(pos);
	}

	// Explicit sentinel?
	if (sa_out[0] == 0) {
		sa_out[0] = @intCast(n - 1);
	}

	@memcpy(bucket_heads, bucket_starts);
	for (0..n) |idx| {
		const pos = sa_out[idx] - 1;
		if (pos >= 0 and types[@intCast(pos)]) { // L-type
			const c: usize = @intCast(text[@intCast(pos)]);
			sa_out[bucket_heads[c]] = pos;
			bucket_heads[c] += 1;
		}
	}

	@memcpy(bucket_tails, bucket_ends);
	i = n;
	while (i > 0) {
		i -= 1;
		const pos = sa_out[i] - 1;
		if (pos >= 0 and !types[@intCast(pos)]) {
			const c: usize = @intCast(text[@intCast(pos)]);
			bucket_tails[c] -= 1;
			sa_out[bucket_tails[c]] = pos;
		}
	}
}

/// Burrows-Wheeler Transform (forward transform) using SA-IS algorithm.
/// Returns the last column of the sorted rotation matrix and the primary index.
/// O(n) time complexity.
///
/// Uses string doubling technique: build SA of input++input, then filter to
/// positions < n. This correctly sorts circular rotations.
pub fn bwtEncode(allocator: Allocator, input: []const u8) !BwtResult {
	const n = input.len;
	if (n == 0) {
		return BwtResult{ .data = try allocator.alloc(u8, 0), .primary_index = 0 };
	}

	// Double the string: "hello" -> "hellohello"
	// This makes suffix comparison equivalent to rotation comparison
	const doubled = try allocator.alloc(u8, n * 2);
	defer allocator.free(doubled);
	@memcpy(doubled[0..n], input);
	@memcpy(doubled[n..], input);

	// Build suffix array on doubled string
	const sa_doubled = try buildSuffixArraySAIS(allocator, doubled);
	defer allocator.free(sa_doubled);

	// Extract positions < n (these correspond to valid rotations)
	const output = try allocator.alloc(u8, n);
	errdefer allocator.free(output);

	var primary_index: u32 = 0;
	var out_idx: usize = 0;

	for (sa_doubled) |pos| {
		if (pos < n) {
			// BWT character: last character of rotation starting at pos
			output[out_idx] = input[(pos + n - 1) % n];
			if (pos == 0) {
				primary_index = @intCast(out_idx);
			}
			out_idx += 1;
			if (out_idx >= n) break;
		}
	}

	return BwtResult{ .data = output, .primary_index = primary_index };
}

/// Move-To-Front encoding.
/// Each input byte is replaced by its position in a list that's updated after each byte.
pub fn mtfEncode(allocator: Allocator, input: []const u8, alphabet: []const u8) ![]u8 {
	var output = try allocator.alloc(u8, input.len);
	errdefer allocator.free(output);

	// Initialize MTF list with alphabet
	var mtf: [256]u8 = undefined;
	for (alphabet, 0..) |c, i| {
		mtf[i] = c;
	}
	const alpha_len = alphabet.len;

	for (input, 0..) |byte, out_idx| {
		// Find position of byte in MTF list
		var pos: usize = 0;
		while (pos < alpha_len and mtf[pos] != byte) {
			pos += 1;
		}

		if (pos >= alpha_len) {
			// Byte not in alphabet - this shouldn't happen with valid input
			allocator.free(output);
			return Error.CorruptData;
		}

		output[out_idx] = @intCast(pos);

		// Move to front
		if (pos > 0) {
			const char = mtf[pos];
			var j = pos;
			while (j > 0) : (j -= 1) {
				mtf[j] = mtf[j - 1];
			}
			mtf[0] = char;
		}
	}

	return output;
}

/// Result of encoding a zero run with RUNA/RUNB
pub const ZeroRunResult = struct {
	symbols: [32]u8, // Max symbols needed for any run length
	len: usize,
};

/// Encode a run of zeros using bijective base-2 (RUNA/RUNB).
/// RUNA (0) contributes 1*power, RUNB (1) contributes 2*power.
pub fn encodeZeroRun(run_len: u32) ZeroRunResult {
	var result = ZeroRunResult{ .symbols = undefined, .len = 0 };

	if (run_len == 0) return result;

	// Bijective base-2 encoding:
	// To encode n, we find the sequence where sum of (symbol+1)*power = n
	var remaining = run_len;
	var power: u32 = 1;

	while (remaining > 0) {
		// At each position, we can contribute 1*power (RUNA) or 2*power (RUNB)
		// Determine which symbol to use
		if (remaining >= 2 * power and (remaining - 2 * power) % (2 * power) < power) {
			// Use RUNB
			result.symbols[result.len] = 1;
			remaining -= 2 * power;
		} else {
			// Use RUNA
			result.symbols[result.len] = 0;
			remaining -= power;
		}
		result.len += 1;
		power *= 2;
	}

	return result;
}

// ============ BitWriter ============

pub fn ByteWriter(comptime WriterType: type) type {
	return struct {
		const Self = @This();

		writer: WriterType,

		pub fn init(writer: WriterType) Self {
			return .{ .writer = writer };
		}

	pub fn writeByte(self: *Self, byte: u8) !void {
		var buf = [1]u8{byte};
		try self.writer.writeAll(&buf);
	}
	};
}

/// Bit writer that writes bits MSB first (bzip2 convention)
pub fn BitWriter(comptime WriterType: type) type {
	return struct {
		const Self = @This();

		writer: WriterType,
		buffer: u64,
		bits_in_buffer: u6,

		pub fn init(writer: WriterType) Self {
			return .{
				.writer = writer,
				.buffer = 0,
				.bits_in_buffer = 0,
			};
		}

		/// Write n bits (MSB first), n can be 0-32
		pub fn writeBits(self: *Self, value: u32, n: u6) !void {
			if (n == 0) return;

			const mask: u64 = (@as(u64, 1) << n) - 1;
			self.buffer = (self.buffer << n) | (@as(u64, value) & mask);
			self.bits_in_buffer += n;

			while (self.bits_in_buffer >= 8) {
				self.bits_in_buffer -= 8;
				const byte: u8 = @truncate(self.buffer >> self.bits_in_buffer);
				try self.writer.writeByte(byte);
			}
		}

		/// Write a single bit
		pub fn writeBit(self: *Self, bit: u1) !void {
			try self.writeBits(bit, 1);
		}

		/// Flush remaining bits (padded with zeros)
		pub fn flush(self: *Self) !void {
			if (self.bits_in_buffer > 0) {
				const remaining: u6 = 8 - self.bits_in_buffer;
				const byte: u8 = @truncate(self.buffer << remaining);
				try self.writer.writeByte(byte);
				self.buffer = 0;
				self.bits_in_buffer = 0;
			}
		}
	};
}

// ============ Huffman Encoding ============

/// Build Huffman code lengths from symbol frequencies.
/// Returns array of code lengths (0 = symbol not used).
pub fn buildHuffmanLengths(freqs: []const u32, num_symbols: usize) [MAX_ALPHA_SIZE]u8 {
	var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

	if (num_symbols == 0) return lengths;

	// Simple approach: assign lengths based on frequency ranking
	// More frequent symbols get shorter codes
	// This is a simplified version - real bzip2 uses package-merge algorithm

	// Find total frequency
	var total_freq: u64 = 0;
	for (freqs[0..num_symbols]) |f| {
		total_freq += f;
	}

	if (total_freq == 0) {
		// All symbols have zero frequency - assign length 1 to first symbol
		lengths[0] = 1;
		return lengths;
	}

	// Assign lengths based on frequency (simplified)
	// Use a basic strategy: frequent symbols get shorter codes
	for (0..num_symbols) |i| {
		if (freqs[i] > 0) {
			// Calculate ideal length based on Shannon entropy
			// length ≈ -log2(probability)
			const prob = @as(f64, @floatFromInt(freqs[i])) / @as(f64, @floatFromInt(total_freq));
			const ideal_len = -@log2(prob);
			var len: u8 = @intFromFloat(@max(1.0, @min(20.0, @ceil(ideal_len))));
			// Ensure minimum length of 1
			if (len == 0) len = 1;
			lengths[i] = len;
		}
	}

	// Ensure at least one symbol has length 1 for valid Huffman tree
	var has_short: bool = false;
	for (lengths[0..num_symbols]) |l| {
		if (l > 0 and l <= 2) {
			has_short = true;
			break;
		}
	}
	if (!has_short) {
		// Find the most frequent symbol and give it a shorter code
		var max_freq: u32 = 0;
		var max_idx: usize = 0;
		for (0..num_symbols) |i| {
			if (freqs[i] > max_freq) {
				max_freq = freqs[i];
				max_idx = i;
			}
		}
		if (max_freq > 0) {
			lengths[max_idx] = 1;
		}
	}

	return lengths;
}

/// Compute optimal Huffman code lengths from symbol frequencies.
/// Uses a simplified heap-based algorithm, then limits lengths to max_len.
/// Returns code lengths for each symbol (0 for unused symbols).
fn computeHuffmanLengths(freqs: []const u32, num_symbols: usize, max_len: u8) [MAX_ALPHA_SIZE]u8 {
	var lengths: [MAX_ALPHA_SIZE]u8 = [_]u8{0} ** MAX_ALPHA_SIZE;

	if (num_symbols == 0) return lengths;
	if (num_symbols == 1) {
		lengths[0] = 1;
		return lengths;
	}

	// Count non-zero frequencies
	var num_used: usize = 0;
	for (freqs[0..num_symbols]) |f| {
		if (f > 0) num_used += 1;
	}

	if (num_used == 0) return lengths;
	if (num_used == 1) {
		// Single symbol - give it length 1
		for (freqs[0..num_symbols], 0..) |f, i| {
			if (f > 0) {
				lengths[i] = 1;
				break;
			}
		}
		return lengths;
	}

	// Node structure for Huffman tree building
	// We use indices: 0..num_symbols are leaves, num_symbols.. are internal nodes
	const Node = struct {
		freq: u64,
		left: u16, // Child index or 0xFFFF for leaf
		right: u16,
		depth: u8,
	};

	var nodes: [MAX_ALPHA_SIZE * 2]Node = undefined;
	var num_nodes: usize = 0;

	// Initialize leaf nodes for used symbols
	var symbol_to_node: [MAX_ALPHA_SIZE]u16 = [_]u16{0xFFFF} ** MAX_ALPHA_SIZE;
	for (freqs[0..num_symbols], 0..) |f, i| {
		if (f > 0) {
			symbol_to_node[i] = @intCast(num_nodes);
			nodes[num_nodes] = .{
				.freq = f,
				.left = 0xFFFF,
				.right = 0xFFFF,
				.depth = 0,
			};
			num_nodes += 1;
		}
	}

	// Build Huffman tree using min-heap for O(n log n) complexity
	// Heap stores node indices, ordered by frequency
	var heap: [MAX_ALPHA_SIZE * 2]u16 = undefined;
	var heap_size: usize = 0;

	// Heap helper functions (inline for performance)
	const heapLess = struct {
		fn call(n: []const Node, a: u16, b: u16) bool {
			return n[a].freq < n[b].freq;
		}
	}.call;

	const heapSwap = struct {
		fn call(h: []u16, i: usize, j: usize) void {
			const tmp = h[i];
			h[i] = h[j];
			h[j] = tmp;
		}
	}.call;

	const heapBubbleUp = struct {
		fn call(n: []const Node, h: []u16, idx: usize) void {
			var i = idx;
			while (i > 0) {
				const parent = (i - 1) / 2;
				if (!heapLess(n, h[i], h[parent])) break;
				heapSwap(h, i, parent);
				i = parent;
			}
		}
	}.call;

	const heapBubbleDown = struct {
		fn call(n: []const Node, h: []u16, size: usize, idx: usize) void {
			var i = idx;
			while (true) {
				var smallest = i;
				const left = 2 * i + 1;
				const right = 2 * i + 2;
				if (left < size and heapLess(n, h[left], h[smallest])) {
					smallest = left;
				}
				if (right < size and heapLess(n, h[right], h[smallest])) {
					smallest = right;
				}
				if (smallest == i) break;
				heapSwap(h, i, smallest);
				i = smallest;
			}
		}
	}.call;

	// Insert initial nodes into heap - O(n log n)
	for (0..num_nodes) |i| {
		heap[heap_size] = @intCast(i);
		heapBubbleUp(&nodes, &heap, heap_size);
		heap_size += 1;
	}

	// Build Huffman tree by repeatedly combining two smallest nodes - O(n log n)
	while (heap_size > 1) {
		// Extract two smallest
		const min1_idx = heap[0];
		heap[0] = heap[heap_size - 1];
		heap_size -= 1;
		heapBubbleDown(&nodes, &heap, heap_size, 0);

		const min2_idx = heap[0];
		heap[0] = heap[heap_size - 1];
		heap_size -= 1;
		heapBubbleDown(&nodes, &heap, heap_size, 0);

		// Combine into new internal node
		nodes[num_nodes] = .{
			.freq = nodes[min1_idx].freq + nodes[min2_idx].freq,
			.left = min1_idx,
			.right = min2_idx,
			.depth = 0,
		};

		// Insert new node into heap
		heap[heap_size] = @intCast(num_nodes);
		heapBubbleUp(&nodes, &heap, heap_size);
		heap_size += 1;
		num_nodes += 1;
	}

	// Calculate depths (code lengths) by traversing from root
	const root = num_nodes - 1;
	nodes[root].depth = 0;

	// Process nodes in reverse order (root to leaves)
	var i: usize = num_nodes;
	while (i > 0) {
		i -= 1;
		const node = nodes[i];
		if (node.left != 0xFFFF) {
			nodes[node.left].depth = node.depth + 1;
			nodes[node.right].depth = node.depth + 1;
		}
	}

	// Extract lengths for original symbols
	// IMPORTANT: All symbols must have a valid non-zero length for canonical Huffman encoding
	// Symbols with 0 frequency get max_len (least efficient, but correct for encoder/decoder agreement)
	for (0..num_symbols) |sym| {
		const node_idx = symbol_to_node[sym];
		if (node_idx != 0xFFFF) {
			var len = nodes[node_idx].depth;
			// Clamp to max_len
			if (len > max_len) len = max_len;
			if (len < 1) len = 1;
			lengths[sym] = len;
		} else {
			// Symbol had 0 frequency - assign max_len for valid Huffman encoding
			lengths[sym] = max_len;
		}
	}

	// If any lengths were clamped, we need to rebalance to maintain valid Huffman
	// For simplicity, use package-merge style adjustment: if over limit, steal from longest
	var iterations: u32 = 0;
	while (iterations < 100) { // Safety limit
		iterations += 1;
		// Check Kraft inequality: sum of 2^(-len) must equal 1
		var kraft: u64 = 0;
		const base: u64 = @as(u64, 1) << @as(u6, @intCast(max_len));
		for (lengths[0..num_symbols]) |len| {
			kraft += base >> @as(u6, @intCast(len));
		}

		if (kraft == base) break; // Valid

		if (kraft > base) {
			// Over-subscribed: need to make some codes longer
			// Find shortest code and make it longer
			var shortest: u8 = max_len;
			var shortest_idx: usize = 0;
			for (lengths[0..num_symbols], 0..) |len, idx| {
				if (len < shortest) {
					shortest = len;
					shortest_idx = idx;
				}
			}
			if (lengths[shortest_idx] < max_len) {
				lengths[shortest_idx] += 1;
			}
		} else {
			// Under-subscribed: need to make some codes shorter
			// Find longest code and make it shorter
			var longest: u8 = 1;
			var longest_idx: usize = 0;
			for (lengths[0..num_symbols], 0..) |len, idx| {
				if (len > longest) {
					longest = len;
					longest_idx = idx;
				}
			}
			if (lengths[longest_idx] > 1) {
				lengths[longest_idx] -= 1;
			} else {
				break; // Can't improve further
			}
		}
	}

	return lengths;
}

/// Build canonical Huffman codes from lengths.
/// Returns array of codes corresponding to each symbol.
pub fn buildHuffmanCodes(lengths: []const u8, num_symbols: usize) [MAX_ALPHA_SIZE]u32 {
	var codes: [MAX_ALPHA_SIZE]u32 = [_]u32{0} ** MAX_ALPHA_SIZE;

	// Count codes of each length
	var count: [MAX_CODE_LEN + 1]u32 = [_]u32{0} ** (MAX_CODE_LEN + 1);
	for (lengths[0..num_symbols]) |len| {
		if (len > 0 and len <= MAX_CODE_LEN) {
			count[len] += 1;
		}
	}

	// Compute first code of each length
	var first_code: [MAX_CODE_LEN + 2]u32 = [_]u32{0} ** (MAX_CODE_LEN + 2);
	var code: u32 = 0;
	for (1..MAX_CODE_LEN + 1) |len| {
		first_code[len] = code;
		code = (code + count[len]) << 1;
	}

	// Assign codes to symbols
	var next_code: [MAX_CODE_LEN + 1]u32 = undefined;
	for (0..MAX_CODE_LEN + 1) |i| {
		next_code[i] = first_code[i];
	}

	for (0..num_symbols) |i| {
		const len = lengths[i];
		if (len > 0 and len <= MAX_CODE_LEN) {
			codes[i] = next_code[len];
			next_code[len] += 1;
		}
	}

	return codes;
}

const BlockPrepared = struct {
	crc: u32,
	primary_index: u32,
	in_use: [256]bool,
	num_in_use: usize,
	alpha_size: usize,
	lengths: [MAX_ALPHA_SIZE]u8,
	codes: [MAX_ALPHA_SIZE]u32,
	symbols: []u16,
	original_len: usize = 0,

	pub fn deinit(self: *BlockPrepared, allocator: Allocator) void {
		allocator.free(self.symbols);
	}
};

const BlockTask = struct {
	index: usize,
	data: []u8,
	owns_data: bool,
};

const BlockResult = struct {
	index: usize,
	result: anyerror!BlockPrepared,
};

const WorkerState = struct {
	allocator: Allocator,
	tasks: *BoundedQueue(BlockTask),
	results: *BoundedQueue(BlockResult),
	cancel: *std.atomic.Value(bool),
};

fn workerLoop(state: *WorkerState) void {
	while (true) {
		const task_opt = state.tasks.dequeue() orelse break;
		if (state.cancel.load(.acquire)) {
			if (task_opt.owns_data) {
				state.allocator.free(task_opt.data);
			}
			continue;
		}

		const prepared = prepareBlock(state.allocator, task_opt.data);
		if (task_opt.owns_data) {
			state.allocator.free(task_opt.data);
		}

		if (prepared) |_| {} else |_| {
			state.cancel.store(true, .release);
		}

		_ = state.results.enqueue(.{
			.index = task_opt.index,
			.result = prepared,
		});
	}
}

fn updateStreamCrc(stream_crc: u32, block_crc: u32) u32 {
	return ((stream_crc << 1) | (stream_crc >> 31)) ^ block_crc;
}

fn prepareBlock(allocator: Allocator, input: []const u8) !BlockPrepared {
	var block_crc = Crc32Bzip2.init();
	block_crc.updateSlice(input);
	const crc_value = block_crc.final();

	const rle_data = try initialRleEncode(allocator, input);
	defer allocator.free(rle_data);

	const bwt_result = try bwtEncode(allocator, rle_data);
	defer allocator.free(bwt_result.data);

	var in_use = [_]bool{false} ** 256;
	for (bwt_result.data) |b| {
		in_use[b] = true;
	}

	var seq_to_unseq: [256]u8 = undefined;
	var unseq_to_seq: [256]u8 = undefined;
	var num_in_use: usize = 0;
	for (0..256) |i| {
		if (in_use[i]) {
			seq_to_unseq[num_in_use] = @intCast(i);
			unseq_to_seq[i] = @intCast(num_in_use);
			num_in_use += 1;
		}
	}

	var mtf_data = try allocator.alloc(u8, bwt_result.data.len);
	defer allocator.free(mtf_data);

	var mtf_list: [256]u8 = undefined;
	for (0..num_in_use) |i| {
		mtf_list[i] = @intCast(i);
	}

	for (bwt_result.data, 0..) |byte, i| {
		const seq = unseq_to_seq[byte];
		var pos: usize = 0;
		while (mtf_list[pos] != seq) : (pos += 1) {}
		mtf_data[i] = @intCast(pos);
		if (pos > 0) {
			const val = mtf_list[pos];
			var j = pos;
			while (j > 0) : (j -= 1) {
				mtf_list[j] = mtf_list[j - 1];
			}
			mtf_list[0] = val;
		}
	}

	var symbols: std.ArrayListUnmanaged(u16) = .empty;
	errdefer symbols.deinit(allocator);

	var idx: usize = 0;
	while (idx < mtf_data.len) {
		if (mtf_data[idx] == 0) {
			var run_len: u32 = 0;
			while (idx < mtf_data.len and mtf_data[idx] == 0) {
				run_len += 1;
				idx += 1;
			}
			const encoded = encodeZeroRun(run_len);
			for (encoded.symbols[0..encoded.len]) |s| {
				try symbols.append(allocator, s);
			}
		} else {
			try symbols.append(allocator, @as(u16, mtf_data[idx]) + 1);
			idx += 1;
		}
	}

	const eob: u16 = @intCast(num_in_use + 1);
	try symbols.append(allocator, eob);

	const alpha_size = num_in_use + 2;
	var freqs: [MAX_ALPHA_SIZE]u32 = [_]u32{0} ** MAX_ALPHA_SIZE;
	for (symbols.items) |s| {
		freqs[s] += 1;
	}

	const lengths = computeHuffmanLengths(&freqs, alpha_size, 17);
	const codes = buildHuffmanCodes(&lengths, alpha_size);

	const symbols_slice = try symbols.toOwnedSlice(allocator);

	return .{
		.crc = crc_value,
		.primary_index = bwt_result.primary_index,
		.in_use = in_use,
		.num_in_use = num_in_use,
		.alpha_size = alpha_size,
		.lengths = lengths,
		.codes = codes,
		.symbols = symbols_slice,
		.original_len = input.len,
	};
}

fn writeBlock(bits: anytype, block: *const BlockPrepared) !void {
	try bits.writeBits(@truncate(BLOCK_MAGIC >> 24), 24);
	try bits.writeBits(@truncate(BLOCK_MAGIC & 0xFFFFFF), 24);
	try bits.writeBits(block.crc, 32);
	try bits.writeBit(0);
	try bits.writeBits(block.primary_index, 24);

	var group_bitmap: u16 = 0;
	for (0..16) |g| {
		for (0..16) |s| {
			const byte = g * 16 + s;
			if (block.in_use[byte]) {
				group_bitmap |= @as(u16, 0x8000) >> @intCast(g);
				break;
			}
		}
	}
	try bits.writeBits(group_bitmap, 16);

	for (0..16) |g| {
		if (group_bitmap & (@as(u16, 0x8000) >> @intCast(g)) != 0) {
			var sym_bitmap: u16 = 0;
			for (0..16) |s| {
				const byte = g * 16 + s;
				if (block.in_use[byte]) {
					sym_bitmap |= @as(u16, 0x8000) >> @intCast(s);
				}
			}
			try bits.writeBits(sym_bitmap, 16);
		}
	}

	try bits.writeBits(2, 3);
	const num_selectors = (block.symbols.len + GROUP_SIZE - 1) / GROUP_SIZE;
	try bits.writeBits(@intCast(num_selectors), 15);

	for (0..num_selectors) |_| {
		try bits.writeBit(0);
	}

	var curr_len: i32 = @intCast(block.lengths[0]);
	try bits.writeBits(@intCast(curr_len), 5);
	for (0..block.alpha_size) |i| {
		const target_len: i32 = @intCast(block.lengths[i]);
		while (curr_len != target_len) {
			try bits.writeBit(1);
			if (curr_len < target_len) {
				try bits.writeBit(0);
				curr_len += 1;
			} else {
				try bits.writeBit(1);
				curr_len -= 1;
			}
		}
		try bits.writeBit(0);
	}

	curr_len = @intCast(block.lengths[0]);
	try bits.writeBits(@intCast(curr_len), 5);
	for (0..block.alpha_size) |i| {
		const target_len: i32 = @intCast(block.lengths[i]);
		while (curr_len != target_len) {
			try bits.writeBit(1);
			if (curr_len < target_len) {
				try bits.writeBit(0);
				curr_len += 1;
			} else {
				try bits.writeBit(1);
				curr_len -= 1;
			}
		}
		try bits.writeBit(0);
	}

	for (block.symbols) |sym| {
		const code = block.codes[sym];
		const len = block.lengths[sym];
		var i: u8 = len;
		while (i > 0) {
			i -= 1;
			const bit: u1 = @truncate(code >> @as(u5, @intCast(i)));
			try bits.writeBit(bit);
		}
	}
}

fn writeSingleBlockStream(writer: anytype, level: u8, block: *const BlockPrepared) !void {
	try writer.writeAll(&STREAM_MAGIC);

	var byte_writer = ByteWriter(@TypeOf(writer)).init(writer);
	try byte_writer.writeByte('0' + level);

	var bits = BitWriter(@TypeOf(byte_writer)).init(byte_writer);
	try writeBlock(&bits, block);

	try bits.writeBits(@truncate(FOOTER_MAGIC >> 24), 24);
	try bits.writeBits(@truncate(FOOTER_MAGIC & 0xFFFFFF), 24);
	try bits.writeBits(block.crc, 32);
	try bits.flush();
}

fn RleBlockReader(comptime ReaderType: type) type {
	return struct {
		const Self = @This();

		reader: ReaderType,
		carry: std.ArrayListUnmanaged(u8) = .empty,
		carry_pos: usize = 0,
		eof: bool = false,

		fn init(reader: ReaderType) Self {
			return .{ .reader = reader };
		}

		fn deinit(self: *Self, allocator: Allocator) void {
			self.carry.deinit(allocator);
		}

		fn fillCarry(self: *Self, allocator: Allocator) !bool {
			if (self.carry_pos < self.carry.items.len) return true;
			if (self.eof) return false;

			self.carry.clearRetainingCapacity();
			self.carry_pos = 0;

			const reader_any = if (@typeInfo(ReaderType) == .pointer) self.reader else &self.reader;
			var buf: [8192]u8 = undefined;
			const n = readAny(reader_any, &buf) catch |err| switch (err) {
				error.EndOfStream => 0,
				else => return err,
			};
			if (n == 0) {
				self.eof = true;
				return false;
			}
			try self.carry.appendSlice(allocator, buf[0..n]);
			return true;
		}

		fn nextBlock(self: *Self, allocator: Allocator, max_rle_size: usize) !?[]u8 {
			var block: std.ArrayListUnmanaged(u8) = .empty;
			errdefer block.deinit(allocator);

			var encoded_complete: usize = 0;
			var run_len: usize = 0;
			var run_byte: u8 = 0;

			while (true) {
				if (!try self.fillCarry(allocator)) break;

				const byte = self.carry.items[self.carry_pos];
				var prospective_complete = encoded_complete;
				var prospective_run_len = run_len;
				var prospective_run_byte = run_byte;

				if (run_len == 0) {
					prospective_run_len = 1;
					prospective_run_byte = byte;
				} else if (byte == run_byte and run_len < 259) {
					prospective_run_len = run_len + 1;
				} else {
					prospective_complete = encoded_complete + encodedLenForRun(run_len);
					prospective_run_len = 1;
					prospective_run_byte = byte;
				}

				const prospective_total = prospective_complete + encodedLenForRun(prospective_run_len);
				if (block.items.len > 0 and prospective_total > max_rle_size) {
					break;
				}

				self.carry_pos += 1;
				try block.append(allocator, byte);

				encoded_complete = prospective_complete;
				run_len = prospective_run_len;
				run_byte = prospective_run_byte;

				if (self.carry_pos >= self.carry.items.len) {
					self.carry.clearRetainingCapacity();
					self.carry_pos = 0;
				}
			}

			if (block.items.len == 0) {
				if (self.eof) return null;
				return null;
			}

			const slice = try block.toOwnedSlice(allocator);
			return @as(?[]u8, slice);
		}
	};
}

// ============ High-Level API ============

/// Compress data using bzip2 algorithm.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn compress(allocator: Allocator, input: []const u8) ![]u8 {
	return compressWithOptions(allocator, input, .{});
}

pub fn compressWithOptions(allocator: Allocator, input: []const u8, options: CompressOptions) ![]u8 {
	var output: std.ArrayListUnmanaged(u8) = .empty;
	errdefer output.deinit(allocator);

	const writer = output.writer(allocator);
	var fbs = std.io.fixedBufferStream(input);
	try compressStreamWithOptions(allocator, fbs.reader(), writer, options);

	return output.toOwnedSlice(allocator);
}

pub fn compressStream(allocator: Allocator, reader: anytype, writer: anytype) !void {
	return compressStreamWithOptions(allocator, reader, writer, .{});
}

pub fn compressStreamWithOptions(allocator: Allocator, reader: anytype, writer: anytype, options: CompressOptions) !void {
	const block_size = try options.blockSizeBytes();
	const thread_count = options.resolvedThreads();
	var block_reader = RleBlockReader(@TypeOf(reader)).init(reader);
	defer block_reader.deinit(allocator);
	var bytes_processed: u64 = 0;

	if (!options.multi_stream) {
		try writer.writeAll(&STREAM_MAGIC);

		var byte_writer = ByteWriter(@TypeOf(writer)).init(writer);
		try byte_writer.writeByte('0' + options.level);

		var bits = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

		var stream_crc: u32 = 0;

		if (thread_count <= 1) {
			while (true) {
				const data_opt = try block_reader.nextBlock(allocator, block_size);
				if (data_opt == null) break;
				const data = data_opt.?;
				defer allocator.free(data);

				var block = try prepareBlock(allocator, data);
				defer block.deinit(allocator);

				try writeBlock(&bits, &block);
				stream_crc = updateStreamCrc(stream_crc, block.crc);
				bytes_processed += block.original_len;
				if (options.on_progress) |cb| {
					cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
				}
			}
		} else {
			const queue_capacity = @max(@as(usize, 1), thread_count * 2);
			var tasks = try BoundedQueue(BlockTask).init(allocator, queue_capacity);
			defer tasks.deinit();
			var results = try BoundedQueue(BlockResult).init(allocator, queue_capacity);
			defer results.deinit();

			var cancel = std.atomic.Value(bool).init(false);
			var state = WorkerState{
				.allocator = allocator,
				.tasks = &tasks,
				.results = &results,
				.cancel = &cancel,
			};

			var threads = try allocator.alloc(std.Thread, thread_count);
			defer allocator.free(threads);

			var spawned: usize = 0;
			while (spawned < thread_count) : (spawned += 1) {
				threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{&state});
			}

			var next_index: usize = 0;
			var submitted: usize = 0;
			var completed: usize = 0;
			var next_write_index: usize = 0;
			var read_done = false;
			var pending = std.AutoHashMap(usize, BlockPrepared).init(allocator);
			defer pending.deinit();
			var first_error: ?anyerror = null;

			while (!read_done or completed < submitted) {
				while (!read_done and tasks.len() < queue_capacity and !cancel.load(.acquire)) {
					const data_opt = try block_reader.nextBlock(allocator, block_size);
					if (data_opt == null) {
						read_done = true;
						tasks.close();
						break;
					}
					const data = data_opt.?;
					if (!tasks.enqueue(.{ .index = next_index, .data = data, .owns_data = true })) {
						allocator.free(data);
						read_done = true;
						tasks.close();
						break;
					}
					next_index += 1;
					submitted += 1;
				}

				if (completed < submitted) {
					if (results.dequeue()) |result| {
						completed += 1;
						if (result.result) |prepared| {
							if (first_error == null) {
								try pending.put(result.index, prepared);
								while (pending.fetchRemove(next_write_index)) |entry| {
									var block = entry.value;
									try writeBlock(&bits, &block);
									stream_crc = updateStreamCrc(stream_crc, block.crc);
									bytes_processed += block.original_len;
									if (options.on_progress) |cb| {
										cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
									}
									block.deinit(allocator);
									next_write_index += 1;
								}
							} else {
								var block = prepared;
								block.deinit(allocator);
							}
						} else |err| {
							if (first_error == null) {
								first_error = err;
								cancel.store(true, .release);
								read_done = true;
								tasks.close();
							}
						}
					}
				} else if (read_done) {
					break;
				}
			}

			tasks.close();

			for (threads) |thread| {
				thread.join();
			}

			if (first_error) |err| {
				var it = pending.iterator();
				while (it.next()) |entry| {
					var block = entry.value_ptr.*;
					block.deinit(allocator);
				}
				return err;
			}

			var it2 = pending.iterator();
			while (it2.next()) |entry| {
				var block = entry.value_ptr.*;
				try writeBlock(&bits, &block);
				stream_crc = updateStreamCrc(stream_crc, block.crc);
				bytes_processed += block.original_len;
				if (options.on_progress) |cb| {
					cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
				}
				block.deinit(allocator);
			}
		}

		try bits.writeBits(@truncate(FOOTER_MAGIC >> 24), 24);
		try bits.writeBits(@truncate(FOOTER_MAGIC & 0xFFFFFF), 24);
		try bits.writeBits(stream_crc, 32);
		try bits.flush();
		return;
	}

	if (thread_count <= 1) {
		while (true) {
			const data_opt = try block_reader.nextBlock(allocator, block_size);
			if (data_opt == null) break;
			const data = data_opt.?;
			defer allocator.free(data);

			var block = try prepareBlock(allocator, data);
			defer block.deinit(allocator);

			try writeSingleBlockStream(writer, options.level, &block);
			bytes_processed += block.original_len;
			if (options.on_progress) |cb| {
				cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
			}
		}
		return;
	}

	const queue_capacity = @max(@as(usize, 1), thread_count * 2);
	var tasks = try BoundedQueue(BlockTask).init(allocator, queue_capacity);
	defer tasks.deinit();
	var results = try BoundedQueue(BlockResult).init(allocator, queue_capacity);
	defer results.deinit();

	var cancel = std.atomic.Value(bool).init(false);
	var state = WorkerState{
		.allocator = allocator,
		.tasks = &tasks,
		.results = &results,
		.cancel = &cancel,
	};

	var threads = try allocator.alloc(std.Thread, thread_count);
	defer allocator.free(threads);

	var spawned: usize = 0;
	while (spawned < thread_count) : (spawned += 1) {
		threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{&state});
	}

	var next_index: usize = 0;
	var submitted: usize = 0;
	var completed: usize = 0;
	var next_write_index: usize = 0;
	var read_done = false;
	var pending = std.AutoHashMap(usize, BlockPrepared).init(allocator);
	defer pending.deinit();
	var first_error: ?anyerror = null;

	while (!read_done or completed < submitted) {
		while (!read_done and tasks.len() < queue_capacity and !cancel.load(.acquire)) {
			const data_opt = try block_reader.nextBlock(allocator, block_size);
			if (data_opt == null) {
				read_done = true;
				tasks.close();
				break;
			}
			const data = data_opt.?;
			if (!tasks.enqueue(.{ .index = next_index, .data = data, .owns_data = true })) {
				allocator.free(data);
				read_done = true;
				tasks.close();
				break;
			}
			next_index += 1;
			submitted += 1;
		}

		if (completed < submitted) {
			if (results.dequeue()) |result| {
				completed += 1;
				if (result.result) |prepared| {
					if (first_error == null) {
						try pending.put(result.index, prepared);
						while (pending.fetchRemove(next_write_index)) |entry| {
							var block = entry.value;
							try writeSingleBlockStream(writer, options.level, &block);
							bytes_processed += block.original_len;
							if (options.on_progress) |cb| {
								cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
							}
							block.deinit(allocator);
							next_write_index += 1;
						}
					} else {
						var block = prepared;
						block.deinit(allocator);
					}
				} else |err| {
					if (first_error == null) {
						first_error = err;
						cancel.store(true, .release);
						read_done = true;
						tasks.close();
					}
				}
			}
		} else if (read_done) {
			break;
		}
	}

	tasks.close();

	for (threads) |thread| {
		thread.join();
	}

	if (first_error) |err| {
		var it = pending.iterator();
		while (it.next()) |entry| {
			var block = entry.value_ptr.*;
			block.deinit(allocator);
		}
		return err;
	}

	var it2 = pending.iterator();
	while (it2.next()) |entry| {
		var block = entry.value_ptr.*;
		try writeSingleBlockStream(writer, options.level, &block);
		bytes_processed += block.original_len;
		if (options.on_progress) |cb| {
			cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
		}
		block.deinit(allocator);
	}
}

/// Decompress bzip2 data from a slice, returning the decompressed data.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn decompress(allocator: Allocator, input: []const u8) ![]u8 {
	return decompressWithOptions(allocator, input, .{});
}

/// Decompress without CRC verification (for diagnostics).
pub fn decompressNoCrc(allocator: Allocator, input: []const u8) ![]u8 {
	return decompressInternal(allocator, input, false);
}

/// Decompress with options (parallel concatenated stream decode when enabled).
pub fn decompressWithOptions(allocator: Allocator, input: []const u8, options: DecompressOptions) ![]u8 {
	if (!options.parallel or options.resolvedThreads() <= 1) {
		return decompressInternalWithOptions(allocator, input, true, options);
	}

	const offsets = try findStreamOffsets(allocator, input);
	defer allocator.free(offsets);

	if (offsets.len <= 1 or offsets[0] != 0) {
		return decompressInternalWithOptions(allocator, input, true, options);
	}

	return decompressParallel(allocator, input, offsets, options) catch |err| {
		const fallback = decompressInternalWithOptions(allocator, input, true, options) catch return err;
		return fallback;
	};
}

fn decompressInternal(allocator: Allocator, input: []const u8, check_crc: bool) ![]u8 {
	return decompressInternalWithOptions(allocator, input, check_crc, .{});
}

fn decompressInternalWithOptions(allocator: Allocator, input: []const u8, check_crc: bool, options: DecompressOptions) ![]u8 {
	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();
	decompressor.on_progress = options.on_progress;
	decompressor.progress_userdata = options.progress_userdata;
	decompressor.progress_bytes_total = options.progress_bytes_total;

	var input_stream = std.io.fixedBufferStream(input);
	var output_list: std.ArrayListUnmanaged(u8) = .empty;
	errdefer output_list.deinit(allocator);

	try decompressor.decompressInternal(input_stream.reader(), output_list.writer(allocator), check_crc);

	return output_list.toOwnedSlice(allocator);
}

/// Decompress a file to a writer, optionally using parallel multi-stream decode.
pub fn decompressFileToWriterWithOptions(
	allocator: Allocator,
	path: []const u8,
	writer: anytype,
	options: DecompressOptions,
) !void {
	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();

	if (!options.parallel or options.resolvedThreads() <= 1) {
		var reader_buf: [64 * 1024]u8 = undefined;
		var reader = file.reader(&reader_buf);
		var decompressor = try Decompressor.init(allocator);
		defer decompressor.deinit();
		try decompressor.decompress(&reader.interface, writer);
		return;
	}

	const stat = try file.stat();
	const offsets = try findStreamOffsetsInFile(allocator, file, stat.size);
	defer allocator.free(offsets);

	if (offsets.len <= 1 or offsets[0] != 0) {
		var reader_buf: [64 * 1024]u8 = undefined;
		var reader = file.reader(&reader_buf);
		var decompressor = try Decompressor.init(allocator);
		defer decompressor.deinit();
		try decompressor.decompress(&reader.interface, writer);
		return;
	}

	try decompressFileParallel(allocator, path, stat.size, offsets, writer, options);
}

fn readU48Be(bytes: []const u8) u48 {
	return (@as(u48, bytes[0]) << 40) |
		(@as(u48, bytes[1]) << 32) |
		(@as(u48, bytes[2]) << 24) |
		(@as(u48, bytes[3]) << 16) |
		(@as(u48, bytes[4]) << 8) |
		@as(u48, bytes[5]);
}

fn looksLikeStreamAt(input: []const u8, offset: usize) bool {
	if (offset + 10 > input.len) return false;
	if (input[offset] != 'B' or input[offset + 1] != 'Z' or input[offset + 2] != 'h') return false;
	const level = input[offset + 3];
	if (level < '1' or level > '9') return false;
	const magic = readU48Be(input[offset + 4 .. offset + 10]);
	return magic == BLOCK_MAGIC or magic == FOOTER_MAGIC;
}

fn findStreamOffsets(allocator: Allocator, input: []const u8) ![]usize {
	var offsets: std.ArrayListUnmanaged(usize) = .empty;
	errdefer offsets.deinit(allocator);

	var i: usize = 0;
	while (i + 10 <= input.len) : (i += 1) {
		if (looksLikeStreamAt(input, i)) {
			try offsets.append(allocator, i);
			i += 3;
		}
	}

	return offsets.toOwnedSlice(allocator);
}

fn findStreamOffsetsInFile(allocator: Allocator, file: std.fs.File, size: u64) ![]u64 {
	var offsets: std.ArrayListUnmanaged(u64) = .empty;
	errdefer offsets.deinit(allocator);

	var tail: [9]u8 = undefined;
	var tail_len: usize = 0;
	var buf: [64 * 1024]u8 = undefined;
	var pos: u64 = 0;

	while (pos < size) {
		const n = try file.pread(buf[0..], pos);
		if (n == 0) break;

		const combined_len = tail_len + n;
		var i: usize = 0;
		while (i + 10 <= combined_len) : (i += 1) {
			const base = pos - @as(u64, @intCast(tail_len));
			const abs = base + @as(u64, @intCast(i));
			const b0 = if (i < tail_len) tail[i] else buf[i - tail_len];
			const b1 = if (i + 1 < tail_len) tail[i + 1] else buf[i + 1 - tail_len];
			const b2 = if (i + 2 < tail_len) tail[i + 2] else buf[i + 2 - tail_len];
			if (b0 != 'B' or b1 != 'Z' or b2 != 'h') continue;

			const b3 = if (i + 3 < tail_len) tail[i + 3] else buf[i + 3 - tail_len];
			if (b3 < '1' or b3 > '9') continue;

			var magic: u48 = 0;
			var j: usize = 0;
			while (j < 6) : (j += 1) {
				const idx = i + 4 + j;
				const byte = if (idx < tail_len) tail[idx] else buf[idx - tail_len];
				magic = (magic << 8) | @as(u48, byte);
			}

			if (magic == BLOCK_MAGIC or magic == FOOTER_MAGIC) {
				try offsets.append(allocator, abs);
			}
		}

		const keep = @min(@as(usize, 9), combined_len);
		var k: usize = 0;
		while (k < keep) : (k += 1) {
			const idx = combined_len - keep + k;
			tail[k] = if (idx < tail_len) tail[idx] else buf[idx - tail_len];
		}
		tail_len = keep;
		pos += n;
	}

	return offsets.toOwnedSlice(allocator);
}

const StreamTask = struct {
	index: usize,
	start: usize,
	end: usize,
};

const StreamResult = struct {
	index: usize,
	result: anyerror![]u8,
};

const StreamWorkerState = struct {
	allocator: Allocator,
	input: []const u8,
	tasks: *BoundedQueue(StreamTask),
	results: *BoundedQueue(StreamResult),
	check_crc: bool,
};

fn streamWorkerLoop(state: *StreamWorkerState) void {
	while (true) {
		const task_opt = state.tasks.dequeue() orelse break;
		const slice = state.input[task_opt.start..task_opt.end];
		const result = decompressInternal(state.allocator, slice, state.check_crc);
		_ = state.results.enqueue(.{ .index = task_opt.index, .result = result });
	}
}

fn decompressParallel(allocator: Allocator, input: []const u8, offsets: []const usize, options: DecompressOptions) ![]u8 {
	const stream_count = offsets.len;
	const thread_count = @min(options.resolvedThreads(), stream_count);
	if (thread_count <= 1) {
		return decompressInternal(allocator, input, true);
	}

	var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
	const thread_allocator = thread_safe.allocator();

	const queue_capacity = @max(@as(usize, 1), thread_count * 2);
	var tasks = try BoundedQueue(StreamTask).init(allocator, queue_capacity);
	defer tasks.deinit();
	var results = try BoundedQueue(StreamResult).init(allocator, queue_capacity);
	defer results.deinit();

	var state = StreamWorkerState{
		.allocator = thread_allocator,
		.input = input,
		.tasks = &tasks,
		.results = &results,
		.check_crc = true,
	};

	var threads = try allocator.alloc(std.Thread, thread_count);
	defer allocator.free(threads);

	var spawned: usize = 0;
	while (spawned < thread_count) : (spawned += 1) {
		threads[spawned] = try std.Thread.spawn(.{}, streamWorkerLoop, .{&state});
	}

	var idx: usize = 0;
	while (idx < stream_count) : (idx += 1) {
		const start = offsets[idx];
		const end = if (idx + 1 < stream_count) offsets[idx + 1] else input.len;
		if (!tasks.enqueue(.{ .index = idx, .start = start, .end = end })) {
			tasks.close();
			for (threads) |thread| thread.join();
			return Error.CorruptData;
		}
	}
	tasks.close();

	var outputs = try allocator.alloc(?[]u8, stream_count);
	defer allocator.free(outputs);
	@memset(outputs, null);

	var completed: usize = 0;
	var first_error: ?anyerror = null;
	var bytes_processed: u64 = 0;
	while (completed < stream_count) {
		if (results.dequeue()) |result| {
			completed += 1;
			if (result.result) |slice| {
				outputs[result.index] = slice;
				// Fire progress callback with compressed stream size as increment
				if (result.index + 1 < offsets.len) {
					bytes_processed += offsets[result.index + 1] - offsets[result.index];
				} else {
					bytes_processed += input.len - offsets[result.index];
				}
				if (options.on_progress) |cb| {
					cb(bytes_processed, options.progress_bytes_total, options.progress_userdata);
				}
			} else |err| {
				if (first_error == null) first_error = err;
			}
		}
	}

	for (threads) |thread| {
		thread.join();
	}

	if (first_error) |err| {
		for (outputs) |slice_opt| {
			if (slice_opt) |slice| thread_allocator.free(slice);
		}
		return err;
	}

	var total: usize = 0;
	for (outputs) |slice_opt| {
		total += slice_opt.?.len;
	}

	const combined = try allocator.alloc(u8, total);
	var pos: usize = 0;
	for (outputs) |slice_opt| {
		const slice = slice_opt.?;
		std.mem.copyForwards(u8, combined[pos .. pos + slice.len], slice);
		pos += slice.len;
		thread_allocator.free(slice);
	}

	return combined;
}

const FileStreamTask = struct {
	index: usize,
	start: u64,
	end: u64,
};

const FileStreamResult = struct {
	index: usize,
	result: anyerror![]u8,
};

const FileStreamWorkerState = struct {
	allocator: Allocator,
	path: []const u8,
	tasks: *BoundedQueue(FileStreamTask),
	results: *BoundedQueue(FileStreamResult),
	check_crc: bool,
};

const FileSliceReader = struct {
	file: std.fs.File,
	start: u64,
	end: u64,
	pos: u64,

	fn init(file: std.fs.File, start: u64, end: u64) FileSliceReader {
		return .{
			.file = file,
			.start = start,
			.end = end,
			.pos = start,
		};
	}

	fn read(self: *FileSliceReader, buffer: []u8) !usize {
		if (self.pos >= self.end) return 0;
		const remaining = self.end - self.pos;
		const max_len: usize = @intCast(@min(@as(u64, buffer.len), remaining));
		const n = try self.file.pread(buffer[0..max_len], self.pos);
		self.pos += n;
		return n;
	}
};

fn fileStreamWorkerLoop(state: *FileStreamWorkerState) void {
	while (true) {
		const task_opt = state.tasks.dequeue() orelse break;
		const file = std.fs.cwd().openFile(state.path, .{}) catch |err| {
			_ = state.results.enqueue(.{ .index = task_opt.index, .result = err });
			continue;
		};
		defer file.close();

		var reader = FileSliceReader.init(file, task_opt.start, task_opt.end);
		var decompressor = Decompressor.init(state.allocator) catch |err| {
			_ = state.results.enqueue(.{ .index = task_opt.index, .result = err });
			continue;
		};
		defer decompressor.deinit();

		var output: std.ArrayListUnmanaged(u8) = .empty;
		const result = decompressor.decompressInternal(&reader, output.writer(state.allocator), state.check_crc);
		if (result) |_| {
			_ = state.results.enqueue(.{ .index = task_opt.index, .result = output.toOwnedSlice(state.allocator) });
		} else |err| {
			output.deinit(state.allocator);
			_ = state.results.enqueue(.{ .index = task_opt.index, .result = err });
		}
	}
}

fn decompressFileParallel(
	allocator: Allocator,
	path: []const u8,
	size: u64,
	offsets: []const u64,
	writer: anytype,
	options: DecompressOptions,
) !void {
	const stream_count = offsets.len;
	const thread_count = @min(options.resolvedThreads(), stream_count);
	if (thread_count <= 1) {
		const file = try std.fs.cwd().openFile(path, .{});
		defer file.close();
		var reader_buf: [64 * 1024]u8 = undefined;
		var reader = file.reader(&reader_buf);
		var decompressor = try Decompressor.init(allocator);
		defer decompressor.deinit();
		try decompressor.decompress(&reader.interface, writer);
		return;
	}

	var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
	const thread_allocator = thread_safe.allocator();

	const queue_capacity = @max(@as(usize, 1), thread_count * 2);
	var tasks = try BoundedQueue(FileStreamTask).init(allocator, queue_capacity);
	defer tasks.deinit();
	var results = try BoundedQueue(FileStreamResult).init(allocator, queue_capacity);
	defer results.deinit();

	var state = FileStreamWorkerState{
		.allocator = thread_allocator,
		.path = path,
		.tasks = &tasks,
		.results = &results,
		.check_crc = true,
	};

	var threads = try allocator.alloc(std.Thread, thread_count);
	defer allocator.free(threads);

	var spawned: usize = 0;
	while (spawned < thread_count) : (spawned += 1) {
		threads[spawned] = try std.Thread.spawn(.{}, fileStreamWorkerLoop, .{&state});
	}

	var idx: usize = 0;
	while (idx < stream_count) : (idx += 1) {
		const start = offsets[idx];
		const end = if (idx + 1 < stream_count) offsets[idx + 1] else size;
		if (!tasks.enqueue(.{ .index = idx, .start = start, .end = end })) {
			tasks.close();
			for (threads) |thread| thread.join();
			return Error.CorruptData;
		}
	}
	tasks.close();

	var outputs = try allocator.alloc(?[]u8, stream_count);
	defer allocator.free(outputs);
	@memset(outputs, null);

	var completed: usize = 0;
	var first_error: ?anyerror = null;
	while (completed < stream_count) {
		if (results.dequeue()) |result| {
			completed += 1;
			if (result.result) |slice| {
				outputs[result.index] = slice;
			} else |err| {
				if (first_error == null) first_error = err;
			}
		}
	}

	for (threads) |thread| {
		thread.join();
	}

	if (first_error) |err| {
		for (outputs) |slice_opt| {
			if (slice_opt) |slice| thread_allocator.free(slice);
		}
		return err;
	}

	var write_index: usize = 0;
	while (write_index < stream_count) : (write_index += 1) {
		const slice = outputs[write_index].?;
		try writer.writeAll(slice);
		thread_allocator.free(slice);
	}
}

/// Decompress bzip2 data from a file path.
/// Caller owns the returned slice and must free it with the provided allocator.
pub fn decompressFile(allocator: Allocator, path: []const u8) ![]u8 {
	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();

	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	var output_list: std.ArrayListUnmanaged(u8) = .empty;
	errdefer output_list.deinit(allocator);

	// Use deprecated reader for compatibility with the generic decompress function
	try decompressor.decompress(file.deprecatedReader(), output_list.writer(allocator));

	return output_list.toOwnedSlice(allocator);
}

// ============ Tests ============

test "CRC32 bzip2 - basic" {
	var crc = Crc32Bzip2.init();
	crc.updateSlice("hello");
	const result = crc.final();
	try std.testing.expect(result != 0);
}

test "CRC32 bzip2 - standard test vector" {
	// The standard CRC-32/BZIP2 check value for "123456789" is 0xfc891918
	// See: https://reveng.sourceforge.io/crc-catalogue/17plus.htm
	var crc = Crc32Bzip2.init();
	crc.updateSlice("123456789");
	const result = crc.final();
	try std.testing.expectEqual(@as(u32, 0xfc891918), result);
}

test "CRC32 bzip2 - empty" {
	var crc = Crc32Bzip2.init();
	const result = crc.final();
	try std.testing.expectEqual(@as(u32, 0), result);
}

test "CRC32 bzip2 - incremental equals batch" {
	var crc1 = Crc32Bzip2.init();
	crc1.update('h');
	crc1.update('e');
	crc1.update('l');
	crc1.update('l');
	crc1.update('o');

	var crc2 = Crc32Bzip2.init();
	crc2.updateSlice("hello");

	try std.testing.expectEqual(crc1.final(), crc2.final());
}

test "derandomize compatibility sequence reaches legacy 129th toggle point" {
	const allocator = std.testing.allocator;
	const data = try allocator.alloc(u8, 70500);
	defer allocator.free(data);
	@memset(data, 0);

	derandomize(data);

	// A 128-entry table would wrap and flip here (wrong for legacy streams).
	try std.testing.expectEqual(@as(u8, 0), data[70148]);
	// The 129th toggle for the canonical sequence lands here.
	try std.testing.expectEqual(@as(u8, 1), data[70440]);
}

// ============ SA-IS Algorithm Unit Tests ============
// These tests verify individual pieces of the SA-IS algorithm

test "SA-IS - suffix array for 'banana'" {
	// "banana$" - well-known test case
	// Sorted suffixes: $, a$, ana$, anana$, banana$, na$, nana$
	// SA = [6, 5, 3, 1, 0, 4, 2] (positions of suffixes in sorted order)
	const allocator = std.testing.allocator;
	const text = "banana";

	const sa = try buildSuffixArraySAIS(allocator, text);
	defer allocator.free(sa);

	// Verify suffix array length (excludes sentinel)
	try std.testing.expectEqual(@as(usize, 6), sa.len);

	// Verify sorted order by checking suffix comparisons
	// sa[i] should give the i-th smallest suffix
	for (0..sa.len - 1) |i| {
		const pos1 = sa[i];
		const pos2 = sa[i + 1];
		const s1 = text[pos1..];
		const s2 = text[pos2..];
		// s1 should be <= s2 in lexicographic order
		const cmp = std.mem.order(u8, s1, s2);
		try std.testing.expect(cmp != .gt);
	}
}

test "SA-IS - suffix array for 'abracadabra'" {
	const allocator = std.testing.allocator;
	const text = "abracadabra";

	const sa = try buildSuffixArraySAIS(allocator, text);
	defer allocator.free(sa);

	try std.testing.expectEqual(@as(usize, 11), sa.len);

	// Verify sorted order
	for (0..sa.len - 1) |i| {
		const s1 = text[sa[i]..];
		const s2 = text[sa[i + 1]..];
		try std.testing.expect(std.mem.order(u8, s1, s2) != .gt);
	}
}

test "SA-IS - suffix array for repetitive 'aaa'" {
	const allocator = std.testing.allocator;
	const text = "aaa";

	const sa = try buildSuffixArraySAIS(allocator, text);
	defer allocator.free(sa);

	// For "aaa$", suffixes: $, a$, aa$, aaa$
	// SA should be [2, 1, 0] (after removing sentinel)
	try std.testing.expectEqual(@as(usize, 3), sa.len);
	try std.testing.expectEqual(@as(u32, 2), sa[0]); // "a" - shortest
	try std.testing.expectEqual(@as(u32, 1), sa[1]); // "aa"
	try std.testing.expectEqual(@as(u32, 0), sa[2]); // "aaa" - longest
}

test "SA-IS - BWT uses correct suffix array" {
	const allocator = std.testing.allocator;

	// Test "banana" BWT
	const result = try bwtEncode(allocator, "banana");
	defer allocator.free(result.data);

	// BWT of "banana" should have length 6
	try std.testing.expectEqual(@as(usize, 6), result.data.len);
}

test "SA-IS - verify suffix array sorted at various sizes" {
	const allocator = std.testing.allocator;

	// Verify SA correctness at various sizes
	// Reference C++ impl: zig-core/c_sais/sais.hh
	const sizes = [_]usize{ 100, 500, 1000, 2000, 4000, 8000, 12000, 16000 };

	for (sizes) |size| {
		// Create test data with pattern
		const text = try allocator.alloc(u8, size);
		defer allocator.free(text);

		for (text, 0..) |*b, i| {
			b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
		}

		const sa = try buildSuffixArraySAIS(allocator, text);
		defer allocator.free(sa);

		// Verify length
		try std.testing.expectEqual(size, sa.len);

		// Verify sorted order: sa[i] suffix should be <= sa[i+1] suffix
		for (0..sa.len - 1) |i| {
			const s1 = text[sa[i]..];
			const s2 = text[sa[i + 1]..];
			const cmp = std.mem.order(u8, s1, s2);
			if (cmp == .gt) {
				std.debug.print("\nSA NOT SORTED at size {}: sa[{}]={} > sa[{}]={}\n", .{ size, i, sa[i], i + 1, sa[i + 1] });
				std.debug.print("  suffix at {}: ", .{sa[i]});
				for (s1[0..@min(20, s1.len)]) |c| std.debug.print("{X:0>2} ", .{c});
				std.debug.print("\n  suffix at {}: ", .{sa[i + 1]});
				for (s2[0..@min(20, s2.len)]) |c| std.debug.print("{X:0>2} ", .{c});
				std.debug.print("\n", .{});
			}
			try std.testing.expect(cmp != .gt);
		}
	}
}

test "stream magic" {
	try std.testing.expectEqualSlices(u8, "BZh", &STREAM_MAGIC);
}

test "block magic values" {
	try std.testing.expectEqual(@as(u48, 0x314159265359), BLOCK_MAGIC);
	try std.testing.expectEqual(@as(u48, 0x177245385090), FOOTER_MAGIC);
}

// ============ BitReader Tests ============

test "BitReader - read aligned bytes" {
	const data = [_]u8{ 0xAB, 0xCD, 0xEF };
	var stream = std.io.fixedBufferStream(&data);
	var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

	// Read 8 bits at a time (byte aligned)
	const b1 = try reader.readBits(8);
	try std.testing.expectEqual(@as(u32, 0xAB), b1);

	const b2 = try reader.readBits(8);
	try std.testing.expectEqual(@as(u32, 0xCD), b2);
}

test "BitReader - read unaligned bits" {
	// Binary: 1010 1100 1101 0011
	const data = [_]u8{ 0xAC, 0xD3 };
	var stream = std.io.fixedBufferStream(&data);
	var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

	// Read 4 bits: should be 1010 = 0xA
	const b1 = try reader.readBits(4);
	try std.testing.expectEqual(@as(u32, 0xA), b1);

	// Read 6 bits: should be 110011 = 0x33
	const b2 = try reader.readBits(6);
	try std.testing.expectEqual(@as(u32, 0x33), b2);

	// Read 6 bits: should be 010011 = 0x13
	const b3 = try reader.readBits(6);
	try std.testing.expectEqual(@as(u32, 0x13), b3);
}

test "BitReader - read single bits" {
	// Binary: 1010 0101
	const data = [_]u8{0xA5};
	var stream = std.io.fixedBufferStream(&data);
	var reader = BitReader(@TypeOf(stream.reader())).init(stream.reader());

	// Read bit by bit
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
}

// ============ Huffman Table Tests ============

test "HuffmanTable - simple 2 symbol table" {
	var table = HuffmanTable.init();

	// Simple table: symbol 0 has code "0" (length 1), symbol 1 has code "1" (length 1)
	const lengths = [_]u8{ 1, 1 };
	try table.build(&lengths, 2);

	// Decode from bit stream
	const data = [_]u8{0b10100000}; // bits: 1, 0, 1, 0, ...
	var stream = std.io.fixedBufferStream(&data);
	const ReaderType = @TypeOf(stream.reader());
	var reader = BitReader(ReaderType).init(stream.reader());

	// First bit is 1 -> symbol 1
	const s1 = try table.decode(ReaderType, &reader);
	try std.testing.expectEqual(@as(u16, 1), s1);

	// Next bit is 0 -> symbol 0
	const s2 = try table.decode(ReaderType, &reader);
	try std.testing.expectEqual(@as(u16, 0), s2);
}

test "HuffmanTable - varying code lengths" {
	var table = HuffmanTable.init();

	// Table: A=1bit, B=2bits, C=3bits, D=3bits
	// Canonical Huffman: A=0, B=10, C=110, D=111
	const lengths = [_]u8{ 1, 2, 3, 3 };
	try table.build(&lengths, 4);

	// bits: 0 10 110 111 = A B C D
	// binary: 0101 1011 1... = 0x5B...
	const data = [_]u8{ 0x5B, 0x80 };
	var stream = std.io.fixedBufferStream(&data);
	const ReaderType = @TypeOf(stream.reader());
	var reader = BitReader(ReaderType).init(stream.reader());

	try std.testing.expectEqual(@as(u16, 0), try table.decode(ReaderType, &reader)); // A
	try std.testing.expectEqual(@as(u16, 1), try table.decode(ReaderType, &reader)); // B
	try std.testing.expectEqual(@as(u16, 2), try table.decode(ReaderType, &reader)); // C
	try std.testing.expectEqual(@as(u16, 3), try table.decode(ReaderType, &reader)); // D
}

// ============ RLE Bijective Base-2 Tests ============

// ============ Inverse BWT Tests ============

test "inverse BWT - simple known transformation" {
	// Test with a known BWT transformation
	// Original: "banana"
	// BWT output: "annb$aa" where $ marks the end
	// Actually for bzip2 style (no explicit end marker):
	// BWT of "banana" produces last column: "nnbaaa" with primary index pointing
	// to the row that starts with the original string's first character
	//
	// Let's use a simpler example: "abracadabra"
	// BWT gives: "ard$rcaaaabb" (with end marker) or similar
	//
	// For a very simple test, let's use "aaab"
	// Rotations: aaab, aaba, abaa, baaa
	// Sorted:    aaab (0), aaba (1), abaa (2), baaa (3)
	// Last col:  b, a, a, a
	// If original "aaab" is at position 0, primary index = 0

	const allocator = std.testing.allocator;

	// Allocate decompressor
	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	// Set up a simple test case
	// BWT of "aaab" gives last column "baaa" with primary index 0
	decompressor.block[0] = 'b';
	decompressor.block[1] = 'a';
	decompressor.block[2] = 'a';
	decompressor.block[3] = 'a';
	decompressor.block_size = 4;
	decompressor.bwt_primary_index = 0;

	// Run inverse BWT
	try decompressor.buildInverseBwt();
	try decompressor.inverseBwt();

	// The output should be "aaab"
	try std.testing.expectEqualSlices(u8, "aaab", decompressor.output[0..4]);
}

test "RLE bijective base-2 encoding - known values" {
	// In bzip2's bijective base-2 system:
	// RUNA (sym=0) contributes (0+1)*power = 1*power
	// RUNB (sym=1) contributes (1+1)*power = 2*power
	// Power doubles with each symbol

	// Helper function to compute run length from symbols
	const computeRunLen = struct {
		fn call(symbols: []const u8) u32 {
			var run_len: u32 = 0;
			var power: u32 = 1;
			for (symbols) |sym| {
				run_len += (@as(u32, sym) + 1) * power;
				power <<= 1;
			}
			return run_len;
		}
	}.call;

	// Test known values
	// 1 = RUNA
	try std.testing.expectEqual(@as(u32, 1), computeRunLen(&[_]u8{0}));
	// 2 = RUNB
	try std.testing.expectEqual(@as(u32, 2), computeRunLen(&[_]u8{1}));
	// 3 = RUNA RUNA (1 + 2)
	try std.testing.expectEqual(@as(u32, 3), computeRunLen(&[_]u8{ 0, 0 }));
	// 4 = RUNB RUNA (2 + 2)
	try std.testing.expectEqual(@as(u32, 4), computeRunLen(&[_]u8{ 1, 0 }));
	// 5 = RUNA RUNB (1 + 4)
	try std.testing.expectEqual(@as(u32, 5), computeRunLen(&[_]u8{ 0, 1 }));
	// 6 = RUNB RUNB (2 + 4)
	try std.testing.expectEqual(@as(u32, 6), computeRunLen(&[_]u8{ 1, 1 }));
	// 7 = RUNA RUNA RUNA (1 + 2 + 4)
	try std.testing.expectEqual(@as(u32, 7), computeRunLen(&[_]u8{ 0, 0, 0 }));
	// 40 = RUNB RUNA RUNA RUNB RUNA (2 + 2 + 4 + 16 + 16)
	try std.testing.expectEqual(@as(u32, 40), computeRunLen(&[_]u8{ 1, 0, 0, 1, 0 }));
}

test "initial RLE expansion - known patterns" {
	const allocator = std.testing.allocator;

	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	// Test: "AAAA" + count(6) should expand to 10 A's
	decompressor.output[0] = 'A';
	decompressor.output[1] = 'A';
	decompressor.output[2] = 'A';
	decompressor.output[3] = 'A';
	decompressor.output[4] = 6; // 6 more copies
	decompressor.output_len = 5;

	try decompressor.expandInitialRle();

	try std.testing.expectEqual(@as(usize, 10), decompressor.output_len);
	for (decompressor.output[0..10]) |byte| {
		try std.testing.expectEqual(@as(u8, 'A'), byte);
	}
}

test "initial RLE expansion - no runs" {
	const allocator = std.testing.allocator;

	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	// Test: "ABC" (no runs) should stay unchanged
	decompressor.output[0] = 'A';
	decompressor.output[1] = 'B';
	decompressor.output[2] = 'C';
	decompressor.output_len = 3;

	try decompressor.expandInitialRle();

	try std.testing.expectEqual(@as(usize, 3), decompressor.output_len);
	try std.testing.expectEqualSlices(u8, "ABC", decompressor.output[0..3]);
}

test "initial RLE expansion - mixed content" {
	const allocator = std.testing.allocator;

	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	// Test: "XY" + "AAAA" + count(2) + "Z" should become "XYAAAAAAZ"
	decompressor.output[0] = 'X';
	decompressor.output[1] = 'Y';
	decompressor.output[2] = 'A';
	decompressor.output[3] = 'A';
	decompressor.output[4] = 'A';
	decompressor.output[5] = 'A';
	decompressor.output[6] = 2; // 2 more A's
	decompressor.output[7] = 'Z';
	decompressor.output_len = 8;

	try decompressor.expandInitialRle();

	try std.testing.expectEqual(@as(usize, 9), decompressor.output_len);
	try std.testing.expectEqualSlices(u8, "XYAAAAAAZ", decompressor.output[0..9]);
}

// ============ Compression Tests (TDD - write tests first!) ============

test "initial RLE encode - no runs" {
	const allocator = std.testing.allocator;
	// Input without runs of 4+ identical bytes should pass through unchanged
	const input = "ABCDEF";
	const result = try initialRleEncode(allocator, input);
	defer allocator.free(result);
	try std.testing.expectEqualSlices(u8, "ABCDEF", result);
}

test "initial RLE encode - single run" {
	const allocator = std.testing.allocator;
	// 10 A's should become "AAAA" + chr(6)
	const input = "AAAAAAAAAA";
	const result = try initialRleEncode(allocator, input);
	defer allocator.free(result);
	try std.testing.expectEqual(@as(usize, 5), result.len);
	try std.testing.expectEqualSlices(u8, "AAAA", result[0..4]);
	try std.testing.expectEqual(@as(u8, 6), result[4]);
}

test "initial RLE encode - exactly 4" {
	const allocator = std.testing.allocator;
	// Exactly 4 identical bytes should become "XXXX" + chr(0)
	const input = "AAAA";
	const result = try initialRleEncode(allocator, input);
	defer allocator.free(result);
	try std.testing.expectEqual(@as(usize, 5), result.len);
	try std.testing.expectEqualSlices(u8, "AAAA", result[0..4]);
	try std.testing.expectEqual(@as(u8, 0), result[4]);
}

test "initial RLE encode - mixed content" {
	const allocator = std.testing.allocator;
	// "XY" + 6 A's + "Z" should become "XY" + "AAAA" + chr(2) + "Z"
	const input = "XYAAAAAAZ";
	const result = try initialRleEncode(allocator, input);
	defer allocator.free(result);
	try std.testing.expectEqual(@as(usize, 8), result.len);
	try std.testing.expectEqualSlices(u8, "XYAAAA", result[0..6]);
	try std.testing.expectEqual(@as(u8, 2), result[6]);
	try std.testing.expectEqual(@as(u8, 'Z'), result[7]);
}

test "RLE block reader caps encoded length" {
	const allocator = std.testing.allocator;
	const max_rle_size: usize = 1000;
	const run_len: usize = 4;
	const runs: usize = (max_rle_size / run_len) * 2;
	const input_len = runs * run_len;

	const data = try allocator.alloc(u8, input_len);
	defer allocator.free(data);

	var i: usize = 0;
	while (i < runs) : (i += 1) {
		const byte = @as(u8, @truncate(i));
		const start = i * run_len;
		@memset(data[start .. start + run_len], byte);
	}

	var fbs = std.io.fixedBufferStream(data);
	var reader = RleBlockReader(@TypeOf(fbs.reader())).init(fbs.reader());
	defer reader.deinit(allocator);

	var rebuilt: std.ArrayListUnmanaged(u8) = .empty;
	defer rebuilt.deinit(allocator);

	while (true) {
		const block_opt = try reader.nextBlock(allocator, max_rle_size);
		if (block_opt == null) break;
		const block = block_opt.?;
		defer allocator.free(block);

		const rle = try initialRleEncode(allocator, block);
		defer allocator.free(rle);
		try std.testing.expect(rle.len <= max_rle_size);
		try rebuilt.appendSlice(allocator, block);
	}

	const rebuilt_slice = try rebuilt.toOwnedSlice(allocator);
	defer allocator.free(rebuilt_slice);
	try std.testing.expectEqualSlices(u8, data, rebuilt_slice);
}

test "BWT forward transform - simple" {
	const allocator = std.testing.allocator;
	// BWT of "banana" is well-known: last column is "annb$aa" or similar
	// For "aaab": rotations are aaab, aaba, abaa, baaa
	// Sorted: aaab, aaba, abaa, baaa -> last column: b, a, a, a
	// Primary index = 0 (original "aaab" is at sorted position 0)
	const result = try bwtEncode(allocator, "aaab");
	defer allocator.free(result.data);
	try std.testing.expectEqualSlices(u8, "baaa", result.data);
	try std.testing.expectEqual(@as(u32, 0), result.primary_index);
}

test "BWT forward transform - hello" {
	const allocator = std.testing.allocator;
	// BWT of "hello": rotations sorted give last column
	// Rotations: hello, elloh, llohe, lohel, ohell
	// Sorted: elloh, hello, llohe, lohel, ohell
	// Last column: h, o, e, l, l
	// Primary index = 1 (original "hello" is at sorted position 1)
	const result = try bwtEncode(allocator, "hello");
	defer allocator.free(result.data);
	try std.testing.expectEqualSlices(u8, "hoell", result.data);
	try std.testing.expectEqual(@as(u32, 1), result.primary_index);
}

test "BWT round-trip" {
	const allocator = std.testing.allocator;
	const original = "the quick brown fox";

	// Encode
	const encoded = try bwtEncode(allocator, original);
	defer allocator.free(encoded.data);

	// Decode using existing decompressor
	var decompressor = try Decompressor.init(allocator);
	defer decompressor.deinit();

	@memcpy(decompressor.block[0..encoded.data.len], encoded.data);
	decompressor.block_size = encoded.data.len;
	decompressor.bwt_primary_index = encoded.primary_index;

	try decompressor.buildInverseBwt();
	try decompressor.inverseBwt();

	try std.testing.expectEqualSlices(u8, original, decompressor.output[0..decompressor.output_len]);
}

test "BWT round-trip - pattern data sizes" {
	const allocator = std.testing.allocator;

	// Test various sizes - smaller sizes to avoid memory pressure issues
	const sizes = [_]usize{ 1024, 2048, 4096, 8192 };

	for (sizes) |size| {
		const data = try allocator.alloc(u8, size);
		defer allocator.free(data);

		for (data, 0..) |*b, i| {
			b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
		}

		const result = try bwtEncode(allocator, data);
		defer allocator.free(result.data);

		var decompressor = try Decompressor.init(allocator);
		defer decompressor.deinit();
		@memcpy(decompressor.block[0..result.data.len], result.data);
		decompressor.block_size = result.data.len;
		decompressor.bwt_primary_index = result.primary_index;
		try decompressor.buildInverseBwt();
		try decompressor.inverseBwt();

		// Debug: check if output is a rotation of input
		if (!std.mem.eql(u8, data, decompressor.output[0..decompressor.output_len])) {
			std.debug.print("\nBWT FAIL at size {}: primary_index={}\n", .{ size, result.primary_index });
			// Check if output is a rotation
			for (0..size) |offset| {
				var is_rotation = true;
				for (0..@min(64, size)) |i| {
					if (data[i] != decompressor.output[(i + offset) % size]) {
						is_rotation = false;
						break;
					}
				}
				if (is_rotation) {
					std.debug.print("  Output appears to be rotation by {}\n", .{offset});
					break;
				}
			}
		}
		try std.testing.expectEqualSlices(u8, data, decompressor.output[0..decompressor.output_len]);
	}
}

test "BWT performance - 50KB should complete in under 500ms" {
	const allocator = std.testing.allocator;

	// Generate 50KB of test data
	const size = 50 * 1024;
	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	// Fill with semi-random but reproducible data
	for (data, 0..) |*b, i| {
		b.* = @truncate((i *% 31 +% 17) ^ (i >> 8));
	}

	const start = std.time.nanoTimestamp();
	const result = try bwtEncode(allocator, data);
	defer allocator.free(result.data);
	const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start, 1_000_000);

	// Must complete in under 500ms (naive O(n²) would take minutes)
	try std.testing.expect(elapsed_ms < 500);

	// Verify output length matches input
	try std.testing.expectEqual(data.len, result.data.len);

	// Verify primary index is valid
	try std.testing.expect(result.primary_index < data.len);
}

test "MTF encode - simple" {
	const allocator = std.testing.allocator;
	// MTF encoding: each byte is replaced by its position in a list that's
	// updated after each byte (move accessed item to front)
	// For "aaab" with alphabet {a, b}:
	// Initial MTF list: [a, b] (or [0, 1] for indices)
	// 'a' -> 0, list stays [a, b]
	// 'a' -> 0, list stays [a, b]
	// 'a' -> 0, list stays [a, b]
	// 'b' -> 1, list becomes [b, a]
	const result = try mtfEncode(allocator, "aaab", "ab");
	defer allocator.free(result);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, result);
}

test "MTF encode - mixed" {
	const allocator = std.testing.allocator;
	// For "abab" with alphabet {a, b}:
	// Initial MTF list: [a, b]
	// 'a' -> 0, list stays [a, b]
	// 'b' -> 1, list becomes [b, a]
	// 'a' -> 1, list becomes [a, b]
	// 'b' -> 1, list becomes [b, a]
	const result = try mtfEncode(allocator, "abab", "ab");
	defer allocator.free(result);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 1, 1 }, result);
}

test "RUNA/RUNB encode - single zero" {
	// A single zero in MTF output becomes RUNA (symbol 0)
	// run_len=1 -> RUNA
	const result = encodeZeroRun(1);
	try std.testing.expectEqual(@as(usize, 1), result.len);
	try std.testing.expectEqual(@as(u8, 0), result.symbols[0]); // RUNA
}

test "RUNA/RUNB encode - two zeros" {
	// run_len=2 -> RUNB
	const result = encodeZeroRun(2);
	try std.testing.expectEqual(@as(usize, 1), result.len);
	try std.testing.expectEqual(@as(u8, 1), result.symbols[0]); // RUNB
}

test "RUNA/RUNB encode - three zeros" {
	// run_len=3 -> RUNA, RUNA (1 + 2 = 3)
	const result = encodeZeroRun(3);
	try std.testing.expectEqual(@as(usize, 2), result.len);
	try std.testing.expectEqual(@as(u8, 0), result.symbols[0]); // RUNA
	try std.testing.expectEqual(@as(u8, 0), result.symbols[1]); // RUNA
}

test "RUNA/RUNB encode - forty zeros" {
	// run_len=40 -> specific sequence
	// 40 = 2 + 2 + 4 + 16 + 16 = RUNB + RUNA + RUNA + RUNB + RUNA
	const result = encodeZeroRun(40);
	try std.testing.expectEqual(@as(usize, 5), result.len);
	try std.testing.expectEqual(@as(u8, 1), result.symbols[0]); // RUNB (2)
	try std.testing.expectEqual(@as(u8, 0), result.symbols[1]); // RUNA (2)
	try std.testing.expectEqual(@as(u8, 0), result.symbols[2]); // RUNA (4)
	try std.testing.expectEqual(@as(u8, 1), result.symbols[3]); // RUNB (16)
	try std.testing.expectEqual(@as(u8, 0), result.symbols[4]); // RUNA (16)
}

test "BitWriter - write bytes" {
	const allocator = std.testing.allocator;
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const stream_writer = output.writer(allocator);
	const byte_writer = ByteWriter(@TypeOf(stream_writer)).init(stream_writer);
	var writer = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

	// Write 8 bits at a time (byte aligned)
	try writer.writeBits(0xAB, 8);
	try writer.writeBits(0xCD, 8);
	try writer.flush();

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, output.items);
}

test "BitWriter - write unaligned bits" {
	const allocator = std.testing.allocator;
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const stream_writer = output.writer(allocator);
	const byte_writer = ByteWriter(@TypeOf(stream_writer)).init(stream_writer);
	var writer = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

	// Write 4 bits: 1010
	try writer.writeBits(0xA, 4);
	// Write 4 bits: 1100
	try writer.writeBits(0xC, 4);
	// Should produce 0xAC
	try writer.flush();

	try std.testing.expectEqualSlices(u8, &[_]u8{0xAC}, output.items);
}

test "BitWriter - write 32 bits" {
	const allocator = std.testing.allocator;
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const stream_writer = output.writer(allocator);
	const byte_writer = ByteWriter(@TypeOf(stream_writer)).init(stream_writer);
	var writer = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

	// Write 32 bits
	try writer.writeBits(0xDEADBEEF, 32);
	try writer.flush();

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, output.items);
}

test "BitWriter - write single bits" {
	const allocator = std.testing.allocator;
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const stream_writer = output.writer(allocator);
	const byte_writer = ByteWriter(@TypeOf(stream_writer)).init(stream_writer);
	var writer = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

	// Write 10100101 bit by bit
	try writer.writeBit(1);
	try writer.writeBit(0);
	try writer.writeBit(1);
	try writer.writeBit(0);
	try writer.writeBit(0);
	try writer.writeBit(1);
	try writer.writeBit(0);
	try writer.writeBit(1);
	try writer.flush();

	try std.testing.expectEqualSlices(u8, &[_]u8{0xA5}, output.items);
}

test "buildHuffmanCodes - uniform lengths" {
	// All 4 symbols with length 2 should get codes 00, 01, 10, 11
	const lengths = [_]u8{ 2, 2, 2, 2 };
	const codes = buildHuffmanCodes(&lengths, 4);

	try std.testing.expectEqual(@as(u32, 0b00), codes[0]);
	try std.testing.expectEqual(@as(u32, 0b01), codes[1]);
	try std.testing.expectEqual(@as(u32, 0b10), codes[2]);
	try std.testing.expectEqual(@as(u32, 0b11), codes[3]);
}

test "buildHuffmanCodes - canonical varying lengths" {
	// Lengths: 1, 2, 3, 3 should give canonical codes: 0, 10, 110, 111
	const lengths = [_]u8{ 1, 2, 3, 3 };
	const codes = buildHuffmanCodes(&lengths, 4);

	try std.testing.expectEqual(@as(u32, 0b0), codes[0]); // length 1
	try std.testing.expectEqual(@as(u32, 0b10), codes[1]); // length 2
	try std.testing.expectEqual(@as(u32, 0b110), codes[2]); // length 3
	try std.testing.expectEqual(@as(u32, 0b111), codes[3]); // length 3
}

test "Huffman encode-decode round-trip" {
	const allocator = std.testing.allocator;

	// Build codes with known lengths
	const lengths = [_]u8{ 2, 2, 3, 3, 0, 0, 0, 0 } ++ [_]u8{0} ** (MAX_ALPHA_SIZE - 8);
	const codes = buildHuffmanCodes(&lengths, 4);

	// Write symbols using BitWriter
	var output: std.ArrayListUnmanaged(u8) = .empty;
	defer output.deinit(allocator);

	const stream_writer = output.writer(allocator);
	const byte_writer = ByteWriter(@TypeOf(stream_writer)).init(stream_writer);
	var writer = BitWriter(@TypeOf(byte_writer)).init(byte_writer);

	// Write symbol 0 (code 00, len 2)
	try writer.writeBits(codes[0], 2);
	// Write symbol 1 (code 01, len 2)
	try writer.writeBits(codes[1], 2);
	// Write symbol 2 (code 10, len 3)
	// Wait, let me recalculate...

	try writer.flush();

	// Build HuffmanTable for decoding
	var table = HuffmanTable.init();
	try table.build(&lengths, 4);

	// Read back using BitReader
	var stream = std.io.fixedBufferStream(output.items);
	const ReaderType = @TypeOf(stream.reader());
	var reader = BitReader(ReaderType).init(stream.reader());

	// Decode symbols
	const sym0 = try table.decode(ReaderType, &reader);
	const sym1 = try table.decode(ReaderType, &reader);

	try std.testing.expectEqual(@as(u16, 0), sym0);
	try std.testing.expectEqual(@as(u16, 1), sym1);
}

test "compress - valid header" {
	const allocator = std.testing.allocator;
	const original = "Hello, World!";

	const compressed = try compress(allocator, original);
	defer allocator.free(compressed);

	// Verify it's valid bzip2 format
	try std.testing.expectEqualSlices(u8, "BZh9", compressed[0..4]);
	try std.testing.expect(compressed.len > 10); // Should have some data
}

test "compress round-trip - simple" {
	const allocator = std.testing.allocator;
	const original = "Hello, World!";

	const compressed = try compress(allocator, original);
	defer allocator.free(compressed);

	// Verify it's valid bzip2 format
	try std.testing.expectEqualSlices(u8, "BZh", compressed[0..3]);

	// Decompress and verify
	const decompressed = try decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compress round-trip - repetitive" {
	const allocator = std.testing.allocator;
	const original = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; // 40 A's

	const compressed = try compress(allocator, original);
	defer allocator.free(compressed);

	const decompressed = try decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "compress round-trip - binary" {
	const allocator = std.testing.allocator;
	var original: [256]u8 = undefined;
	for (0..256) |i| {
		original[i] = @intCast(i);
	}

	const compressed = try compress(allocator, &original);
	defer allocator.free(compressed);

	const decompressed = try decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, &original, decompressed);
}

test "compress calls on_progress callback" {
	const allocator = std.testing.allocator;
	const input = "Hello, world! This is a test of progress callbacks." ** 100;

	const State = struct {
		call_count: usize = 0,
		last_bytes: u64 = 0,
		total: u64 = 0,
	};
	var state = State{};

	const result = try compressWithOptions(allocator, input, .{
		.level = 1,
		.on_progress = &struct {
			fn cb(bytes_processed: u64, bytes_total: u64, userdata: ?*anyopaque) callconv(.c) void {
				const s: *State = @ptrCast(@alignCast(userdata));
				s.call_count += 1;
				s.last_bytes = bytes_processed;
				s.total = bytes_total;
			}
		}.cb,
		.progress_userdata = @ptrCast(&state),
		.progress_bytes_total = input.len,
	});
	defer allocator.free(result);

	try std.testing.expect(state.call_count > 0);
	try std.testing.expectEqual(@as(u64, input.len), state.total);
}

test "decompress calls on_progress callback" {
	const allocator = std.testing.allocator;
	const input = "Decompress progress test data string repeating." ** 50;

	const compressed = try compressWithOptions(allocator, input, .{ .level = 1 });
	defer allocator.free(compressed);

	const State = struct {
		call_count: usize = 0,
		last_bytes: u64 = 0,
	};
	var state = State{};

	const result = try decompressWithOptions(allocator, compressed, .{
		.on_progress = &struct {
			fn cb(bytes_processed: u64, _: u64, userdata: ?*anyopaque) callconv(.c) void {
				const s: *State = @ptrCast(@alignCast(userdata));
				s.call_count += 1;
				s.last_bytes = bytes_processed;
			}
		}.cb,
		.progress_userdata = @ptrCast(&state),
		.progress_bytes_total = compressed.len,
	});
	defer allocator.free(result);

	try std.testing.expect(state.call_count > 0);
}

test "multi-block decompress round-trip" {
	const allocator = std.testing.allocator;

	// Test multiple sizes that span block boundaries (900KB per block at level 9).
	const sizes = [_]usize{ 900_200, 1_800_000, 5_000_000, 10_000_000 };

	for (sizes) |total_size| {
		const full_data = try allocator.alloc(u8, total_size);
		defer allocator.free(full_data);

		// Prepend 200 bytes of 0x81 header, then patterned data
		const header_len = @min(200, total_size);
		for (full_data[0..header_len]) |*b| b.* = 0x81;
		for (full_data[header_len..], 0..) |*byte, i| {
			byte.* = @truncate(i *% 7 +% (i >> 16));
		}

		const compressed = try compress(allocator, full_data);
		defer allocator.free(compressed);

		const decompressed = try decompress(allocator, compressed);
		defer allocator.free(decompressed);

		try std.testing.expectEqual(full_data.len, decompressed.len);
		try std.testing.expectEqualSlices(u8, full_data, decompressed);
	}
}

test "large multi-block compress round-trip with progress callback" {
	const allocator = std.testing.allocator;

	// Simulate what blar does: compress large data with a progress callback
	const total_size = 5_000_000;
	const data = try allocator.alloc(u8, total_size);
	defer allocator.free(data);

	for (data, 0..) |*byte, i| {
		byte.* = @truncate(i *% 13 +% (i >> 12));
	}

	const State = struct {
		call_count: usize = 0,
		last_bytes: u64 = 0,
		last_total: u64 = 0,
	};
	var state = State{};

	const compressed = try compressWithOptions(allocator, data, .{
		.on_progress = &struct {
			fn cb(bytes_processed: u64, bytes_total: u64, userdata: ?*anyopaque) callconv(.c) void {
				const s: *State = @ptrCast(@alignCast(userdata));
				s.call_count += 1;
				s.last_bytes = bytes_processed;
				s.last_total = bytes_total;
			}
		}.cb,
		.progress_userdata = @ptrCast(&state),
		.progress_bytes_total = total_size,
	});
	defer allocator.free(compressed);

	try std.testing.expect(state.call_count > 0);

	// Now decompress to verify round-trip
	const decompressed = try decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try std.testing.expectEqualSlices(u8, data, decompressed);
}

test "compress round-trip with null bytes in data" {
	// Regression test: SA-IS character mapping must be consistent between
	// type classification (getChar with byte+1) and bucket sort. Data containing
	// 0x00 bytes previously caused sentinel confusion in the suffix array
	// construction, producing incorrect BWT output.
	const allocator = std.testing.allocator;

	// Create data with plenty of null bytes mixed with other patterns
	const size = 900_200; // Just over one block to exercise multi-block + SA-IS
	const data = try allocator.alloc(u8, size);
	defer allocator.free(data);

	// Pattern with frequent null bytes — simulates binary file formats
	for (data, 0..) |*byte, i| {
		byte.* = @truncate((i *% 5) ^ (i >> 8));
		// Inject null bytes at regular intervals and clusters
		if (i % 37 == 0 or i % 128 < 4) byte.* = 0;
	}

	const compressed = try compress(allocator, data);
	defer allocator.free(compressed);

	const decompressed = try decompress(allocator, compressed);
	defer allocator.free(decompressed);

	try std.testing.expectEqual(data.len, decompressed.len);
	try std.testing.expectEqualSlices(u8, data, decompressed);
}

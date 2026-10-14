//! SA-IS (Suffix Array by Induced Sorting) — O(n) suffix-array construction.
//! Extracted from bzip2.zig; pure algorithm with no bzip2-specific deps.
//! The SA-IS unit tests remain in bzip2.zig and exercise this via the
//! re-exported `buildSuffixArraySAIS`.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

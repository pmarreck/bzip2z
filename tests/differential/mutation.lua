-- Pure, seeded mutators for the differential sweep (no I/O), following the
-- mutation vocabulary's geometry v3: shotgun flips exactly 16 distinct bits
-- inside one fully contained 32-byte window; nuke overwrites one fully
-- contained 4096-byte window with seeded random bytes that differ from the
-- original. Inputs too short for the window are refused, never clipped.
-- The draw order is this project's own; cases do not replay corruption_probe's.
local bit = require("bit")
local ffi = require("ffi")

local M = {}

M.SHOTGUN_WINDOW_BYTES = 32
M.SHOTGUN_BITS = 16
M.NUKE_BYTES = 4096
local NUKE_MAX_REDRAWS = 16

-- splitmix64 generator on LuaJIT uint64 cdata (wrapping arithmetic).
-- next() returns the raw 64-bit output; below(n) a number in [0, n), using
-- modulo reduction whose bias is below n / 2^64 (negligible for n <= 2^32).
function M.rng(seed)
	local state = ffi.new("uint64_t", seed)
	local r = {}
	function r.next()
		state = state + 0x9E3779B97F4A7C15ULL
		local z = state
		z = bit.bxor(z, bit.rshift(z, 30)) * 0xBF58476D1CE4E5B9ULL
		z = bit.bxor(z, bit.rshift(z, 27)) * 0x94D049BB133111EBULL
		return bit.bxor(z, bit.rshift(z, 31))
	end
	function r.below(n)
		return tonumber(r.next() % ffi.new("uint64_t", n))
	end
	return r
end

local function flip_bit(bytes, stream_bit)
	-- MSB-first, the order a bzip2 decoder reads bits.
	local i = math.floor(stream_bit / 8) + 1
	bytes[i] = bit.bxor(bytes[i], bit.rshift(0x80, stream_bit % 8))
end

local function to_bytes(data)
	local t = {}
	for i = 1, #data do t[i] = data:byte(i) end
	return t
end

local function from_bytes(t)
	local parts = {}
	for i = 1, #t, 4096 do
		parts[#parts + 1] = string.char(unpack(t, i, math.min(i + 4095, #t)))
	end
	return table.concat(parts)
end

-- Shotgun: returns the mutated string and a record {offset, bits}, where bits
-- are the sorted stream-bit indexes flipped. Returns nil and a reason when the
-- input is shorter than the window.
function M.shotgun(data, rng)
	local window = M.SHOTGUN_WINDOW_BYTES
	if #data < window then return nil, "input shorter than the shotgun window" end
	local offset = rng.below(#data - window + 1)
	-- Partial Fisher-Yates over the window's bit positions: exactly
	-- SHOTGUN_BITS distinct positions with no rejection loop.
	local positions = {}
	for i = 0, window * 8 - 1 do positions[i] = i end
	local bytes, flipped = to_bytes(data), {}
	for i = 0, M.SHOTGUN_BITS - 1 do
		local j = i + rng.below(window * 8 - i)
		positions[i], positions[j] = positions[j], positions[i]
		local stream_bit = offset * 8 + positions[i]
		flip_bit(bytes, stream_bit)
		flipped[#flipped + 1] = stream_bit
	end
	table.sort(flipped)
	return from_bytes(bytes), { offset = offset, bits = flipped }
end

-- Nuke: returns the mutated string and a record {offset, length, redraws}.
-- A replacement equal to the original window is redrawn; a generator that
-- never changes the window fails after a bounded number of redraws.
function M.nuke(data, rng)
	local size = M.NUKE_BYTES
	if #data < size then return nil, "input shorter than the nuke window" end
	local offset = rng.below(#data - size + 1)
	local original = data:sub(offset + 1, offset + size)
	for redraws = 0, NUKE_MAX_REDRAWS - 1 do
		local t = {}
		for i = 1, size do t[i] = rng.below(256) end
		local replacement = from_bytes(t)
		if replacement ~= original then
			return data:sub(1, offset) .. replacement .. data:sub(offset + size + 1), { offset = offset, length = size, redraws = redraws }
		end
	end
	error("nuke: generator never changed the window")
end

return M

-- Pure classification for the differential sweep, kept apart from process
-- spawning so tests can inject verdicts (no binaries needed).
local M = {}

-- Exit code of a command run with os.execute. LuaJIT returns the raw wait
-- status (exit code * 256); a child killed by a signal under /bin/sh shows up
-- as exit code 128 + signal.
function M.exit_code(status)
	if type(status) == "number" and status > 255 then return math.floor(status / 256) end
	return status
end

-- Per-binary exit-code contracts for `-t`. Reference bzip2: 0 ok, 2 corrupt
-- input; 1 (environment) and 3 (internal) are not detections. bzip2z's CLI:
-- 0 ok, 1 any file-level failure (it does not separate corruption from I/O
-- errors), 2 usage error. Unlisted codes are experiment errors.
M.CONTRACTS = {
	reference = { [0] = "accept", [2] = "reject" },
	bzip2z = { [0] = "accept", [1] = "reject" },
}

-- Map an exit code to accept, reject, crash or error under a contract.
function M.verdict_from_exit(code, contract)
	if code >= 128 then return "crash" end
	return contract[code] or "error"
end

-- True when four bytes form a legal stream header: "BZh" and a level digit.
function M.header_is_valid(bytes)
	local digit = bytes:byte(4)
	return bytes:sub(1, 3) == "BZh" and digit ~= nil and digit >= 0x31 and digit <= 0x39
end

-- Classify one trial. `excusable` must be true only when the flip lies in a
-- later stream's header AND left that header invalid: the reference then
-- ignores the data as trailing garbage while bzip2z reports it. Returns the
-- outcome name and whether it must fail the sweep.
function M.classify(ours, ref, excusable)
	if ours == "crash" and ref == "crash" then return "both_crash", true end
	if ours == "crash" then return "bzip2z_crash", true end
	if ref == "crash" then return "reference_crash", true end
	if ours == "error" or ref == "error" then return "experiment_error", true end
	if ours == "accept" and ref == "accept" then return "both_accept", false end
	if ours == "reject" and ref == "reject" then return "both_reject", false end
	if ours == "reject" and excusable then return "intentional_divergence", false end
	if ours == "reject" then return "bzip2z_only_reject", true end
	return "reference_only_reject", true
end

return M

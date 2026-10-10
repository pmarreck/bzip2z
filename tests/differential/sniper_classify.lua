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

-- Map a shell exit status to a verdict. Through /bin/sh a signal-killed
-- child reports 128 + signal number, so >= 128 is a crash, not a rejection.
function M.verdict_from_exit(code)
	if code == 0 then return "accept" end
	if code >= 128 then return "crash" end
	return "reject"
end

-- Classify one trial. `in_trailing_window` is true when the flipped bit lies
-- in a later stream's "BZh<digit>" header, where the reference deliberately
-- ignores invalid trailing data. Returns the outcome name and whether it
-- must fail the sweep.
function M.classify(ours, ref, in_trailing_window)
	if ours == "accept" and ref == "accept" then return "both_accept", false end
	if ours == "reject" and ref == "reject" then return "both_reject", false end
	if ours == "reject" and ref == "accept" and in_trailing_window then return "intentional_divergence", false end
	if ours == "reject" and ref == "accept" then return "bzip2z_only_reject", true end
	if ours == "accept" and ref == "reject" then return "reference_only_reject", true end
	if ours == "crash" and ref == "crash" then return "both_crash", true end
	if ours == "crash" then return "bzip2z_crash", true end
	return "reference_crash", true
end

return M

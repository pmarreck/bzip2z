# Lane runner for the complete test entry point (sourced, not executed).
# Each lane is one required check: its exit status is recorded, a failure
# never stops later lanes, and lanes_finish fails if any lane failed or if
# no lane ran at all. A missing command or a signal counts as a failure, and
# so does a lane that exits 0 but writes to stderr: tests capture and assert
# their expected diagnostics, so anything reaching stderr is unfinished.

lanes_names=()
lanes_status=()
lanes_reasons=()

# lane NAME COMMAND [ARGS...]: run one required check and record its status.
# The lane's stderr is held in a temporary file and shown only on failure.
lane() {
	local name="$1"
	shift
	echo "== lane: $name"
	local err_file
	err_file="$(mktemp "${TMPDIR:-/tmp}/lane-stderr.XXXXXX")" || {
		echo "== lane: $name: FAILED (cannot create stderr capture)" >&2
		lanes_names+=("$name")
		lanes_status+=(1)
		lanes_reasons+=("cannot create stderr capture")
		return 0
	}
	"$@" 2>"$err_file"
	local status=$? reason=""
	if [ "$status" -ne 0 ]; then
		reason="exit $status"
	elif [ -s "$err_file" ]; then
		status=1
		reason="stray stderr, $(wc -c <"$err_file") bytes"
	fi
	lanes_names+=("$name")
	lanes_status+=("$status")
	lanes_reasons+=("$reason")
	if [ "$status" -eq 0 ]; then
		echo "== lane: $name: ok"
	else
		cat "$err_file" >&2
		echo "== lane: $name: FAILED ($reason)" >&2
	fi
	rm -f "$err_file"
	return 0
}

# lanes_finish: print a summary to stderr and return nonzero unless at least
# one lane ran and every lane exited 0.
lanes_finish() {
	local total=${#lanes_names[@]} failed=0 i
	for ((i = 0; i < total; i++)); do
		if [ "${lanes_status[$i]}" -ne 0 ]; then
			failed=$((failed + 1))
			echo "failed lane: ${lanes_names[$i]} (${lanes_reasons[$i]})" >&2
		fi
	done
	if [ "$total" -eq 0 ]; then
		echo "no lanes ran" >&2
		return 1
	fi
	echo "$((total - failed))/$total lanes passed" >&2
	[ "$failed" -eq 0 ]
}

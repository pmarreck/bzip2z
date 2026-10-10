# Lane runner for the complete test entry point (sourced, not executed).
# Each lane is one required check: its exit status is recorded, a failure
# never stops later lanes, and lanes_finish fails if any lane failed or if
# no lane ran at all. A missing command or a signal counts as a failure.

lanes_names=()
lanes_status=()

# lane NAME COMMAND [ARGS...]: run one required check and record its status.
lane() {
	local name="$1"
	shift
	echo "== lane: $name"
	"$@"
	local status=$?
	lanes_names+=("$name")
	lanes_status+=("$status")
	if [ "$status" -eq 0 ]; then
		echo "== lane: $name: ok"
	else
		echo "== lane: $name: FAILED (exit $status)" >&2
	fi
	return 0
}

# lanes_finish: print a summary to stderr and return nonzero unless at least
# one lane ran and every lane exited 0.
lanes_finish() {
	local total=${#lanes_names[@]} failed=0 i
	for ((i = 0; i < total; i++)); do
		if [ "${lanes_status[$i]}" -ne 0 ]; then
			failed=$((failed + 1))
			echo "failed lane: ${lanes_names[$i]} (exit ${lanes_status[$i]})" >&2
		fi
	done
	if [ "$total" -eq 0 ]; then
		echo "no lanes ran" >&2
		return 1
	fi
	echo "$((total - failed))/$total lanes passed" >&2
	[ "$failed" -eq 0 ]
}

#!/usr/bin/env bash

FAILURES=0
DEMO="./zig-out/bin/progrez-demo"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; ((FAILURES++)); }

echo "=== CLI Integration Tests ==="

# Test 1: Demo runs without crash
echo "Test 1: Demo runs successfully"
if ${DEMO} 2>/dev/null; then
	pass "demo exits 0"
else
	fail "demo exited non-zero"
fi

# Test 2: PROGRESS=false suppresses progress output
echo "Test 2: PROGRESS=false suppresses progress output"
stderr_output=$(PROGRESS=false ${DEMO} 2>&1 1>/dev/null)
if [ -z "$stderr_output" ]; then
	pass "no stderr output with PROGRESS=false"
else
	# May still have completion summary — check no progress bar chars
	if echo "$stderr_output" | grep -q '█\|░\|⠋'; then
		fail "progress chars found despite PROGRESS=false"
	else
		pass "no progress bar chars with PROGRESS=false"
	fi
fi

# Test 3: Completion summary present
echo "Test 3: Completion summary"
stderr_output=$(PROGRESS=true PROGREZ_INTERVAL=5000 ${DEMO} 2>&1 1>/dev/null)
if echo "$stderr_output" | grep -q 'completed'; then
	pass "completion summary found"
else
	fail "missing completion summary"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
	echo "FAILED: $FAILURES test(s)"
	exit "$FAILURES"
fi
echo "ALL CLI TESTS PASSED"

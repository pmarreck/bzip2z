---
description: "File-based tests must take scratch paths from helpers.tmpPath (src/test_helpers.zig), which adds the process id to a per-process counter so test processes sharing TMPDIR never race on the same files."
datetime: 2026-06-01T16:41:00-04:00 # EDT
tags: [tests, testing, tmpdir, temp-files, tmppath, test-helpers, pid, process-id, race-condition, flaky-tests, concurrency, zig-build-test, bench]
---
Found 2026-06-01, landed 2026-10-14 (5a9198c..ffaf051). Temp paths were once
`$TMPDIR/<name>-<counter>`. The counter restarts at 0 in every process, and
`zig build test` ran two test binaries over the same suite in parallel, so both
produced identical paths. "parallel file decode streams without large allocs"
then failed about 36% of runs, "failed without output", and passed every time
when its binary ran alone.

Current layout:
- `src/test_helpers.zig` is a build module of its own (so the library tests and
  the bench executable can both import it) with its own test binary.
- `tmpPath` is `$TMPDIR/<name>-<pid>-<counter>`. Even with a single library
  test binary, the pid still guards two concurrent `./test` runs.
- `helpers.io()` returns `std.testing.io` in test builds so interop tests can
  spawn the reference `bzip2`/`pbzip2`.
- The bench executable sits outside the test graph, so `./test` has a
  "bench builds" lane to catch API rot.

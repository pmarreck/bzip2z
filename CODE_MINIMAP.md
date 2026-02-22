# Code Minimap

- AGENTS.md: Agent workflow and project rules (do not delete).
- .gitignore: Ignore build outputs and OS cruft.
- LICENSE: Project license.
- NEXT_STEPS.md: Short list of follow-on actions.
- build.zig: Zig build definitions (library, CLI binaries, core/lib/bench tests, bench, fuzz).
- build.zig.zon: Zig package manifest and version pin.
- flake.nix: Nix dev shell with Zig, bzip2, and pbzip2.
- build: Convenience wrapper for `zig build` with cache dir.
- test: Convenience wrapper for `zig build test` + CLI tests.
- src/lib.zig: Library entrypoint and version export.
- src/bzip2.zig: Core bzip2 implementation + multi-block, pbzip2-style multi-stream, parallel decode, and legacy randomized-block compatibility handling for CRC-correct decode.
- src/bzip2_test.zig: Unit + interop tests (system bzip2).
- src/concurrency.zig: Bounded queue for worker threading.
- bench/bench_bzip2.zig: Benchmark vs system bzip2.
- fuzz/fuzz_stream_bzip2.zig: Fuzzing harness for round-trip safety.
- cli/main.zig: bzip2-compatible CLI with opt-in pbzip2-style multi-stream (-j).
- tests/cli_test: Bash CLI tests (uses capture.bash).
- README.md: Overview, usage, benchmarks (results + environment), credits.

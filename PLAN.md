# PLAN

- [x] Fix CI portability in `tests/cli_test` by using dotfiles `capture` when available and an in-memory fallback otherwise (no tempfile capture path). (completed 2026-02-22 14:41 EST)
- [x] Repair CI observability and Garnix host compatibility by fixing README Garnix badge endpoint and scoping flake checks/packages to Linux-hosted multi-target builds. (completed 2026-02-22 14:41 EST)
- [x] Add pure-memory Zig core surface (`src/core.zig`) and C FFI adapter (`src/ffi.zig`, `c/include/bzip2z.h`). (completed 2026-02-22 13:25 EST)
- [x] Replace Zig CLI adapter with C CLI adapter that only calls the FFI (`c/cli.c`) while keeping CLI behavior used by tests. (completed 2026-02-22 13:25 EST)
- [x] Update `build.zig` to build/install C CLI binaries (`bzip2`, `bunzip2`, `bzcat`) and FFI static library. (completed 2026-02-22 13:25 EST)
- [x] Add Garnix CI definitions in `flake.nix` (flake-only, no Garnix YAML) for macOS aarch64, Linux x86_64/aarch64, Windows x86_64/aarch64 targets. (completed 2026-02-22 13:25 EST)
- [x] Add GitHub Actions CI matrix for the same 5 targets and publish downloadable artifacts. (completed 2026-02-22 13:25 EST)
- [x] Add README badges for Garnix and GitHub CI; update `CODE_MINIMAP.md` for new architecture files. (completed 2026-02-22 13:25 EST)
- [x] Re-run `./test`, run feasible flake/workflow sanity checks, then commit and push on `yolo`. (completed 2026-02-22 13:25 EST)
- [x] Reject over-long RUNA/RUNB chains as CorruptData (validate inbox 2026-09-29); wired bzip2.zig/core.zig inline tests into test root; ReleaseSafe corrupt-input pass in ./test. Replied to validate with 9d7a049 + package hash. (completed 2026-09-29 21:05 EDT)
- [x] Streaming decode API `decompressStream(allocator, reader, writer, options)`: any reader -> any writer (incl. discard), all block + stream CRCs across concatenated streams, allocations bounded by block not stream size (inbox/2026-07-10 from validate-archive-streaming; reply there). (completed 2026-09-29 21:40 EDT)
- [x] Optional `Diagnostics` out-param for `decompressStream`: stream/block index, stream + block start bit, bit offset at detection (byte + bit), decode phase, stored vs computed CRC. Tell validate when landed. (completed 2026-09-29 21:40 EDT)
- [x] Map reader/writer failures to ReadFailed/WriteFailed instead of CorruptData; write via writeAll (current `_ = writer.write` can drop bytes on short writes). (completed 2026-09-29 21:40 EDT)
- [ ] A block that decodes to zero symbols skips the BWT-index and CRC checks (`decodeBlockInternal` returns early); reference bzip2 rejects origPtr >= nblock there. Add a failing test, then reject.
- [ ] BitReader pulls one byte per `read` call; unbuffered `read`-style sources (validate FileSource) pay a call per byte. Consider an internal refill buffer, measured with hyperfine.
- [ ] Optional: surface Diagnostics through the C FFI and the CLI's decompression error message.

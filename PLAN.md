# PLAN

- [x] Add pure-memory Zig core surface (`src/core.zig`) and C FFI adapter (`src/ffi.zig`, `c/include/bzip2z.h`). (completed 2026-02-22 13:25 EST)
	Curiosity poke: Do any FFI exports leak file or stream I/O semantics?
- [x] Replace Zig CLI adapter with C CLI adapter that only calls the FFI (`c/cli.c`) while keeping CLI behavior used by tests. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Are combined short flags and `-j` parsing still compatible with current tests?
- [x] Update `build.zig` to build/install C CLI binaries (`bzip2`, `bunzip2`, `bzcat`) and FFI static library. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Are artifacts linkable across all target triples without host-only assumptions?
- [x] Add Garnix CI definitions in `flake.nix` (flake-only, no Garnix YAML) for macOS aarch64, Linux x86_64/aarch64, Windows x86_64/aarch64 targets. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Are target triples correct for Zig 0.15 and valid on CI runners?
- [x] Add GitHub Actions CI matrix for the same 5 targets and publish downloadable artifacts. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Does artifact staging reliably include the expected binaries per target?
- [x] Add README badges for Garnix and GitHub CI; update `CODE_MINIMAP.md` for new architecture files. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Are badge endpoints and workflow filenames stable and accurate?
- [x] Re-run `./test`, run feasible flake/workflow sanity checks, then commit and push on `yolo`. (completed 2026-02-22 13:25 EST)
	Curiosity poke: Any regression hidden by existing tests after the CLI language/runtime swap?

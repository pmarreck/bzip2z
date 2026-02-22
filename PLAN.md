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

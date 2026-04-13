# Bug: no nix build package for macOS

## Summary

The flake only defines packages for `x86_64-linux` (via `ciHostSystems`), so `nix build` fails on macOS with:

```
error: flake does not provide attribute 'packages.aarch64-darwin.default'
```

## Fix

Either expand `ciHostSystems` to include macOS:

```nix
ciHostSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
```

Or add a separate native macOS package definition using `devSystems` or `allBuildSystems` which already include Darwin targets.

## Impact

The `./build` script follows the unified pattern but will fail on macOS because nix is available but no macOS package exists. The zig fallback path doesn't get reached since the script correctly tries nix first when available.

## Discovered

2026-04-13 while applying the unified Zig + Nix build pattern across all projects.

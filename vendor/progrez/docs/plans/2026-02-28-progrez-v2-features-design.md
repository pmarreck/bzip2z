# progrez v2 Features — Design Document

**Date**: 2026-02-28
**Status**: Approved

## Overview

Five feature additions to progrez: throughput stats, throughput sparkline, label updating, flake/CI infrastructure, and cross-platform system notifications.

## Feature 1: Throughput Stats

Display `ema_bytes_per_sec` as a formatted stat in the determinate bar.

```
Compressing ▐████████░░░░░░░▌ 58.3%  234/400 files  12.3/21.1 MB  4.2 MB/s  ETA 0:42
```

- New formatter: `formatThroughput(bytes_per_sec, buf)` → `"4.2 MB/s"` (reuses `formatBytes` + `/s`)
- Added to `renderDeterminate` stats section
- Dropping priority (lowest first): ETA → throughput → bytes → files → %
- Suppressed until `samples_count >= 3` (same as ETA)
- Also shown in log mode

### Files
- `src/format.zig` — add `formatThroughput`
- `src/render.zig` — add throughput to stat levels in `renderDeterminate` and `renderLogLine`

## Feature 2: Throughput Sparkline

Rolling window of last 8 rate samples rendered as block elements `▁▂▃▄▅▆▇█`.

```
Compressing ▐████████░░░░░░░▌ 58.3%  234/400 files  4.2 MB/s ▁▃▅▇▅▃▂▁  ETA 0:42
```

- Opt-in: `PROGREZ_SPARKLINE=true` env var or `progrez_set_sparkline(ctx, true)`
- Ring buffer: `rate_history: [8]f64` + `rate_history_idx: u8` in `ProgrezState`
- `recordUpdate()` pushes latest rate into ring buffer
- `formatSparkline(rate_history, count, buf)` normalizes to min/max of window, maps to 8 block levels
- Drops at same priority as throughput (just after, before bytes)
- Omitted in non-TTY log mode

### Files
- `src/core.zig` — add `rate_history`, `rate_history_idx` fields; update `recordUpdate()`
- `src/format.zig` — add `formatSparkline`
- `src/render.zig` — add sparkline to stat levels
- `src/ffi.zig` — add `progrez_set_sparkline` export, parse `PROGREZ_SPARKLINE` env var

## Feature 3: Label Update

Change the label mid-operation without recreating the context.

```c
progrez_set_label(ctx, "Extracting");
```

- Add `setLabel(label: []const u8)` method to `ProgrezState` (fixed-buffer copy, same as `init`)
- New export `progrez_set_label(ctx, label)` in ffi.zig
- Thread-safe: label is a fixed buffer (128 bytes), not a pointer

### Files
- `src/core.zig` — add `setLabel()` method
- `src/ffi.zig` — add `progrez_set_label` export
- `include/progrez.h` — add declaration

## Feature 4: Flake Output + CI

### Flake Output
- Verify `packages.default` installs headers (`include/progrez.h`) alongside the static library
- Ensure both static and shared libraries are installed
- The existing flake output is sufficient for downstream Nix consumers (`inputs.progrez.packages.${system}.default`)

### Garnix CI
- Already functional (auto-evaluates `packages` and `checks` from flake.nix)
- Add badge to README

### GitHub Actions CI
- `.github/workflows/ci.yml`
- Triggers: push to `yolo`, pull requests
- Uses `DeterminateSystems/nix-installer-action` for Nix setup
- Runs `nix flake check`
- Matrix: `ubuntu-latest`, `macos-latest`

### README Badges
```markdown
[![Garnix](https://img.shields.io/endpoint?url=https://garnix.io/api/badges/pmarreck/progrez?branch=yolo)](https://garnix.io)
[![CI](https://github.com/pmarreck/progrez/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/progrez/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

### Files
- `flake.nix` — verify header installation
- `.github/workflows/ci.yml` — new
- `README.md` — add badges

## Feature 5: System Notifications

On `progrez_finish()`, if elapsed time exceeds a threshold, fire a system notification.

### Notification Message
Same as completion summary:
```
bzip2z completed: compression of mydir/ in 23.45s (400 files, 21.1 MB)
```

### Detection & Dispatch (fork/exec)
- **macOS**: `osascript -e 'display notification "..." with title "progrez"'`
- **Linux**: `notify-send "progrez" "..."`
- **Fallback**: Terminal bell `\a`
- OS detection at compile time via `builtin.os.tag`
- Probe for command availability at `progrez_create()` time, store which method to use

### Configuration
| Mechanism | Description |
|---|---|
| `PROGREZ_NOTIFY` | `true`/`false`/`auto` (default: `auto`) |
| `PROGREZ_NOTIFY_AFTER` | Seconds threshold (default: 10) |
| `progrez_set_notify(ctx, bool)` | Programmatic on/off |
| `progrez_set_notify_after(ctx, u32)` | Programmatic threshold (seconds) |

`auto` means: notify only if elapsed > threshold AND a notification method is available.

### Callback Override
```c
typedef void (*progrez_notify_fn)(const char* message, void* userdata);
void progrez_set_notify_callback(progrez_ctx* ctx, progrez_notify_fn fn, void* userdata);
```
- If callback is set, it's called instead of built-in fork/exec
- Built-in notification is skipped when a callback is registered

### Thread Safety
Notification fires synchronously inside `progrez_finish()` after the render thread is joined.

### FfiContext Additions
```
notify_mode: enum { auto, on, off }
notify_after_secs: u32
notify_method: enum { none, osascript, notify_send, bell }
notify_callback: ?*const fn([*:0]const u8, ?*anyopaque) void
notify_userdata: ?*anyopaque
```

### Files
- `src/ffi.zig` — notification logic in `progrez_finish()`, new fields, exports, env var parsing
- `include/progrez.h` — new declarations

## Environment Variables Summary (all features)

| Variable | Values | Default | Feature |
|---|---|---|---|
| `PROGREZ_SPARKLINE` | `true`/`false` | `false` | Sparkline |
| `PROGREZ_NOTIFY` | `true`/`false`/`auto` | `auto` | Notifications |
| `PROGREZ_NOTIFY_AFTER` | seconds | `10` | Notifications |

## Testing Strategy

- **Throughput**: Unit test `formatThroughput` with various rates
- **Sparkline**: Unit test `formatSparkline` with known rate histories, verify normalization
- **Label update**: Unit test `setLabel` on `ProgrezState`, verify buffer contents
- **CI**: The CI itself validates the build/test pipeline
- **Notifications**: Unit test env var parsing, notification method detection (mocked). Integration test that `PROGREZ_NOTIFY=false` suppresses notification. Cannot test actual system notifications in CI.

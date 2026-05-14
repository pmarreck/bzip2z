# progrez

Unified progress indication library for CLI/TUI applications.

Provides polished, professional progress bars that take advantage of modern
terminal features (truecolor, Unicode block elements, braille characters).
Decouples data reporting from display rendering: callers provide data points
at arbitrary rates, and the library renders independently on a configurable
timer via a dedicated render thread. Also supports manual render mode for
scroll-region layouts or custom cursor positioning.

## Key concepts

- **Determinate mode**: Known total — shows a filling bar with %, counts, ETA
- **Indeterminate mode**: Unknown total — shows a braille spinner with counts
- **Completion summary**: On finish, replaces progress bar with a persistent summary line
- **Caller identity**: Optional tool name + context for rich completion messages

## Render modes

- **Automatic** (default): Render thread spawns on first `progrez_update()` and draws to stderr at the configured interval. No caller effort beyond `update`.
- **Manual**: Calling `progrez_render_line()` enters manual mode — no thread is spawned. Caller drives rendering at their own cadence, writing the returned buffer wherever they want (scroll-region row, specific cursor position, etc.).

## Architecture

Pure Zig core (no I/O) -> C FFI boundary (threading, terminal I/O) -> Any consumer

## Quick Start (C)

```c
#include "progrez.h"

progrez_ctx *ctx = progrez_create("Processing");
progrez_set_identity(ctx, "my-tool", "batch import of records/");
progrez_set_determinate(ctx, num_files, total_bytes);

for (uint64_t i = 0; i < num_files; i++) {
    // do work
    progrez_update(ctx, i + 1, bytes_done);
}

progrez_finish(ctx);
progrez_destroy(ctx);
```

For indeterminate mode (unknown total):

```c
progrez_ctx *ctx = progrez_create("Scanning");
progrez_set_indeterminate(ctx);
progrez_set_guess(ctx, estimated_files, 0);  // optional guess

while (scanning) {
    progrez_update(ctx, files_found, bytes_seen);
}

// Switch to determinate once total is known:
progrez_set_determinate(ctx, actual_total_files, actual_total_bytes);
```

## Environment Variable Overrides

| Variable | Values | Effect |
|---|---|---|
| `PROGRESS` | `true`/`1`, `false`/`0` | Force progress on/off (overrides TTY detection) |
| `PROGREZ_INTERVAL` | milliseconds (e.g. `500`) | Render interval (default: 100ms) |
| `PROGREZ_STYLE` | `ascii` | Force ASCII mode (no Unicode, no color) |
| `PROGREZ_GRADIENT` | hex colors (e.g. `FF0000,00FF00` or `FF0000,FFFF00,00FF00`) | Custom gradient (2 or 3 stops) |
| `PROGREZ_SPARKLINE` | `true`/`false` | Enable throughput sparkline graph |
| `PROGREZ_NOTIFY` | `true`/`false`/`auto` | System notifications (default: `auto`) |
| `PROGREZ_NOTIFY_AFTER` | seconds (default: `10`) | Notification time threshold |
| `NO_COLOR` | any value | Disable all color output (respects no-color.org convention) |

Standard terminal variables (`COLORTERM`, `TERM`, `WT_SESSION`) are also read for capability detection.

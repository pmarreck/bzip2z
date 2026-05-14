# progrez

[![Garnix](https://img.shields.io/endpoint?url=https://garnix.io/api/badges/pmarreck/progrez?branch=yolo)](https://garnix.io)
[![CI](https://github.com/pmarreck/progrez/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/progrez/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Unified progress indication library for CLI/TUI applications.

Provides polished, professional progress bars that take advantage of modern
terminal features (truecolor, Unicode block elements, braille characters).
Decouples data reporting from display rendering: callers provide data points
at arbitrary rates, and the library renders independently on a configurable
timer via a dedicated render thread.

(I could not for the life of me, and neither could Claude, figure out how to render this gif properly including the Braille characters that act as indeterminate progress indication; suffice it to say that the real thing does NOT produce tofu/question-mark characters.)

[![asciicast](demo.gif)](https://asciinema.org/a/803959)

## Key concepts

- **Determinate mode**: Known total — shows a filling bar with %, counts, ETA
- **Indeterminate mode**: Unknown total — shows a braille spinner with counts
- **Completion summary**: On finish, replaces progress bar with a persistent summary line
- **Caller identity**: Optional tool name + context for rich completion messages

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

## Additional API

```c
/* Change the label mid-operation */
progrez_set_label(ctx, "Extracting");

/* Enable throughput sparkline graph */
progrez_set_sparkline(ctx, true);

/* Configure notifications */
progrez_set_notify(ctx, true);             /* force on */
progrez_set_notify_after(ctx, 30);         /* 30 second threshold */
progrez_set_notify_callback(ctx, my_fn, userdata);  /* custom callback */
```

## Manual Render Mode

For scroll-region layouts or custom cursor positioning, use `progrez_render_line()` instead of the automatic render thread. Calling it enters manual mode — the render thread is never spawned, and you control when and where each frame is drawn.

```c
progrez_ctx *ctx = progrez_create("Processing");
progrez_set_determinate(ctx, total_files, total_bytes);

char buf[4096];
while (working) {
    progrez_update(ctx, files_done, bytes_done);
    size_t len = progrez_render_line(ctx, buf, sizeof(buf), terminal_width);
    // Write buf[0..len] wherever you want (scroll region, specific row, etc.)
}

progrez_finish(ctx);
progrez_destroy(ctx);
```

Key differences from automatic mode:
- No render thread — you call `progrez_render_line()` at your own cadence
- You provide the terminal width (automatic mode detects it via ioctl)
- `progrez_update()` still updates the data; `progrez_render_line()` reads it and renders
- First call to `progrez_render_line()` locks in manual mode for that context

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

## Building

```bash
# Build (requires Nix with flakes)
nix develop -c zig build

# Run tests
nix develop -c zig build test

# Run the demo
nix develop -c ./zig-out/bin/progrez-demo
```

## License

MIT

# progrez — Unified Progress Indication Library

**Date**: 2026-02-27
**Status**: Approved

## Purpose

A reusable Zig library (with C FFI) providing polished, professional progress indication for CLI/TUI applications. The library decouples data reporting from display rendering: callers provide data points via callbacks at arbitrary rates, and the library independently renders smooth, attractive progress output on its own schedule.

## Architecture

Zig core (pure logic, no I/O) → C FFI (threading, I/O, terminal) → Any consumer

```
Caller thread(s)                    Render thread (owned by library)
     │                                   │
     ├─ progrez_update(files, bytes) ──► atomic snapshot write (seqlock)
     │                                   │
     │                              sleep(interval_ms)
     │                              read snapshot (atomic)
     │                              pure core: render(state, term_width) -> []u8
     │                              write rendered line to stderr
     │                              loop
     │
     ├─ progrez_finish() ──────────► signal stop, join thread
```

## State Machine

```
CREATE ──► INDETERMINATE ──(set_total)──► DETERMINATE ──(finish)──► DONE
CREATE ──► DETERMINATE ────────────────────────────────(finish)──► DONE
```

- Either entry point (indeterminate or determinate) is valid
- Transitioning to determinate cleans up indeterminate's visual artifacts
- `finish()` cleans up whatever mode was active
- One active progress display at a time (v1); multiple contexts can exist but only one renders

## Core Data Model

### ProgrezState (pure Zig, no I/O)

```
mode: enum { indeterminate, determinate }

# Counters
files_processed: u64
files_total: ?u64          # null = unknown
bytes_processed: u64
bytes_total: ?u64          # null = unknown

# Timing
start_time_ns: i128
last_update_ns: i128

# EMA rate tracking
ema_bytes_per_sec: f64     # exponential moving average
ema_files_per_sec: f64
ema_alpha: f64             # decay factor (default 0.3)
samples_count: u32         # for initial ramp-up

# Indeterminate mode extras
guess_total_files: ?u64    # optional hint from prior run
guess_total_bytes: ?u64
spinner_frame: u8          # cycles through braille spinner chars

# Display label
label: [128]u8             # e.g. "Scanning", "Compressing"
label_len: u8

# Caller identity (optional, for completion summaries & future notifications)
caller_name: [64]u8        # e.g. "bzip2z", "z7z" — the tool using progrez
caller_name_len: u8
context_name: [256]u8      # e.g. "compression of mydir/", "extraction of archive.7z"
context_name_len: u16
```

### ProgrezSnapshot (atomically swapped between threads)

```
files_processed: u64
files_total: ?u64
bytes_processed: u64
bytes_total: ?u64
timestamp_ns: i128
```

Thread safety via seqlock pattern: atomic u8 generation counter + memcpy with acquire/release. No mutexes needed.

## C FFI API

```c
typedef struct progrez_ctx progrez_ctx;

// Lifecycle
progrez_ctx* progrez_create(const char* label);
void         progrez_destroy(progrez_ctx* ctx);

// Optional caller identity (for completion summaries & future notifications)
void progrez_set_identity(progrez_ctx* ctx,
                          const char* caller_name,   // e.g. "bzip2z"
                          const char* context_name); // e.g. "compression of mydir/"

// Mode setup (call one or both, in order)
void progrez_set_indeterminate(progrez_ctx* ctx);
void progrez_set_determinate(progrez_ctx* ctx,
                             uint64_t files_total,   // 0 = not tracking files
                             uint64_t bytes_total);   // 0 = not tracking bytes

// Optional hints for indeterminate mode
void progrez_set_guess(progrez_ctx* ctx,
                       uint64_t guess_files,  // 0 = no guess
                       uint64_t guess_bytes); // 0 = no guess

// Data updates (call from any thread, as often as you like)
void progrez_update(progrez_ctx* ctx,
                    uint64_t files_processed,
                    uint64_t bytes_processed);

// Completion (cleans up display, stops render thread)
void progrez_finish(progrez_ctx* ctx);

// Configuration (optional, can also be set via env vars)
void progrez_set_interval_ms(progrez_ctx* ctx, uint32_t ms);
```

### Environment Variable Overrides

| Variable | Values | Effect |
|----------|--------|--------|
| `PROGRESS` | `true`/`1`/`false`/`0` | Force progress on/off regardless of TTY |
| `PROGREZ_INTERVAL` | milliseconds (default: 1000) | Render interval |
| `PROGREZ_STYLE` | `ascii` | Force ASCII fallback |
| `NO_COLOR` | any value | Disable color (https://no-color.org) |

## Rendering Design

### Determinate mode (single line, full terminal width)

```
Compressing ▐████████████████████░░░░░░░░▌ 58.3%  234/400 files  12.3/21.1 MB  ETA 0:42
```

Components:
1. **Label** (left) — from `progrez_create(label)`
2. **Bar** (fills remaining space) — Unicode block elements (`█▉▊▋▌▍▎▏` for 8 sub-char levels, `░` for empty)
3. **Stats** (right, fixed width) — progressively dropped if terminal too narrow

Color gradient across filled portion (ANSI truecolor):
- 0%: cyan `(0, 255, 255)`
- 50%: blue-violet `(128, 0, 255)`
- 100%: magenta `(255, 0, 255)`

Stats dropping priority (narrowest terminal first): ETA → bytes → files → %
Bar always gets at least 10 characters.

### Indeterminate mode (braille spinner + count)

```
Scanning ⣾ 1,247 files  4.2 MB
```

Spinner cycles: `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`

With guess total (different visual style to signal uncertainty):

```
Scanning ⣾ [⡀⡄⡆⡇⣇⣧⣷⣿····] ~62%  1,247/~2,000 files  4.2 MB
```

### ASCII fallback (legacy terminals / PROGREZ_STYLE=ascii)

```
Compressing [============>           ] 58.3%  234/400 files  ETA 0:42
```

### Completion summary

On `progrez_finish()`, the progress bar is replaced with a one-line completion summary. If caller identity was set via `progrez_set_identity()`:

```
bzip2z completed: compression of mydir/ in 23.45s (400 files, 21.1 MB)
```

If no identity was set, falls back to the label:

```
Compressing completed in 23.45s (400 files, 21.1 MB)
```

The summary is written once and left in the terminal scrollback (unlike the progress bar itself which overwrites in place). After the summary, the line is finalized with `\n` so subsequent output appears cleanly below it.

## ETA Calculation

Exponential moving average (EMA) of rate with configurable decay factor (alpha = 0.3):

```
new_rate = bytes_delta / time_delta
ema_rate = alpha * new_rate + (1 - alpha) * ema_rate
eta_seconds = bytes_remaining / ema_rate
```

ETA display is suppressed until `samples_count >= 3` (roughly 3 render intervals) to avoid wild initial estimates.

## Platform Support

| Feature | macOS/Linux | Windows Terminal | Windows ConHost |
|---------|------------|------------------|-----------------|
| TTY detection | `isatty(2)` | `GetConsoleMode` | `GetConsoleMode` |
| Terminal width | `ioctl TIOCGWINSZ` | `GetConsoleScreenBufferInfo` | `GetConsoleScreenBufferInfo` |
| Truecolor | `\x1b[38;2;r;g;bm` | Yes | 16-color fallback |
| Unicode blocks | Yes | Yes | ASCII fallback |
| Braille chars | Yes | Yes | ASCII spinner fallback |

Detection order:
1. `PROGREZ_STYLE` env var (overrides all)
2. `NO_COLOR` (disables color, keeps Unicode)
3. `TERM` / `WT_SESSION` / `COLORTERM` for truecolor
4. `isatty(stderr)` for TTY vs pipe
5. Windows: `GetConsoleMode` + `ENABLE_VIRTUAL_TERMINAL_PROCESSING`

### Non-interactive (piped stderr)

Prints periodic log lines without ANSI codes:
```
[progrez] Compressing 25% 100/400 files 5.3/21.1 MB ETA 1:23
```

Frequency: every 10 seconds or 10% progress, whichever comes first.

## Project Structure

```
progrez/
├── build.zig
├── flake.nix
├── include/
│   └── progrez.h
├── src/
│   ├── core.zig               # Pure logic: EMA, formatting, state
│   ├── ffi.zig                # C FFI exports, thread management, I/O
│   ├── terminal.zig           # Terminal capability detection (cross-platform)
│   └── render.zig             # Line composition: bar + stats layout
├── tests/
│   ├── unit/
│   │   ├── test_core.zig      # EMA math, unit formatting, % calc
│   │   ├── test_render.zig    # Bar rendering at various widths
│   │   └── test_terminal.zig  # Capability detection with mocked env
│   ├── cli/
│   │   └── test_cli.sh        # Integration via compiled C test binary
│   └── integration/
│       └── test_ffi.c         # C program exercising full FFI
├── examples/
│   └── demo.c                 # Usage example
├── test                       # Master test runner (bash)
├── build                      # Build script (bash)
├── PLAN.md
├── PROJECT_OVERVIEW.md
└── CODE_MINIMAP.md
```

## Testing Strategy

**Unit tests** (`tests/unit/`, Zig test blocks):
- Core: EMA convergence with synthetic timing, unit formatting, percentage edge cases
- Render: byte-exact bar output at widths 40/80/120/200, stat dropping, ASCII fallback, color escape sequences
- Terminal: mocked env vars for capability detection

**Integration tests** (`tests/cli/test_cli.sh`):
- Compile C test binary linking `libprogrez.a`
- Assert stderr contains expected patterns
- `PROGRESS=false` suppresses output
- `PROGREZ_STYLE=ascii` forces ASCII
- Non-TTY mode (piped stderr) produces log-mode output

**No timing-dependent tests** — the pure core accepts timestamps as inputs, making all timing injectable and deterministic.

## Future Ideas (not v1)

- Multiple simultaneous progress bars (stacked, multi-line)
- TOML-based theming for global style customization
- Kitty graphics protocol support (animated textures for progress)
- Windowed linear regression for ETA (captures acceleration trends)
- i18n for progress labels
- Completion notifications via system mechanisms (macOS notifications, libnotify, etc.) using caller identity

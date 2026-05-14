# Code Minimap

## src/lib.zig
Module root. Re-exports all submodules (`core`, `format`, `terminal`, `render`, `ffi`). Forces FFI symbol emission via comptime import. Test block references all submodules.

## src/core.zig
Pure logic core: progress state, mode transitions, EMA rate estimation, ETA/percentage computation.

- `Mode` — enum: `idle`, `indeterminate`, `determinate`
- `ProgrezSnapshot` — immutable point-in-time snapshot of progress counters and timestamp
- `ProgrezState` — all mutable progress state (counters, timing, EMA, guesses, spinner, label, identity)
  - `init(label)` — create state in idle mode with given label
  - `getLabel()` — return label as slice
  - `setLabel(label)` — update display label mid-operation
  - `setIndeterminate()` — transition to spinner mode
  - `setDeterminate(files_total, bytes_total)` — transition to bar mode with known totals (0 = not tracking)
  - `setIdentity(caller_name, context_name)` — set caller identity for rich completion messages
  - `getCallerName()` — return caller name or null if no identity set
  - `getContextName()` — return context name or null if no identity set
  - `setGuess(guess_files, guess_bytes)` — set estimated totals for indeterminate mode (0 = no guess)
  - `snapshot(now_ns)` — capture read-only snapshot of current counters
  - `recordUpdate(bytes_processed, files_processed, now_ns)` — record cumulative progress, recalculate EMA rates, push to sparkline ring buffer
  - `estimateEtaSeconds()` — estimate seconds remaining via EMA rate (null if <3 samples or no total)
  - `percentComplete()` — completion fraction [0.0, 1.0] (null if no total known)
  - `elapsedSeconds(now_ns)` — seconds elapsed since start_time_ns

## src/format.zig
Pure formatting functions. All take a value + caller-provided buffer, return a slice. No allocations.

- `formatBytes(bytes, buf)` — human-readable byte count with SI units (B, KB, MB, GB, TB)
- `formatCount(count, buf)` — integer with comma-separated thousands
- `formatPercent(fraction, buf)` — fraction [0.0-1.0] as percentage with one decimal place
- `formatEta(seconds, buf)` — seconds as "ETA M:SS" or "ETA H:MM:SS"
- `formatElapsed(seconds, buf)` — seconds as "X.XXs", "XmXXs", or "XhXmXs"
- `formatThroughput(bytes_per_sec, buf)` — throughput rate as "4.2 MB/s" with SI units
- `formatSparkline(rates, count, buf)` — rate history as Unicode block sparkline (▁▂▃▄▅▆▇█)

## src/terminal.zig
Terminal capability detection. Pure logic: takes injected EnvInfo, returns TerminalCaps.

- `EnvInfo` — struct of environment info injected by caller (env vars + tty state + width)
- `TerminalCaps` — detected capabilities: is_tty, unicode, truecolor, color_256, color_16, width
  - `detect(env)` — detect capabilities from EnvInfo with priority: PROGREZ_STYLE=ascii > NO_COLOR > COLORTERM > WT_SESSION > TERM > defaults

## src/render.zig
Progress bar rendering. Pure logic: takes state + terminal caps, writes into caller-provided buffer.

- `renderDeterminate(state, caps, now_ns, buf)` — single-line determinate bar with progressive stat dropping at narrow widths
- `renderIndeterminate(state, caps, buf)` — single-line indeterminate spinner with optional guess percentage
- `renderCompletionSummary(state, now_ns, buf)` — persistent completion summary with elapsed time and details
- `renderLogLine(state, now_ns, buf)` — plain-text log line for non-TTY output (no ANSI, no Unicode art)
- `renderLine(state, caps, now_ns, buf)` — top-level dispatch: selects renderer based on mode (idle returns empty)

Internal (not pub):
- `renderUnicodeBar(buf, start, bar_width, frac, truecolor)` — Unicode bar with sub-character precision and optional truecolor gradient
- `renderAsciiBar(buf, start, bar_width, frac)` — ASCII bar with `[===>   ]` style
- `writeColoredBlock(buf, start, block, cell_idx, total_cells)` — truecolor gradient: cyan -> violet -> magenta

## src/ffi.zig
C FFI boundary layer. Bridges pure Zig core to C consumers. Manages render thread, seqlock, and I/O.

- `FfiContext` — opaque context handle exposed to C as `progrez_ctx*`
- `progrez_create(label)` — create context, read env vars, detect terminal (render thread deferred to first update)
- `progrez_destroy(ctx)` — free context (finishes render thread if still active)
- `progrez_update(ctx, files_processed, bytes_processed)` — update counters via seqlock; spawns render thread on first call (unless manual mode)
- `progrez_finish(ctx)` — stop render thread, write completion summary to stderr
- `progrez_render_line(ctx, buf, buf_size, width)` — render one frame into caller's buffer (enters manual mode on first call, preventing render thread)
- `progrez_set_indeterminate(ctx)` — switch to spinner mode
- `progrez_set_determinate(ctx, files_total, bytes_total)` — switch to bar mode with known totals
- `progrez_set_guess(ctx, guess_files, guess_bytes)` — set estimated totals for indeterminate mode
- `progrez_set_identity(ctx, caller_name, context_name)` — set caller identity
- `progrez_set_interval_ms(ctx, ms)` — set render interval in milliseconds
- `progrez_set_gradient(ctx, ...)` — set 3-stop gradient (start, mid, end RGB)
- `progrez_set_gradient_2(ctx, ...)` — set 2-stop gradient (start, end RGB)
- `progrez_set_label(ctx, label)` — update display label mid-operation
- `progrez_set_sparkline(ctx, enabled)` — enable/disable throughput sparkline
- `progrez_set_notify(ctx, enabled)` — enable/disable system notifications
- `progrez_set_notify_after(ctx, seconds)` — set notification time threshold
- `progrez_set_notify_callback(ctx, fn, userdata)` — set custom notification callback

Internal:
- `parseProgressEnv(val)` — parse PROGRESS env var ("true"/"1" -> true, "false"/"0" -> false)
- `parseIntervalEnv(val)` — parse PROGREZ_INTERVAL as u32 ms (default 100)
- `parseHexColor(hex)` — parse 6-digit hex color string to Color
- `parseGradientEnv(val)` — parse PROGREZ_GRADIENT env var (2 or 3-stop)
- `parseNotifyEnv(val)` — parse PROGREZ_NOTIFY env var (auto/on/off)
- `parseNotifyAfterEnv(val)` — parse PROGREZ_NOTIFY_AFTER as u32 secs (default 10)
- `detectNotifyMethod()` — detect available notification method (osascript/notify-send/bell)
- `sendNotification(method, message, alloc)` — dispatch system notification
- `getEnvVar(name)` — read environment variable
- `getTerminalWidth()` — POSIX ioctl TIOCGWINSZ on stderr (default 80)
- `readSnapshot(ctx)` — seqlock read: returns snapshot if consistent, null if write in progress
- `shouldEmitLogLine(ctx, now_ns)` — log throttle: every 10s or every 10% progress milestone
- `renderLoop(ctx)` — main render loop on dedicated thread

## include/progrez.h
C header. Declares opaque `progrez_ctx` type and all FFI functions including gradient, label, sparkline, and notification APIs.

## examples/demo.c
C demo program. Exercises indeterminate scan phase then determinate processing phase via the C FFI.

## tests/cli/test_cli.sh
CLI integration tests (Bash). 3 tests: demo runs without crash, PROGRESS=false suppresses output, completion summary present.

## build.zig
Build system. Static library (`libprogrez`), dynamic library (`libprogrez.dylib`/`.so`), C demo executable (`progrez-demo`), unit test step. Default optimize: ReleaseFast. Installs C header to `include/`. Exposes Zig module for downstream consumers.

## flake.nix
Nix flake. Provides `packages.default` (the library), `checks.test` (unit tests for Garnix CI), and `devShells.default` (zig + hyperfine).

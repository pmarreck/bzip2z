//! C FFI boundary layer for progrez.
//! Bridges pure Zig core logic to C consumers via exported functions.
//! Manages the render thread, seqlock-based snapshot passing, and I/O.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const terminal = @import("terminal.zig");
const render = @import("render.zig");
const GradientColors = render.GradientColors;
const Color = render.Color;

fn ffiAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

/// Cross-platform stderr file handle.
fn stderrFile() std.Io.File {
    return std.Io.File.stderr();
}

fn progrezIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Write bytes to an `std.Io.File` (0.16 needs a writer + flush).
fn writeAllToFile(file: std.Io.File, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(progrezIo(), &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// Cross-platform isatty check for stderr.
fn stderrIsAtty() bool {
    return stderrFile().isTty(progrezIo()) catch false;
}

/// Opaque context handle exposed to C as `progrez_ctx*`.
/// Contains all state needed for progress tracking and rendering.
const FfiContext = struct {
    state: core.ProgrezState,
    caps: terminal.TerminalCaps,
    interval_ms: u32,
    render_thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    // Seqlock for snapshot passing (writer: caller thread, reader: render thread)
    snapshot: core.ProgrezSnapshot,
    generation: std.atomic.Value(u32),
    // Config
    progress_enabled: bool,
    is_tty: bool,
    /// Manual render mode: caller drives rendering via progrez_render_line().
    /// Set automatically when progrez_render_line() is called before progrez_update().
    /// Prevents the render thread from being spawned.
    manual_mode: bool,
    // Gradient colors for the progress bar
    gradient: GradientColors,
    // Log mode tracking (non-TTY output)
    last_log_percent: i8, // -1 = no log yet
    last_log_time_ns: i128,
    // Notification config
    notify_mode: NotifyMode,
    notify_after_secs: u32,
    notify_method: NotifyMethod,
    notify_callback: ?*const fn ([*:0]const u8, ?*anyopaque) void,
    notify_userdata: ?*anyopaque,
};

// ── Env Var Parsing Helpers ─────────────────────────────────────────────

/// Parse PROGRESS env var: "true"/"1" -> true, "false"/"0" -> false, else null.
fn parseProgressEnv(val: ?[]const u8) ?bool {
    const v = val orelse return null;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    return null;
}

/// Parse PROGREZ_INTERVAL env var as u32 milliseconds. Default 100.
fn parseIntervalEnv(val: ?[]const u8) u32 {
    const v = val orelse return 100;
    return std.fmt.parseInt(u32, v, 10) catch 100;
}

/// Parse a 6-digit hex color (e.g. "FF00FF") into a Color. Returns null on invalid input.
fn parseHexColor(hex: []const u8) ?Color {
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

/// Parse PROGREZ_GRADIENT env var. Format: "RRGGBB,RRGGBB" (2-stop) or "RRGGBB,RRGGBB,RRGGBB" (3-stop).
/// Returns null if not set or invalid.
fn parseGradientEnv(val: ?[]const u8) ?GradientColors {
    const v = val orelse return null;
    // Find first comma
    const comma1 = std.mem.indexOfScalar(u8, v, ',') orelse return null;
    const first = v[0..comma1];
    const rest = v[comma1 + 1 ..];

    // Check for second comma
    if (std.mem.indexOfScalar(u8, rest, ',')) |comma2| {
        // 3-stop: start,mid,end
        const second = rest[0..comma2];
        const third = rest[comma2 + 1 ..];
        const c1 = parseHexColor(first) orelse return null;
        const c2 = parseHexColor(second) orelse return null;
        const c3 = parseHexColor(third) orelse return null;
        return .{ .start = c1, .mid = c2, .end = c3 };
    } else {
        // 2-stop: start,end
        const c1 = parseHexColor(first) orelse return null;
        const c2 = parseHexColor(rest) orelse return null;
        return .{ .start = c1, .mid = null, .end = c2 };
    }
}

const NotifyMode = enum { auto, on, off };
const NotifyMethod = enum { none, osascript, notify_send, bell };

fn parseNotifyEnv(val: ?[]const u8) NotifyMode {
    const v = val orelse return .auto;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return .on;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return .off;
    return .auto;
}

fn parseNotifyAfterEnv(val: ?[]const u8) u32 {
    const v = val orelse return 10;
    return std.fmt.parseInt(u32, v, 10) catch 10;
}

/// Detect which notification method is available on this system.
fn detectNotifyMethod() NotifyMethod {
    if (comptime builtin.os.tag == .macos) {
        return .osascript;
    } else if (comptime builtin.os.tag == .linux) {
        // Check if notify-send exists by trying to run "which notify-send"
        const result = std.process.run(ffiAllocator(), progrezIo(), .{
            .argv = &.{ "which", "notify-send" },
        }) catch return .bell;
        defer ffiAllocator().free(result.stdout);
        defer ffiAllocator().free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code == 0) return .notify_send,
            else => {},
        }
        return .bell;
    } else {
        return .bell;
    }
}

/// Run a command, ignoring stdout/stderr (best-effort).
fn spawnAndIgnore(alloc: std.mem.Allocator, argv: []const []const u8) void {
    const result = std.process.run(alloc, progrezIo(), .{ .argv = argv }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// Send a system notification.
fn sendNotification(method: NotifyMethod, message: []const u8, alloc: std.mem.Allocator) void {
    switch (method) {
        .osascript => {
            // Build AppleScript command with escaped message
            var escaped_buf: [1024]u8 = undefined;
            var escaped_len: usize = 0;
            for (message) |c| {
                if (c == '"' or c == '\\') {
                    if (escaped_len < escaped_buf.len) {
                        escaped_buf[escaped_len] = '\\';
                        escaped_len += 1;
                    }
                }
                if (escaped_len < escaped_buf.len) {
                    escaped_buf[escaped_len] = c;
                    escaped_len += 1;
                }
            }
            var script_buf: [1200]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buf, "display notification \"{s}\" with title \"progrez\"", .{escaped_buf[0..escaped_len]}) catch return;
            spawnAndIgnore(alloc, &.{ "osascript", "-e", script });
        },
        .notify_send => {
            spawnAndIgnore(alloc, &.{ "notify-send", "progrez", message });
        },
        .bell => {
            const stderr_file = stderrFile();
            writeAllToFile(stderr_file, "\x07") catch {};
        },
        .none => {},
    }
}

/// Read an environment variable. Returns null if not set.
fn getEnvVar(name: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        // std.c.getenv unavailable on Windows (WTF-16 env strings).
        // For now, skip env-var reading on Windows; features degrade gracefully.
        return null;
    } else {
        const c_val = std.c.getenv(name.ptr) orelse return null;
        return std.mem.span(c_val);
    }
}

// ── Terminal Width Detection ────────────────────────────────────────────

fn getTerminalWidth() u16 {
    if (comptime builtin.os.tag == .windows) {
        // Windows: TODO use kernel32 GetConsoleScreenBufferInfo
        return 80;
    } else {
        // POSIX: ioctl TIOCGWINSZ on stderr (fd 2)
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(2, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.col > 0) return ws.col;
        return 80;
    }
}

// ── Render Thread ───────────────────────────────────────────────────────

/// Seqlock read: returns snapshot if consistent, null if write was in progress.
fn readSnapshot(ctx: *FfiContext) ?core.ProgrezSnapshot {
    const gen1 = ctx.generation.load(.acquire);
    if (gen1 & 1 != 0) return null; // Write in progress (odd generation)
    const snap = ctx.snapshot;
    const gen2 = ctx.generation.load(.acquire);
    if (gen1 != gen2) return null; // Changed during read
    return snap;
}

/// Determine whether a log line should be emitted in non-TTY mode.
/// Criteria: every 10 seconds OR every 10% progress milestone.
fn shouldEmitLogLine(ctx: *FfiContext, now_ns: i128) bool {
    // Every 10 seconds
    const elapsed_since_last = now_ns - ctx.last_log_time_ns;
    if (elapsed_since_last >= 10 * std.time.ns_per_s) {
        ctx.last_log_time_ns = now_ns;
        return true;
    }
    // Every 10% progress
    if (ctx.state.percentComplete()) |pct| {
        const pct_int: i8 = @intFromFloat(pct * 10.0); // 0-10 (in 10% increments)
        if (pct_int > ctx.last_log_percent) {
            ctx.last_log_percent = pct_int;
            return true;
        }
    }
    return false;
}

/// Main render loop running on the dedicated render thread.
/// Reads snapshots via seqlock, renders to stderr.
fn renderLoop(ctx: *FfiContext) void {
    var render_buf: [8192]u8 = undefined;

    while (!ctx.stop_flag.load(.acquire)) {
        // Sleep for the configured interval
        std.Io.sleep(progrezIo(), .fromMilliseconds(@intCast(ctx.interval_ms)), .awake) catch {};

        if (ctx.stop_flag.load(.acquire)) break;

        // Seqlock read
        const snap = readSnapshot(ctx) orelse continue;

        // Apply snapshot to state
        // IMPORTANT: recordUpdate must be called BEFORE overwriting bytes/files_processed,
        // because it computes delta from the old values to calculate rates.
        if (snap.files_total) |ft| ctx.state.files_total = ft;
        if (snap.bytes_total) |bt| ctx.state.bytes_total = bt;
        ctx.state.recordUpdate(snap.bytes_processed, snap.files_processed, snap.timestamp_ns);

        const now_ns = snap.timestamp_ns;

        if (ctx.is_tty) {
            // Get current terminal width (may change if user resizes)
            ctx.caps.width = getTerminalWidth();

            // Advance spinner frame
            ctx.state.spinner_frame +%= 1;

            // Render the progress line (already padded to terminal width)
            const line = render.renderLine(&ctx.state, ctx.caps, now_ns, &render_buf, ctx.gradient);
            if (line.len > 0) {
                const stderr_file = stderrFile();
                writeAllToFile(stderr_file, "\r") catch {};
                writeAllToFile(stderr_file, line) catch {};
            }
        } else {
            // Log mode: emit line every 10s or 10% progress
            if (shouldEmitLogLine(ctx, now_ns)) {
                const line = render.renderLogLine(&ctx.state, now_ns, &render_buf);
                if (line.len > 0) {
                    const stderr_file = stderrFile();
                    writeAllToFile(stderr_file, line) catch {};
                }
            }
        }
    }
}

// ── Exported FFI Functions ──────────────────────────────────────────────

/// Create a new progress context. Returns null on allocation failure.
/// The label defaults to "Progress" if null is passed.
/// Reads env vars: PROGRESS, PROGREZ_INTERVAL, PROGREZ_STYLE, NO_COLOR,
/// COLORTERM, TERM, WT_SESSION.
export fn progrez_create(label: ?[*:0]const u8) ?*FfiContext {
    const alloc = ffiAllocator();
    const ctx = alloc.create(FfiContext) catch return null;

    // Parse label from C string
    const label_slice: []const u8 = if (label) |l| std.mem.span(l) else "Progress";

    // Read env vars
    const progress_env = getEnvVar("PROGRESS");
    const interval_env = getEnvVar("PROGREZ_INTERVAL");
    const style_env = getEnvVar("PROGREZ_STYLE");
    const no_color_env = getEnvVar("NO_COLOR");
    const colorterm_env = getEnvVar("COLORTERM");
    const term_env = getEnvVar("TERM");
    const wt_session_env = getEnvVar("WT_SESSION");

    const interval_ms = parseIntervalEnv(if (interval_env) |e| @as([]const u8, e) else null);
    const gradient_env = getEnvVar("PROGREZ_GRADIENT");
    const gradient = parseGradientEnv(if (gradient_env) |e| @as([]const u8, e) else null) orelse GradientColors.default;

    // Detect TTY on stderr (fd 2)
    const is_tty = stderrIsAtty();

    // Determine terminal width
    const width: u16 = if (is_tty) getTerminalWidth() else 80;

    // Detect terminal capabilities
    const caps = terminal.TerminalCaps.detect(.{
        .progrez_style = if (style_env) |e| @as([]const u8, e) else null,
        .no_color = if (no_color_env) |e| @as([]const u8, e) else null,
        .colorterm = if (colorterm_env) |e| @as([]const u8, e) else null,
        .term = if (term_env) |e| @as([]const u8, e) else null,
        .wt_session = if (wt_session_env) |e| @as([]const u8, e) else null,
        .is_tty = is_tty,
        .width = width,
    });

    // Determine if progress is enabled:
    // PROGRESS env var overrides TTY check
    const progress_enabled = parseProgressEnv(if (progress_env) |e| @as([]const u8, e) else null) orelse is_tty;

    const now_ns = std.Io.Clock.Timestamp.now(progrezIo(), .awake).raw.toNanoseconds();

    // Initialize state
    var state = core.ProgrezState.init(label_slice);
    state.start_time_ns = now_ns;
    state.last_update_ns = now_ns;

    const sparkline_env = getEnvVar("PROGREZ_SPARKLINE");
    if (sparkline_env) |e| {
        if (std.mem.eql(u8, @as([]const u8, e), "true") or std.mem.eql(u8, @as([]const u8, e), "1")) {
            state.sparkline_enabled = true;
        }
    }

    const notify_env = getEnvVar("PROGREZ_NOTIFY");
    const notify_after_env = getEnvVar("PROGREZ_NOTIFY_AFTER");
    const notify_mode = parseNotifyEnv(if (notify_env) |e| @as([]const u8, e) else null);
    const notify_after = parseNotifyAfterEnv(if (notify_after_env) |e| @as([]const u8, e) else null);
    const notify_method: NotifyMethod = if (notify_mode != .off) detectNotifyMethod() else .none;

    ctx.* = .{
        .state = state,
        .caps = caps,
        .interval_ms = interval_ms,
        .render_thread = null,
        .stop_flag = std.atomic.Value(bool).init(false),
        .snapshot = .{
            .files_processed = 0,
            .files_total = null,
            .bytes_processed = 0,
            .bytes_total = null,
            .timestamp_ns = now_ns,
        },
        .generation = std.atomic.Value(u32).init(0),
        .progress_enabled = progress_enabled,
        .is_tty = is_tty,
        .manual_mode = false,
        .gradient = gradient,
        .last_log_percent = -1,
        .last_log_time_ns = now_ns,
        .notify_mode = notify_mode,
        .notify_after_secs = notify_after,
        .notify_method = notify_method,
        .notify_callback = null,
        .notify_userdata = null,
    };

    // Render thread is spawned lazily on first progrez_update() call,
    // unless manual_mode is set (via progrez_render_line()).
    return ctx;
}

/// Render the current progress bar into a caller-provided buffer.
/// Returns the number of bytes written (not null-terminated).
/// On first call, sets manual_mode to prevent the render thread from starting.
/// The caller is responsible for calling this at their own cadence.
export fn progrez_render_line(ctx: ?*FfiContext, buf: [*]u8, buf_size: usize, width: u16) usize {
    const c = ctx orelse return 0;
    if (buf_size == 0) return 0;

    // Enter manual mode: prevent render thread from starting (or stop it if already running)
    if (!c.manual_mode) {
        c.manual_mode = true;
        if (c.render_thread) |thread| {
            c.stop_flag.store(true, .release);
            thread.join();
            c.render_thread = null;
        }
    }

    // Apply latest snapshot to state
    const now_ns = std.Io.Clock.Timestamp.now(progrezIo(), .awake).raw.toNanoseconds();
    if (c.snapshot.files_total) |ft| c.state.files_total = ft;
    if (c.snapshot.bytes_total) |bt| c.state.bytes_total = bt;
    c.state.recordUpdate(c.snapshot.bytes_processed, c.snapshot.files_processed, now_ns);

    // Update width for this render
    var caps = c.caps;
    caps.width = width;

    // Advance spinner frame
    c.state.spinner_frame +%= 1;

    // Render into caller's buffer
    const line = render.renderLine(&c.state, caps, now_ns, buf[0..buf_size], c.gradient);
    return line.len;
}

/// Destroy a progress context and free its memory.
/// If the render thread is still active, finishes it first.
export fn progrez_destroy(ctx: ?*FfiContext) void {
    const c = ctx orelse return;
    // If render thread is still active, finish first
    if (c.render_thread != null) {
        progrez_finish(ctx);
    }
    ffiAllocator().destroy(c);
}

/// Update progress counters. Uses seqlock for thread-safe snapshot passing.
/// files_processed and bytes_processed are absolute (cumulative) values.
/// On first call, spawns the render thread (unless manual_mode is active).
export fn progrez_update(ctx: ?*FfiContext, files_processed: u64, bytes_processed: u64) void {
    const c = ctx orelse return;
    const now_ns = std.Io.Clock.Timestamp.now(progrezIo(), .awake).raw.toNanoseconds();

    // Lazily spawn render thread on first update
    if (c.render_thread == null and c.progress_enabled and !c.manual_mode) {
        c.render_thread = std.Thread.spawn(.{}, renderLoop, .{c}) catch null;
    }

    // Seqlock write: odd generation = write in progress
    const gen = c.generation.load(.monotonic);
    c.generation.store(gen +% 1, .release); // odd = writing

    c.snapshot = .{
        .files_processed = files_processed,
        .files_total = c.state.files_total,
        .bytes_processed = bytes_processed,
        .bytes_total = c.state.bytes_total,
        .timestamp_ns = now_ns,
    };

    c.generation.store(gen +% 2, .release); // even = done
}

/// Signal completion: stop the render thread and write a summary to stderr.
export fn progrez_finish(ctx: ?*FfiContext) void {
    const c = ctx orelse return;

    // Signal the render thread to stop
    c.stop_flag.store(true, .release);

    // Join the render thread
    if (c.render_thread) |thread| {
        thread.join();
        c.render_thread = null;
    }

    // Apply final snapshot to state for the summary
    if (readSnapshot(c)) |snap| {
        c.state.files_processed = snap.files_processed;
        c.state.bytes_processed = snap.bytes_processed;
    }

    // Write completion summary to stderr
    if (c.progress_enabled) {
        const now_ns = std.Io.Clock.Timestamp.now(progrezIo(), .awake).raw.toNanoseconds();
        var summary_buf: [1024]u8 = undefined;
        const summary = render.renderCompletionSummary(&c.state, now_ns, &summary_buf);
        if (summary.len > 0) {
            const stderr_file = stderrFile();
            if (c.is_tty) {
                // Clear the progress line first
                writeAllToFile(stderr_file, "\r\x1b[2K") catch {};
            }
            writeAllToFile(stderr_file, summary) catch {};
        }

        // Send notification if enabled and elapsed time exceeds threshold
        const elapsed_secs = c.state.elapsedSeconds(now_ns);
        const should_notify = switch (c.notify_mode) {
            .on => true,
            .off => false,
            .auto => elapsed_secs >= @as(f64, @floatFromInt(c.notify_after_secs)),
        };

        if (should_notify) {
            if (c.notify_callback) |cb| {
                // Use callback if registered
                const notify_msg = render.renderCompletionSummary(&c.state, now_ns, &summary_buf);
                const msg_trimmed = std.mem.trimEnd(u8, notify_msg, "\n");
                var c_str_buf: [512]u8 = undefined;
                if (msg_trimmed.len < c_str_buf.len) {
                    @memcpy(c_str_buf[0..msg_trimmed.len], msg_trimmed);
                    c_str_buf[msg_trimmed.len] = 0;
                    cb(@ptrCast(&c_str_buf), c.notify_userdata);
                }
            } else if (c.notify_method != .none) {
                const notify_msg = render.renderCompletionSummary(&c.state, now_ns, &summary_buf);
                const msg_trimmed = std.mem.trimEnd(u8, notify_msg, "\n");
                sendNotification(c.notify_method, msg_trimmed, ffiAllocator());
            }
        }
    }
}

/// Switch to indeterminate mode (spinner, no percentage).
export fn progrez_set_indeterminate(ctx: ?*FfiContext) void {
    const c = ctx orelse return;
    c.state.setIndeterminate();
}

/// Switch to determinate mode with known totals.
/// A total of 0 means "not tracking that dimension".
export fn progrez_set_determinate(ctx: ?*FfiContext, files_total: u64, bytes_total: u64) void {
    const c = ctx orelse return;
    c.state.setDeterminate(files_total, bytes_total);
}

/// Set estimated totals (guesses) for indeterminate mode.
/// A value of 0 means "no guess".
export fn progrez_set_guess(ctx: ?*FfiContext, guess_files: u64, guess_bytes: u64) void {
    const c = ctx orelse return;
    c.state.setGuess(guess_files, guess_bytes);
}

/// Set the caller identity (who is reporting progress and what for).
export fn progrez_set_identity(ctx: ?*FfiContext, caller_name: ?[*:0]const u8, context_name: ?[*:0]const u8) void {
    const c = ctx orelse return;
    const cn: []const u8 = if (caller_name) |n| std.mem.span(n) else "";
    const cxn: []const u8 = if (context_name) |n| std.mem.span(n) else "";
    c.state.setIdentity(cn, cxn);
}

/// Set the render interval in milliseconds.
export fn progrez_set_interval_ms(ctx: ?*FfiContext, ms: u32) void {
    const c = ctx orelse return;
    c.interval_ms = ms;
}

/// Set the gradient colors for the progress bar.
/// Pass 3 RGB color stops (start, mid, end). To use a 2-stop gradient,
/// set mid_r=mid_g=mid_b=255 and mid_is_none=true (or just use the env var).
/// For simplicity, this always takes 3 stops; set mid equal to the average
/// of start and end for a perceptually linear 2-stop effect, or use
/// PROGREZ_GRADIENT env var for 2-stop support.
export fn progrez_set_gradient(
    ctx: ?*FfiContext,
    start_r: u8,
    start_g: u8,
    start_b: u8,
    mid_r: u8,
    mid_g: u8,
    mid_b: u8,
    end_r: u8,
    end_g: u8,
    end_b: u8,
) void {
    const c = ctx orelse return;
    c.gradient = .{
        .start = .{ .r = start_r, .g = start_g, .b = start_b },
        .mid = .{ .r = mid_r, .g = mid_g, .b = mid_b },
        .end = .{ .r = end_r, .g = end_g, .b = end_b },
    };
}

/// Set a 2-stop gradient (start to end, linear interpolation).
export fn progrez_set_gradient_2(
    ctx: ?*FfiContext,
    start_r: u8,
    start_g: u8,
    start_b: u8,
    end_r: u8,
    end_g: u8,
    end_b: u8,
) void {
    const c = ctx orelse return;
    c.gradient = .{
        .start = .{ .r = start_r, .g = start_g, .b = start_b },
        .mid = null,
        .end = .{ .r = end_r, .g = end_g, .b = end_b },
    };
}

/// Enable or disable the throughput sparkline display.
export fn progrez_set_sparkline(ctx: ?*FfiContext, enabled: bool) void {
    const c = ctx orelse return;
    c.state.sparkline_enabled = enabled;
}

/// Update the display label.
export fn progrez_set_label(ctx: ?*FfiContext, label: ?[*:0]const u8) void {
    const c = ctx orelse return;
    const label_slice: []const u8 = if (label) |l| std.mem.span(l) else "";
    c.state.setLabel(label_slice);
}

/// Enable or disable notifications.
export fn progrez_set_notify(ctx: ?*FfiContext, enabled: bool) void {
    const c = ctx orelse return;
    c.notify_mode = if (enabled) .on else .off;
}

/// Set the notification time threshold in seconds.
export fn progrez_set_notify_after(ctx: ?*FfiContext, seconds: u32) void {
    const c = ctx orelse return;
    c.notify_after_secs = seconds;
}

/// Set a notification callback. If set, the built-in notification is skipped.
export fn progrez_set_notify_callback(
    ctx: ?*FfiContext,
    callback: ?*const fn ([*:0]const u8, ?*anyopaque) void,
    userdata: ?*anyopaque,
) void {
    const c = ctx orelse return;
    c.notify_callback = callback;
    c.notify_userdata = userdata;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "ffi: null ctx safety" {
    progrez_update(null, 0, 0);
    progrez_finish(null);
    progrez_destroy(null);
    progrez_set_indeterminate(null);
    progrez_set_determinate(null, 0, 0);
    progrez_set_guess(null, 0, 0);
    progrez_set_identity(null, null, null);
    progrez_set_interval_ms(null, 0);
    progrez_set_gradient(null, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    progrez_set_gradient_2(null, 0, 0, 0, 0, 0, 0);
    progrez_set_sparkline(null, false);
    progrez_set_label(null, null);
    progrez_set_notify(null, false);
    progrez_set_notify_after(null, 0);
    progrez_set_notify_callback(null, null, null);
}

test "ffi: parse progress env" {
    try std.testing.expectEqual(@as(?bool, true), parseProgressEnv("true"));
    try std.testing.expectEqual(@as(?bool, true), parseProgressEnv("1"));
    try std.testing.expectEqual(@as(?bool, false), parseProgressEnv("false"));
    try std.testing.expectEqual(@as(?bool, false), parseProgressEnv("0"));
    try std.testing.expectEqual(@as(?bool, null), parseProgressEnv(null));
    try std.testing.expectEqual(@as(?bool, null), parseProgressEnv("garbage"));
}

test "ffi: parse interval env" {
    try std.testing.expectEqual(@as(u32, 500), parseIntervalEnv("500"));
    try std.testing.expectEqual(@as(u32, 100), parseIntervalEnv(null));
    try std.testing.expectEqual(@as(u32, 100), parseIntervalEnv("garbage"));
}

test "ffi: parse hex color" {
    const c = parseHexColor("FF8000");
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(u8, 255), c.?.r);
    try std.testing.expectEqual(@as(u8, 128), c.?.g);
    try std.testing.expectEqual(@as(u8, 0), c.?.b);
    try std.testing.expectEqual(@as(?Color, null), parseHexColor(""));
    try std.testing.expectEqual(@as(?Color, null), parseHexColor("ZZZZZZ"));
    try std.testing.expectEqual(@as(?Color, null), parseHexColor("FFF")); // too short
}

test "ffi: parse gradient env 2-stop" {
    const g = parseGradientEnv("FF0000,00FF00");
    try std.testing.expect(g != null);
    try std.testing.expectEqual(@as(u8, 255), g.?.start.r);
    try std.testing.expectEqual(@as(u8, 0), g.?.start.g);
    try std.testing.expectEqual(@as(u8, 0), g.?.end.r);
    try std.testing.expectEqual(@as(u8, 255), g.?.end.g);
    try std.testing.expect(g.?.mid == null);
}

test "ffi: parse gradient env 3-stop" {
    const g = parseGradientEnv("FF0000,FFFF00,00FF00");
    try std.testing.expect(g != null);
    try std.testing.expectEqual(@as(u8, 255), g.?.start.r);
    try std.testing.expectEqual(@as(u8, 255), g.?.mid.?.r);
    try std.testing.expectEqual(@as(u8, 255), g.?.mid.?.g);
    try std.testing.expectEqual(@as(u8, 0), g.?.end.r);
    try std.testing.expectEqual(@as(u8, 255), g.?.end.g);
}

test "ffi: parse gradient env invalid" {
    try std.testing.expectEqual(@as(?GradientColors, null), parseGradientEnv(null));
    try std.testing.expectEqual(@as(?GradientColors, null), parseGradientEnv("garbage"));
    try std.testing.expectEqual(@as(?GradientColors, null), parseGradientEnv("FF0000")); // no comma
    try std.testing.expectEqual(@as(?GradientColors, null), parseGradientEnv("ZZ0000,FF0000")); // bad hex
}

test "ffi: seqlock read returns null during write" {
    // Simulate a write-in-progress by setting an odd generation
    var ctx: FfiContext = undefined;
    ctx.generation = std.atomic.Value(u32).init(1); // odd = write in progress
    ctx.snapshot = .{
        .files_processed = 0,
        .files_total = null,
        .bytes_processed = 0,
        .bytes_total = null,
        .timestamp_ns = 0,
    };
    try std.testing.expectEqual(@as(?core.ProgrezSnapshot, null), readSnapshot(&ctx));
}

test "ffi: seqlock read returns snapshot when consistent" {
    var ctx: FfiContext = undefined;
    ctx.generation = std.atomic.Value(u32).init(2); // even = consistent
    ctx.snapshot = .{
        .files_processed = 42,
        .files_total = null,
        .bytes_processed = 1000,
        .bytes_total = null,
        .timestamp_ns = 999,
    };
    const snap = readSnapshot(&ctx);
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 42), snap.?.files_processed);
    try std.testing.expectEqual(@as(u64, 1000), snap.?.bytes_processed);
}

test "ffi: shouldEmitLogLine respects 10s interval" {
    var ctx: FfiContext = undefined;
    ctx.state = core.ProgrezState.init("Test");
    ctx.last_log_time_ns = 0;
    ctx.last_log_percent = -1;

    // At 5 seconds: not yet (no progress either)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 5 * std.time.ns_per_s));

    // At 10 seconds: yes
    try std.testing.expect(shouldEmitLogLine(&ctx, 10 * std.time.ns_per_s));

    // Immediately after: no (timer was reset)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 10 * std.time.ns_per_s + 1));
}

test "ffi: shouldEmitLogLine respects 10% progress milestones" {
    var ctx: FfiContext = undefined;
    ctx.state = core.ProgrezState.init("Test");
    ctx.state.setDeterminate(0, 1000);
    ctx.last_log_time_ns = 0;
    ctx.last_log_percent = -1;

    // 5% progress: triggers because decile 0 > last_log_percent of -1
    // (first progress emission at any percentage)
    ctx.state.bytes_processed = 50;
    try std.testing.expect(shouldEmitLogLine(&ctx, 1 * std.time.ns_per_s));
    // last_log_percent is now 0

    // Still at 5%: no (same decile)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 2 * std.time.ns_per_s));

    // 10% progress: yes (decile 1 > 0)
    ctx.state.bytes_processed = 100;
    try std.testing.expect(shouldEmitLogLine(&ctx, 3 * std.time.ns_per_s));

    // Still at 10%: no
    try std.testing.expect(!shouldEmitLogLine(&ctx, 4 * std.time.ns_per_s));

    // 20% progress: yes (decile 2 > 1)
    ctx.state.bytes_processed = 200;
    try std.testing.expect(shouldEmitLogLine(&ctx, 5 * std.time.ns_per_s));
}

test "ffi: parse notify env" {
    try std.testing.expectEqual(NotifyMode.auto, parseNotifyEnv(null));
    try std.testing.expectEqual(NotifyMode.on, parseNotifyEnv("true"));
    try std.testing.expectEqual(NotifyMode.on, parseNotifyEnv("1"));
    try std.testing.expectEqual(NotifyMode.off, parseNotifyEnv("false"));
    try std.testing.expectEqual(NotifyMode.off, parseNotifyEnv("0"));
    try std.testing.expectEqual(NotifyMode.auto, parseNotifyEnv("auto"));
    try std.testing.expectEqual(NotifyMode.auto, parseNotifyEnv("garbage"));
}

test "ffi: parse notify after env" {
    try std.testing.expectEqual(@as(u32, 10), parseNotifyAfterEnv(null));
    try std.testing.expectEqual(@as(u32, 30), parseNotifyAfterEnv("30"));
    try std.testing.expectEqual(@as(u32, 10), parseNotifyAfterEnv("garbage"));
    try std.testing.expectEqual(@as(u32, 0), parseNotifyAfterEnv("0"));
}

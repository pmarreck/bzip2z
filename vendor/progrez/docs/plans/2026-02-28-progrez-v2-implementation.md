# progrez v2 Features — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add throughput stats, sparkline, label update, CI infrastructure, and system notifications to progrez.

**Architecture:** Pure additions to the existing Zig core + C FFI architecture. New formatting functions in format.zig, new state fields in core.zig, new render logic in render.zig, new FFI exports in ffi.zig. CI is infrastructure-only (no code changes). Notifications use fork/exec via `std.process.Child`.

**Tech Stack:** Zig 0.15.x, C FFI, Nix flakes, GitHub Actions, Garnix

---

### Task 1: Throughput Formatter

**Files:**
- Modify: `src/format.zig`

**Step 1: Write the failing test**

Add to the bottom of `src/format.zig`, before the closing `}` (if any) or at the end:

```zig
test "format: throughput" {
    var buf: [32]u8 = undefined;

    // Zero
    try std.testing.expectEqualStrings("0 B/s", formatThroughput(0.0, &buf));

    // Bytes range
    try std.testing.expectEqualStrings("500.0 B/s", formatThroughput(500.0, &buf));

    // KB range
    try std.testing.expectEqualStrings("1.5 KB/s", formatThroughput(1500.0, &buf));

    // MB range
    try std.testing.expectEqualStrings("12.3 MB/s", formatThroughput(12_300_000.0, &buf));

    // GB range
    try std.testing.expectEqualStrings("1.0 GB/s", formatThroughput(1_000_000_000.0, &buf));
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL with "use of undefined identifier 'formatThroughput'"

**Step 3: Write minimal implementation**

Add after the `formatElapsed` function in `src/format.zig`:

```zig
/// Format a throughput rate (bytes/sec) into a human-readable string.
/// Examples: "0 B/s", "1.5 KB/s", "12.3 MB/s"
pub fn formatThroughput(bytes_per_sec: f64, buf: []u8) []const u8 {
    if (bytes_per_sec <= 0.0) {
        const s = "0 B/s";
        if (buf.len >= s.len) {
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        }
        return "";
    }
    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s" };
    var val = bytes_per_sec;
    var unit_idx: usize = 0;
    while (val >= 1000.0 and unit_idx < units.len - 1) {
        val /= 1000.0;
        unit_idx += 1;
    }
    if (unit_idx == 0 and val < 10.0) {
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[unit_idx] }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[unit_idx] }) catch "";
}
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/format.zig
git commit -m "feat: add formatThroughput formatter"
```

---

### Task 2: Throughput in Determinate Bar

**Files:**
- Modify: `src/render.zig`

**Step 1: Write the failing test**

Add to `src/render.zig` tests:

```zig
test "render: determinate bar shows throughput" {
    var state = core.ProgrezState.init("Test");
    state.setDeterminate(100, 10_000);
    state.files_processed = 50;
    state.bytes_processed = 5000;
    state.ema_bytes_per_sec = 1_500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 120,
    };

    var buf_arr: [2048]u8 = undefined;
    const line = renderDeterminate(&state, caps, 5_000_000_000, &buf_arr, GradientColors.default);

    // Should contain throughput
    try std.testing.expect(std.mem.indexOf(u8, line, "MB/s") != null or
        std.mem.indexOf(u8, line, "KB/s") != null);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL (no throughput in output)

**Step 3: Implement throughput in stat levels**

In `renderDeterminate`, add a `throughput_buf` and `throughput_str` alongside the existing eta/bytes/files/pct buffers. Then update the `StatLevel` enum and the stat assembly loop to include throughput between bytes and ETA.

Changes to `renderDeterminate` in `src/render.zig`:

1. Add throughput formatting after the ETA formatting block:
```zig
    var throughput_buf: [32]u8 = undefined;
    var throughput_str: []const u8 = "";
    if (state.ema_bytes_per_sec > 0.0 and state.samples_count >= 3) {
        throughput_str = format.formatThroughput(state.ema_bytes_per_sec, &throughput_buf);
    }
```

2. Change `StatLevel` to:
```zig
    const StatLevel = enum { all, no_eta, no_throughput, no_bytes, no_files, none };
    const levels = [_]StatLevel{ .all, .no_eta, .no_throughput, .no_bytes, .no_files, .none };
```

3. Update the stat assembly loop — add throughput between bytes and eta:
```zig
        if (level == .all or level == .no_eta) {
            if (throughput_str.len > 0) {
                stats_parts[stats_count] = throughput_str;
                stats_count += 1;
            }
        }
```
Place this AFTER the bytes block and BEFORE the eta block. Increase `stats_parts` array size from `[4]` to `[5]`.

Also add throughput to `renderLogLine` — after the bytes section, before ETA:
```zig
    // Throughput
    if (state.ema_bytes_per_sec > 0.0 and state.samples_count >= 3) {
        var throughput_buf: [32]u8 = undefined;
        const tp_str = format.formatThroughput(state.ema_bytes_per_sec, &throughput_buf);
        if (pos + 1 + tp_str.len <= buf.len) {
            buf[pos] = ' ';
            pos += 1;
            @memcpy(buf[pos .. pos + tp_str.len], tp_str);
            pos += tp_str.len;
        }
    }
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/render.zig
git commit -m "feat: add throughput stats to progress bar and log mode"
```

---

### Task 3: Sparkline — Core State

**Files:**
- Modify: `src/core.zig`

**Step 1: Write the failing test**

Add to `src/core.zig` tests:

```zig
test "core: rate history ring buffer" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 10000);
    state.start_time_ns = 0;
    state.last_update_ns = 0;

    // Record several updates at 1-second intervals
    state.recordUpdate(1000, 0, 1 * std.time.ns_per_s);
    state.recordUpdate(3000, 0, 2 * std.time.ns_per_s);
    state.recordUpdate(6000, 0, 3 * std.time.ns_per_s);
    state.recordUpdate(10000, 0, 4 * std.time.ns_per_s);

    try std.testing.expectEqual(@as(u8, 4), state.rate_history_len);
    // First rate: 1000 bytes/sec
    try std.testing.expect(state.rate_history[0] > 0.0);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL — no `rate_history_len` field

**Step 3: Implement rate history in ProgrezState**

Add fields to `ProgrezState` struct:
```zig
    // Sparkline rate history (ring buffer of last 8 instantaneous rates)
    rate_history: [8]f64,
    rate_history_len: u8,      // how many entries have been written (0-8)
    rate_history_idx: u8,      // next write position
```

Initialize in `init()`:
```zig
            .rate_history = [_]f64{0.0} ** 8,
            .rate_history_len = 0,
            .rate_history_idx = 0,
```

In `recordUpdate()`, after computing the instantaneous byte rate (`new_byte_rate`), push to ring buffer:
```zig
        // Push to sparkline ring buffer
        self.rate_history[self.rate_history_idx] = new_byte_rate;
        self.rate_history_idx = (self.rate_history_idx + 1) % 8;
        if (self.rate_history_len < 8) self.rate_history_len += 1;
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core.zig
git commit -m "feat: add rate history ring buffer for sparkline"
```

---

### Task 4: Sparkline Formatter

**Files:**
- Modify: `src/format.zig`

**Step 1: Write the failing test**

```zig
test "format: sparkline" {
    var buf: [16]u8 = undefined;

    // Ascending rates
    const rates1 = [8]f64{ 100, 200, 300, 400, 500, 600, 700, 800 };
    const s1 = formatSparkline(&rates1, 8, &buf);
    try std.testing.expectEqual(@as(usize, 24), s1.len); // 8 chars * 3 bytes each (UTF-8)

    // All same rate = all same block
    const rates2 = [8]f64{ 500, 500, 500, 500, 500, 500, 500, 500 };
    const s2 = formatSparkline(&rates2, 8, &buf);
    try std.testing.expectEqual(@as(usize, 24), s2.len);

    // Partial buffer (only 3 entries)
    const rates3 = [8]f64{ 100, 300, 200, 0, 0, 0, 0, 0 };
    const s3 = formatSparkline(&rates3, 3, &buf);
    try std.testing.expectEqual(@as(usize, 9), s3.len); // 3 chars * 3 bytes

    // Zero entries
    const rates4 = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const s4 = formatSparkline(&rates4, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), s4.len);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL

**Step 3: Implement formatSparkline**

Add to `src/format.zig`:

```zig
/// Sparkline block elements (8 levels, lowest to highest).
const sparkline_blocks = [8][]const u8{
    "\xe2\x96\x81", // ▁
    "\xe2\x96\x82", // ▂
    "\xe2\x96\x83", // ▃
    "\xe2\x96\x84", // ▄
    "\xe2\x96\x85", // ▅
    "\xe2\x96\x86", // ▆
    "\xe2\x96\x87", // ▇
    "\xe2\x96\x88", // █
};

/// Format a sparkline from a rate history buffer.
/// Normalizes values to min/max of the window, maps to 8 block levels.
/// Returns empty slice if count == 0.
pub fn formatSparkline(rates: *const [8]f64, count: u8, buf: []u8) []const u8 {
    if (count == 0) return "";
    const n: usize = @intCast(count);

    // Find min/max
    var min_rate: f64 = rates[0];
    var max_rate: f64 = rates[0];
    for (0..n) |i| {
        if (rates[i] < min_rate) min_rate = rates[i];
        if (rates[i] > max_rate) max_rate = rates[i];
    }

    var pos: usize = 0;
    const range = max_rate - min_rate;

    for (0..n) |i| {
        const level: usize = if (range <= 0.0)
            3 // middle level if all same
        else
            @min(@as(usize, @intFromFloat(((rates[i] - min_rate) / range) * 7.0)), 7);

        const block = sparkline_blocks[level];
        if (pos + block.len <= buf.len) {
            @memcpy(buf[pos .. pos + block.len], block);
            pos += block.len;
        }
    }

    return buf[0..pos];
}
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/format.zig
git commit -m "feat: add formatSparkline formatter"
```

---

### Task 5: Sparkline in Render + FFI

**Files:**
- Modify: `src/render.zig`
- Modify: `src/ffi.zig`
- Modify: `include/progrez.h`

**Step 1: Write the failing test**

Add to `src/render.zig` tests:

```zig
test "render: determinate bar shows sparkline when enabled" {
    var state = core.ProgrezState.init("Test");
    state.setDeterminate(100, 10_000);
    state.files_processed = 50;
    state.bytes_processed = 5000;
    state.ema_bytes_per_sec = 1_500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;
    state.sparkline_enabled = true;
    // Fill rate history
    for (0..8) |i| {
        state.rate_history[i] = @as(f64, @floatFromInt(i + 1)) * 200_000.0;
    }
    state.rate_history_len = 8;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 120,
    };

    var buf_arr: [2048]u8 = undefined;
    const line = renderDeterminate(&state, caps, 5_000_000_000, &buf_arr, GradientColors.default);

    // Should contain sparkline block chars (▁ through █)
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96") != null);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL — no `sparkline_enabled` field

**Step 3: Implement**

1. Add to `ProgrezState` in `src/core.zig`:
```zig
    sparkline_enabled: bool,
```
Initialize as `false` in `init()`.

2. In `renderDeterminate` in `src/render.zig`, add sparkline formatting after throughput:
```zig
    var sparkline_buf: [32]u8 = undefined;
    var sparkline_str: []const u8 = "";
    if (state.sparkline_enabled and state.rate_history_len >= 2) {
        // Read ring buffer in order (oldest first)
        var ordered: [8]f64 = undefined;
        const n = state.rate_history_len;
        const start_idx = if (n >= 8) state.rate_history_idx else 0;
        for (0..n) |i| {
            ordered[i] = state.rate_history[(start_idx + i) % 8];
        }
        sparkline_str = format.formatSparkline(&ordered, n, &sparkline_buf);
    }
```

Add sparkline to the stat levels — drops at same level as throughput:
```zig
        if (level == .all or level == .no_eta) {
            if (sparkline_str.len > 0) {
                stats_parts[stats_count] = sparkline_str;
                stats_count += 1;
            }
        }
```
Place immediately after the throughput insertion. Increase `stats_parts` array from `[5]` to `[6]`.

3. In `src/ffi.zig`, add parsing for `PROGREZ_SPARKLINE` env var in `progrez_create`:
```zig
    const sparkline_env = getEnvVar("PROGREZ_SPARKLINE");
    if (sparkline_env) |e| {
        if (std.mem.eql(u8, @as([]const u8, e), "true") or std.mem.eql(u8, @as([]const u8, e), "1")) {
            state.sparkline_enabled = true;
        }
    }
```

4. Add new FFI export:
```zig
/// Enable or disable the throughput sparkline display.
export fn progrez_set_sparkline(ctx: ?*FfiContext, enabled: bool) void {
    const c = ctx orelse return;
    c.state.sparkline_enabled = enabled;
}
```

5. Add null safety test for new function:
```zig
    progrez_set_sparkline(null, false);
```

6. Add to `include/progrez.h`:
```c
void progrez_set_sparkline(progrez_ctx *ctx, _Bool enabled);
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core.zig src/render.zig src/ffi.zig include/progrez.h
git commit -m "feat: add sparkline display for throughput history"
```

---

### Task 6: Label Update

**Files:**
- Modify: `src/core.zig`
- Modify: `src/ffi.zig`
- Modify: `include/progrez.h`

**Step 1: Write the failing test**

Add to `src/core.zig` tests:

```zig
test "core: setLabel updates label" {
    var state = ProgrezState.init("Scanning");
    try std.testing.expectEqualStrings("Scanning", state.getLabel());

    state.setLabel("Compressing");
    try std.testing.expectEqualStrings("Compressing", state.getLabel());

    state.setLabel("Verifying");
    try std.testing.expectEqualStrings("Verifying", state.getLabel());
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL — no `setLabel` method

**Step 3: Implement**

Add to `ProgrezState` in `src/core.zig`:
```zig
    /// Update the display label.
    pub fn setLabel(self: *ProgrezState, label: []const u8) void {
        const copy_len = @min(label.len, self.label_buf.len);
        @memcpy(self.label_buf[0..copy_len], label[0..copy_len]);
        self.label_len = @intCast(copy_len);
    }
```

Add FFI export in `src/ffi.zig`:
```zig
/// Update the display label.
export fn progrez_set_label(ctx: ?*FfiContext, label: ?[*:0]const u8) void {
    const c = ctx orelse return;
    const label_slice: []const u8 = if (label) |l| std.mem.span(l) else "";
    c.state.setLabel(label_slice);
}
```

Add null safety test:
```zig
    progrez_set_label(null, null);
```

Add to `include/progrez.h`:
```c
void progrez_set_label(progrez_ctx *ctx, const char *label);
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/core.zig src/ffi.zig include/progrez.h
git commit -m "feat: add progrez_set_label for mid-operation label changes"
```

---

### Task 7: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

**Step 1: Create CI workflow**

```yaml
name: CI

on:
  push:
    branches: [yolo]
  pull_request:

jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: DeterminateSystems/nix-installer-action@main
      - uses: DeterminateSystems/magic-nix-cache-action@main
      - run: nix flake check
```

**Step 2: Verify flake check works locally**

Run: `nix flake check 2>&1`
Expected: PASS (builds and tests pass)

**Step 3: Add badges to README.md**

Add after the `# progrez` title line (line 1), before the description:

```markdown
[![CI](https://github.com/pmarreck/progrez/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/progrez/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

**Step 4: Commit**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "feat: add GitHub Actions CI and README badges"
```

---

### Task 8: Flake Output Verification

**Files:**
- Modify: `flake.nix`

**Step 1: Verify current flake output installs headers**

Run: `nix build .#default 2>&1 && ls result/lib/ result/include/ 2>&1`

If headers are not installed, update the `installPhase` in `flake.nix` to copy them:
```nix
postInstall = ''
  mkdir -p $out/include
  cp include/progrez.h $out/include/
'';
```

**Step 2: Verify both static and shared libraries are present**

Run: `ls result/lib/`
Expected: Should contain `libprogrez.a` and `libprogrez.dylib` (or `.so` on Linux)

**Step 3: Commit if changes needed**

```bash
git add flake.nix
git commit -m "fix: ensure flake output includes headers and shared library"
```

---

### Task 9: System Notifications — Core

**Files:**
- Modify: `src/ffi.zig`
- Modify: `include/progrez.h`

**Step 1: Write the failing test**

Add to `src/ffi.zig` tests:

```zig
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
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1`
Expected: FAIL — undefined identifiers

**Step 3: Implement notification infrastructure**

Add types and parsers to `src/ffi.zig`:

```zig
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
        // Check if notify-send exists
        const result = std.process.Child.run(.{
            .allocator = ffiAllocator(),
            .argv = &.{ "which", "notify-send" },
        }) catch return .bell;
        ffiAllocator().free(result.stdout);
        ffiAllocator().free(result.stderr);
        if (result.term.Exited == 0) return .notify_send;
        return .bell;
    } else {
        return .bell;
    }
}

/// Send a system notification.
fn sendNotification(method: NotifyMethod, message: []const u8) void {
    switch (method) {
        .osascript => {
            var escaped_buf: [1024]u8 = undefined;
            // Escape double quotes for AppleScript
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
            var child = std.process.Child.init(.{
                .argv = &.{ "osascript", "-e", script },
            }, ffiAllocator());
            _ = child.spawnAndWait() catch {};
        },
        .notify_send => {
            var child = std.process.Child.init(.{
                .argv = &.{ "notify-send", "progrez", message },
            }, ffiAllocator());
            _ = child.spawnAndWait() catch {};
        },
        .bell => {
            const stderr_file: std.fs.File = .{ .handle = 2 };
            stderr_file.writeAll("\x07") catch {};
        },
        .none => {},
    }
}
```

Add fields to `FfiContext`:
```zig
    // Notification config
    notify_mode: NotifyMode,
    notify_after_secs: u32,
    notify_method: NotifyMethod,
    notify_callback: ?*const fn ([*:0]const u8, ?*anyopaque) void,
    notify_userdata: ?*anyopaque,
```

Initialize in `progrez_create`:
```zig
    const notify_env = getEnvVar("PROGREZ_NOTIFY");
    const notify_after_env = getEnvVar("PROGREZ_NOTIFY_AFTER");
    const notify_mode = parseNotifyEnv(if (notify_env) |e| @as([]const u8, e) else null);
    const notify_after = parseNotifyAfterEnv(if (notify_after_env) |e| @as([]const u8, e) else null);
    const notify_method = if (notify_mode != .off) detectNotifyMethod() else NotifyMethod.none;
```

And in the context initialization:
```zig
        .notify_mode = notify_mode,
        .notify_after_secs = notify_after,
        .notify_method = notify_method,
        .notify_callback = null,
        .notify_userdata = null,
```

Add notification dispatch to `progrez_finish`, after the completion summary write:
```zig
    // Send notification if enabled and elapsed time exceeds threshold
    if (c.progress_enabled) {
        const elapsed_secs = c.state.elapsedSeconds(now_ns);
        const should_notify = switch (c.notify_mode) {
            .on => true,
            .off => false,
            .auto => elapsed_secs >= @as(f64, @floatFromInt(c.notify_after_secs)),
        };

        if (should_notify) {
            if (c.notify_callback) |cb| {
                // Use callback if registered
                var notify_msg_buf: [512]u8 = undefined;
                const notify_msg = render.renderCompletionSummary(&c.state, now_ns, &notify_msg_buf);
                // Strip trailing newline for notification
                const msg_trimmed = std.mem.trimRight(u8, notify_msg, "\n");
                var c_str_buf: [512]u8 = undefined;
                if (msg_trimmed.len < c_str_buf.len) {
                    @memcpy(c_str_buf[0..msg_trimmed.len], msg_trimmed);
                    c_str_buf[msg_trimmed.len] = 0;
                    cb(@ptrCast(&c_str_buf), c.notify_userdata);
                }
            } else {
                // Use built-in notification
                var notify_msg_buf: [512]u8 = undefined;
                const notify_msg = render.renderCompletionSummary(&c.state, now_ns, &notify_msg_buf);
                const msg_trimmed = std.mem.trimRight(u8, notify_msg, "\n");
                sendNotification(c.notify_method, msg_trimmed);
            }
        }
    }
```

Add FFI exports:
```zig
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
```

Add null safety tests:
```zig
    progrez_set_notify(null, false);
    progrez_set_notify_after(null, 0);
    progrez_set_notify_callback(null, null, null);
```

Add to `include/progrez.h`:
```c
/* Notification configuration */
void progrez_set_notify(progrez_ctx *ctx, _Bool enabled);
void progrez_set_notify_after(progrez_ctx *ctx, uint32_t seconds);

typedef void (*progrez_notify_fn)(const char *message, void *userdata);
void progrez_set_notify_callback(progrez_ctx *ctx, progrez_notify_fn fn, void *userdata);
```

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test 2>&1`
Expected: PASS

**Step 5: Commit**

```bash
git add src/ffi.zig include/progrez.h
git commit -m "feat: add cross-platform system notifications with callback support"
```

---

### Task 10: Update Docs, Demos, and Final Polish

**Files:**
- Modify: `README.md`
- Modify: `PROJECT_OVERVIEW.md`
- Modify: `CODE_MINIMAP.md`
- Modify: `examples/demo.c`
- Modify: `examples/demo.lua`
- Modify: `PLAN.md`

**Step 1: Update README env var table**

Add the new env vars:
```markdown
| `PROGREZ_SPARKLINE` | `true`/`false` | Enable throughput sparkline graph |
| `PROGREZ_NOTIFY` | `true`/`false`/`auto` | System notifications (default: auto) |
| `PROGREZ_NOTIFY_AFTER` | seconds (default: `10`) | Notification time threshold |
```

Add new API functions to quick start section if appropriate.

**Step 2: Update demos to showcase new features**

In `examples/demo.c`, add label update between phases:
```c
    /* Transition label when switching modes */
    progrez_set_label(ctx, "Processing");
```

In `examples/demo.lua`, same:
```lua
progrez.progrez_set_label(ctx, "Processing")
```

Update LuaJIT FFI declarations with new functions.

**Step 3: Update PROJECT_OVERVIEW.md and CODE_MINIMAP.md**

Add new env vars, functions, and fields to the docs.

**Step 4: Update PLAN.md**

Mark all tasks complete.

**Step 5: Run full test suite**

Run: `bash test 2>&1`
Expected: ALL TESTS PASSED

**Step 6: Commit**

```bash
git add README.md PROJECT_OVERVIEW.md CODE_MINIMAP.md examples/demo.c examples/demo.lua PLAN.md
git commit -m "docs: update documentation and demos for v2 features"
```

---

## Dependency Graph

```
Task 1 (throughput formatter) ─────► Task 2 (throughput in render)
Task 3 (sparkline core state) ─┬──► Task 4 (sparkline formatter) ──► Task 5 (sparkline in render + FFI)
                               │
Task 6 (label update) ─────────┤    (independent)
Task 7 (GitHub Actions CI) ────┤    (independent)
Task 8 (flake verification) ───┤    (independent)
                               │
Task 9 (notifications) ────────┘    (independent of features 1-5, depends on existing FFI)

Task 10 (docs + polish) ──────────► depends on ALL above
```

Tasks 1-2 are sequential. Tasks 3-4-5 are sequential. Tasks 6, 7, 8, 9 are independent of each other and can run in parallel (after Task 1 since it adds to format.zig). Task 10 depends on everything.

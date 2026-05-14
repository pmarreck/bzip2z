//! Pure logic core: EMA rate calculation, unit formatting,
//! percentage/ETA computation, bar rendering.
//! No I/O, no threading, no terminal access.

const std = @import("std");

/// Progress display mode.
pub const Mode = enum {
    idle,
    indeterminate,
    determinate,
};

/// Immutable point-in-time snapshot of progress state.
pub const ProgrezSnapshot = struct {
    files_processed: u64,
    files_total: ?u64,
    bytes_processed: u64,
    bytes_total: ?u64,
    timestamp_ns: i128,
};

/// All mutable progress state. No I/O, no allocations.
pub const ProgrezState = struct {
    mode: Mode,

    // Counters
    files_processed: u64,
    files_total: ?u64,
    bytes_processed: u64,
    bytes_total: ?u64,

    // Timing
    start_time_ns: i128,
    last_update_ns: i128,

    // EMA rate estimation
    ema_bytes_per_sec: f64,
    ema_files_per_sec: f64,
    ema_alpha: f64,
    samples_count: u32,

    // Guesses (for indeterminate mode)
    guess_total_files: ?u64,
    guess_total_bytes: ?u64,

    // Spinner
    spinner_frame: u8,

    // Sparkline rate history (ring buffer of last 8 instantaneous rates)
    rate_history: [8]f64,
    rate_history_len: u8, // how many entries have been written (0-8)
    rate_history_idx: u8, // next write position
    sparkline_enabled: bool,

    // Label (inline buffer, no allocations)
    label_buf: [128]u8,
    label_len: u8,

    // Identity (caller name + context)
    caller_name_buf: [64]u8,
    caller_name_len: u8,
    context_name_buf: [256]u8,
    context_name_len: u16,
    has_identity: bool,

    /// Create a new ProgrezState in idle mode with the given label.
    pub fn init(label: []const u8) ProgrezState {
        var state: ProgrezState = .{
            .mode = .idle,
            .files_processed = 0,
            .files_total = null,
            .bytes_processed = 0,
            .bytes_total = null,
            .start_time_ns = 0,
            .last_update_ns = 0,
            .ema_bytes_per_sec = 0.0,
            .ema_files_per_sec = 0.0,
            .ema_alpha = 0.3,
            .samples_count = 0,
            .guess_total_files = null,
            .guess_total_bytes = null,
            .spinner_frame = 0,
            .rate_history = [_]f64{0.0} ** 8,
            .rate_history_len = 0,
            .rate_history_idx = 0,
            .sparkline_enabled = false,
            .label_buf = undefined,
            .label_len = 0,
            .caller_name_buf = undefined,
            .caller_name_len = 0,
            .context_name_buf = undefined,
            .context_name_len = 0,
            .has_identity = false,
        };
        const len: u8 = @intCast(@min(label.len, state.label_buf.len));
        @memcpy(state.label_buf[0..len], label[0..len]);
        state.label_len = len;
        return state;
    }

    /// Return the label as a slice.
    pub fn getLabel(self: *const ProgrezState) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    /// Update the display label.
    pub fn setLabel(self: *ProgrezState, label: []const u8) void {
        const copy_len = @min(label.len, self.label_buf.len);
        @memcpy(self.label_buf[0..copy_len], label[0..copy_len]);
        self.label_len = @intCast(copy_len);
    }

    /// Transition to indeterminate mode (spinner, no percentage).
    pub fn setIndeterminate(self: *ProgrezState) void {
        self.mode = .indeterminate;
    }

    /// Transition to determinate mode with known totals.
    /// A total of 0 means "not tracking that dimension" (stored as null).
    pub fn setDeterminate(self: *ProgrezState, files_total: u64, bytes_total: u64) void {
        self.mode = .determinate;
        self.files_total = if (files_total == 0) null else files_total;
        self.bytes_total = if (bytes_total == 0) null else bytes_total;
    }

    /// Set the caller identity (who is reporting progress and what for).
    pub fn setIdentity(self: *ProgrezState, caller_name: []const u8, context_name: []const u8) void {
        const cn_len: u8 = @intCast(@min(caller_name.len, self.caller_name_buf.len));
        @memcpy(self.caller_name_buf[0..cn_len], caller_name[0..cn_len]);
        self.caller_name_len = cn_len;

        const ctx_len: u16 = @intCast(@min(context_name.len, self.context_name_buf.len));
        @memcpy(self.context_name_buf[0..ctx_len], context_name[0..ctx_len]);
        self.context_name_len = ctx_len;

        self.has_identity = true;
    }

    /// Return the caller name, or null if no identity has been set.
    pub fn getCallerName(self: *const ProgrezState) ?[]const u8 {
        if (!self.has_identity) return null;
        return self.caller_name_buf[0..self.caller_name_len];
    }

    /// Return the context name, or null if no identity has been set.
    pub fn getContextName(self: *const ProgrezState) ?[]const u8 {
        if (!self.has_identity) return null;
        return self.context_name_buf[0..self.context_name_len];
    }

    /// Set estimated totals (guesses) for indeterminate mode.
    /// A value of 0 means "no guess" (stored as null).
    pub fn setGuess(self: *ProgrezState, guess_files: u64, guess_bytes: u64) void {
        self.guess_total_files = if (guess_files == 0) null else guess_files;
        self.guess_total_bytes = if (guess_bytes == 0) null else guess_bytes;
    }

    /// Capture a read-only snapshot of the current progress state.
    pub fn snapshot(self: *const ProgrezState, now_ns: i128) ProgrezSnapshot {
        return .{
            .files_processed = self.files_processed,
            .files_total = self.files_total,
            .bytes_processed = self.bytes_processed,
            .bytes_total = self.bytes_total,
            .timestamp_ns = now_ns,
        };
    }

    /// Record a progress update and recalculate the EMA rate.
    /// bytes_processed and files_processed are absolute (cumulative) values.
    pub fn recordUpdate(self: *ProgrezState, bytes_processed: u64, files_processed: u64, now_ns: i128) void {
        const delta_ns = now_ns - self.last_update_ns;
        if (delta_ns > 0) {
            const delta_secs = @as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0;

            // Bytes rate
            const bytes_delta: i128 = @as(i128, bytes_processed) - @as(i128, self.bytes_processed);
            if (bytes_delta > 0) {
                const instantaneous_bytes_rate = @as(f64, @floatFromInt(bytes_delta)) / delta_secs;
                if (self.samples_count == 0) {
                    // First sample: seed the EMA directly
                    self.ema_bytes_per_sec = instantaneous_bytes_rate;
                } else {
                    self.ema_bytes_per_sec = self.ema_alpha * instantaneous_bytes_rate + (1.0 - self.ema_alpha) * self.ema_bytes_per_sec;
                }

                // Push to sparkline ring buffer
                self.rate_history[self.rate_history_idx] = instantaneous_bytes_rate;
                self.rate_history_idx = (self.rate_history_idx + 1) % 8;
                if (self.rate_history_len < 8) self.rate_history_len += 1;
            }

            // Files rate
            const files_delta: i128 = @as(i128, files_processed) - @as(i128, self.files_processed);
            if (files_delta > 0) {
                const instantaneous_files_rate = @as(f64, @floatFromInt(files_delta)) / delta_secs;
                if (self.samples_count == 0) {
                    self.ema_files_per_sec = instantaneous_files_rate;
                } else {
                    self.ema_files_per_sec = self.ema_alpha * instantaneous_files_rate + (1.0 - self.ema_alpha) * self.ema_files_per_sec;
                }
            }

            self.samples_count += 1;
        }

        self.last_update_ns = now_ns;
        self.bytes_processed = bytes_processed;
        self.files_processed = files_processed;
    }

    /// Estimate time remaining in seconds based on EMA rate.
    /// Returns null if not enough samples (<3), no total is known, or rate is zero.
    pub fn estimateEtaSeconds(self: *const ProgrezState) ?f64 {
        if (self.samples_count < 3) return null;

        if (self.bytes_total) |total| {
            if (self.ema_bytes_per_sec <= 0.0) return null;
            const remaining = @as(f64, @floatFromInt(total)) - @as(f64, @floatFromInt(self.bytes_processed));
            if (remaining <= 0.0) return 0.0;
            return remaining / self.ema_bytes_per_sec;
        }

        if (self.files_total) |total| {
            if (self.ema_files_per_sec <= 0.0) return null;
            const remaining = @as(f64, @floatFromInt(total)) - @as(f64, @floatFromInt(self.files_processed));
            if (remaining <= 0.0) return 0.0;
            return remaining / self.ema_files_per_sec;
        }

        return null;
    }

    /// Calculate completion percentage as a value in [0.0, 1.0].
    /// Returns null if no total is known.
    /// Calculate completion percentage as a value in [0.0, 1.0].
    /// Clamped to 1.0 even if processed exceeds total (overshoot).
    /// Returns null if no total is known.
    pub fn percentComplete(self: *const ProgrezState) ?f64 {
        if (self.bytes_total) |total| {
            if (total > 0) {
                return @min(1.0, @as(f64, @floatFromInt(self.bytes_processed)) / @as(f64, @floatFromInt(total)));
            }
        }
        if (self.files_total) |total| {
            if (total > 0) {
                return @min(1.0, @as(f64, @floatFromInt(self.files_processed)) / @as(f64, @floatFromInt(total)));
            }
        }
        return null;
    }

    /// Calculate elapsed time in seconds from start_time_ns to now_ns.
    pub fn elapsedSeconds(self: *const ProgrezState, now_ns: i128) f64 {
        const elapsed_ns = now_ns - self.start_time_ns;
        return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "core: state initializes in idle mode" {
    const state = ProgrezState.init("Compressing");
    try std.testing.expectEqual(Mode.idle, state.mode);
    try std.testing.expectEqualStrings("Compressing", state.getLabel());
    try std.testing.expectEqual(@as(?u64, null), state.files_total);
    try std.testing.expectEqual(@as(?u64, null), state.bytes_total);
    try std.testing.expectEqual(@as(u64, 0), state.files_processed);
    try std.testing.expectEqual(@as(u64, 0), state.bytes_processed);
}

test "core: state transitions to indeterminate" {
    var state = ProgrezState.init("Scanning");
    state.setIndeterminate();
    try std.testing.expectEqual(Mode.indeterminate, state.mode);
}

test "core: state transitions to determinate" {
    var state = ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    try std.testing.expectEqual(Mode.determinate, state.mode);
    try std.testing.expectEqual(@as(?u64, 400), state.files_total);
    try std.testing.expectEqual(@as(?u64, 21_000_000), state.bytes_total);
}

test "core: state transitions indeterminate -> determinate" {
    var state = ProgrezState.init("Processing");
    state.setIndeterminate();
    try std.testing.expectEqual(Mode.indeterminate, state.mode);
    state.setDeterminate(100, 5_000_000);
    try std.testing.expectEqual(Mode.determinate, state.mode);
    try std.testing.expectEqual(@as(?u64, 100), state.files_total);
}

test "core: zero total means not tracking" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 1000); // 0 files = not tracking files
    try std.testing.expectEqual(@as(?u64, null), state.files_total);
    try std.testing.expectEqual(@as(?u64, 1000), state.bytes_total);
}

test "core: set identity" {
    var state = ProgrezState.init("Compressing");
    state.setIdentity("bzip2z", "compression of mydir/");
    try std.testing.expectEqualStrings("bzip2z", state.getCallerName().?);
    try std.testing.expectEqualStrings("compression of mydir/", state.getContextName().?);
}

test "core: identity is null by default" {
    const state = ProgrezState.init("Compressing");
    try std.testing.expectEqual(@as(?[]const u8, null), state.getCallerName());
    try std.testing.expectEqual(@as(?[]const u8, null), state.getContextName());
}

test "core: snapshot captures current counters" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(100, 5000);
    state.files_processed = 42;
    state.bytes_processed = 2100;
    const snap = state.snapshot(1_000_000_000);
    try std.testing.expectEqual(@as(u64, 42), snap.files_processed);
    try std.testing.expectEqual(@as(u64, 2100), snap.bytes_processed);
    try std.testing.expectEqual(@as(?u64, 100), snap.files_total);
    try std.testing.expectEqual(@as(?u64, 5000), snap.bytes_total);
    try std.testing.expectEqual(@as(i128, 1_000_000_000), snap.timestamp_ns);
}

test "core: set guess" {
    var state = ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.setGuess(2000, 0);
    try std.testing.expectEqual(@as(?u64, 2000), state.guess_total_files);
    try std.testing.expectEqual(@as(?u64, null), state.guess_total_bytes);
}

test "core: EMA rate calculation with constant rate" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 10_000);
    state.start_time_ns = 0;

    // Simulate 10 updates at constant rate: 1000 bytes/sec
    var time_ns: i128 = 0;
    var bytes: u64 = 0;
    for (0..10) |_| {
        time_ns += 1_000_000_000; // 1 second
        bytes += 1000;
        state.recordUpdate(bytes, 0, time_ns);
    }

    // EMA should converge near 1000 bytes/sec
    try std.testing.expect(state.ema_bytes_per_sec > 900.0);
    try std.testing.expect(state.ema_bytes_per_sec < 1100.0);
}

test "core: EMA suppressed until minimum samples" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 10_000);
    state.start_time_ns = 0;

    // First update — not enough samples for ETA
    state.recordUpdate(100, 0, 1_000_000_000);
    try std.testing.expectEqual(@as(u32, 1), state.samples_count);
    try std.testing.expectEqual(@as(?f64, null), state.estimateEtaSeconds());

    // Second update
    state.recordUpdate(200, 0, 2_000_000_000);
    try std.testing.expectEqual(@as(?f64, null), state.estimateEtaSeconds());

    // Third update — now ETA available
    state.recordUpdate(300, 0, 3_000_000_000);
    try std.testing.expect(state.estimateEtaSeconds() != null);
}

test "core: ETA calculation" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 10_000);
    state.start_time_ns = 0;

    // 3 updates at 1000 bytes/sec
    state.recordUpdate(1000, 0, 1_000_000_000);
    state.recordUpdate(2000, 0, 2_000_000_000);
    state.recordUpdate(3000, 0, 3_000_000_000);

    // 7000 bytes remaining at ~1000 bytes/sec ≈ 7 seconds
    const eta = state.estimateEtaSeconds().?;
    try std.testing.expect(eta > 5.0);
    try std.testing.expect(eta < 10.0);
}

test "core: percentage calculation" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 1000);
    state.bytes_processed = 500;
    try std.testing.expect(@abs(state.percentComplete().? - 0.5) < 0.001);

    state.bytes_processed = 0;
    try std.testing.expect(@abs(state.percentComplete().? - 0.0) < 0.001);

    state.bytes_processed = 1000;
    try std.testing.expect(@abs(state.percentComplete().? - 1.0) < 0.001);
}

test "core: percentage null when no total" {
    var state = ProgrezState.init("Test");
    state.setIndeterminate();
    try std.testing.expectEqual(@as(?f64, null), state.percentComplete());
}

test "core: elapsed seconds" {
    var state = ProgrezState.init("Test");
    state.start_time_ns = 0;
    try std.testing.expect(@abs(state.elapsedSeconds(2_500_000_000) - 2.5) < 0.001);
}

test "core: setLabel updates label" {
    var state = ProgrezState.init("Scanning");
    try std.testing.expectEqualStrings("Scanning", state.getLabel());

    state.setLabel("Compressing");
    try std.testing.expectEqualStrings("Compressing", state.getLabel());

    state.setLabel("Verifying");
    try std.testing.expectEqualStrings("Verifying", state.getLabel());
}

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

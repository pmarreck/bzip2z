//! Progress bar rendering: determinate and indeterminate modes.
//! Pure logic: takes state + terminal caps, writes into caller-provided buffer.

const std = @import("std");
const core = @import("core.zig");
const terminal = @import("terminal.zig");
const format = @import("format.zig");

// Unicode bar characters: full block + sub-character precision (7/8 down to 1/8)
// Index 0 = full block, index 7 = 1/8 block
const partial_blocks = [8][]const u8{
    "\xe2\x96\x88", // █ FULL BLOCK (U+2588)
    "\xe2\x96\x89", // ▉ LEFT SEVEN EIGHTHS BLOCK (U+2589)
    "\xe2\x96\x8a", // ▊ LEFT THREE QUARTERS BLOCK (U+258A)
    "\xe2\x96\x8b", // ▋ LEFT FIVE EIGHTHS BLOCK (U+258B)
    "\xe2\x96\x8c", // ▌ LEFT HALF BLOCK (U+258C)
    "\xe2\x96\x8d", // ▍ LEFT THREE EIGHTHS BLOCK (U+258D)
    "\xe2\x96\x8e", // ▎ LEFT ONE QUARTER BLOCK (U+258E)
    "\xe2\x96\x8f", // ▏ LEFT ONE EIGHTH BLOCK (U+258F)
};

const full_block = "\xe2\x96\x88"; // █
const empty_block = "\xe2\x96\x91"; // ░ LIGHT SHADE (U+2591)
const bar_left_cap = "\xe2\x96\x90"; // ▐ RIGHT HALF BLOCK (U+2590)
const bar_right_cap = "\xe2\x96\x8c"; // ▌ LEFT HALF BLOCK (U+258C)

const min_bar_width: usize = 10;

/// RGB color triplet.
pub const Color = struct { r: u8, g: u8, b: u8 };

/// Gradient color stops for the progress bar.
/// Supports 2-stop (start/end) or 3-stop (start/mid/end) gradients.
pub const GradientColors = struct {
    start: Color = .{ .r = 0, .g = 255, .b = 255 }, // cyan
    mid: ?Color = .{ .r = 128, .g = 0, .b = 255 }, // violet (null = lerp start->end)
    end: Color = .{ .r = 255, .g = 0, .b = 255 }, // magenta

    pub const default: GradientColors = .{};
};

/// Render a single-line determinate progress bar into `buf`.
/// Returns a slice of `buf` containing the rendered line.
///
/// Layout: `{label} {bar} {stats}`
///
/// Stats are progressively dropped at narrow widths:
///   pct + files + bytes + eta  (all fit)
///   pct + files + bytes        (drop eta)
///   pct + files                (drop bytes)
///   pct                        (drop files)
///   (empty)                    (drop pct -- extremely narrow)
pub fn renderDeterminate(state: *const core.ProgrezState, caps: terminal.TerminalCaps, now_ns: i128, buf: []u8, gradient: GradientColors) []const u8 {
    _ = now_ns;
    const width: usize = @intCast(caps.width);
    if (width == 0 or buf.len == 0) return "";

    // --- 1. Format all stat pieces into small stack buffers ---
    const pct_frac: f64 = state.percentComplete() orelse 0.0;

    var pct_buf: [16]u8 = undefined;
    const pct_str = format.formatPercent(pct_frac, &pct_buf);

    var files_buf: [64]u8 = undefined;
    var files_str: []const u8 = "";
    if (state.files_total) |ft| {
        files_str = std.fmt.bufPrint(&files_buf, "{d}/{d} files", .{ state.files_processed, ft }) catch "";
    }

    var bytes_buf: [64]u8 = undefined;
    var bytes_str: []const u8 = "";
    if (state.bytes_total) |bt| {
        var proc_buf: [32]u8 = undefined;
        var total_buf: [32]u8 = undefined;
        const proc_s = format.formatBytes(state.bytes_processed, &proc_buf);
        const total_s = format.formatBytes(bt, &total_buf);
        bytes_str = std.fmt.bufPrint(&bytes_buf, "{s}/{s}", .{ proc_s, total_s }) catch "";
    }

    var eta_buf: [32]u8 = undefined;
    var eta_str: []const u8 = "";
    if (state.estimateEtaSeconds()) |eta_secs| {
        eta_str = format.formatEta(eta_secs, &eta_buf);
    }

    var throughput_buf: [32]u8 = undefined;
    var throughput_str: []const u8 = "";
    if (state.ema_bytes_per_sec > 0.0 and state.samples_count >= 3) {
        throughput_str = format.formatThroughput(state.ema_bytes_per_sec, &throughput_buf);
    }

    var sparkline_buf: [32]u8 = undefined;
    var sparkline_str: []const u8 = "";
    if (state.sparkline_enabled and state.rate_history_len >= 2) {
        // Read ring buffer in order (oldest first)
        var ordered: [8]f64 = undefined;
        const n = state.rate_history_len;
        const start_idx: usize = if (n >= 8) state.rate_history_idx else 0;
        for (0..n) |i| {
            ordered[i] = state.rate_history[(start_idx + i) % 8];
        }
        sparkline_str = format.formatSparkline(&ordered, n, &sparkline_buf);
    }

    // --- 2. Build stats string with priority dropping ---
    // Stat pieces in priority order (lowest priority = dropped first):
    //   eta, throughput, bytes, files, pct
    // We try fitting all, then progressively drop from the end (lowest priority).

    const label = state.getLabel();
    // Fixed overhead: label + 1 space + 2 spaces around bar = label_len + 3
    // But we need: label + " " + bar + "  " + stats
    // So: overhead = label_len + 1 (space after label) + 2 (spaces before stats)
    // bar_width = width - overhead - stats_display_len
    // We need bar_width >= min_bar_width

    const label_len = label.len;

    // Try all 5 stat levels (4 stats -> 0 stats)
    const StatLevel = enum { all, no_eta, no_throughput, no_bytes, no_files, none };
    const levels = [_]StatLevel{ .all, .no_eta, .no_throughput, .no_bytes, .no_files, .none };

    var chosen_stats_buf: [256]u8 = undefined;
    var chosen_stats: []const u8 = "";
    var chosen_bar_width: usize = 0;

    for (levels) |level| {
        // Build stats string for this level
        var stats_parts: [6][]const u8 = undefined;
        var stats_count: usize = 0;

        // Always include pct unless level == .none
        if (level != .none) {
            stats_parts[stats_count] = pct_str;
            stats_count += 1;
        }
        if (level == .all or level == .no_eta or level == .no_throughput or level == .no_bytes) {
            if (files_str.len > 0) {
                stats_parts[stats_count] = files_str;
                stats_count += 1;
            }
        }
        if (level == .all or level == .no_eta or level == .no_throughput) {
            if (bytes_str.len > 0) {
                stats_parts[stats_count] = bytes_str;
                stats_count += 1;
            }
        }
        if (level == .all or level == .no_eta) {
            if (throughput_str.len > 0) {
                stats_parts[stats_count] = throughput_str;
                stats_count += 1;
            }
        }
        if (level == .all or level == .no_eta) {
            if (sparkline_str.len > 0) {
                stats_parts[stats_count] = sparkline_str;
                stats_count += 1;
            }
        }
        if (level == .all) {
            if (eta_str.len > 0) {
                stats_parts[stats_count] = eta_str;
                stats_count += 1;
            }
        }

        // Join with "  " (2 spaces)
        var stats_len: usize = 0;
        for (0..stats_count) |i| {
            if (i > 0) {
                @memcpy(chosen_stats_buf[stats_len .. stats_len + 2], "  ");
                stats_len += 2;
            }
            const part = stats_parts[i];
            @memcpy(chosen_stats_buf[stats_len .. stats_len + part.len], part);
            stats_len += part.len;
        }
        chosen_stats = chosen_stats_buf[0..stats_len];

        // Calculate bar width
        // Layout: "{label} {bar} [spinner]  {stats}" or "{label} {bar}" if no stats
        // Reserve 2 display columns for spinner (" ⠋") when at 100%
        const spinner_cols: usize = if (pct_frac >= 1.0) 2 else 0;
        const overhead = label_len + 1 + spinner_cols + (if (stats_len > 0) stats_len + 2 else @as(usize, 0));
        if (overhead >= width) {
            // Not even enough room for label + overhead, try dropping more
            if (level == .none) {
                // Even with no stats, label + space doesn't fit.
                // Give minimum bar
                chosen_bar_width = min_bar_width;
                chosen_stats = "";
                break;
            }
            continue;
        }
        const available = width - overhead;
        if (available >= min_bar_width) {
            chosen_bar_width = available;
            break;
        }
        // Not enough for min_bar_width, try dropping more stats
        if (level == .none) {
            // With no stats and label, bar is width - label_len - 1
            if (width > label_len + 1) {
                chosen_bar_width = width - label_len - 1;
            } else {
                chosen_bar_width = min_bar_width;
            }
            chosen_stats = "";
            break;
        }
    }

    if (chosen_bar_width < min_bar_width) {
        chosen_bar_width = min_bar_width;
    }

    // --- 3. Render the bar ---
    var pos: usize = 0;

    // Write label
    if (label_len > 0 and pos + label_len < buf.len) {
        @memcpy(buf[pos .. pos + label_len], label);
        pos += label_len;
    }

    // Space after label
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }

    // Render the bar itself
    if (caps.unicode) {
        pos = renderUnicodeBar(buf, pos, chosen_bar_width, pct_frac, caps.truecolor, gradient);
    } else {
        pos = renderAsciiBar(buf, pos, chosen_bar_width, pct_frac);
    }

    // Show spinner after bar when at 100% (indicates still processing)
    if (pct_frac >= 1.0) {
        if (caps.unicode) {
            const frame_idx = state.spinner_frame % braille_spinner.len;
            const frame = braille_spinner[frame_idx];
            if (pos + 1 + frame.len <= buf.len) {
                buf[pos] = ' ';
                pos += 1;
                @memcpy(buf[pos .. pos + frame.len], frame);
                pos += frame.len;
            }
        } else {
            const frame_idx = state.spinner_frame % ascii_spinner.len;
            if (pos + 2 <= buf.len) {
                buf[pos] = ' ';
                buf[pos + 1] = ascii_spinner[frame_idx];
                pos += 2;
            }
        }
    }

    // Space + stats
    if (chosen_stats.len > 0) {
        if (pos + 2 + chosen_stats.len <= buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = ' ';
            pos += 2;
            @memcpy(buf[pos .. pos + chosen_stats.len], chosen_stats);
            pos += chosen_stats.len;
        }
    }

    return buf[0..pos];
}

// Braille spinner frames (Unicode): ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
const braille_spinner = [10][]const u8{
    "\xe2\xa0\x8b", // ⠋
    "\xe2\xa0\x99", // ⠙
    "\xe2\xa0\xb9", // ⠹
    "\xe2\xa0\xb8", // ⠸
    "\xe2\xa0\xbc", // ⠼
    "\xe2\xa0\xb4", // ⠴
    "\xe2\xa0\xa6", // ⠦
    "\xe2\xa0\xa7", // ⠧
    "\xe2\xa0\x87", // ⠇
    "\xe2\xa0\x8f", // ⠏
};

const ascii_spinner = [4]u8{ '|', '/', '-', '\\' };

/// Render a single-line indeterminate spinner into `buf`.
/// Returns a slice of `buf` containing the rendered line.
///
/// Layout without guess:  `{label} {spinner} {count} files  {bytes}`
/// Layout with guess:     `{label} {spinner} ~{pct}%  {count}/~{guess} files  {bytes}`
pub fn renderIndeterminate(state: *const core.ProgrezState, caps: terminal.TerminalCaps, buf: []u8) []const u8 {
    const width: usize = @intCast(caps.width);
    if (width == 0 or buf.len == 0) return "";

    var pos: usize = 0;

    // --- 1. Write label ---
    const label = state.getLabel();
    if (label.len > 0 and pos + label.len < buf.len) {
        @memcpy(buf[pos .. pos + label.len], label);
        pos += label.len;
    }

    // Space after label
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }

    // --- 2. Write spinner character ---
    if (caps.unicode) {
        const frame_idx = state.spinner_frame % braille_spinner.len;
        const frame = braille_spinner[frame_idx];
        if (pos + frame.len <= buf.len) {
            @memcpy(buf[pos .. pos + frame.len], frame);
            pos += frame.len;
        }
    } else {
        const frame_idx = state.spinner_frame % ascii_spinner.len;
        if (pos < buf.len) {
            buf[pos] = ascii_spinner[frame_idx];
            pos += 1;
        }
    }

    // Space after spinner
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }

    // --- 3. Build stats section ---
    // If guess_total_files is set, compute approximate percentage
    const has_guess_files = state.guess_total_files != null;
    const has_guess_bytes = state.guess_total_bytes != null;
    const has_guess = has_guess_files or has_guess_bytes;

    // Approximate percentage (from guess)
    var approx_pct_buf: [16]u8 = undefined;
    var approx_pct_str: []const u8 = "";
    if (has_guess) {
        var frac: f64 = 0.0;
        if (state.guess_total_bytes) |gb| {
            if (gb > 0) {
                frac = @as(f64, @floatFromInt(state.bytes_processed)) / @as(f64, @floatFromInt(gb));
            }
        } else if (state.guess_total_files) |gf| {
            if (gf > 0) {
                frac = @as(f64, @floatFromInt(state.files_processed)) / @as(f64, @floatFromInt(gf));
            }
        }
        frac = @min(frac, 0.99); // Cap at 99% since it's a guess
        const pct_int: u64 = @intFromFloat(frac * 100.0);
        approx_pct_str = std.fmt.bufPrint(&approx_pct_buf, "~{d}%", .{pct_int}) catch "";
    }

    // File count
    var files_buf: [64]u8 = undefined;
    var files_str: []const u8 = "";
    if (state.files_processed > 0) {
        var count_buf: [32]u8 = undefined;
        const count_str = format.formatCount(state.files_processed, &count_buf);

        if (state.guess_total_files) |gf| {
            var guess_count_buf: [32]u8 = undefined;
            const guess_str = format.formatCount(gf, &guess_count_buf);
            files_str = std.fmt.bufPrint(&files_buf, "{s}/~{s} files", .{ count_str, guess_str }) catch "";
        } else {
            files_str = std.fmt.bufPrint(&files_buf, "{s} files", .{count_str}) catch "";
        }
    }

    // Byte count
    var bytes_buf: [64]u8 = undefined;
    var bytes_str: []const u8 = "";
    if (state.bytes_processed > 0) {
        var proc_buf: [32]u8 = undefined;
        const proc_s = format.formatBytes(state.bytes_processed, &proc_buf);
        bytes_str = std.fmt.bufPrint(&bytes_buf, "{s}", .{proc_s}) catch "";
    }

    // --- 4. Assemble stats into output buffer ---
    // Stats parts in order: approx_pct, files, bytes
    var stats_parts: [3][]const u8 = undefined;
    var stats_count: usize = 0;

    if (approx_pct_str.len > 0) {
        stats_parts[stats_count] = approx_pct_str;
        stats_count += 1;
    }
    if (files_str.len > 0) {
        stats_parts[stats_count] = files_str;
        stats_count += 1;
    }
    if (bytes_str.len > 0) {
        stats_parts[stats_count] = bytes_str;
        stats_count += 1;
    }

    // Write stats joined by "  " (2 spaces)
    for (0..stats_count) |i| {
        if (i > 0) {
            if (pos + 2 <= buf.len) {
                buf[pos] = ' ';
                buf[pos + 1] = ' ';
                pos += 2;
            }
        }
        const part = stats_parts[i];
        if (pos + part.len <= buf.len) {
            @memcpy(buf[pos .. pos + part.len], part);
            pos += part.len;
        }
    }

    return buf[0..pos];
}

/// Render a Unicode progress bar with sub-character precision.
/// Returns the new position in the buffer.
fn renderUnicodeBar(buf: []u8, start: usize, bar_width: usize, frac: f64, truecolor: bool, gradient: GradientColors) usize {
    var pos = start;

    // Bar structure: cap + inner + cap
    // The caps take 1 display column each but are multi-byte UTF-8.
    // Inner width = bar_width - 2 (for the two caps)
    const inner_width = if (bar_width > 2) bar_width - 2 else 1;

    // Left cap: ▐
    if (pos + bar_left_cap.len <= buf.len) {
        @memcpy(buf[pos .. pos + bar_left_cap.len], bar_left_cap);
        pos += bar_left_cap.len;
    }

    // Calculate fill: how many full cells + partial
    // Use 8ths precision
    const fill_eighths: usize = @intFromFloat(@min(frac, 1.0) * @as(f64, @floatFromInt(inner_width)) * 8.0);
    const full_cells = fill_eighths / 8;
    const partial_eighth = fill_eighths % 8;
    const empty_cells = inner_width - full_cells - (if (partial_eighth > 0) @as(usize, 1) else @as(usize, 0));

    // Render filled cells
    for (0..full_cells) |i| {
        if (truecolor) {
            pos = writeColoredBlock(buf, pos, full_block, i, inner_width, gradient);
        } else {
            if (pos + full_block.len <= buf.len) {
                @memcpy(buf[pos .. pos + full_block.len], full_block);
                pos += full_block.len;
            }
        }
    }

    // Render partial cell (if any)
    if (partial_eighth > 0) {
        // partial_blocks: index 0 = 8/8 (full), we need (8 - partial_eighth)
        // Actually: partial_eighth=7 means 7/8 filled -> index 1
        // partial_eighth=1 means 1/8 filled -> index 7
        const idx = 8 - partial_eighth;
        const block = partial_blocks[idx];
        if (truecolor) {
            pos = writeColoredPartialBlock(buf, pos, block, full_cells, inner_width, gradient);
        } else {
            if (pos + block.len <= buf.len) {
                @memcpy(buf[pos .. pos + block.len], block);
                pos += block.len;
            }
        }
    }

    // Reset color after filled section if truecolor
    if (truecolor and (full_cells > 0 or partial_eighth > 0)) {
        const reset = "\x1b[0m";
        if (pos + reset.len <= buf.len) {
            @memcpy(buf[pos .. pos + reset.len], reset);
            pos += reset.len;
        }
    }

    // Render empty cells
    if (truecolor and empty_cells > 0) {
        // Set dim foreground for ░ chars so they match the partial block's BG
        var dim_esc_buf: [32]u8 = undefined;
        const dim_esc = std.fmt.bufPrint(&dim_esc_buf, "\x1b[38;2;{d};{d};{d}m", .{
            empty_bg_r, empty_bg_g, empty_bg_b,
        }) catch "";
        if (pos + dim_esc.len <= buf.len) {
            @memcpy(buf[pos .. pos + dim_esc.len], dim_esc);
            pos += dim_esc.len;
        }
        for (0..empty_cells) |_| {
            if (pos + empty_block.len <= buf.len) {
                @memcpy(buf[pos .. pos + empty_block.len], empty_block);
                pos += empty_block.len;
            }
        }
        const reset2 = "\x1b[0m";
        if (pos + reset2.len <= buf.len) {
            @memcpy(buf[pos .. pos + reset2.len], reset2);
            pos += reset2.len;
        }
    } else {
        for (0..empty_cells) |_| {
            if (pos + empty_block.len <= buf.len) {
                @memcpy(buf[pos .. pos + empty_block.len], empty_block);
                pos += empty_block.len;
            }
        }
    }

    // Right cap: ▌
    if (pos + bar_right_cap.len <= buf.len) {
        @memcpy(buf[pos .. pos + bar_right_cap.len], bar_right_cap);
        pos += bar_right_cap.len;
    }

    return pos;
}

/// Render an ASCII progress bar.
fn renderAsciiBar(buf: []u8, start: usize, bar_width: usize, frac: f64) usize {
    var pos = start;

    // Bar structure: [ + inner + ]
    const inner_width = if (bar_width > 2) bar_width - 2 else 1;

    if (pos < buf.len) {
        buf[pos] = '[';
        pos += 1;
    }

    const filled: usize = @intFromFloat(@min(frac, 1.0) * @as(f64, @floatFromInt(inner_width)));

    // Filled: '='
    for (0..filled) |_| {
        if (pos < buf.len) {
            buf[pos] = '=';
            pos += 1;
        }
    }

    // Cursor: '>' (if not at end)
    if (filled < inner_width) {
        if (pos < buf.len) {
            buf[pos] = '>';
            pos += 1;
        }
        // Empty: ' '
        const empty = inner_width - filled - 1;
        for (0..empty) |_| {
            if (pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
    }

    if (pos < buf.len) {
        buf[pos] = ']';
        pos += 1;
    }

    return pos;
}

/// Linearly interpolate between two colors.
fn lerpColor(a: Color, b: Color, t: f64) Color {
    return .{
        .r = @intFromFloat(@as(f64, @floatFromInt(a.r)) + (@as(f64, @floatFromInt(b.r)) - @as(f64, @floatFromInt(a.r))) * t),
        .g = @intFromFloat(@as(f64, @floatFromInt(a.g)) + (@as(f64, @floatFromInt(b.g)) - @as(f64, @floatFromInt(a.g))) * t),
        .b = @intFromFloat(@as(f64, @floatFromInt(a.b)) + (@as(f64, @floatFromInt(b.b)) - @as(f64, @floatFromInt(a.b))) * t),
    };
}

/// Compute the gradient color at a given cell position.
fn gradientColor(cell_idx: usize, total_cells: usize, gradient: GradientColors) Color {
    const t: f64 = if (total_cells <= 1) 0.0 else @as(f64, @floatFromInt(cell_idx)) / @as(f64, @floatFromInt(total_cells - 1));

    if (gradient.mid) |mid| {
        // 3-stop gradient: start -> mid -> end
        if (t <= 0.5) {
            return lerpColor(gradient.start, mid, t * 2.0);
        } else {
            return lerpColor(mid, gradient.end, (t - 0.5) * 2.0);
        }
    } else {
        // 2-stop gradient: start -> end
        return lerpColor(gradient.start, gradient.end, t);
    }
}

/// The color used for the empty/unfilled portion of the bar (░ background).
/// A dark gray that's visible but unobtrusive.
const empty_bg_r: u8 = 60;
const empty_bg_g: u8 = 60;
const empty_bg_b: u8 = 60;

/// Write a partial block character with foreground gradient color AND
/// background color matching the empty bar region, so the gap in the
/// partial character doesn't show the terminal's own background.
fn writeColoredPartialBlock(buf: []u8, start: usize, block: []const u8, cell_idx: usize, total_cells: usize, gradient: GradientColors) usize {
    var pos = start;
    const c = gradientColor(cell_idx, total_cells, gradient);

    // Set both FG (38) and BG (48) in one escape
    var esc_buf: [64]u8 = undefined;
    const esc = std.fmt.bufPrint(&esc_buf, "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{
        c.r, c.g, c.b,
        empty_bg_r, empty_bg_g, empty_bg_b,
    }) catch "";

    if (pos + esc.len + block.len <= buf.len) {
        @memcpy(buf[pos .. pos + esc.len], esc);
        pos += esc.len;
        @memcpy(buf[pos .. pos + block.len], block);
        pos += block.len;
    }

    return pos;
}

/// Write a single colored block character with truecolor gradient.
/// Gradient: cyan(0,255,255) -> violet(128,0,255) -> magenta(255,0,255)
fn writeColoredBlock(buf: []u8, start: usize, block: []const u8, cell_idx: usize, total_cells: usize, gradient: GradientColors) usize {
    var pos = start;
    const c = gradientColor(cell_idx, total_cells, gradient);

    // Write ANSI truecolor escape: \x1b[38;2;R;G;Bm
    var esc_buf: [32]u8 = undefined;
    const esc = std.fmt.bufPrint(&esc_buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch "";

    if (pos + esc.len + block.len <= buf.len) {
        @memcpy(buf[pos .. pos + esc.len], esc);
        pos += esc.len;
        @memcpy(buf[pos .. pos + block.len], block);
        pos += block.len;
    }

    return pos;
}

/// Top-level render dispatcher: selects the correct renderer based on mode.
/// Returns a slice of `buf` containing the rendered line, or empty for idle.
/// Count display columns in a UTF-8 string.
/// Assumes all codepoints are single-width (valid for ASCII, braille, block elements).
fn countDisplayCols(s: []const u8) usize {
    var cols: usize = 0;
    for (s) |byte| {
        if (byte & 0xC0 != 0x80) cols += 1;
    }
    return cols;
}

pub fn renderLine(state: *const core.ProgrezState, caps: terminal.TerminalCaps, now_ns: i128, buf: []u8, gradient: GradientColors) []const u8 {
    const content = switch (state.mode) {
        .idle => return "",
        .indeterminate => renderIndeterminate(state, caps, buf),
        .determinate => renderDeterminate(state, caps, now_ns, buf, gradient),
    };
    // Pad with spaces to fill the terminal width so that mode switches
    // (e.g. determinate → indeterminate) don't leave leftover characters.
    const width: usize = @intCast(caps.width);
    const display_cols = countDisplayCols(content);
    if (display_cols < width and content.len + (width - display_cols) <= buf.len) {
        const pad = width - display_cols;
        @memset(buf[content.len .. content.len + pad], ' ');
        return buf[0 .. content.len + pad];
    }
    return content;
}

/// Render a persistent completion summary line into `buf`.
/// Returns a slice of `buf` containing the rendered line (ends with '\n').
///
/// Format with identity:  `{caller_name} completed: {context_name} in {elapsed} ({details})\n`
/// Format without identity: `{label} completed in {elapsed} ({details})\n`
///
/// Details (parenthesized):
///   - If files_processed > 0: "{count} files"
///   - If bytes_processed > 0: "{bytes}"
///   - Separated with ", " if both present
pub fn renderCompletionSummary(state: *const core.ProgrezState, now_ns: i128, buf: []u8) []const u8 {
    if (buf.len == 0) return "";

    var pos: usize = 0;

    // --- 1. Write prefix: identity or label ---
    if (state.getCallerName()) |caller_name| {
        // "{caller_name} completed: {context_name} in "
        if (pos + caller_name.len <= buf.len) {
            @memcpy(buf[pos .. pos + caller_name.len], caller_name);
            pos += caller_name.len;
        }
        const completed_str = " completed: ";
        if (pos + completed_str.len <= buf.len) {
            @memcpy(buf[pos .. pos + completed_str.len], completed_str);
            pos += completed_str.len;
        }
        if (state.getContextName()) |context_name| {
            if (pos + context_name.len <= buf.len) {
                @memcpy(buf[pos .. pos + context_name.len], context_name);
                pos += context_name.len;
            }
        }
        const in_str = " in ";
        if (pos + in_str.len <= buf.len) {
            @memcpy(buf[pos .. pos + in_str.len], in_str);
            pos += in_str.len;
        }
    } else {
        // "{label} completed in "
        const label = state.getLabel();
        if (pos + label.len <= buf.len) {
            @memcpy(buf[pos .. pos + label.len], label);
            pos += label.len;
        }
        const completed_in_str = " completed in ";
        if (pos + completed_in_str.len <= buf.len) {
            @memcpy(buf[pos .. pos + completed_in_str.len], completed_in_str);
            pos += completed_in_str.len;
        }
    }

    // --- 2. Write elapsed time ---
    const elapsed_secs = state.elapsedSeconds(now_ns);
    var elapsed_buf: [32]u8 = undefined;
    const elapsed_str = format.formatElapsed(elapsed_secs, &elapsed_buf);
    if (pos + elapsed_str.len <= buf.len) {
        @memcpy(buf[pos .. pos + elapsed_str.len], elapsed_str);
        pos += elapsed_str.len;
    }

    // --- 3. Build details (files, bytes) ---
    var has_details = false;

    // Files
    var files_detail_buf: [64]u8 = undefined;
    var files_detail: []const u8 = "";
    if (state.files_processed > 0) {
        var count_buf: [32]u8 = undefined;
        const count_str = format.formatCount(state.files_processed, &count_buf);
        files_detail = std.fmt.bufPrint(&files_detail_buf, "{s} files", .{count_str}) catch "";
        if (files_detail.len > 0) has_details = true;
    }

    // Bytes
    var bytes_detail_buf: [32]u8 = undefined;
    var bytes_detail: []const u8 = "";
    if (state.bytes_processed > 0) {
        bytes_detail = format.formatBytes(state.bytes_processed, &bytes_detail_buf);
        if (bytes_detail.len > 0) has_details = true;
    }

    // --- 4. Write details in parentheses ---
    if (has_details) {
        if (pos + 2 <= buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = '(';
            pos += 2;
        }

        if (files_detail.len > 0) {
            if (pos + files_detail.len <= buf.len) {
                @memcpy(buf[pos .. pos + files_detail.len], files_detail);
                pos += files_detail.len;
            }
            if (bytes_detail.len > 0) {
                if (pos + 2 <= buf.len) {
                    buf[pos] = ',';
                    buf[pos + 1] = ' ';
                    pos += 2;
                }
            }
        }

        if (bytes_detail.len > 0) {
            if (pos + bytes_detail.len <= buf.len) {
                @memcpy(buf[pos .. pos + bytes_detail.len], bytes_detail);
                pos += bytes_detail.len;
            }
        }

        if (pos < buf.len) {
            buf[pos] = ')';
            pos += 1;
        }
    }

    // --- 5. Trailing newline ---
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    return buf[0..pos];
}

/// Render a plain-text log line for non-TTY output (piped stderr, CI).
/// No ANSI escapes, no Unicode art. Ends with '\n'.
///
/// Format: `[progrez] {label} {stats}\n`
///
/// Stats (space-separated):
///   - Percentage (if determinate): `25%` (integer)
///   - File count: `100/400 files` (determinate) or `500 files` (indeterminate)
///   - Byte count: `5.3 MB/21.0 MB` (determinate) or `2.0 MB` (indeterminate)
///   - ETA (if available): `ETA 1:23`
pub fn renderLogLine(state: *const core.ProgrezState, now_ns: i128, buf: []u8) []const u8 {
    _ = now_ns;
    if (buf.len == 0) return "";

    var pos: usize = 0;

    // --- 1. Write prefix ---
    const prefix = "[progrez] ";
    if (pos + prefix.len <= buf.len) {
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
    }

    // --- 2. Write label ---
    const label = state.getLabel();
    if (label.len > 0 and pos + label.len <= buf.len) {
        @memcpy(buf[pos .. pos + label.len], label);
        pos += label.len;
    }

    // --- 3. Stats ---

    // Percentage (determinate mode with known total, integer)
    if (state.mode == .determinate) {
        if (state.percentComplete()) |pct_frac| {
            const pct_int: u64 = @intFromFloat(pct_frac * 100.0);
            var pct_buf: [16]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, " {d}%", .{pct_int}) catch "";
            if (pos + pct_str.len <= buf.len) {
                @memcpy(buf[pos .. pos + pct_str.len], pct_str);
                pos += pct_str.len;
            }
        }
    }

    // File count
    if (state.files_processed > 0) {
        var files_buf: [64]u8 = undefined;
        var files_str: []const u8 = "";
        if (state.files_total) |ft| {
            files_str = std.fmt.bufPrint(&files_buf, " {d}/{d} files", .{ state.files_processed, ft }) catch "";
        } else {
            files_str = std.fmt.bufPrint(&files_buf, " {d} files", .{state.files_processed}) catch "";
        }
        if (pos + files_str.len <= buf.len) {
            @memcpy(buf[pos .. pos + files_str.len], files_str);
            pos += files_str.len;
        }
    }

    // Byte count
    if (state.bytes_processed > 0) {
        var proc_buf: [32]u8 = undefined;
        const proc_s = format.formatBytes(state.bytes_processed, &proc_buf);

        if (state.bytes_total) |bt| {
            var total_buf: [32]u8 = undefined;
            const total_s = format.formatBytes(bt, &total_buf);
            var bytes_buf: [80]u8 = undefined;
            const bytes_str = std.fmt.bufPrint(&bytes_buf, " {s}/{s}", .{ proc_s, total_s }) catch "";
            if (pos + bytes_str.len <= buf.len) {
                @memcpy(buf[pos .. pos + bytes_str.len], bytes_str);
                pos += bytes_str.len;
            }
        } else {
            var bytes_buf: [48]u8 = undefined;
            const bytes_str = std.fmt.bufPrint(&bytes_buf, " {s}", .{proc_s}) catch "";
            if (pos + bytes_str.len <= buf.len) {
                @memcpy(buf[pos .. pos + bytes_str.len], bytes_str);
                pos += bytes_str.len;
            }
        }
    }

    // Throughput
    if (state.ema_bytes_per_sec > 0.0 and state.samples_count >= 3) {
        var tp_buf: [32]u8 = undefined;
        const tp_str = format.formatThroughput(state.ema_bytes_per_sec, &tp_buf);
        if (pos + 1 + tp_str.len <= buf.len) {
            buf[pos] = ' ';
            pos += 1;
            @memcpy(buf[pos .. pos + tp_str.len], tp_str);
            pos += tp_str.len;
        }
    }

    // ETA (if available)
    if (state.estimateEtaSeconds()) |eta_secs| {
        var eta_buf: [32]u8 = undefined;
        const eta_str = format.formatEta(eta_secs, &eta_buf);
        if (pos + 1 + eta_str.len <= buf.len) {
            buf[pos] = ' ';
            pos += 1;
            @memcpy(buf[pos .. pos + eta_str.len], eta_str);
            pos += eta_str.len;
        }
    }

    // --- 4. Trailing newline ---
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    return buf[0..pos];
}

// ── Tests ──────────────────────────────────────────────────────────────

test "render: determinate bar at width 80 (unicode, no color)" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr, GradientColors.default);

    // Should contain label, percentage, file count
    try std.testing.expect(std.mem.indexOf(u8, line, "Compressing") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "58.") != null); // ~58.6%
    try std.testing.expect(std.mem.indexOf(u8, line, "234/400") != null);
    // Should contain block chars (filled or empty)
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x88") != null or
        std.mem.indexOf(u8, line, "\xe2\x96\x91") != null);
}

test "render: determinate bar ASCII fallback" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = false,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr, GradientColors.default);

    // Should use ASCII bar chars
    try std.testing.expect(std.mem.indexOf(u8, line, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "]") != null);
    // Should NOT contain unicode blocks
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x88") == null);
}

test "render: progressive stat dropping at narrow width" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 40,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr, GradientColors.default);

    // At width 40, ETA should be dropped but % should still be present
    try std.testing.expect(std.mem.indexOf(u8, line, "%") != null);
    // Bar should still exist
    try std.testing.expect(line.len > 0);
}

test "render: truecolor gradient produces ANSI escape sequences" {
    var state = core.ProgrezState.init("Test");
    state.setDeterminate(0, 1000);
    state.bytes_processed = 500;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = true,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [4096]u8 = undefined;
    const line = renderDeterminate(&state, caps, 0, &buf_arr, GradientColors.default);

    // Should contain ANSI truecolor escape
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[38;2;") != null);
    // Should contain reset
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[0m") != null);
}

test "render: 0% progress" {
    var state = core.ProgrezState.init("Starting");
    state.setDeterminate(100, 10_000);
    state.files_processed = 0;
    state.bytes_processed = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 0, &buf_arr, GradientColors.default);

    try std.testing.expect(std.mem.indexOf(u8, line, "0.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Starting") != null);
}

test "render: 100% progress" {
    var state = core.ProgrezState.init("Done");
    state.setDeterminate(100, 10_000);
    state.files_processed = 100;
    state.bytes_processed = 10_000;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 5_000_000_000, &buf_arr, GradientColors.default);

    try std.testing.expect(std.mem.indexOf(u8, line, "100.0%") != null);
}

test "render: indeterminate spinner" {
    var state = core.ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.files_processed = 1247;
    state.bytes_processed = 4_200_000;
    state.spinner_frame = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [512]u8 = undefined;
    const line = renderIndeterminate(&state, caps, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "Scanning") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1,247") != null);
}

test "render: indeterminate with guess shows approximate percent" {
    var state = core.ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.files_processed = 1247;
    state.bytes_processed = 4_200_000;
    state.guess_total_files = 2000;
    state.spinner_frame = 3;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [512]u8 = undefined;
    const line = renderIndeterminate(&state, caps, &buf);

    // Should show approximate percentage
    try std.testing.expect(std.mem.indexOf(u8, line, "~") != null);
}

test "render: indeterminate ASCII fallback" {
    var state = core.ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.files_processed = 100;
    state.spinner_frame = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = false,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [512]u8 = undefined;
    const line = renderIndeterminate(&state, caps, &buf);

    // ASCII spinner should be used (|, /, -, \)
    try std.testing.expect(line.len > 0);
    // No braille chars
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2") == null); // No UTF-8 braille
}

test "render: completion summary with identity" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 400;
    state.bytes_processed = 21_000_000;
    state.start_time_ns = 0;
    state.setIdentity("bzip2z", "compression of mydir/");

    var buf: [512]u8 = undefined;
    const line = renderCompletionSummary(&state, 23_450_000_000, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "bzip2z completed: compression of mydir/") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "23.45s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "400") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
}

test "render: completion summary without identity" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 400;
    state.bytes_processed = 21_000_000;
    state.start_time_ns = 0;

    var buf: [512]u8 = undefined;
    const line = renderCompletionSummary(&state, 23_450_000_000, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "Compressing completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "23.45s") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
}

test "render: log mode line (non-TTY)" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 100;
    state.bytes_processed = 5_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    var buf: [256]u8 = undefined;
    const line = renderLogLine(&state, 10_000_000_000, &buf);

    // No ANSI escapes
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[") == null);
    // Contains expected data
    try std.testing.expect(std.mem.indexOf(u8, line, "[progrez]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Compressing") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "25") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "100/400") != null);
}

test "render: log mode indeterminate" {
    var state = core.ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.files_processed = 500;
    state.bytes_processed = 2_000_000;

    var buf: [256]u8 = undefined;
    const line = renderLogLine(&state, 5_000_000_000, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "[progrez]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Scanning") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "500") != null);
}

test "render: completion summary bytes only (no files)" {
    var state = core.ProgrezState.init("Processing");
    state.setDeterminate(0, 5_000_000); // 0 files = not tracking
    state.bytes_processed = 5_000_000;
    state.start_time_ns = 0;

    var buf: [512]u8 = undefined;
    const line = renderCompletionSummary(&state, 10_000_000_000, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "Processing completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "10.00s") != null);
    // Should have bytes but not "files"
    try std.testing.expect(std.mem.indexOf(u8, line, "5.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "files") == null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
}

test "render: dispatch selects correct renderer for determinate" {
    var state = core.ProgrezState.init("Test");
    state.setDeterminate(100, 5000);
    state.files_processed = 50;
    state.bytes_processed = 2500;

    const tty_caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [2048]u8 = undefined;
    const line = renderLine(&state, tty_caps, 1_000_000_000, &buf, GradientColors.default);
    // Determinate mode should produce block chars
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x88") != null or
        std.mem.indexOf(u8, line, "\xe2\x96\x91") != null);
}

test "render: dispatch selects indeterminate renderer" {
    var state = core.ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.files_processed = 100;
    state.spinner_frame = 0;

    const tty_caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [512]u8 = undefined;
    const line = renderLine(&state, tty_caps, 1_000_000_000, &buf, GradientColors.default);
    // Indeterminate should have spinner or count
    try std.testing.expect(std.mem.indexOf(u8, line, "Scanning") != null);
}

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

test "render: dispatch returns empty for idle" {
    const state = core.ProgrezState.init("Idle");

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf: [512]u8 = undefined;
    const line = renderLine(&state, caps, 0, &buf, GradientColors.default);
    try std.testing.expectEqual(@as(usize, 0), line.len);
}

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

    // Should contain sparkline lower block chars (▁ = \xe2\x96\x81)
    // This char is NOT used by the progress bar itself, so it can only come from sparkline
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x81") != null);
}

// ── Scenario Tests ──────────────────────────────────────────────────────
// These tests simulate realistic progress sequences using recordUpdate()
// with injected timestamps, then assert on the rendered output.

/// Helper: plain unicode terminal caps at a given width (no color escapes to simplify assertions).
fn testCaps(width: u16) terminal.TerminalCaps {
    return .{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = width,
    };
}

test "scenario: 50% progress at 2 MB/s shows throughput and ETA" {
    var state = core.ProgrezState.init("Copying");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(100, 20_000_000);

    var t: i128 = 0;
    for (1..6) |i| {
        t += std.time.ns_per_s;
        state.recordUpdate(@intCast(i * 2_000_000), @intCast(i * 10), t);
    }

    var buf: [4096]u8 = undefined;
    const line = renderLine(&state, testCaps(120), t, &buf, GradientColors.default);

    try std.testing.expect(std.mem.indexOf(u8, line, "Copying") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "50/100 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "10.0 MB/20.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "2.0 MB/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ETA 5s") != null);
}

test "scenario: sparkline with varying rates" {
    var state = core.ProgrezState.init("Compressing");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(200, 30_000_000);
    state.sparkline_enabled = true;

    const rates = [_]u64{ 500_000, 1_000_000, 3_000_000, 2_000_000, 4_000_000, 1_500_000, 5_000_000, 3_500_000 };
    var cumulative_bytes: u64 = 0;
    var t: i128 = 0;
    for (rates, 1..) |bytes_this_interval, i| {
        t += std.time.ns_per_s;
        cumulative_bytes += bytes_this_interval;
        state.recordUpdate(cumulative_bytes, @intCast(i * 25), t);
    }

    var buf: [4096]u8 = undefined;
    const line = renderLine(&state, testCaps(140), t, &buf, GradientColors.default);

    try std.testing.expect(std.mem.indexOf(u8, line, "Compressing") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "68.3%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "200/200 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "3.1 MB/s") != null);
    // Sparkline contains block elements (▁ through █)
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x81") != null); // ▁
    try std.testing.expect(std.mem.indexOf(u8, line, "ETA 3s") != null);
}

test "scenario: ETA decreases as progress advances" {
    var state = core.ProgrezState.init("Downloading");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(0, 10_000_000);

    for (1..4) |i| {
        state.recordUpdate(@intCast(i * 1_000_000), 0, @intCast(i * std.time.ns_per_s));
    }

    var buf: [4096]u8 = undefined;
    const line_early = renderLine(&state, testCaps(100), 3 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, line_early, "30.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line_early, "1.0 MB/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line_early, "ETA 7s") != null);

    for (4..9) |i| {
        state.recordUpdate(@intCast(i * 1_000_000), 0, @intCast(i * std.time.ns_per_s));
    }

    const line_late = renderLine(&state, testCaps(100), 8 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, line_late, "80.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line_late, "ETA 2s") != null);
}

test "scenario: log mode shows all stats" {
    var state = core.ProgrezState.init("Indexing");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(500, 50_000_000);

    for (1..6) |i| {
        state.recordUpdate(@intCast(i * 5_000_000), @intCast(i * 50), @intCast(i * std.time.ns_per_s));
    }

    var buf: [4096]u8 = undefined;
    const line = renderLogLine(&state, 5 * std.time.ns_per_s, &buf);

    try std.testing.expect(std.mem.indexOf(u8, line, "[progrez] Indexing 50% 250/500 files 25.0 MB/50.0 MB 5.0 MB/s ETA 5s") != null);
}

test "scenario: narrow terminal drops stats progressively" {
    var state = core.ProgrezState.init("Sync");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(100, 10_000_000);
    state.sparkline_enabled = true;

    for (1..6) |i| {
        state.recordUpdate(@intCast(i * 1_000_000), @intCast(i * 10), @intCast(i * std.time.ns_per_s));
    }
    for (0..8) |i| {
        state.rate_history[i] = @as(f64, @floatFromInt(i + 1)) * 200_000.0;
    }
    state.rate_history_len = 8;

    var buf: [4096]u8 = undefined;

    // Wide (140): all stats including sparkline and ETA
    const wide = renderLine(&state, testCaps(140), 5 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, wide, "ETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "MB/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide, "\xe2\x96\x81") != null); // sparkline

    // Medium (80): drops ETA, sparkline, throughput
    const med = renderLine(&state, testCaps(80), 5 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, med, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, med, "5.0 MB/10.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, med, "ETA") == null);

    // Narrow (40): drops bytes too, keeps files + pct
    const narrow = renderLine(&state, testCaps(40), 5 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "50/100 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "MB/s") == null);

    // Very narrow (30): only pct
    const tiny = renderLine(&state, testCaps(30), 5 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, tiny, "50.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiny, "files") == null);
}

test "scenario: completion summary with identity" {
    var state = core.ProgrezState.init("Archiving");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(100, 10_000_000);
    state.setIdentity("z7z", "compressing /data");

    for (1..11) |i| {
        state.recordUpdate(@intCast(i * 1_000_000), @intCast(i * 10), @intCast(i * std.time.ns_per_s));
    }

    var buf: [1024]u8 = undefined;
    const summary = renderCompletionSummary(&state, 10 * std.time.ns_per_s, &buf);

    try std.testing.expect(std.mem.indexOf(u8, summary, "z7z completed: compressing /data in 10.00s (100 files, 10.0 MB)") != null);
}

test "scenario: 100% spinner rotates through braille frames" {
    var state = core.ProgrezState.init("Finishing");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(0, 10_000_000);

    for (1..6) |i| {
        state.recordUpdate(@intCast(i * 2_000_000), 0, @intCast(i * std.time.ns_per_s));
    }

    var buf: [4096]u8 = undefined;
    const expected_frames = [_][]const u8{
        "\xe2\xa0\x8b", // ⠋ frame 0
        "\xe2\xa0\x99", // ⠙ frame 1
        "\xe2\xa0\xb9", // ⠹ frame 2
        "\xe2\xa0\xb8", // ⠸ frame 3
        "\xe2\xa0\xbc", // ⠼ frame 4
        "\xe2\xa0\xb4", // ⠴ frame 5
        "\xe2\xa0\xa6", // ⠦ frame 6
        "\xe2\xa0\xa7", // ⠧ frame 7
        "\xe2\xa0\x87", // ⠇ frame 8
        "\xe2\xa0\x8f", // ⠏ frame 9
        "\xe2\xa0\x8b", // ⠋ frame 10 wraps to 0
    };

    for (expected_frames, 0..) |expected_char, i| {
        state.spinner_frame = @intCast(i);
        const line = renderLine(&state, testCaps(80), 5 * std.time.ns_per_s, &buf, GradientColors.default);
        try std.testing.expect(std.mem.indexOf(u8, line, expected_char) != null);
    }
}

test "scenario: 100% shows spinner, percentage clamped on overshoot" {
    var state = core.ProgrezState.init("Finalizing");
    state.start_time_ns = 0;
    state.last_update_ns = 0;
    state.setDeterminate(100, 10_000_000);

    for (1..6) |i| {
        state.recordUpdate(@intCast(i * 2_000_000), @intCast(i * 20), @intCast(i * std.time.ns_per_s));
    }

    var buf: [4096]u8 = undefined;

    // At 100%: spinner should appear after bar
    const line = renderLine(&state, testCaps(120), 5 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, line, "100.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "2.0 MB/s") != null);
    // Braille spinner char (⠋ = \xe2\xa0\x8b)
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\xa0\x8b") != null);

    // Overshoot: percentage still clamped to 100.0%
    state.recordUpdate(12_000_000, 120, 12 * std.time.ns_per_s);
    const overshoot = renderLine(&state, testCaps(120), 12 * std.time.ns_per_s, &buf, GradientColors.default);
    try std.testing.expect(std.mem.indexOf(u8, overshoot, "100.0%") != null);
    // Should NOT show 120.0%
    try std.testing.expect(std.mem.indexOf(u8, overshoot, "120.0%") == null);
    // Spinner still present
    try std.testing.expect(std.mem.indexOf(u8, overshoot, "\xe2\xa0\x8b") != null);
}

// Alias for tests (matches the non-test function name used by renderLine)
const countDisplayColumns = countDisplayCols;

test "scenario: renderLine always fills exactly terminal width" {
    // After a mode switch (determinate → indeterminate), leftover characters
    // from the longer previous line are visible if the new line is shorter.
    // Fix: renderLine must always pad to exactly the terminal width.
    const w: u16 = 80;
    var buf: [4096]u8 = undefined;

    // Determinate line at 50%
    {
        var state = core.ProgrezState.init("Processing");
        state.start_time_ns = 0;
        state.last_update_ns = 0;
        state.setDeterminate(100, 10_000_000);
        for (1..4) |i| {
            state.recordUpdate(@intCast(i * 1_000_000), @intCast(i * 10), @intCast(i * std.time.ns_per_s));
        }
        const line = renderLine(&state, testCaps(w), 3 * std.time.ns_per_s, &buf, GradientColors.default);
        const cols = countDisplayColumns(line);
        if (cols != w) {
            std.debug.print("\nDETERMINATE: expected {d} cols, got {d}, line=|{s}|\n", .{ w, cols, line });
        }
        try std.testing.expectEqual(@as(usize, w), cols);
    }

    // Indeterminate line (shorter content — must still pad to width)
    {
        var state = core.ProgrezState.init("Scanning");
        state.start_time_ns = 0;
        state.last_update_ns = 0;
        state.setIndeterminate();
        state.recordUpdate(5000, 10, 1 * std.time.ns_per_s);
        state.spinner_frame = 3;
        const line = renderLine(&state, testCaps(w), 1 * std.time.ns_per_s, &buf, GradientColors.default);
        const cols = countDisplayColumns(line);
        if (cols != w) {
            std.debug.print("\nINDETERMINATE: expected {d} cols, got {d}, line=|{s}|\n", .{ w, cols, line });
        }
        try std.testing.expectEqual(@as(usize, w), cols);
    }
}

test "scenario: 100% with spinner does not exceed terminal width" {
    const widths = [_]u16{ 80, 120, 60, 40 };
    for (widths) |w| {
        var state = core.ProgrezState.init("Building");
        state.start_time_ns = 0;
        state.last_update_ns = 0;
        state.setDeterminate(50, 5_000_000);

        for (1..6) |i| {
            state.recordUpdate(@intCast(i * 1_000_000), @intCast(i * 10), @intCast(i * std.time.ns_per_s));
        }

        var buf: [4096]u8 = undefined;
        const line = renderLine(&state, testCaps(w), 5 * std.time.ns_per_s, &buf, GradientColors.default);
        const display_cols = countDisplayColumns(line);

        // The rendered line's display width must never exceed the terminal width
        if (display_cols > w) {
            std.debug.print("\nWIDTH OVERFLOW: terminal={d}, rendered={d}, line=|{s}|\n", .{ w, display_cols, line });
        }
        try std.testing.expect(display_cols <= w);
    }
}

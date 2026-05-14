//! Pure formatting functions for progress display.
//! All functions take a value and a caller-provided buffer,
//! write into it, and return a slice. No allocations.

const std = @import("std");

/// Format a byte count into a human-readable string using SI units.
/// Uses SI units: 1 KB = 1000 bytes.
/// Thresholds: < 1000 = B, < 1M = KB, < 1G = MB, < 1T = GB, else TB.
/// One decimal place for KB and above.
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const KB: u64 = 1_000;
    const MB: u64 = 1_000_000;
    const GB: u64 = 1_000_000_000;
    const TB: u64 = 1_000_000_000_000;

    if (bytes < KB) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (bytes < MB) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB));
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{val}) catch "?";
    } else if (bytes < GB) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB));
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{val}) catch "?";
    } else if (bytes < TB) {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB));
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{val}) catch "?";
    } else {
        const val: f64 = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(TB));
        return std.fmt.bufPrint(buf, "{d:.1} TB", .{val}) catch "?";
    }
}

/// Format a count with comma-separated thousands.
/// Builds digits right-to-left, inserting commas every 3 digits.
pub fn formatCount(count: u64, buf: []u8) []const u8 {
    if (count == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    // Build right-to-left into a temp stack buffer.
    // Max u64 is 18,446,744,073,709,551,615 = 20 digits + 6 commas = 26 chars.
    var tmp: [32]u8 = undefined;
    var pos: usize = tmp.len;
    var remaining = count;
    var digit_count: usize = 0;

    while (remaining > 0) {
        if (digit_count > 0 and digit_count % 3 == 0) {
            pos -= 1;
            tmp[pos] = ',';
        }
        pos -= 1;
        tmp[pos] = @intCast('0' + @as(u8, @intCast(remaining % 10)));
        remaining /= 10;
        digit_count += 1;
    }

    const len = tmp.len - pos;
    @memcpy(buf[0..len], tmp[pos..tmp.len]);
    return buf[0..len];
}

/// Format a fraction (0.0-1.0) as a percentage with one decimal place.
pub fn formatPercent(fraction: f64, buf: []u8) []const u8 {
    const pct = fraction * 100.0;
    return std.fmt.bufPrint(buf, "{d:.1}%", .{pct}) catch "?";
}

/// Format seconds as ETA. < 60 = "ETA Xs", < 3600 = "ETA XmXs", >= 3600 = "ETA XhXmXs".
pub fn formatEta(seconds: f64, buf: []u8) []const u8 {
    const total_secs: u64 = @intFromFloat(seconds);
    const h = total_secs / 3600;
    const m = (total_secs % 3600) / 60;
    const s = total_secs % 60;

    if (h > 0) {
        return std.fmt.bufPrint(buf, "ETA {d}h{d}m{d}s", .{ h, m, s }) catch "?";
    } else if (m > 0) {
        return std.fmt.bufPrint(buf, "ETA {d}m{d}s", .{ m, s }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "ETA {d}s", .{s}) catch "?";
    }
}

/// Format elapsed time in seconds.
/// < 60s = "X.XXs" (2 decimal places), < 3600 = "XmXXs", >= 3600 = "XhXmXs".
pub fn formatElapsed(seconds: f64, buf: []u8) []const u8 {
    if (seconds < 60.0) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{seconds}) catch "?";
    } else if (seconds < 3600.0) {
        const total_secs: u64 = @intFromFloat(seconds);
        const m = total_secs / 60;
        const s = total_secs % 60;
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ m, s }) catch "?";
    } else {
        const total_secs: u64 = @intFromFloat(seconds);
        const h = total_secs / 3600;
        const m = (total_secs % 3600) / 60;
        const s = total_secs % 60;
        return std.fmt.bufPrint(buf, "{d}h{d}m{d}s", .{ h, m, s }) catch "?";
    }
}

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
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[unit_idx] }) catch "";
}

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

// ── Tests ──────────────────────────────────────────────────────────────

test "format: bytes to human readable" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(0, &buf));
    try std.testing.expectEqualStrings("1 B", formatBytes(1, &buf));
    try std.testing.expectEqualStrings("999 B", formatBytes(999, &buf));
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1000, &buf));
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(1536, &buf));
    try std.testing.expectEqualStrings("1.0 MB", formatBytes(1_000_000, &buf));
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(1_000_000_000, &buf));
    try std.testing.expectEqualStrings("1.0 TB", formatBytes(1_000_000_000_000, &buf));
    try std.testing.expectEqualStrings("2.3 GB", formatBytes(2_300_000_000, &buf));
}

test "format: count with commas" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatCount(0, &buf));
    try std.testing.expectEqualStrings("42", formatCount(42, &buf));
    try std.testing.expectEqualStrings("999", formatCount(999, &buf));
    try std.testing.expectEqualStrings("1,000", formatCount(1_000, &buf));
    try std.testing.expectEqualStrings("1,247", formatCount(1_247, &buf));
    try std.testing.expectEqualStrings("1,000,000", formatCount(1_000_000, &buf));
    try std.testing.expectEqualStrings("12,345,678", formatCount(12_345_678, &buf));
}

test "format: percentage" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.0%", formatPercent(0.0, &buf));
    try std.testing.expectEqualStrings("50.0%", formatPercent(0.5, &buf));
    try std.testing.expectEqualStrings("99.9%", formatPercent(0.999, &buf));
    try std.testing.expectEqualStrings("100.0%", formatPercent(1.0, &buf));
}

test "format: ETA" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ETA 5s", formatEta(5.0, &buf));
    try std.testing.expectEqualStrings("ETA 42s", formatEta(42.0, &buf));
    try std.testing.expectEqualStrings("ETA 1m0s", formatEta(60.0, &buf));
    try std.testing.expectEqualStrings("ETA 1m23s", formatEta(83.0, &buf));
    try std.testing.expectEqualStrings("ETA 10m0s", formatEta(600.0, &buf));
    try std.testing.expectEqualStrings("ETA 1h0m0s", formatEta(3600.0, &buf));
    try std.testing.expectEqualStrings("ETA 2h30m15s", formatEta(9015.0, &buf));
}

test "format: elapsed time" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.00s", formatElapsed(0.0, &buf));
    try std.testing.expectEqualStrings("1.23s", formatElapsed(1.23, &buf));
    try std.testing.expectEqualStrings("23.45s", formatElapsed(23.45, &buf));
    try std.testing.expectEqualStrings("1m23s", formatElapsed(83.0, &buf));
    try std.testing.expectEqualStrings("1h0m0s", formatElapsed(3600.0, &buf));
}

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

test "format: sparkline" {
    var buf: [32]u8 = undefined;

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

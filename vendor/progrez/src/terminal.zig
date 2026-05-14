//! Terminal capability detection — pure logic, no I/O.
//! Takes an EnvInfo struct (injectable) rather than reading env vars directly.
//! The FFI layer reads env vars and passes them in, keeping this module pure.

const std = @import("std");

/// Environment information, injected by the caller.
/// The FFI layer reads actual env vars / tty state and populates this.
pub const EnvInfo = struct {
    progrez_style: ?[]const u8,
    no_color: ?[]const u8,
    colorterm: ?[]const u8,
    term: ?[]const u8,
    wt_session: ?[]const u8,
    is_tty: bool,
    width: u16,
};

/// Detected terminal capabilities.
pub const TerminalCaps = struct {
    is_tty: bool,
    unicode: bool,
    truecolor: bool,
    color_256: bool,
    color_16: bool,
    width: u16,

    /// Detect terminal capabilities from the given environment info.
    ///
    /// Detection priority:
    /// 1. PROGREZ_STYLE=ascii -> unicode=false, all color=false
    /// 2. NO_COLOR set -> all color=false (unicode stays true)
    /// 3. COLORTERM=truecolor or 24bit -> truecolor + 256 + 16
    /// 4. WT_SESSION set -> truecolor + unicode (Windows Terminal)
    /// 5. TERM contains "256color" -> color_256 + color_16
    /// 6. TERM set to anything -> color_16
    /// 7. Default: unicode=true, all color=false
    pub fn detect(env: EnvInfo) TerminalCaps {
        var caps: TerminalCaps = .{
            .is_tty = env.is_tty,
            .unicode = true, // default true on modern systems
            .truecolor = false,
            .color_256 = false,
            .color_16 = false,
            .width = env.width,
        };

        // 1. PROGREZ_STYLE=ascii forces ASCII mode: no unicode, no color
        if (env.progrez_style) |style| {
            if (std.mem.eql(u8, style, "ascii")) {
                caps.unicode = false;
                return caps;
            }
        }

        // 2. NO_COLOR disables all color (but unicode stays true)
        if (env.no_color != null) {
            // Still detect unicode capabilities but skip all color detection
            return caps;
        }

        // 3. COLORTERM=truecolor or COLORTERM=24bit
        if (env.colorterm) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                caps.truecolor = true;
                caps.color_256 = true;
                caps.color_16 = true;
                return caps;
            }
        }

        // 4. WT_SESSION set -> Windows Terminal (truecolor + unicode)
        if (env.wt_session != null) {
            caps.truecolor = true;
            caps.color_256 = true;
            caps.color_16 = true;
            return caps;
        }

        // 5. TERM contains "256color"
        if (env.term) |term| {
            if (std.mem.indexOf(u8, term, "256color") != null) {
                caps.color_256 = true;
                caps.color_16 = true;
                return caps;
            }
            // 6. TERM set to anything -> at least color_16
            caps.color_16 = true;
            return caps;
        }

        // 7. Default: unicode=true, all color=false (already set)
        return caps;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "terminal: PROGREZ_STYLE=ascii forces ASCII" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = "ascii",
        .no_color = null,
        .colorterm = null,
        .term = null,
        .wt_session = null,
        .is_tty = true,
        .width = 80,
    });
    try std.testing.expect(!caps.unicode);
    try std.testing.expect(!caps.truecolor);
    try std.testing.expect(!caps.color_256);
    try std.testing.expect(caps.is_tty);
    try std.testing.expectEqual(@as(u16, 80), caps.width);
}

test "terminal: NO_COLOR disables color but keeps unicode" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = "1",
        .colorterm = "truecolor",
        .term = "xterm-256color",
        .wt_session = null,
        .is_tty = true,
        .width = 120,
    });
    try std.testing.expect(caps.unicode);
    try std.testing.expect(!caps.truecolor);
    try std.testing.expect(!caps.color_256);
    try std.testing.expect(!caps.color_16);
}

test "terminal: truecolor detection via COLORTERM" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = "truecolor",
        .term = "xterm-256color",
        .wt_session = null,
        .is_tty = true,
        .width = 80,
    });
    try std.testing.expect(caps.truecolor);
    try std.testing.expect(caps.unicode);
}

test "terminal: 24bit COLORTERM also means truecolor" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = "24bit",
        .term = "xterm",
        .wt_session = null,
        .is_tty = true,
        .width = 80,
    });
    try std.testing.expect(caps.truecolor);
}

test "terminal: 256color from TERM" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = null,
        .term = "xterm-256color",
        .wt_session = null,
        .is_tty = true,
        .width = 80,
    });
    try std.testing.expect(!caps.truecolor);
    try std.testing.expect(caps.color_256);
    try std.testing.expect(caps.unicode);
}

test "terminal: Windows Terminal via WT_SESSION" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = null,
        .term = null,
        .wt_session = "some-guid",
        .is_tty = true,
        .width = 120,
    });
    try std.testing.expect(caps.truecolor);
    try std.testing.expect(caps.unicode);
}

test "terminal: non-tty still detects caps" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = "truecolor",
        .term = "xterm-256color",
        .wt_session = null,
        .is_tty = false,
        .width = 80,
    });
    try std.testing.expect(!caps.is_tty);
    try std.testing.expect(caps.truecolor); // caps detected even when not TTY
}

test "terminal: width passed through" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = null,
        .term = null,
        .wt_session = null,
        .is_tty = true,
        .width = 200,
    });
    try std.testing.expectEqual(@as(u16, 200), caps.width);
}

test "terminal: bare minimum (no env vars, no tty)" {
    const caps = TerminalCaps.detect(.{
        .progrez_style = null,
        .no_color = null,
        .colorterm = null,
        .term = null,
        .wt_session = null,
        .is_tty = false,
        .width = 80,
    });
    try std.testing.expect(!caps.is_tty);
    try std.testing.expect(caps.unicode); // unicode is default true on modern systems
    try std.testing.expect(!caps.truecolor);
    try std.testing.expect(!caps.color_256);
    try std.testing.expect(!caps.color_16);
}

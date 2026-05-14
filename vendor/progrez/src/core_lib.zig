//! Pure-logic module root for downstream Zig consumers.
//! Excludes ffi.zig (no C symbol emission, no render thread).
pub const core = @import("core.zig");
pub const format = @import("format.zig");
pub const terminal = @import("terminal.zig");
pub const render = @import("render.zig");

test {
    _ = core;
    _ = format;
    _ = terminal;
    _ = render;
}

//! The Transfers taskbar icon: a quiet arrow when nothing runs; a progress
//! ring in the accent around it while transfers run, whose arc is their
//! combined progress; pause bars and a muted ring when all are paused. A dot
//! asks for attention: a conflict waits (accent) or a transfer failed
//! (danger).
const ui_paint = @import("ui").paint;
const theme = @import("ui").theme;
const glyphs = @import("glyphs.zig");
const Server = @import("../Server.zig");
const Summary = @import("model.zig").Summary;

pub fn paint(r: *ui_paint.Renderer, server: *Server, x: f32, y: f32, size: f32, color: [4]f32) void {
    const client = server.transfers orelse return glyphs.strokes(r, x, y, size, &glyphs.arrow_down, 2, color);
    paintSummary(r, client.model.summary(), x, y, size, color);
}

pub fn paintSummary(r: *ui_paint.Renderer, s: Summary, x: f32, y: f32, size: f32, color: [4]f32) void {
    const t = theme.global;
    const unit = size / 24;
    if (s.active == 0) {
        // Only sharing: the arrow points the other way.
        glyphs.strokes(r, x, y, size, if (s.seeding > 0) &glyphs.arrow_up else &glyphs.arrow_down, 2, color);
    } else {
        var track = color;
        track[3] *= 0.22;
        var arc = if (s.all_paused) color else t.accent;
        if (s.all_paused) arc[3] *= 0.6;
        // An unknown total still shows a ring, so running reads as running.
        glyphs.ring(r, x + 12 * unit, y + 12 * unit, 9 * unit, 2.2 * unit, s.fraction orelse 0, track, arc);
        glyphs.strokes(r, x, y, size, if (s.all_paused) &glyphs.ring_pause else &glyphs.ring_arrow, 2, color);
    }
    if (s.attention or s.failed > 0) {
        const dot = if (s.attention) t.accent else t.danger;
        r.fillRect(x + 17 * unit, y + 1 * unit, 6 * unit, 6 * unit, .{ .color = dot, .radius = 3 * unit });
    }
}

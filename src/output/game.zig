//! The window an output shows as a game: the keyboard-focused toplevel that
//! fills it, fullscreen or borderless. Tearing, adaptive sync, game mode
//! notifications and focus on map follow it, so every caller agrees on one rule.

const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const Server = @import("../Server.zig");
const workspaces = @import("../workspaces.zig");

pub fn window(output: *Output) ?*Toplevel {
    const server = output.server;
    const focused = server.input.seat.keyboard_state.focused_surface orelse return null;
    const top = Toplevel.fromSurface(server, focused) orelse return null;
    if (!top.in_world or top.minimized or top.tab_hidden or top.currentOutput() != output) return null;
    if (top.isFullscreen() or coversOutput(top, output)) return top;
    return null;
}

/// The focused window while it is a game in front of the user: fullscreen (as
/// asked, before the client acks) or a borderless window filling its output.
pub fn inFront(server: *Server) ?*Toplevel {
    const top = server.world.toplevels.first() orelse return null;
    if (!top.in_world or top.minimized or top.tab_hidden or !workspaces.visible(top)) return null;
    const keyboard = server.input.seat.keyboard_state.focused_surface orelse return null;
    if (Toplevel.fromSurface(server, keyboard) != top) return null;
    if (top.fullscreen) return top;
    const output = top.currentOutput() orelse return null;
    return if (window(output) == top) top else null;
}

/// Borderless windowed, the default of many games: an undecorated window the
/// client placed itself (not maximized or tiled) whose frame is the output.
fn coversOutput(top: *Toplevel, output: *Output) bool {
    if (top.hasServerDecorations() or top.isMaximized() or top.forcedGeometry() != null) return false;
    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return false;
    const world = &output.server.world;
    const a = top.frameWorld(0, 0);
    const b = top.frameWorld(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height));
    const start = world.toLayout(a.x, a.y);
    const end = world.toLayout(b.x, b.y);
    return near(start.x, box.x) and near(start.y, box.y) and
        near(end.x, box.x + box.width) and near(end.y, box.y + box.height);
}

fn near(value: f64, edge: i32) bool {
    return @abs(value - @as(f64, @floatFromInt(edge))) < 1.0;
}

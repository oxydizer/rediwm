const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Toplevel = @import("Toplevel.zig");
const gpa = @import("main.zig").gpa;

const Decoration = @This();

decoration: *wlr.XdgToplevelDecorationV1,
toplevel: ?*Toplevel,
request_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleRequestMode),
destroy: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleDestroy),

pub fn create(decoration: *wlr.XdgToplevelDecorationV1, toplevel: *Toplevel) !void {
    const tracked = try gpa.create(Decoration);
    errdefer gpa.destroy(tracked); // listener add below is infallible; this covers any later try
    tracked.* = .{ .decoration = decoration, .toplevel = toplevel };
    decoration.events.request_mode.add(&tracked.request_mode);
    decoration.events.destroy.add(&tracked.destroy);
    toplevel.decoration = tracked;
}

fn handleRequestMode(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    decoration: *wlr.XdgToplevelDecorationV1,
) void {
    _ = decoration;
    const tracked: *Decoration = @fieldParentPtr("request_mode", listener);
    tracked.applyMode();
}

pub fn applyMode(tracked: *Decoration) void {
    const toplevel = tracked.toplevel orelse return;
    // Clients can request a mode before their first XDG commit. Defer the
    // configure until that surface has been initialized.
    if (!toplevel.isInitialized()) return;
    // With no preference, offer our frame; explicit CSD requests win unless overridden by rule.
    const mode: wlr.XdgToplevelDecorationV1.Mode = if (toplevel.live_rules.decorations) |dec| switch (dec) {
        .server => .server_side,
        .client => .client_side,
        .auto => if (tracked.decoration.requested_mode == .client_side) .client_side else .server_side,
    } else if (tracked.decoration.requested_mode == .client_side)
        .client_side
    else
        .server_side;
    if (tracked.decoration.scheduled_mode != mode) {
        _ = tracked.decoration.setMode(mode);
    }
}

fn handleDestroy(
    listener: *wl.Listener(*wlr.XdgToplevelDecorationV1),
    _: *wlr.XdgToplevelDecorationV1,
) void {
    const tracked: *Decoration = @fieldParentPtr("destroy", listener);
    if (tracked.toplevel) |toplevel| {
        if (toplevel.decoration == tracked) toplevel.decoration = null;
    }
    tracked.request_mode.link.remove();
    tracked.destroy.link.remove();
    gpa.destroy(tracked);
}

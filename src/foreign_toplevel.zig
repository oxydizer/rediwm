//! wlr-foreign-toplevel-management-v1: the window list that docks, waybar's
//! taskbar and rofi/fuzzel window switchers use. Unlike the ext list published
//! for capture (xdg-shell only), every mapped window, X11 included, gets a
//! handle. `Toplevel` owns one `Handle` while mapped and calls `sync` wherever
//! it already reports a window change; `sync` sends only what differs.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Toplevel = @import("Toplevel.zig");
const Output = @import("Output.zig");
const gpa = @import("main.zig").gpa;

pub const Handle = struct {
    toplevel: *Toplevel,
    handle: *wlr.ForeignToplevelHandleV1,
    output: ?*wlr.Output = null,
    parent: ?*Handle = null,

    request_activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) = .init(handleActivate),
    request_close: wl.Listener(*wlr.ForeignToplevelHandleV1) = .init(handleClose),
    request_minimize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized) = .init(handleMinimize),
    request_maximize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized) = .init(handleMaximize),
    request_fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) = .init(handleFullscreen),

    pub fn create(manager: *wlr.ForeignToplevelManagerV1, toplevel: *Toplevel) !*Handle {
        const self = try gpa.create(Handle);
        errdefer gpa.destroy(self);
        self.* = .{ .toplevel = toplevel, .handle = try wlr.ForeignToplevelHandleV1.create(manager) };
        const events = &self.handle.events;
        events.request_activate.add(&self.request_activate);
        events.request_close.add(&self.request_close);
        events.request_minimize.add(&self.request_minimize);
        events.request_maximize.add(&self.request_maximize);
        events.request_fullscreen.add(&self.request_fullscreen);
        self.sync();
        // Mapping may focus the window before its handle exists.
        const seat = toplevel.server.input.seat;
        if (seat.keyboard_state.focused_surface) |focused| {
            self.setActivated(Toplevel.fromSurface(toplevel.server, focused) == toplevel);
        }
        return self;
    }

    pub fn destroy(self: *Handle) void {
        // Children must not keep announcing a parent that no longer exists.
        var it = self.toplevel.server.world.toplevels.iterator(.forward);
        while (it.next()) |other| {
            const child = other.wlr_foreign orelse continue;
            if (child.parent == self) {
                child.handle.setParent(null);
                child.parent = null;
            }
        }
        self.request_activate.link.remove();
        self.request_close.link.remove();
        self.request_minimize.link.remove();
        self.request_maximize.link.remove();
        self.request_fullscreen.link.remove();
        self.handle.destroy();
        gpa.destroy(self);
    }

    /// Sends title, app id, state, output and parent changes. Activation is
    /// separate (`setActivated`): only focus changes know it without a lookup.
    pub fn sync(self: *Handle) void {
        const toplevel = self.toplevel;
        const handle = self.handle;
        const title = toplevel.titlePtr() orelse "";
        if (!sameZ(handle.title, title)) handle.setTitle(title);
        const app_id = toplevel.appIdPtr() orelse "";
        if (!sameZ(handle.app_id, app_id)) handle.setAppId(app_id);
        self.syncState();

        const output: ?*wlr.Output = if (toplevel.minimized)
            self.output
        else if (toplevel.currentOutput()) |o| o.wlr_output else null;
        if (output != self.output) {
            if (self.output) |old| handle.outputLeave(old);
            if (output) |new| handle.outputEnter(new);
            self.output = output;
        }

        const parent = if (toplevel.parentWindow()) |p| p.wlr_foreign else null;
        if (parent != self.parent) {
            handle.setParent(if (parent) |p| p.handle else null);
            self.parent = parent;
        }
    }

    /// Minimized/maximized/fullscreen only; cheap enough for every commit,
    /// since wlroots ignores unchanged states.
    pub fn syncState(self: *Handle) void {
        const toplevel = self.toplevel;
        self.handle.setMinimized(toplevel.minimized);
        self.handle.setMaximized(toplevel.isMaximized());
        self.handle.setFullscreen(toplevel.isFullscreen());
    }

    pub fn setActivated(self: *Handle, activated: bool) void {
        self.handle.setActivated(activated);
    }

    /// Output teardown: wlroots drops its own record, so forget ours before a
    /// new output can reuse the address.
    pub fn forgetOutput(self: *Handle, output: *wlr.Output) void {
        if (self.output == output) self.output = null;
    }

    fn blocked(self: *Handle) bool {
        const server = self.toplevel.server;
        return server.locker != null or server.polkit_dialog != null or !self.toplevel.in_world;
    }

    fn handleActivate(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated), _: *wlr.ForeignToplevelHandleV1.event.Activated) void {
        const self: *Handle = @fieldParentPtr("request_activate", listener);
        if (self.blocked()) return;
        const toplevel = self.toplevel;
        const world = &toplevel.server.world;
        // As a taskbar click: restore, focus, then pan the canvas to it.
        if (toplevel.minimized) toplevel.restore() else world.focus(toplevel);
        if (toplevel.currentOutput()) |output| world.revealIfOffscreen(toplevel, output);
        toplevel.server.scheduleFrames();
    }

    fn handleClose(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1), _: *wlr.ForeignToplevelHandleV1) void {
        const self: *Handle = @fieldParentPtr("request_close", listener);
        if (self.blocked()) return;
        self.toplevel.sendClose();
    }

    fn handleMinimize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized), event: *wlr.ForeignToplevelHandleV1.event.Minimized) void {
        const self: *Handle = @fieldParentPtr("request_minimize", listener);
        if (self.blocked()) return;
        // `minimize` can disconnect a self-capturing client and free `self`.
        if (event.minimized) self.toplevel.minimize() else self.toplevel.restore();
    }

    fn handleMaximize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized), event: *wlr.ForeignToplevelHandleV1.event.Maximized) void {
        const self: *Handle = @fieldParentPtr("request_maximize", listener);
        if (self.blocked() or self.toplevel.minimized) return;
        if (event.maximized != self.toplevel.isMaximized()) self.toplevel.setMaximized(event.maximized);
    }

    fn handleFullscreen(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen), event: *wlr.ForeignToplevelHandleV1.event.Fullscreen) void {
        const self: *Handle = @fieldParentPtr("request_fullscreen", listener);
        if (self.blocked() or self.toplevel.minimized) return;
        const toplevel = self.toplevel;
        if (event.fullscreen) {
            // zig-wlroots declares this non-null; wlroots sends NULL when the
            // client names no output.
            const raw: *const ?*wlr.Output = @ptrCast(&event.output);
            const requested = if (raw.*) |o| Output.fromWlr(o) else null;
            if (requested) |output| {
                toplevel.setFullscreenOn(output);
            } else if (!toplevel.isFullscreen()) {
                toplevel.toggleFullscreen();
            }
        } else if (toplevel.isFullscreen()) {
            toplevel.toggleFullscreen();
        }
    }
};

fn sameZ(current: ?[*:0]u8, wanted: [*:0]const u8) bool {
    const have = current orelse return false;
    return std.mem.orderZ(u8, have, wanted) == .eq;
}

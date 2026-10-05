//! zwp_keyboard_shortcuts_inhibit_manager_v1: lets VMs and remote desktops
//! (virt-manager, GNOME Boxes, Remmina) take over Super, Alt+Tab and every
//! other compositor binding while the user has grabbed input into them. GTK
//! asks for it from `gdk_seat_grab`, so a client only holds an inhibitor
//! while the user has deliberately captured the keyboard. wlroots owns the
//! protocol objects; this module decides which inhibitor, if any, is active.
//!
//! The inhibitor on the keyboard-focused surface is granted without a prompt,
//! as sway does. While it is active compositor bindings and modifier gestures
//! (modifier-drag pan, Alt+wheel zoom) belong to the client. Hardware keys,
//! Ctrl+Alt+F<n>, the lock screen and authentication dialogs still come
//! first, and the `restore_shortcuts` binding (Super+Escape) revokes the
//! grant until focus leaves the surface or the client asks again, so a
//! client that also locks the pointer can never trap the user.
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Input = @import("../Input.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

const log = @import("std").log.scoped(.shortcuts_inhibit);

input: *Input,
manager: *wlr.KeyboardShortcutsInhibitManagerV1,
active: ?*wlr.KeyboardShortcutsInhibitorV1 = null,
/// Revoked by `restore_shortcuts`; only ever the focused surface's.
revoked: ?*wlr.KeyboardShortcutsInhibitorV1 = null,
new_inhibitor: wl.Listener(*wlr.KeyboardShortcutsInhibitorV1) = .init(newInhibitor),
keyboard_focus: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(keyboardFocusChanged),

/// The destroy listener for one wlroots inhibitor, reachable through its
/// `data`. An inhibitor without one (allocation failed) never activates.
const Inhibitor = struct {
    owner: *Self,
    destroy: wl.Listener(*wlr.KeyboardShortcutsInhibitorV1) = .init(destroyed),

    fn release(inhibitor: *Inhibitor, wlr_inhibitor: *wlr.KeyboardShortcutsInhibitorV1) void {
        inhibitor.destroy.link.remove();
        wlr_inhibitor.data = null;
        gpa.destroy(inhibitor);
    }
};

pub fn init(self: *Self, input: *Input) !void {
    // The display owns and frees the global.
    const manager = try wlr.KeyboardShortcutsInhibitManagerV1.create(input.server.wl_server);
    self.* = .{ .input = input, .manager = manager };
    manager.events.new_inhibitor.add(&self.new_inhibitor);
    input.seat.keyboard_state.events.focus_change.add(&self.keyboard_focus);
}

/// Runs before the seat is destroyed; inhibitors still alive are freed with
/// the display later and must not reach this (then freed) state.
pub fn deinit(self: *Self) void {
    self.new_inhibitor.link.remove();
    self.keyboard_focus.link.remove();
    self.active = null;
    self.revoked = null;
    var it = self.manager.inhibitors.iterator(.forward);
    while (it.next()) |wlr_inhibitor| {
        const data = wlr_inhibitor.data orelse continue;
        const inhibitor: *Inhibitor = @ptrCast(@alignCast(data));
        inhibitor.release(wlr_inhibitor);
    }
}

/// Whether compositor bindings and modifier gestures currently belong to
/// the focused client.
pub fn inhibiting(self: *const Self) bool {
    return self.active != null;
}

/// The `restore_shortcuts` action. Returns false when nothing was inhibited,
/// so the binding still reaches clients in the ordinary case.
pub fn revoke(self: *Self) bool {
    const inhibitor = self.active orelse return false;
    log.info("shortcuts restored from inhibiting client", .{});
    self.revoked = inhibitor;
    self.sync();
    return true;
}

fn sync(self: *Self) void {
    const wanted = self.candidate();
    if (self.active == wanted) return;
    if (self.active) |inhibitor| inhibitor.deactivate();
    self.active = wanted;
    if (wanted) |inhibitor| inhibitor.activate();
}

fn candidate(self: *Self) ?*wlr.KeyboardShortcutsInhibitorV1 {
    const seat = self.input.seat;
    const surface = seat.keyboard_state.focused_surface orelse return null;
    var it = self.manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        // wlroots allows one inhibitor per surface and seat.
        if (inhibitor.surface != surface or inhibitor.seat != seat) continue;
        if (inhibitor.data == null or inhibitor == self.revoked) return null;
        return inhibitor;
    }
    return null;
}

fn newInhibitor(listener: *wl.Listener(*wlr.KeyboardShortcutsInhibitorV1), wlr_inhibitor: *wlr.KeyboardShortcutsInhibitorV1) void {
    const self: *Self = @fieldParentPtr("new_inhibitor", listener);
    const inhibitor = gpa.create(Inhibitor) catch return;
    inhibitor.* = .{ .owner = self };
    wlr_inhibitor.data = inhibitor;
    wlr_inhibitor.events.destroy.add(&inhibitor.destroy);
    self.sync();
}

fn destroyed(listener: *wl.Listener(*wlr.KeyboardShortcutsInhibitorV1), wlr_inhibitor: *wlr.KeyboardShortcutsInhibitorV1) void {
    const inhibitor: *Inhibitor = @fieldParentPtr("destroy", listener);
    const self = inhibitor.owner;
    // The resource is going away: no inactive event, and nothing to replace
    // it, since there is at most one inhibitor per surface.
    if (self.active == wlr_inhibitor) self.active = null;
    if (self.revoked == wlr_inhibitor) self.revoked = null;
    inhibitor.release(wlr_inhibitor);
}

fn keyboardFocusChanged(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), event: *wlr.Seat.event.KeyboardFocusChange) void {
    const self: *Self = @fieldParentPtr("keyboard_focus", listener);
    if (self.revoked) |inhibitor| {
        if (event.new_surface != inhibitor.surface) self.revoked = null;
    }
    self.sync();
}

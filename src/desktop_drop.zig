//! The compositor as a drag-and-drop target, for the compositor-drawn desktop.
//!
//! wlroots only delivers a drop to a focused client: releasing over no
//! client surface makes the drag grab destroy (cancel) the source. `take`
//! runs before that release reaches the grab. Ending the grab runs
//! `drag_destroy`, which unlinks the source without cancelling it, and the
//! target then negotiates with the source directly: accept, action, drop,
//! send, and finally dnd_finish (or destroy, which cancels). The release
//! itself then reaches the default grab, so the seat's button count stays
//! right.
//!
//! The `wlr_data_source_dnd_*` calls are safe for every source version:
//! client sources only install those hooks when their resource version
//! supports the event, and the wrappers skip missing hooks.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const uri_list = "text/uri-list";

pub const Action = enum { copy, move };

pub const Target = struct {
    /// The dropped source until its transfer finishes.
    source: ?*wlr.DataSource = null,
    source_destroy: wl.Listener(*wlr.DataSource) = .init(sourceDestroyed),
    /// True from `take` until `finish`, even if the source went away.
    active: bool = false,

    fn sourceDestroyed(listener: *wl.Listener(*wlr.DataSource), _: *wlr.DataSource) void {
        const self: *Target = @fieldParentPtr("source_destroy", listener);
        self.source_destroy.link.remove();
        self.source = null;
    }

    /// The seat's pointer drag, when it is over the target: no client
    /// surface has its focus and it carries a URI list.
    fn dragSource(seat: *wlr.Seat) ?*wlr.DataSource {
        const drag = seat.drag orelse return null;
        if (drag.focus != null or drag.grab_type != .keyboard_pointer) return null;
        const source = drag.source orelse return null;
        return if (offersUriList(source)) source else null;
    }

    /// Tells a drag hovering the target what a drop would do, so its source
    /// can show the right cursor. Entering a client resets this.
    pub fn hover(self: *const Target, seat: *wlr.Seat, preferred: Action) void {
        const source = dragSource(seat) orelse return;
        const action = if (self.active) null else negotiate(source, preferred);
        // Motion arrives far faster than this changes; a client entering
        // resets `accepted`, so returning here sends it again.
        if (action) |value| {
            if (source.accepted and source.current_dnd_action == dndAction(value)) return;
            source.accept(0, uri_list);
            source.dndAction(dndAction(value));
        } else if (source.accepted) source.accept(0, null);
    }

    /// Takes over the drag as its target. Call on the grab button's release,
    /// before `pointerNotifyButton`. Returns the read end of the URI list and
    /// the negotiated action, or null (leaving the drag untouched, so wlroots
    /// cancels it) when there is nothing usable or a drop is still running.
    pub fn take(self: *Target, seat: *wlr.Seat, button: u32, preferred: Action) ?struct { fd: i32, action: Action } {
        if (self.active or button != seat.pointer_state.grab_button) return null;
        const source = dragSource(seat) orelse return null;
        const action = negotiate(source, preferred) orelse return null;
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return null;

        seat.pointerEndGrab();
        self.source = source;
        self.active = true;
        source.events.destroy.add(&self.source_destroy);
        source.accept(0, uri_list);
        source.dndAction(dndAction(action));
        source.dndDrop();
        // wlr_data_source_send closes the write end itself.
        source.send(uri_list, fds[1]);
        return .{ .fd = fds[0], .action = action };
    }

    /// Ends a taken drop: dnd_finish when it was carried out, otherwise
    /// cancel it the way wlroots cancels an unfinished client offer.
    pub fn finish(self: *Target, done: bool) void {
        self.active = false;
        const source = self.source orelse return;
        self.source_destroy.link.remove();
        self.source = null;
        if (done) source.dndFinish() else if (source.impl.dnd_finish != null) source.destroy();
    }
};

fn dndAction(action: Action) wl.DataDeviceManager.DndAction.Enum {
    return if (action == .move) .move else .copy;
}

pub fn offersUriList(source: *wlr.DataSource) bool {
    for (source.mime_types.slice([*:0]const u8)) |mime| {
        if (std.mem.eql(u8, std.mem.span(mime), uri_list)) return true;
    }
    return false;
}

/// The action a drop would perform, or null when the source allows neither.
/// Sources older than v3 have no action mask and always copy.
pub fn negotiate(source: *wlr.DataSource, preferred: Action) ?Action {
    if (source.actions < 0) return .copy;
    const mask: u32 = @bitCast(source.actions);
    const copy_bit: u32 = @intFromEnum(wl.DataDeviceManager.DndAction.Enum.copy);
    const move_bit: u32 = @intFromEnum(wl.DataDeviceManager.DndAction.Enum.move);
    const bit = if (preferred == .move) move_bit else copy_bit;
    if (mask & bit != 0) return preferred;
    if (mask & copy_bit != 0) return .copy;
    if (mask & move_bit != 0) return .move;
    return null;
}

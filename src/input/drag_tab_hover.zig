//! A drag resting on a titlebar tab switches to that tab.
//!
//! The compositor draws the tabs a client publishes (rediwm_titlebar_tabs_v1),
//! so a drag over them reaches no client surface. To drop a file into another
//! tab of a window, the user rests the drag on that tab: after `delay_ms` the
//! compositor asks the client to select it, exactly as a click does (`select`).
//! The drop then lands in the tab's view like any other drop there.
//!
//! The tab under the drag lights up as under any pointer (`motion.zig`), so it
//! is clear which tab will open. Window tabs (separate windows grouped by the
//! compositor) are not switched: only tabs a client published.
const wl = @import("wayland").server.wl;
const Input = @import("../Input.zig");
const Toplevel = @import("../Toplevel.zig");
const scene_data = @import("../scene_data.zig");

const Self = @This();

/// How long the drag rests on a tab before it opens: long enough that a drag
/// crossing the strip on its way elsewhere switches nothing.
pub const delay_ms: c_int = 600;

input: *Input,
/// The tab the drag rests on: its window and the client's tab id. The window
/// is kept by id and looked up again, so a window that goes away mid-drag
/// leaves nothing dangling.
window_id: ?u64 = null,
tab_id: u64 = 0,
timer: ?*wl.EventSource = null,

pub fn init(self: *Self, input: *Input) void {
    self.* = .{ .input = input };
}

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
    self.window_id = null;
}

/// The pointer moved during a drag: (re)start the wait when it reaches a
/// tab, stop it when it leaves.
pub fn motion(self: *Self) void {
    const found = self.tabUnderDrag();
    const window_id = if (found) |f| f.toplevel.id else null;
    const tab_id = if (found) |f| f.tab_id else 0;
    if (window_id == self.window_id and tab_id == self.tab_id) return;

    self.window_id = window_id;
    self.tab_id = tab_id;
    if (found == null) return self.disarm();
    self.arm();
}

/// A window is going away; forget it if the drag rests on one of its tabs.
pub fn detach(self: *Self, toplevel: *Toplevel) void {
    if (self.window_id != toplevel.id) return;
    self.window_id = null;
    self.disarm();
}

const Found = struct { toplevel: *Toplevel, tab_id: u64 };

/// The published tab under a pointer drag, if any (not its close button).
fn tabUnderDrag(self: *Self) ?Found {
    const input = self.input;
    const drag = input.seat.drag orelse return null;
    if (drag.grab_type != .keyboard_pointer) return null;
    const res = switch (scene_data.hitTest(input.server, input.cursor.x, input.cursor.y)) {
        .chrome => |chrome| chrome,
        else => return null,
    };
    const published = res.toplevel.titlebar_tabs orelse return null;
    if (!published.active()) return null;
    if (res.sy >= @as(f64, @floatFromInt(res.toplevel.titlebarHeight()))) return null;
    return switch (res.toplevel.tabAt(res.sx, res.sy)) {
        .tab => |id| .{ .toplevel = res.toplevel, .tab_id = id },
        else => null,
    };
}

fn arm(self: *Self) void {
    if (self.timer == null) {
        self.timer = self.input.server.wl_server.getEventLoop().addTimer(*Self, expired, self) catch return;
    }
    self.timer.?.timerUpdate(delay_ms) catch {};
}

fn disarm(self: *Self) void {
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
}

fn expired(self: *Self) c_int {
    // Still a drag, still on the same tab: select it. Anything else means the
    // pointer has moved on and `motion` already disarmed or re-armed.
    const found = self.tabUnderDrag() orelse return 0;
    if (found.toplevel.id != self.window_id or found.tab_id != self.tab_id) return 0;
    const published = found.toplevel.titlebar_tabs orelse return 0;
    if (published.has(found.tab_id)) published.sendSelect(found.tab_id);
    return 0;
}

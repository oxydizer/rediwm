//! Repaints and theme changes, the volume/brightness controls under the pointer, power-command exits and the minute clock.

const i18n = @import("i18n");
const Child = @import("child.zig");
const Output = @import("../Output.zig");
const anim = @import("ui").anim;
const lock_controls = @import("lock_controls.zig");
const lock_mod = @import("lock.zig");
const Lock = lock_mod.Lock;
const c = lock_mod.c;
const ControlsAt = lock_mod.ControlsAt;
const controlsPick = lock_mod.controlsPick;

pub fn changed(self: *Lock) void {
    self.revision +%= 1;
    self.server.scheduleFrames();
}

/// The active keyboard layout changed: the lock's layout button shows it.
pub fn inputSourceChanged(self: *Lock) void {
    self.refreshLayoutLabel();
    if (self.greeter == null) self.changed();
}

/// Several layouts on the user's lock (never the greeter): passwords are often
/// typed with the wrong one.
pub fn refreshLayoutLabel(self: *Lock) void {
    self.layout_label_len = 0;
    if (self.greeter != null) return;
    const sources = self.server.input_sources orelse return;
    if (sources.layoutCount() < 2) return;
    const label = sources.activeLayoutLabel();
    const n = @min(label.len, self.layout_label.len);
    @memcpy(self.layout_label[0..n], label[0..n]);
    self.layout_label_len = @intCast(n);
}

/// A reskin invalidates both the screen and its small controls raster.
pub fn themeChanged(self: *Lock) void {
    var outputs = self.server.outputs.iterator(.forward);
    while (outputs.next()) |out| out.lock_view.controls_key = null;
    self.changed();
}

/// Volume, mute or brightness changed; redraw only the controls block.
pub fn controlsChanged(self: *Lock) void {
    if (self.greeter != null) return;
    const previous_volume = self.controls.volume;
    const previous_muted = self.controls.muted;
    const previous_brightness = self.controls.brightness;
    if (self.controls.refresh(self.server)) {
        self.server.scheduleFrames();
        const active_changed = if (self.controls.active) |kind| switch (kind) {
            .volume => self.controls.volume != previous_volume or self.controls.muted != previous_muted,
            .brightness => self.controls.brightness != previous_brightness,
        } else false;
        if (self.controls_visible and active_changed) self.showControls(self.controls.active.?);
    }
}

/// Hardware feedback selects the same row as pointer use, including when
/// a key leaves the value unchanged at its limit.
pub fn showControl(self: *Lock, kind: lock_controls.Kind) void {
    if (self.greeter != null) return;
    if (self.controls.refresh(self.server)) self.server.scheduleFrames();
    self.showControls(kind);
}

pub fn showControls(self: *Lock, requested: lock_controls.Kind) void {
    if (self.greeter != null or self.controls.height() == 0) return;
    const kind = if (self.controls.drag) |drag| drag.kind else requested;
    const selected = self.controls.select(kind);
    if (self.controls.active != kind) return;
    const newly_visible = !self.controls_visible;
    self.controls_visible = true;
    self.controls_hide_at = anim.nowMs() + 2500;
    self.scheduleClock();
    if (newly_visible or selected) self.server.scheduleFrames();
}

/// The control under a layout point, with its track's left edge and
/// width in layout pixels. An ext-session-lock client's surface hides
/// the built-in controls along with the rest of the screen.
pub fn controlsAt(self: *Lock, x: f64, y: f64) ?ControlsAt {
    if (self.greeter != null) return null;
    const out = Output.atLayout(self.server, x, y) orelse return null;
    if (self.client) |client| if (client.covers(out)) return null;
    const b = out.cached_box;
    const found = controlsPick(&self.controls, @floatFromInt(b.width), @floatFromInt(b.height), @floatCast(x - @as(f64, @floatFromInt(b.x))), @floatCast(y - @as(f64, @floatFromInt(b.y)))) orelse return null;
    return .{ .hit = found.hit, .left = found.left + @as(f32, @floatFromInt(b.x)), .span = found.span };
}

/// The pointer moved: continues a drag, else follows the hover.
pub fn pointerMoved(self: *Lock, x: f64, y: f64) void {
    if (self.controls.drag != null) {
        const before = self.controls.revision;
        self.controls.dragTo(self.server, @floatCast(x));
        self.controls_hide_at = anim.nowMs() + 2500;
        self.scheduleClock();
        if (self.controls.revision != before) self.server.scheduleFrames();
        return;
    }
    const at = self.controlsAt(x, y);
    if (at) |found| self.showControls(found.hit.kind);
    const hit: ?lock_controls.Hit = if (at) |found| found.hit else null;
    if (self.controls.setHover(hit)) self.server.scheduleFrames();
}

/// The primary button went up, wherever the pointer is.
pub fn pointerReleased(self: *Lock) void {
    if (self.controls.endDrag()) {
        self.controls_hide_at = anim.nowMs() + 2500;
        self.scheduleClock();
        self.server.scheduleFrames();
    }
}

pub fn powerExited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const self: *Lock = @ptrCast(@alignCast(owner.?));
    self.power_child = null;
    self.status = if (status != null and status.? == 0) i18n.tr("Power request accepted") else i18n.tr("Power request denied or unavailable");
    self.changed();
}

pub fn tick(self: *Lock) c_int {
    const minute = @divTrunc(c.time(null), 60);
    if (minute != self.minute) {
        self.minute = minute;
        self.changed();
    }
    if (self.controls_visible and self.controls.drag == null and anim.nowMs() >= self.controls_hide_at) {
        self.controls_visible = false;
        self.controls_hide_at = 0;
        _ = self.controls.setHover(null);
        self.server.scheduleFrames();
    }
    self.scheduleClock();
    return 0;
}

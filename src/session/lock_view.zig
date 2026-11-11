//! The lock's per-output View and its Geometry, and painting the lock and greeter choices.

const i18n = @import("i18n");
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const Output = @import("../Output.zig");
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const text = @import("ui").text;
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const lock_controls = @import("lock_controls.zig");
const CaretOverlay = @import("../caret_overlay.zig").CaretOverlay;
const Greeter = greeter_mod.Greeter;
const text_field = ui.widgets.field;
const lock_mod = @import("lock.zig");
const c = lock_mod.c;
const Lock = lock_mod.Lock;
const focus_account = lock_mod.focus_account;
const focus_session = lock_mod.focus_session;

pub const Geometry = struct {
    s: f32,
    w: f32,
    h: f32,
    left: f32,
    top: f32,
    pub fn init(w: f32, h: f32) Geometry {
        // ui_scale trims the whole panel (fonts, field, button) down from the
        // 600x900 design canvas's 1:1 cap — full size read as oversized on
        // typical outputs.
        const ui_scale: f32 = 0.85;
        const s = @min(1, @min(w / 600, h / 900)) * ui_scale;
        return .{ .w = w, .h = h, .s = s, .left = (w - 390 * s) / 2, .top = (h - 670 * s) / 2 - 20 * s };
    }

    /// The password field in design units: draw through `Renderer.zoomed(s)`.
    pub fn field(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 430, .w = 390, .h = 56 };
    }

    /// Power (0) and Restart (1), bottom right, in the same units.
    pub fn powerAction(geo: Geometry, i: usize) text_field.Rect {
        const center = geo.w / geo.s - 170 + @as(f32, @floatFromInt(i)) * 100;
        return .{ .x = center - 45, .y = geo.h / geo.s - 96, .w = 90, .h = 76 };
    }

    /// The volume/brightness block of `block_h` design units, centred on the
    /// power buttons' band and horizontally on the screen, in whole layout
    /// pixels output-local. It never reaches the power buttons: the canvas is
    /// at least 705 design units wide, they start 215 from its right edge.
    pub fn controlsBox(geo: Geometry, block_h: f32) struct { x: i32, y: i32, w: i32, h: i32 } {
        const x = (geo.w / geo.s - lock_controls.width) / 2;
        const y = geo.h / geo.s - 58 - block_h / 2;
        return .{
            .x = @intFromFloat(@round(x * geo.s)),
            .y = @intFromFloat(@round(y * geo.s)),
            .w = @intFromFloat(@ceil(lock_controls.width * geo.s)),
            .h = @intFromFloat(@ceil(block_h * geo.s)),
        };
    }

    /// The keyboard layout button, bottom left, in the same units (the
    /// greeter's session chooser sits there instead).
    pub fn layoutButton(geo: Geometry) text_field.Rect {
        return .{ .x = 30, .y = geo.h / geo.s - 96, .w = 90, .h = 76 };
    }

    /// The Unlock / Log In button, in the same units.
    pub fn submit(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 508, .w = 390, .h = 52 };
    }
};

pub const field_options: text_field.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 }, .trailing = .reveal };

pub const View = struct {
    tree: *sn.Tree,
    guard: *sn.Rect,
    wallpaper: *sn.Buffer,
    ui_node: *sn.Buffer,
    /// The password field's caret, above `ui_node`: it blinks and glides
    /// without re-rastering the whole screen.
    caret: CaretOverlay,
    /// The volume/brightness block: its own small raster (`Lock.controls`),
    /// so dragging a slider never re-rasters the screen under it.
    controls_node: *sn.Buffer,
    controls_key: ?ControlsKey = null,
    revision: u64 = 0,
    content_ready: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    scale: f32 = 0,

    pub fn create(parent: *sn.Tree) !View {
        const tree = try parent.createSceneTree();
        errdefer tree.node.destroy();
        const guard = try col.createRect(tree, 0, 0, col.Straight.fromRgba(lockBackground()).premultiply());
        const wallpaper = try tree.createSceneBuffer(null);
        wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        wallpaper.setFilterMode(.bilinear);
        const node = try tree.createSceneBuffer(null);
        node.setFilterMode(.bilinear);
        const caret = try CaretOverlay.create(tree);
        const controls_node = try tree.createSceneBuffer(null);
        controls_node.setFilterMode(.bilinear);
        controls_node.node.setEnabled(false);
        tree.node.setEnabled(false);
        return .{ .tree = tree, .guard = guard, .wallpaper = wallpaper, .ui_node = node, .caret = caret, .controls_node = controls_node };
    }

    pub fn cover(self: *View, out: *Output) void {
        var box: wlr.Box = undefined;
        out.server.output_layout.getBox(out.wlr_output, &box);
        self.tree.node.setPosition(box.x, box.y);
        self.guard.setSize(box.width, box.height);
        col.setRect(self.guard, col.Straight.fromRgba(lockBackground()).premultiply());
        self.wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        self.tree.node.setEnabled(true);
        out.server.lock_tree.node.raiseToTop();
    }

    pub fn hide(self: *View) void {
        self.tree.node.setEnabled(false);
        self.ui_node.setBuffer(null);
        self.wallpaper.setBuffer(null);
        self.caret.hide();
        self.hideControls();
        self.revision = 0;
        self.content_ready = false;
        Buffer.drainPool();
    }

    pub fn hideControls(self: *View) void {
        self.controls_node.node.setEnabled(false);
        self.controls_node.setBuffer(null);
        self.controls_key = null;
    }

    /// Rasters the volume/brightness block when it, or the output it sits
    /// on, changed. The greeter and an output without either backend show none.
    pub fn syncControls(self: *View, lock: *Lock, b: wlr.Box, scale: f32) void {
        const block_h = lock.controls.height();
        if (lock.greeter != null or !lock.controls_visible or block_h == 0 or b.width <= 0 or b.height <= 0) return self.hideControls();
        const key = ControlsKey{ .revision = lock.controls.revision, .width = b.width, .height = b.height, .scale = scale };
        if (self.controls_key) |have| if (std.meta.eql(have, key)) return;
        const geo = Geometry.init(@floatFromInt(b.width), @floatFromInt(b.height));
        const box = geo.controlsBox(block_h);
        const buf = Buffer.createUnpooled(box.w, box.h, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        var zoomed = renderer.zoomed(geo.s);
        zoomed.palette = ui.theme.shellPalette();
        lock.controls.paint(&zoomed);
        buf.publish(self.controls_node, scale, null);
        self.controls_node.setDestSize(box.w, box.h);
        self.controls_node.node.setPosition(box.x, box.y);
        self.controls_node.node.setEnabled(true);
        self.controls_key = key;
    }

    /// Returns whether the field's caret still wants frames.
    pub fn sync(self: *View, out: *Output) bool {
        const lock = out.server.locker orelse return false;
        self.cover(out);
        // A lock client's surface replaces the built-in screen, which stays
        // ready underneath in case the client dies.
        const covered = if (lock.client) |client| blk: {
            client.syncOutput(out);
            break :blk client.covers(out);
        } else false;
        self.ui_node.node.setEnabled(!covered);
        self.wallpaper.node.setEnabled(!covered);
        if (covered) {
            self.caret.hide();
            self.hideControls();
            return false;
        }
        const b = out.cached_box;
        const scale = out.wlr_output.scale;
        const now = anim.nowMs();
        self.syncControls(lock, b, scale);
        if (self.revision == lock.revision and self.width == b.width and self.height == b.height and self.scale == scale) return self.caret.frame(now);
        if (b.width <= 0 or b.height <= 0) return false;
        // Drop stale pixels before a failed resize allocation.
        self.content_ready = false;
        out.greeter_presented = false;
        self.ui_node.setBuffer(null);
        if (lock.greeter_wallpaper orelse out.server.wallpaper) |image| {
            self.wallpaper.setBuffer(&image.base);
            self.wallpaper.setDestSize(b.width, b.height);
        } else self.wallpaper.setBuffer(null);
        const buf = Buffer.create(b.width, b.height, scale) catch return false;
        defer buf.base.drop();
        buf.sensitive = true;
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
        const painted = paint(&renderer, lock, @floatFromInt(b.width), @floatFromInt(b.height), lock.server.config.region.clock_24h);
        self.caret.update(now, if (painted.caret) |place| .{
            .caret = place,
            .origin_x = 0,
            .origin_y = 0,
            .factor = painted.factor,
            .scale = scale,
            .color = ui.theme.shellPalette().caretColor(),
        } else null, lock.caret_edit_ms);
        self.ui_node.setBuffer(&buf.base);
        self.ui_node.setDestSize(b.width, b.height);
        self.content_ready = true;
        self.revision = lock.revision;
        self.width = b.width;
        self.height = b.height;
        self.scale = scale;
        return self.caret.frame(now);
    }
};

pub const ControlsKey = struct { revision: u64, width: i32, height: i32, scale: f32 };

pub fn lockBackground() [4]f32 {
    var bg = ui.theme.global.lock_bg;
    bg[3] = 1;
    return bg;
}

pub fn label(r: *ui.paint.Renderer, cx: f32, y: f32, width: f32, height: f32, value: []const u8, size: f32, color: [4]f32) void {
    const measured = text.measureWidthF(value, .manrope, size, r.scale) catch width;
    const w = @min(width, measured + 1);
    r.drawText(cx - w / 2, y, w, height, .{ .content = value, .font_size = size, .color = color });
}

/// Where the field's caret went, in design units `factor` layout pixels
/// wide; the caret itself is the view's overlay.
pub const Painted = struct { caret: ?ui.widgets.secret_input.Input.CaretPlace, factor: f32 };

pub fn paint(r: *ui.paint.Renderer, lock: *Lock, w: f32, h: f32, clock_24h: bool) Painted {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const geo = Geometry.init(w, h);
    const s = geo.s;
    const y = geo.top;
    const cx = w / 2;
    var raw = c.time(null);
    var tm: c.struct_tm = undefined;
    var time_buf: [32]u8 = @splat(0);
    var date_buf: [96]u8 = @splat(0);
    var period: [16]u8 = @splat(0);
    var pattern: [256]u8 = undefined;
    const date_pattern = std.fmt.bufPrintSentinel(&pattern, "{s}", .{i18n.trc("date", "%A, %B %-d")}, 0) catch "%A, %B %-d";
    if (c.localtime_r(&raw, &tm) != null) {
        _ = c.strftime(&time_buf, time_buf.len, if (clock_24h) "%H:%M" else "%l:%M", &tm);
        if (!clock_24h) _ = c.strftime(&period, period.len, "%p", &tm);
        _ = c.strftime(&date_buf, date_buf.len, date_pattern, &tm);
    }
    const time_str = std.mem.trim(u8, std.mem.sliceTo(&time_buf, 0), " ");
    const period_str = std.mem.sliceTo(&period, 0);
    const tw = text.measureWidthF(time_str, .manrope, 100 * s, r.scale) catch 220 * s;
    const pw = text.measureWidthF(period_str, .manrope, 64 * s, r.scale) catch 100 * s;
    const period_gap: f32 = if (period_str.len == 0) 0 else 20 * s;
    const start = cx - (tw + pw + period_gap) / 2;
    r.drawText(start, y, tw + 2, 110 * s, .{ .content = time_str, .font_size = 100 * s, .color = fg });
    r.drawText(start + tw + period_gap, y + 24 * s, pw + 2, 86 * s, .{ .content = period_str, .font_size = 64 * s, .color = muted });
    label(r, cx, y + 110 * s, w, 45 * s, std.mem.sliceTo(&date_buf, 0), 30 * s, muted);
    r.fillRect(cx - 35 * s, y + 174 * s, 70 * s, 2 * s, .{ .color = muted });
    // Shared components draw in the 600x900 design units the layout uses.
    var zoomed = r.zoomed(s);
    zoomed.palette = ui.theme.shellPalette();
    const avatar_image: ?ui.paint.Image = if (lock.avatar) |image| .{ .pixels = image.pixels, .width = image.width, .height = image.height } else null;
    ui.widgets.avatar.paint(&zoomed, cx / s - 60, y / s + 214, 120, .{ .image = avatar_image, .ring = true });
    const name = std.mem.sliceTo(&lock.name, 0);
    label(r, cx, y + 343 * s, 500 * s, 36 * s, if (name.len > 0) name else std.mem.sliceTo(&lock.user, 0), 25 * s, fg);
    label(r, cx, y + 380 * s, 500 * s, 30 * s, std.mem.sliceTo(&lock.user, 0), 18 * s, muted);
    if (lock.greeter) |greeter| paintChoices(r, lock, greeter, geo, h);
    const field = text_field.paintSecret(&zoomed, geo.field(), field_options, .{
        .focused = lock.focus == 0,
        .disabled = lock.busy(),
        .revealed = lock.reveal,
        .trailing_focused = lock.focus == 1,
        .external_caret = true,
    }, lock.field(), if (lock.prompting()) i18n.tr("Response") else i18n.tr("Password"));
    const action = if (lock.greeter != null)
        (if (lock.busy()) i18n.tr("Signing in…") else if (lock.prompting()) i18n.tr("Continue") else i18n.tr("Log In"))
    else if (lock.busy()) i18n.tr("Checking…") else i18n.tr("Unlock");
    ui.widgets.button.paint(&zoomed, geo.submit(), .{
        .variant = .primary,
        .size = .lg,
        .label = action,
        .trailing_icon = .chevron_right,
    }, .{ .pointer = if (lock.busy()) .disabled else .idle, .focused = lock.focus == 2 });
    label(r, cx, y + 590 * s, w - 20, 32 * s, if (lock.caps and std.mem.eql(u8, lock.status, lock.idleStatus())) i18n.tr("Caps Lock is on") else lock.status, 16 * s, muted);
    for (0..2) |i| ui.widgets.button.paint(&zoomed, geo.powerAction(i), .{
        .variant = .ghost,
        .size = .sm,
        .stacked = true,
        .leading_icon = if (i == 0) .power else .reboot,
        .label = if (i == 0) i18n.tr("Power") else i18n.tr("Restart"),
    }, .{ .focused = lock.focus == 3 + i });
    r.fillRect(w - 120 * s, h - 90 * s, s, 34 * s, .{ .color = ui.theme.global.lock_divider });
    if (layoutButtonShown(lock)) ui.widgets.button.paint(&zoomed, geo.layoutButton(), .{
        .variant = .ghost,
        .size = .sm,
        .stacked = true,
        .leading_icon = .keyboard,
        .label = lock.layout_label[0..lock.layout_label_len],
    }, .{ .focused = lock.focus == lock_mod.focus_layout });
    return .{ .caret = field.caret, .factor = s };
}

/// See `Lock.refreshLayoutLabel`.
pub fn layoutButtonShown(lock: *const Lock) bool {
    return lock.layout_label_len > 0;
}

/// Greeter: account arrows beside the picture, session chooser bottom-left.
pub fn paintChoices(r: *ui.paint.Renderer, lock: *const Lock, greeter: *const Greeter, geo: Geometry, h: f32) void {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const s = geo.s;
    const cx = geo.w / 2;
    const ay = geo.top + 214 * s;
    const idle = greeter.phase == .idle;
    if (greeter.users.len > 1) {
        if (lock.focus == focus_account) r.fillRect(cx - 150 * s, ay - 6 * s, 300 * s, 205 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 14 * s, .border_width = s, .border_color = fg });
        if (idle) {
            var zoomed = r.zoomed(s);
            zoomed.palette = ui.theme.shellPalette();
            for ([_]f32{ -1, 1 }) |side| ui.widgets.button.paint(&zoomed, .{ .x = cx / s + side * 110 - 22, .y = ay / s + 30, .w = 44, .h = 60 }, .{
                .variant = .ghost,
                .icon = if (side < 0) .chevron_left else .chevron_right,
                .icon_scale = 0.7,
                .label = if (side < 0) i18n.tr("Previous account") else i18n.tr("Next account"),
            }, .{});
        }
    }
    const session = greeter.selectedSession() orelse return;
    const color = if (lock.focus == focus_session) fg else muted;
    const x = 30 * s;
    const name_w = @min(280 * s, (text.measureWidthF(session.name, .manrope, 16 * s, r.scale) catch 280 * s) + 1);
    r.drawText(x, h - 90 * s, name_w, 30 * s, .{ .content = session.name, .font_size = 16 * s, .color = if (lock.focus == focus_session) fg else ui.theme.global.lock_session_fg });
    const caption = if (greeter.sessions.len > 1) i18n.tr("Session  ›") else i18n.tr("Session");
    const caption_w = (text.measureWidthF(caption, .manrope, 13 * s, r.scale) catch 90 * s) + 1;
    r.drawText(x, h - 54 * s, caption_w, 24 * s, .{ .content = caption, .font_size = 13 * s, .color = color });
    if (lock.focus == focus_session) r.fillRect(x - 12 * s, h - 96 * s, @max(name_w, caption_w) + 24 * s, 76 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 10 * s, .border_width = s, .border_color = fg });
}

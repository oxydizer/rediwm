const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Output = @import("../Output.zig");
const scene = @import("../scene_data.zig");
const gpa = @import("../main.zig").gpa;
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const field = @import("ui").widgets.field;
const button = @import("ui").widgets.button;
const toggle = @import("ui").widgets.toggle;
const checkbox = @import("ui").widgets.checkbox;
const Secret = @import("ui").widgets.secret_input.Input;
const Caret = @import("../caret_overlay.zig").CaretOverlay;
const hover_glide = @import("ui").hover_glide;
const network = @import("manager.zig");
const sonar = @import("sonar.zig");
const secure = @import("secure_allocator.zig").allocator;
const anim = @import("ui").anim;
const present = @import("../panel_present.zig");
const Rect = field.Rect;
const width: f32 = 420;
const header: f32 = 70;
const footer: f32 = 64;
const row_height: f32 = 64;
const Focus = enum { toggle, row, hidden, ssid, security, security_option, password, reveal, autojoin, join, cancel, settings };
const Hit = struct { box: Rect, focus: Focus, index: usize = 0 };
/// One inline form region (a network row's or the hidden-network form) and
/// its eased height. `net == null` means the hidden-network form.
const Expansion = struct {
    open: bool = false,
    net: ?network.Network = null,
    height: anim.Anim = .{},
    shown: f32 = 0,
    fn matches(self: Expansion, net: ?network.Network) bool {
        if (!self.open) return false;
        const a = self.net orelse return net == null;
        const b = net orelse return false;
        return network.sameNetwork(a, b);
    }
};
const expand_curve: anim.Curve = .{ .duration = .{ .ms = 220, .ease = .out_cubic } };

pub const Popup = struct {
    output: *Output,
    buffer_node: *wlr.SceneBuffer,
    sonar_node: *wlr.SceneBuffer,
    sonar_step: i64 = -1,
    sonar_shown: bool = false,
    sonar_fade_start: i64 = -1,
    node_data: scene.SceneData = undefined,
    caret: Caret,
    factor: f32 = 1,
    height: f32 = 400,
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    slide: anim.Anim = .{},
    password: Secret,
    name_bytes: [32]u8 = @splat(0),
    name: Secret = undefined,
    selected: ?network.Network = null,
    hidden: bool = false,
    security: network.Security = .personal,
    security_open: bool = false,
    revealed: bool = false,
    autojoin: bool = true,
    focus: Focus = .toggle,
    focus_index: usize = 0,
    hover: ?usize = null,
    item_hover: hover_glide.Glide = .{},
    hits: [280]Hit = undefined,
    hit_count: usize = 0,
    scroll: f32 = 0,
    content_height: f32 = 0,
    status_height: f32 = 0,
    error_message: []const u8 = "",
    edit_ms: i64 = 0,
    caret_reported: bool = false,
    // The form being opened and the one collapsing out of the way.
    opening: Expansion = .{},
    closing: Expansion = .{},

    pub fn create(output: *Output) !*Popup {
        const self = try gpa.create(Popup);
        errdefer gpa.destroy(self);
        const bytes = try secure.alloc(u8, 128);
        errdefer secure.free(bytes);
        @memset(bytes, 0);
        const node = try output.server.overlay_tree.createSceneBuffer(null);
        errdefer node.node.destroy();
        const sonar_node = try output.server.overlay_tree.createSceneBuffer(null);
        errdefer sonar_node.node.destroy();
        sonar_node.setFilterMode(.bilinear);
        const caret = try Caret.create(output.server.overlay_tree);
        self.* = .{ .output = output, .buffer_node = node, .sonar_node = sonar_node, .caret = caret, .password = .{ .storage = bytes } };
        self.name = .{ .storage = &self.name_bytes };
        self.node_data = .{ .role = .{ .wifi_popup = self } };
        scene.SceneData.attach(&self.node_data, &node.node);
        // The caret belongs to the panel for hit testing too.
        scene.SceneData.attach(&self.node_data, &self.caret.node.node);
        scene.SceneData.attach(&self.node_data, &sonar_node.node);
        node.setFilterMode(.bilinear);
        self.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        if (self.manager()) |m| {
            if (m.available and m.hardware and m.enabled and m.device.len != 0 and m.count > 0) self.focus = .row;
        }
        self.refresh();
        return self;
    }
    pub fn destroy(self: *Popup) void {
        @import("../Keyboard.zig").forgetShellTarget(self.output.server, self);
        if (self.output.server.input.open_wifi == self) self.output.server.input.open_wifi = null;
        self.password.clear();
        secure.free(self.password.storage);
        self.caret.destroy();
        self.sonar_node.node.destroy();
        self.buffer_node.node.destroy();
        gpa.destroy(self);
    }
    fn openSettings(self: *Popup) void {
        const output = self.output;
        // Opening Settings destroys this popup; do not touch self afterwards.
        output.toggleControlCenter();
        if (output.server.input.open_control_center) |cc| cc.selectPage(.network);
    }
    fn manager(self: *Popup) ?*network.Manager {
        return self.output.server.network;
    }
    pub fn tick(self: *Popup, now: i64) bool {
        _ = self.slide.sampleChanged(now, anim.quantum_alpha);
        present.applySlide(self.buffer_node, self.panel_box, self.slide.value(now), if (self.output.server.config.compositor.taskbar_position == .top) -20 else 20);
        if (self.caret.placed) |*p| p.origin_y = @floatFromInt(self.buffer_node.node.y);
        const active = self.caret.frame(now);
        self.paintSonar(now);
        const row_quantum = anim.rasterPixelQuantum(self.output.wlr_output.scale) / (row_height * self.factor);
        if (self.item_hover.step(now, 1, row_quantum)) self.refresh();
        const expanding = !self.opening.height.settled(now) or !self.closing.height.settled(now);
        // Sample both every frame: sampleChanged must run once per frame each.
        const quantum = 1 / (self.output.wlr_output.scale * self.factor);
        const moved_open = self.opening.height.sampleChanged(now, quantum);
        const moved_close = self.closing.height.sampleChanged(now, quantum);
        if (moved_open or moved_close) {
            self.refresh();
            if (!self.opening.height.settled(now)) self.ensureFormVisible();
        }
        return active or expanding or self.item_hover.animating(now) or !self.slide.settled(now) or self.sonarFading() or (self.sonarVisible() and self.searching() and anim.enabled() and !anim.reducedMotion());
    }
    fn searching(self: *Popup) bool {
        return if (self.manager()) |m| m.searching() else false;
    }
    fn sonarVisible(self: *Popup) bool {
        const m = self.manager() orelse return false;
        return m.available and m.enabled and m.hardware and m.device.len != 0;
    }
    fn sonarFading(self: *Popup) bool {
        return self.sonar_shown and self.sonar_fade_start >= 0;
    }
    fn paintSonar(self: *Popup, now: i64) void {
        const available = self.sonarVisible();
        const searching_now = available and self.searching();
        var opacity: f32 = 1;
        if (searching_now) {
            self.sonar_shown = true;
            self.sonar_fade_start = -1;
        } else if (self.sonar_shown and available) {
            if (self.sonar_fade_start < 0) self.sonar_fade_start = now;
            const t = @as(f32, @floatFromInt(now - self.sonar_fade_start)) / 300;
            if (t >= 1) self.sonar_shown = false else opacity = 1 - t;
        } else {
            self.sonar_shown = false;
        }
        self.sonar_node.node.setEnabled(self.sonar_shown);
        if (!self.sonar_shown) {
            self.sonar_step = -1;
            self.sonar_fade_start = -1;
            return;
        }
        self.sonar_node.setOpacity(opacity);
        const sonar_scale: f32 = 48 / sonar.size;
        const inset = (sonar.size - 48) / 2;
        self.sonar_node.node.setPosition(
            self.buffer_node.node.x + @as(i32, @intFromFloat(@round((100 + inset) * self.factor))),
            self.buffer_node.node.y + @as(i32, @intFromFloat(@round((8 + inset) * self.factor))),
        );
        if (self.sonarFading() and self.sonar_step >= 0) return;
        const moving = searching_now and anim.enabled() and !anim.reducedMotion();
        const step = if (moving) @divTrunc(now, 32) else 0;
        if (self.sonar_step == step) return;
        const side: i32 = @intFromFloat(@round(sonar.size * sonar_scale * self.factor));
        const buf = PanelBuffer.createUnpooled(side, side, self.output.wlr_output.scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = self.output.wlr_output.scale * self.factor * sonar_scale };
        const m = self.manager().?;
        sonar.paint(&r, m.networks[0..m.count], if (moving) @as(f32, @floatFromInt(@mod(step, 100))) / 100 else null);
        self.sonar_node.setBuffer(&buf.base);
        self.sonar_node.setDestSize(side, side);
        self.sonar_step = step;
    }
    fn clearForm(self: *Popup) void {
        self.password.clear();
        self.name.clear();
        self.revealed = false;
        self.selected = null;
        self.hidden = false;
        self.security_open = false;
        self.error_message = "";
        self.focus = .toggle;
        self.caret.hide();
    }
    pub fn changed(self: *Popup) void {
        if (self.manager()) |m| {
            if (!m.available or !m.enabled or !m.hardware) self.clearForm();
            if (self.selected) |selected| {
                var found = false;
                for (m.networks[0..m.count]) |net| if (network.sameNetwork(net, selected)) {
                    self.selected = net;
                    if (net.connected) {
                        self.password.clear();
                        self.revealed = false;
                        if (self.focus == .password or self.focus == .reveal or self.focus == .join) self.focus = .toggle;
                    }
                    found = true;
                    break;
                };
                if (!found) self.clearForm();
            }
        }
        self.refresh();
    }
    pub fn motion(self: *Popup, sx: f64, sy: f64) void {
        const next = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor));
        if (next == self.hover) return;
        self.hover = next;
        const target: ?hover_glide.Cell = if (next) |i| if (self.hits[i].focus == .row)
            .{ .col = 0, .row = @intCast(self.hits[i].index) }
        else
            null else null;
        self.item_hover.setTarget(anim.nowMs(), target);
        self.refresh();
    }
    fn hit(self: *Popup, x: f32, y: f32) ?usize {
        // Forms are clipped between the fixed header and settings footer.
        var cursor = self.hit_count;
        while (cursor > 0) {
            cursor -= 1;
            const i = cursor;
            const h = self.hits[i];
            if (h.focus != .toggle and h.focus != .settings and (y < header or y >= self.height - footer - self.status_height)) continue;
            if (contains(h.box, x, y)) return i;
        }
        return null;
    }
    pub fn widgetAt(self: *Popup, sx: f64, sy: f64) ?[]const u8 {
        const index = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor)) orelse return null;
        return @tagName(self.hits[index].focus);
    }
    pub fn press(self: *Popup, sx: f64, sy: f64) void {
        const i = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor)) orelse return;
        const h = self.hits[i];
        if (h.focus == .settings) {
            self.openSettings();
            return;
        }
        self.focus = h.focus;
        self.focus_index = h.index;
        self.edit_ms = anim.nowMs();
        self.activate();
        self.refresh();
        self.ensureFormVisible();
        self.ensureFocusVisible();
    }
    pub fn scrollWheel(self: *Popup, delta: f32) void {
        self.scroll = std.math.clamp(self.scroll + delta, 0, @max(0, self.content_height - (self.height - header - footer - self.status_height)));
        self.hover = null;
        self.item_hover.setTarget(anim.nowMs(), null);
        self.refresh();
    }
    fn ensureFormVisible(self: *Popup) void {
        if (!self.hidden and self.selected == null) return;
        for (self.hits[0..self.hit_count]) |h| if (h.focus == .cancel) {
            const extra = h.box.y + h.box.h + 8 - self.height + footer + self.status_height;
            const previous = self.scroll;
            self.scroll = @min(self.scroll + @max(0, extra), @max(0, self.content_height - (self.height - header - footer - self.status_height)));
            if (self.scroll != previous) self.refresh();
            break;
        };
    }
    fn ensureFocusVisible(self: *Popup) void {
        for (self.hits[0..self.hit_count]) |h| {
            if (!self.focused(h.focus, h.index) or h.focus == .toggle or h.focus == .settings) continue;
            const previous = self.scroll;
            if (h.box.y < header) self.scroll += h.box.y - header;
            if (h.box.y + h.box.h > self.height - footer - self.status_height) self.scroll += h.box.y + h.box.h - self.height + footer + self.status_height;
            if (previous != self.scroll) self.refresh();
            break;
        }
    }
    fn canUse(self: *Popup) bool {
        const m = self.manager() orelse return false;
        return m.available and m.hardware and m.enabled and m.device.len != 0 and !m.busy;
    }
    fn formSecurity(self: *Popup) network.Security {
        return if (self.hidden) self.security else if (self.selected) |s| s.security else .open;
    }
    fn needsPassword(self: *Popup) bool {
        if (self.hidden) return self.security != .open;
        const s = self.selected orelse return false;
        return (s.security == .personal or s.security == .sae) and !s.connected;
    }
    fn activate(self: *Popup) void {
        const m = self.manager() orelse return;
        if (self.focus == .toggle) {
            self.clearForm();
            m.toggle();
            return;
        }
        if (self.focus == .cancel) {
            self.clearForm();
            return;
        }
        if (!self.canUse()) return;
        switch (self.focus) {
            .row => {
                if (self.focus_index >= m.count) return;
                const net = m.networks[self.focus_index];
                const same = if (self.selected) |s| network.sameNetwork(s, net) else false;
                self.clearForm();
                if (!same) {
                    self.selected = net;
                    self.focus = if (self.needsPassword()) .password else .join;
                }
            },
            .hidden => {
                const was = self.hidden;
                self.clearForm();
                self.hidden = !was;
                self.focus = if (self.hidden) .ssid else .hidden;
            },
            .security => self.security_open = !self.security_open,
            .security_option => {
                self.security = switch (self.focus_index) {
                    0 => .personal,
                    1 => .sae,
                    else => .open,
                };
                self.security_open = false;
                self.password.clear();
                self.revealed = false;
                self.focus = .security;
            },
            .reveal => self.revealed = !self.revealed,
            .autojoin => self.autojoin = !self.autojoin,
            .join => self.join(),
            else => {},
        }
    }
    fn join(self: *Popup) void {
        const m = self.manager() orelse return;
        var net = self.selected orelse network.Network{ .security = self.security };
        if (self.hidden) {
            if (self.name.len == 0) {
                self.error_message = "Enter a network name.";
                self.focus = .ssid;
                return;
            }
            net.ssid.set(self.name.value());
        }
        if (net.connected) return;
        const pw = self.password.value();
        if (network.joinError(net, pw)) |message| {
            self.error_message = message;
            self.focus = .password;
            return;
        }
        self.error_message = "";
        m.join(net, pw, self.autojoin, self.hidden);
        self.password.clear();
        self.revealed = false;
    }
    pub fn keyRepeats(self: *Popup, sym: xkb.Keysym, utf8: []const u8) bool {
        if (self.focus != .password and self.focus != .ssid) return false;
        return switch (@intFromEnum(sym)) {
            xkb.Keysym.BackSpace, xkb.Keysym.Delete, xkb.Keysym.Left, xkb.Keysym.Right => true,
            else => utf8.len > 0 and @intFromEnum(sym) != xkb.Keysym.Return and @intFromEnum(sym) != xkb.Keysym.Tab and @intFromEnum(sym) != xkb.Keysym.Escape,
        };
    }
    pub fn key(self: *Popup, sym: xkb.Keysym, utf8: []const u8, mods: wlr.Keyboard.ModifierMask) void {
        const code = @intFromEnum(sym);
        if (self.focus == .settings and (code == xkb.Keysym.Return or code == xkb.Keysym.KP_Enter or code == xkb.Keysym.space)) {
            self.openSettings();
            return;
        }
        if (code == xkb.Keysym.Escape) {
            self.output.closeWifi();
            return;
        }
        if (code == xkb.Keysym.Tab or code == xkb.Keysym.ISO_Left_Tab) {
            self.navigate(mods.shift or code == xkb.Keysym.ISO_Left_Tab);
            return;
        }
        if (code == xkb.Keysym.Return or code == xkb.Keysym.KP_Enter) {
            if (self.focus == .password or self.focus == .ssid) {
                if (self.canUse()) self.join();
            } else self.activate();
            self.refresh();
            self.ensureFormVisible();
            self.ensureFocusVisible();
            return;
        }
        if (self.focus == .password or self.focus == .ssid) {
            if (!self.canUse()) return;
            const input = if (self.focus == .password) &self.password else &self.name;
            if (mods.ctrl) {
                if (code == xkb.Keysym.u) input.clear();
            } else if (!mods.alt and !mods.logo) switch (code) {
                xkb.Keysym.BackSpace => input.backspace(),
                xkb.Keysym.Delete => input.delete(),
                xkb.Keysym.Left => input.left(),
                xkb.Keysym.Right => input.right(),
                xkb.Keysym.Home => input.cursor = 0,
                xkb.Keysym.End => input.cursor = input.len,
                else => {
                    if (utf8.len > 0) _ = input.insert(utf8);
                },
            };
            self.edit_ms = anim.nowMs();
            self.error_message = "";
            self.refresh();
            return;
        }
        if (code == xkb.Keysym.Up or code == xkb.Keysym.Down) {
            self.navigate(code == xkb.Keysym.Up);
            return;
        }
        if (code == xkb.Keysym.space) {
            self.activate();
            self.refresh();
            self.ensureFormVisible();
            self.ensureFocusVisible();
        }
    }
    fn navigate(self: *Popup, backwards: bool) void {
        if (self.hit_count == 0) return;
        var index: usize = if (backwards) 0 else self.hit_count - 1;
        for (self.hits[0..self.hit_count], 0..) |h, i| if (h.focus == self.focus and ((h.focus != .row and h.focus != .security_option) or h.index == self.focus_index)) {
            index = i;
            break;
        };
        index = (index + (if (backwards) self.hit_count - 1 else 1)) % self.hit_count;
        const next = self.hits[index];
        self.focus = next.focus;
        self.focus_index = next.index;
        if (next.focus != .toggle and next.focus != .settings) {
            if (next.box.y < header) self.scroll += next.box.y - header;
            if (next.box.y + next.box.h > self.height - footer - self.status_height) self.scroll += next.box.y + next.box.h - self.height + footer + self.status_height;
        }
        self.edit_ms = anim.nowMs();
        self.refresh();
    }
    fn addHit(self: *Popup, box: Rect, focus: Focus, index: usize) bool {
        const i = self.hit_count;
        self.hits[i] = .{ .box = box, .focus = focus, .index = index };
        self.hit_count += 1;
        return self.hover == i;
    }
    fn focused(self: *Popup, f: Focus, index: usize) bool {
        return self.focus == f and ((f != .row and f != .security_option) or self.focus_index == index);
    }
    fn networkRowY(self: *Popup, index: usize) ?f32 {
        const m = self.manager() orelse return null;
        if (!m.available or !m.enabled or !m.hardware or m.device.len == 0 or index >= m.count) return null;
        var y = header - self.scroll;
        for (m.networks[0..index]) |net| y += row_height + self.shownHeight(net);
        return y;
    }
    fn itemHoverBox(self: *Popup, row: f32) ?Rect {
        const m = self.manager() orelse return null;
        if (m.count == 0) return null;
        const bounded = std.math.clamp(row, 0, @as(f32, @floatFromInt(m.count - 1)));
        const low: usize = @intFromFloat(@floor(bounded));
        const high = @min(low + 1, m.count - 1);
        const low_y = self.networkRowY(low) orelse return null;
        const high_y = self.networkRowY(high) orelse return null;
        return .{ .x = 12, .y = low_y + (high_y - low_y) * (bounded - @floor(bounded)), .w = width - 24, .h = row_height };
    }
    fn formHeight(self: *Popup) f32 {
        if (self.hidden) return @as(f32, if (self.security == .open) 220 else 292) + @as(f32, if (self.security_open) 102 else 0);
        if (self.selected) |s| {
            if (s.connected) return 44;
            if (s.security == .unsupported and s.saved.len == 0) return 60;
            return if (self.needsPassword()) 144 else if (s.saved.len != 0) 58 else 76;
        }
        return 0;
    }
    /// Retargets the eased form heights at the current selection; a newly
    /// opened form grows from zero while the previous one collapses.
    fn syncExpansion(self: *Popup, now: i64) void {
        const want = self.selected != null or self.hidden;
        const form: ?network.Network = if (self.hidden) null else self.selected;
        if (want and !self.opening.matches(form)) {
            // Reopening the form that is still collapsing reverses it.
            const previous = self.opening;
            if (self.closing.matches(form)) {
                self.opening = self.closing;
            } else {
                self.opening = .{ .open = true, .net = form };
            }
            self.closing = previous;
        } else if (!want and self.opening.open) {
            self.closing = self.opening;
            self.opening = .{};
        }
        if (self.opening.open) self.opening.net = form;
        if (self.opening.open) self.opening.height.retargetTo(now, self.formHeight(), expand_curve);
        if (self.closing.open) self.closing.height.retargetTo(now, 0, expand_curve);
        self.opening.shown = if (self.opening.open) @max(0, self.opening.height.value(now)) else 0;
        self.closing.shown = if (self.closing.open) @max(0, self.closing.height.value(now)) else 0;
        if (self.closing.open and self.closing.height.settled(now)) self.closing = .{};
    }
    /// Current eased height of the form below `net` (null = hidden form).
    fn shownHeight(self: *Popup, net: ?network.Network) f32 {
        if (self.opening.matches(net)) return self.opening.shown;
        if (self.closing.matches(net)) return self.closing.shown;
        return 0;
    }
    pub fn refresh(self: *Popup) void {
        const bar = self.output.taskbar orelse return;
        const anchor = bar.itemBox(.network) orelse return;
        var output_box: wlr.Box = undefined;
        self.output.server.output_layout.getBox(self.output.wlr_output, &output_box);
        self.factor = @min(1, @min(@as(f32, @floatFromInt(@max(1, output_box.width - 24))) / width, @as(f32, @floatFromInt(@max(1, output_box.height - @import("../Taskbar.zig").barHeight() - 24))) / 200));
        const m = self.manager();
        const enabled = if (m) |n| n.available and n.enabled and n.hardware and n.device.len != 0 else false;
        const count = if (enabled) m.?.count else 0;
        self.syncExpansion(anim.nowMs());
        self.content_height = if (enabled) @as(f32, @floatFromInt(count)) * row_height + 58 + self.opening.shown + self.closing.shown else 110;
        if (enabled and count == 0) self.content_height += row_height;
        const status = if (self.error_message.len != 0) self.error_message else if (m) |n| n.message else "NetworkManager is unavailable";
        self.status_height = if (enabled and status.len != 0) 40 else 0;
        self.height = @min(header + self.content_height + footer + self.status_height, @max(160, @as(f32, @floatFromInt(output_box.height - @import("../Taskbar.zig").barHeight() - 24)) / self.factor));
        self.scroll = std.math.clamp(self.scroll, 0, @max(0, self.content_height - (self.height - header - footer - self.status_height)));
        const w: i32 = @intFromFloat(@round(width * self.factor));
        const h: i32 = @intFromFloat(@round(self.height * self.factor));
        const left = std.math.clamp(anchor.x + @divTrunc(anchor.width - w, 2), output_box.x + 12, @max(output_box.x + 12, output_box.x + output_box.width - w - 12));
        self.panel_box = .{ .x = left, .y = self.output.taskbarPopupY(h, 12), .width = w, .height = h };
        const scale = self.output.wlr_output.scale;
        const buf = PanelBuffer.create(w, h, scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale * self.factor };
        const t = theme.shellPalette();
        r.palette = t;
        var bg = t.window_bg;
        bg[3] = 1;
        r.fillRect(0, 0, width, self.height - 12, .{ .color = bg, .radius = 9, .border_width = 1, .border_color = t.border_hover });
        const tip = std.math.clamp(@as(f32, @floatFromInt(anchor.x + @divTrunc(anchor.width, 2) - left)) / self.factor, 24, width - 24);
        // Same taskbar pointer as the battery/calendar panels.
        for (0..@intCast(buf.height)) |iy| {
            const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale;
            if (y < self.height - 13) continue;
            for (0..@intCast(buf.width)) |ix| {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale;
                const d = (@abs(x - tip) + y - self.height) / @sqrt(@as(f32, 2));
                const coverage = std.math.clamp(0.5 - d * r.scale, 0, 1);
                if (coverage == 0) continue;
                const mix = (1 - std.math.clamp((-d - 1) * r.scale + 0.5, 0, 1)) * t.border_hover[3];
                buf.pixels[iy * @as(usize, @intCast(buf.width)) + ix] = (@import("../color.zig").Straight{ .r = bg[0] * (1 - mix) + t.border_hover[0] * mix, .g = bg[1] * (1 - mix) + t.border_hover[1] * mix, .b = bg[2] * (1 - mix) + t.border_hover[2] * mix, .a = coverage }).argb();
            }
        }
        if (self.output.server.config.compositor.taskbar_position == .top) buf.flipVertical();
        self.hit_count = 0;
        label(&r, 24, 14, 180, 42, "Wi-Fi", 23, t.window_fg, true);
        // Same switch as Settings; the hit target is padded for the pointer.
        const toggle_box: Rect = .{ .x = 396 - toggle.width, .y = 35 - toggle.height / 2, .w = toggle.width, .h = toggle.height };
        _ = self.addHit(.{ .x = toggle_box.x - 8, .y = toggle_box.y - 8, .w = toggle_box.w + 16, .h = toggle_box.h + 16 }, .toggle, 0);
        toggle.paint(&r, toggle_box, .{ .style = .settings, .on = if (m) |n| n.enabled else false, .focused = self.focus == .toggle, .disabled = if (m) |n| !n.available or !n.hardware or n.busy else true });
        r.fillRect(20, 65, width - 40, 1, .{ .color = t.border });
        r.clip = .{ .x = 12, .y = header, .w = width - 24, .h = self.height - header - footer - self.status_height };
        self.caret_reported = false;
        if (self.item_hover.frame.alpha > 0) if (self.itemHoverBox(self.item_hover.frame.row)) |box| {
            var fill = t.surface_hover;
            var border = t.border_soft;
            fill[3] *= self.item_hover.frame.alpha;
            border[3] *= self.item_hover.frame.alpha;
            r.fillRect(box.x, box.y, box.w, box.h, .{ .color = fill, .radius = 5, .border_width = 1, .border_color = border });
        };
        var y = header - self.scroll;
        if (enabled) {
            if (count == 0) {
                label(&r, 28, y, width - 56, row_height, if (self.searching()) "Searching for networks…" else "No networks found. Try reopening to scan again.", 12, t.window_dim, false);
                y += row_height;
            }
            for (m.?.networks[0..count], 0..) |net, i| {
                const selected = if (self.selected) |s| network.sameNetwork(s, net) else false;
                const extra = self.shownHeight(net);
                const box: Rect = .{ .x = 12, .y = y, .w = width - 24, .h = row_height };
                _ = self.addHit(box, .row, i);
                if (selected or extra > 0 or net.connected or self.focused(.row, i)) r.fillRect(12, y, width - 24, row_height + extra, .{ .color = t.surface_hover, .radius = 5 });
                if (net.connected or selected or extra > 0) r.fillRect(12, y + 5, 3, row_height - 10 + extra, .{ .color = t.accent, .radius = 1 });
                var signal_color = t.window_fg;
                signal_color[3] *= 0.45 + @as(f32, @floatFromInt(net.strength)) / 100 * 0.55;
                r.drawIcon(30, y + 18, 28, 28, .{ .id = .wifi, .color = signal_color });
                label(&r, 78, y + 8, 272, 26, network.networkName(&net), 16, t.window_fg, false);
                const subtitle = network.networkSubtitle(net);
                label(&r, 78, y + 34, 270, 22, subtitle, 12, t.window_dim, false);
                if (net.security != .open) r.drawIcon(353, y + 23, 18, 18, .{ .id = .lock, .color = t.window_dim });
                if (selected or net.connected) r.drawIcon(379, y + 25, 14, 14, .{ .id = if (selected) .chevron_up else .chevron_right, .color = t.window_fg });
                y += row_height;
                if (selected) self.paintFormClipped(&r, y, extra);
                y += extra;
            }
            r.fillRect(22, y + 6, width - 44, 1, .{ .color = t.border });
            y += 10;
            const hidden_box: Rect = .{ .x = 22, .y = y, .w = width - 44, .h = 48 };
            const hover = self.addHit(hidden_box, .hidden, 0);
            button.paint(&r, hidden_box, .{ .variant = .ghost, .label = "Join Hidden Network", .leading_icon = .plus, .trailing_icon = if (self.hidden) .chevron_up else .chevron_down }, .{ .focused = self.focus == .hidden, .pointer = if (hover) .hover else .idle });
            y += 48;
            const hidden_extra = self.shownHeight(null);
            if (self.hidden) self.paintFormClipped(&r, y, hidden_extra);
            y += hidden_extra;
        } else {
            const value = if (m) |n| (if (!n.available) "NetworkManager is unavailable" else if (!n.hardware) "Wi-Fi is disabled by the hardware switch" else if (!n.enabled) "Wi-Fi is turned off" else "No Wi-Fi adapter found") else "NetworkManager is unavailable";
            r.drawIcon(190, y + 16, 32, 32, .{ .id = .wifi, .color = t.window_dim });
            label(&r, 28, y + 55, width - 56, 32, value, 13, t.window_dim, false);
        }
        r.clip = null;
        if (self.status_height != 0) label(&r, 28, self.height - footer - self.status_height, width - 56, self.status_height, status, 11, if (m.?.busy) t.window_dim else t.danger, false);
        const viewport = self.height - header - footer - self.status_height;
        const strip = scrollbar.gutter(theme.global.scrollbar_width);
        if (scrollbar.Geometry.compute(.vertical, .{ .x = width - strip, .y = header, .w = strip, .h = viewport }, viewport, self.content_height, self.scroll)) |geometry|
            scrollbar.paint(&r, scrollbar.look(geometry, .{}, theme.global.scrollbar_width, t));
        r.fillRect(20, self.height - footer + 2, width - 40, 1, .{ .color = t.border });
        const settings_box: Rect = .{ .x = 22, .y = self.height - footer + 7, .w = width - 44, .h = 40 };
        const settings_hovered = self.addHit(settings_box, .settings, 0);
        button.paint(&r, settings_box, .{ .variant = .ghost, .leading_icon = .settings, .label = "Network Settings", .alignment = .left }, .{ .focused = self.focus == .settings, .pointer = if (settings_hovered) .hover else .idle });
        self.buffer_node.setBuffer(&buf.base);
        self.buffer_node.setDestSize(w, h);
        present.applySlide(self.buffer_node, self.panel_box, self.slide.value(anim.nowMs()), if (self.output.server.config.compositor.taskbar_position == .top) -20 else 20);
        self.sonar_step = -1;
        self.paintSonar(anim.nowMs());
        if (self.caret.placed) |*p| {
            p.origin_x = @floatFromInt(left);
            p.origin_y = @floatFromInt(self.buffer_node.node.y);
        }
        if (!self.caret_reported) self.caret.hide();
        _ = self.caret.frame(anim.nowMs());
        self.output.wlr_output.scheduleFrame();
    }
    /// Paints the form laid out at full size, revealing only its eased height.
    fn paintFormClipped(self: *Popup, r: *paint.Renderer, top: f32, shown: f32) void {
        if (shown <= 0) return;
        const outer = r.clip.?;
        defer r.clip = outer;
        const y0 = @max(outer.y, top);
        const y1 = @min(outer.y + outer.h, top + shown);
        r.clip = .{ .x = outer.x, .y = y0, .w = outer.w, .h = @max(0, y1 - y0) };
        self.paintForm(r, top);
    }
    fn paintForm(self: *Popup, r: *paint.Renderer, top: f32) void {
        const t = r.palette.?;
        var y = top + 4;
        if (self.selected) |net| {
            if (net.connected) {
                label(r, 78, y, 280, 32, "You're connected to this network", 12, t.window_dim, false);
                return;
            }
            if (net.security == .unsupported and net.saved.len == 0) {
                label(r, 28, y, 364, 48, "Configure this network with a network tool", 12, t.window_dim, false);
                return;
            }
        }
        if (self.hidden) {
            label(r, 28, y, 360, 20, "Network Name (SSID)", 12, t.window_dim, false);
            y += 22;
            self.paintInput(r, y, .ssid);
            y += 48;
            label(r, 28, y, 360, 20, "Security", 12, t.window_dim, false);
            y += 22;
            const box: Rect = .{ .x = 28, .y = y, .w = 364, .h = 34 };
            const hover = self.addHit(box, .security, 0);
            button.paint(r, box, .{ .label = switch (self.security) {
                .open => "Open",
                .sae => "WPA3 Personal",
                else => "WPA2 / WPA3 Personal",
            }, .trailing_icon = .chevron_down }, .{ .focused = self.focus == .security, .pointer = if (!self.canUse()) .disabled else if (hover) .hover else .idle });
            y += 42;
            if (self.security_open) {
                for ([_][]const u8{ "WPA2 / WPA3 Personal", "WPA3 Personal", "Open" }, 0..) |name, i| {
                    const choice: Rect = .{ .x = 28, .y = y, .w = 364, .h = 34 };
                    const hovered = self.addHit(choice, .security_option, i);
                    button.paint(r, choice, .{ .variant = .ghost, .label = name }, .{ .focused = self.focused(.security_option, i), .selected = @intFromEnum(self.security) == ([_]usize{ 1, 2, 0 })[i], .pointer = if (hovered) .hover else .idle });
                    y += 34;
                }
            }
        }
        if (self.needsPassword()) {
            label(r, 28, y, 360, 20, "Password", 12, t.window_dim, false);
            y += 22;
            self.paintInput(r, y, .password);
            y += 50;
        }
        const saved = if (self.selected) |s| s.saved.len != 0 else false;
        if (!saved) {
            const check_box: Rect = .{ .x = 28, .y = y, .w = 210, .h = 28 };
            _ = self.addHit(check_box, .autojoin, 0);
            checkbox.paint(r, check_box, "Auto-join this network", .{ .checked = self.autojoin, .focused = self.focus == .autojoin, .disabled = !self.canUse() });
            y += 32;
        }
        const join_box: Rect = .{ .x = 202, .y = y, .w = 96, .h = 34 };
        const hover_join = self.addHit(join_box, .join, 0);
        button.paint(r, join_box, .{ .variant = .primary, .label = "Join" }, .{ .focused = self.focus == .join, .pointer = if (!self.canUse()) .disabled else if (hover_join) .hover else .idle });
        const cancel_box: Rect = .{ .x = 306, .y = y, .w = 86, .h = 34 };
        const hover_cancel = self.addHit(cancel_box, .cancel, 0);
        button.paint(r, cancel_box, .{ .label = "Cancel" }, .{ .focused = self.focus == .cancel, .pointer = if (hover_cancel) .hover else .idle });
    }
    fn paintInput(self: *Popup, r: *paint.Renderer, y: f32, focus: Focus) void {
        const box: Rect = .{ .x = 28, .y = y, .w = 364, .h = 40 };
        const secret = focus == .password;
        const opts: field.Options = .{ .trailing = if (secret) .reveal else .none };
        _ = self.addHit(box, focus, 0);
        // Reverse hit testing lets the eye sit inside the field.
        if (secret) if (field.arrange(box, opts, r.palette.?).trailing) |eye| {
            _ = self.addHit(eye, .reveal, 0);
        };
        const layout = field.paintSecret(r, box, opts, .{ .focused = self.focus == focus, .disabled = !self.canUse(), .revealed = !secret or self.revealed, .trailing_focused = self.focus == .reveal, .external_caret = true }, if (secret) &self.password else &self.name, if (secret) (if (self.selected != null and self.selected.?.saved.len != 0) "Leave blank to use saved password" else "Enter password") else "Enter network name");
        const visible = r.clip.?;
        if (layout.caret) |place| if (place.y >= visible.y and place.y + place.h <= visible.y + visible.h) {
            self.caret_reported = true;
            self.caret.update(anim.nowMs(), .{ .caret = place, .origin_x = @floatFromInt(self.panel_box.x), .origin_y = @floatFromInt(self.panel_box.y), .factor = self.factor, .scale = self.output.wlr_output.scale, .color = r.palette.?.caretColor() }, self.edit_ms);
        };
    }
};
fn contains(b: Rect, x: f32, y: f32) bool {
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
}
fn label(r: *paint.Renderer, x: f32, y: f32, w: f32, h: f32, s: []const u8, size: f32, color: [4]f32, bold: bool) void {
    r.drawText(x, y, w, h, .{ .content = s, .font_size = size, .color = color, .weight = if (bold) 700 else 400 });
}

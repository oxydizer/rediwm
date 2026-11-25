//! Wayland keymap and playback shortcuts. Apply playback changes between
//! dispatches (a dmabuf probe may dispatch while a frame is being shown).
const std = @import("std");
const c = @import("c_gfx");
const wl = @import("wayland").client.wl;
const Osd = @import("osd.zig").Osd;
const Cursor = @import("ui").client_cursor;
const xdg = @import("wayland").client.xdg;

pub const Input = struct {
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    context: ?*c.xkb_context = null,
    state: ?*c.xkb_state = null,
    toplevel: ?*xdg.Toplevel = null,
    fullscreen: bool = false,
    osd: *Osd = undefined,
    pointer: ?*wl.Pointer = null,
    cursor: Cursor = .{},
    cursor_surface: ?*wl.Surface = null,
    cursor_theme: ?*wl.CursorTheme = null,
    inside: bool = false,
    serial: u32 = 0,
    cursor_hidden: ?bool = null,
    axis: f64 = 0,
    discrete: i32 = 0,

    pub fn syncCursor(self: *Input) void {
        const ptr = self.pointer orelse return;
        if (!self.inside) return;
        const hide = self.fullscreen and !self.osd.visible;
        if (self.cursor_hidden == hide) return;
        self.cursor_hidden = hide;
        if (hide) {
            ptr.setCursor(self.serial, null, 0, 0);
        } else if (!self.cursor.set(ptr, self.serial, "default")) {
            const theme = self.cursor_theme orelse return;
            const cursor = theme.getCursor("left_ptr") orelse return;
            if (cursor.image_count == 0) return;
            const img = cursor.images[0];
            const buffer = img.getBuffer() catch return;
            const surface = self.cursor_surface orelse return;
            ptr.setCursor(self.serial, surface, @intCast(img.hotspot_x), @intCast(img.hotspot_y));
            surface.attach(buffer, 0, 0);
            surface.damage(0, 0, @intCast(img.width), @intCast(img.height));
            surface.commit();
        }
    }

    fn pointerEvent(_: *wl.Pointer, ev: wl.Pointer.Event, self: *Input) void {
        const bar = self.osd;
        if (bar.surface == null) return;
        switch (ev) {
            .enter => |e| {
                self.inside = true;
                self.serial = e.serial;
                self.cursor_hidden = null;
                bar.motion(@floatCast(e.surface_x.toDouble()), @floatCast(e.surface_y.toDouble()));
                self.syncCursor();
            },
            .leave => {
                self.inside = false;
                self.axis = 0;
                self.discrete = 0;
                bar.leave();
            },
            .motion => |m| bar.motion(@floatCast(m.surface_x.toDouble()), @floatCast(m.surface_y.toDouble())),
            .button => |b| if (b.button == 0x110) bar.button(b.state == .pressed),
            .axis => |e| if (e.axis == .vertical_scroll) {
                self.axis += e.value.toDouble();
            },
            .axis_discrete => |e| if (e.axis == .vertical_scroll) {
                self.discrete += e.discrete;
            },
            .frame => {
                const amount = if (self.discrete != 0) @as(f64, @floatFromInt(self.discrete)) else self.axis / 10;
                if (amount != 0) bar.scroll(amount);
                self.axis = 0;
                self.discrete = 0;
            },
            else => {},
        }
    }

    pub fn deinit(self: *Input) void {
        self.cursor.deinit();
        if (self.cursor_theme) |theme| theme.destroy();
        if (self.cursor_surface) |surface| surface.destroy();
        if (self.pointer) |p| p.release();
        if (self.keyboard) |k| k.release();
        if (self.state) |s| c.xkb_state_unref(s);
        if (self.context) |ctx| c.xkb_context_unref(ctx);
        if (self.seat) |s| s.release();
    }
    pub fn seatEvent(seat: *wl.Seat, ev: wl.Seat.Event, self: *Input) void {
        switch (ev) {
            .capabilities => |caps| {
                if (caps.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch return;
                    self.pointer.?.setListener(*Input, pointerEvent, self);
                } else if (!caps.capabilities.pointer and self.pointer != null) {
                    self.osd.leave();
                    self.inside = false;
                    self.cursor.clearPointer();
                    self.pointer.?.release();
                    self.pointer = null;
                }
                if (caps.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = seat.getKeyboard() catch return;
                    self.keyboard.?.setListener(*Input, keyEvent, self);
                } else if (!caps.capabilities.keyboard) {
                    if (self.keyboard) |k| k.release();
                    self.keyboard = null;
                }
            },
            else => {},
        }
    }
    fn keyEvent(_: *wl.Keyboard, ev: wl.Keyboard.Event, self: *Input) void {
        switch (ev) {
            .keymap => |km| {
                defer _ = c.close(km.fd);
                if (self.state) |s| c.xkb_state_unref(s);
                self.state = null;
                if (km.format != .xkb_v1 or km.size == 0) return;
                const mem = c.mmap(null, km.size, c.PROT_READ, c.MAP_PRIVATE, km.fd, 0);
                if (mem == c.MAP_FAILED) return;
                defer _ = c.munmap(mem, km.size);
                if (self.context == null) self.context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return;
                const map = c.xkb_keymap_new_from_buffer(self.context, @ptrCast(mem), km.size - 1, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
                defer c.xkb_keymap_unref(map);
                self.state = c.xkb_state_new(map);
            },
            .modifiers => |m| if (self.state) |s| {
                _ = c.xkb_state_update_mask(s, m.mods_depressed, m.mods_latched, m.mods_locked, 0, 0, m.group);
            },
            .key => |k| {
                if (k.state != .pressed) return;
                const s = self.state orelse return;
                const top = self.toplevel orelse return;
                const delta: i64 = if (c.xkb_state_mod_name_is_active(s, "Shift", c.XKB_STATE_MODS_EFFECTIVE) > 0) 60 else 5;
                const bar = self.osd;
                const sym = c.xkb_state_key_get_one_sym(s, k.key + 8);
                if (bar.menu.open) {
                    switch (sym) {
                        c.XKB_KEY_Escape => return bar.closeMenu(),
                        c.XKB_KEY_Up, c.XKB_KEY_ISO_Left_Tab => return bar.menuNavigate(true),
                        c.XKB_KEY_Down, c.XKB_KEY_Tab => return bar.menuNavigate(false),
                        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => return bar.menuActivate(),
                        else => bar.closeMenu(),
                    }
                }
                if (c.xkb_state_mod_name_is_active(s, "Control", c.XKB_STATE_MODS_EFFECTIVE) > 0) {
                    if (sym == c.XKB_KEY_o or sym == c.XKB_KEY_O) bar.open = true;
                    return;
                }
                switch (sym) {
                    c.XKB_KEY_space => bar.toggle = !bar.toggle,
                    c.XKB_KEY_Left => bar.relative -|= delta,
                    c.XKB_KEY_Right => bar.relative +|= delta,
                    c.XKB_KEY_F, c.XKB_KEY_f => if (self.fullscreen) top.unsetFullscreen() else top.setFullscreen(null),
                    c.XKB_KEY_Up => bar.setVolume(bar.volume + 5),
                    c.XKB_KEY_Down => bar.setVolume(bar.volume - 5),
                    c.XKB_KEY_m, c.XKB_KEY_M => {
                        bar.muted = !bar.muted;
                        bar.dirty = true;
                        bar.reveal();
                    },
                    c.XKB_KEY_period => bar.steps +|= 1,
                    c.XKB_KEY_k, c.XKB_KEY_K => bar.toggle_subtitles = !bar.toggle_subtitles,
                    c.XKB_KEY_comma => bar.steps -|= 1,
                    c.XKB_KEY_Escape => if (self.fullscreen) top.unsetFullscreen(),
                    else => {},
                }
            },
            else => {},
        }
    }
};

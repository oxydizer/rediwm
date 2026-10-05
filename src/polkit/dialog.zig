//! Compositor-owned authentication surface. Sensitive input never enters the
//! generic widget tree, clipboard, text cache or IPC inspection payloads.
const std = @import("std");
const wlr = @import("wlroots");
const col = @import("../color.zig");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const Agent = @import("agent.zig").Agent;
const Event = @import("helper.zig").Event;
const ui = @import("ui");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const CaretOverlay = @import("../caret_overlay.zig").CaretOverlay;
const anim = @import("ui").anim;
const gpa = @import("../main.zig").gpa;
extern fn rediwm_polkit_secret_new() ?*anyopaque;
extern fn rediwm_polkit_secret_free(*anyopaque) void;
const Focus = enum { input, cancel, unlock, action };
const field_box: ui.widgets.field.Rect = .{ .x = 28, .y = 284, .w = 504, .h = 56 };
const cancel_box: ui.widgets.field.Rect = .{ .x = 28, .y = 408, .w = 244, .h = 52 };
const unlock_box: ui.widgets.field.Rect = .{ .x = 288, .y = 408, .w = 244, .h = 52 };

pub const Dialog = struct {
    server: *Server,
    output: *wlr.Output,
    scrim: *wlr.SceneRect,
    node: *wlr.SceneBuffer,
    /// The response field's caret, above `node`.
    caret: CaretOverlay,
    /// Last key into the dialog: restarts the caret's blink phase.
    caret_edit_ms: i64 = 0,
    memory: *anyopaque,
    input: ui.widgets.secret_input.Input,
    action: []u8,
    message: []u8,
    account: @import("identity.zig").Account,
    prompt: [512]u8 = @splat(0),
    status: [512]u8 = @splat(0),
    attempt: u8 = 1,
    waiting: bool = true,
    ended: bool = false,
    hidden: bool = true,
    message_pending: bool = false,
    status_error: bool = false,
    focus: Focus = .input,
    pressed: ?Focus = null,
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    fit: f32 = 1,

    pub fn opened(owner: ?*anyopaque, agent: *Agent, action: []const u8, message: []const u8) void {
        const server: *Server = @ptrCast(@alignCast(owner.?));
        if (server.polkit_dialog) |old| old.destroy();
        if (server.locker != null) return agent.cancel();
        const output = server.output_layout.outputAt(server.input.cursor.x, server.input.cursor.y) orelse {
            agent.cancel();
            return;
        };
        const dialog = create(server, output, agent, action, message) catch {
            agent.cancel();
            return;
        };
        server.polkit_dialog = dialog;
        @import("../extra_protocols.zig").rediwm_protocols_revoke(server.extra_protocols);
        // End active capture before any authentication pixels are presented.
        if (server.capture_mgr) |manager| manager.stopAll();
        server.switcher.cancel();
        server.screenshot_selector.cancel();
        server.input.clearGrab();
        server.input.pan_session = null;
        server.input.cursor_mode = .passthrough;
        server.input.active_buttons = 0;
        server.input.gesture = .none;
        server.input.finger_pan = false;
        server.world.cancelPan();
        var keyboards = server.input.keyboards.iterator(.forward);
        while (keyboards.next()) |keyboard| keyboard.cancelHardware();
        server.input.seat.keyboardEndGrab();
        server.input.seat.pointerEndGrab();
        server.input.window_menu.close();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        server.input.setDefaultCursor();
        ui.input.reset();
        dialog.relayout();
        if (server.ipc) |ipc| @import("../ipc/events.zig").onPolkitPrompt(ipc, true);
    }
    fn create(server: *Server, output: *wlr.Output, agent: *Agent, action: []const u8, message: []const u8) !*Dialog {
        if (action.len > 4096 or message.len > 8192 or !std.unicode.utf8ValidateSlice(action) or !std.unicode.utf8ValidateSlice(message)) return error.InvalidDescription;
        const self = try gpa.create(Dialog);
        errdefer gpa.destroy(self);
        const memory = rediwm_polkit_secret_new() orelse return error.SecretMemory;
        errdefer rediwm_polkit_secret_free(memory);
        const owned_action = try gpa.dupe(u8, action);
        errdefer gpa.free(owned_action);
        const owned_message = try gpa.dupe(u8, message);
        errdefer gpa.free(owned_message);
        const scrim = try col.createRect(server.lock_tree, 0, 0, col.Straight.fromRgba(ui.theme.global.polkit_backdrop).premultiply());
        errdefer scrim.node.destroy();
        const node = try server.lock_tree.createSceneBuffer(null);
        errdefer node.node.destroy();
        node.setFilterMode(.bilinear);
        const caret = try CaretOverlay.create(server.lock_tree);
        self.* = .{ .server = server, .output = output, .scrim = scrim, .node = node, .caret = caret, .memory = memory, .input = .{ .storage = @as([*]u8, @ptrCast(memory))[0..510] }, .action = owned_action, .message = owned_message, .account = agent.active.?.account };
        self.attempt = agent.active.?.attempt;
        if (self.attempt > 1) {
            set(&self.status, "Authentication failed. Please try again.");
            self.message_pending = true;
            self.status_error = true;
        } else set(&self.status, "Waiting for authentication service…");
        return self;
    }
    pub fn destroy(self: *Dialog) void {
        const server = self.server;
        server.polkit_dialog = null;
        if (server.ipc) |ipc| @import("../ipc/events.zig").onPolkitPrompt(ipc, false);
        self.input.clear();
        rediwm_polkit_secret_free(self.memory);
        self.scrim.node.destroy();
        self.caret.destroy();
        self.node.node.destroy();
        gpa.free(self.action);
        gpa.free(self.message);
        gpa.destroy(self);
        // Resolve the current toplevel rather than retaining a possibly dead one.
        if (server.locker == null) if (server.world.toplevels.first()) |top| server.world.focusSurface(top, null);
    }
    pub fn cancel(self: *Dialog) void {
        const server = self.server;
        if (server.polkit) |agent| agent.cancel();
        if (server.polkit_dialog) |dialog| dialog.destroy();
    }
    pub fn event(owner: ?*anyopaque, agent: *Agent, e: Event) void {
        const server: *Server = @ptrCast(@alignCast(owner.?));
        const self = server.polkit_dialog orelse return;
        if (agent.restart) {
            self.input.clear();
            self.waiting = true;
        }
        switch (e) {
            .success, .cancelled => {
                self.destroy();
                return;
            },
            .failure, .transport_error => {
                self.input.clear();
                self.waiting = true;
                self.ended = true;
                self.focus = .cancel;
                set(&self.status, if (e == .failure) "Authentication failed." else "Authentication service unavailable.");
            },
            .prompt_hidden, .prompt_visible => |prompt| {
                self.input.clear();
                self.hidden = e == .prompt_hidden;
                self.waiting = false;
                self.focus = .input;
                set(&self.prompt, prompt);
                if (!self.message_pending) {
                    set(&self.status, "Administrator privileges are required to continue.");
                    self.status_error = false;
                }
                self.message_pending = false;
            },
            .info, .error_message => |message| {
                set(&self.status, message);
                self.message_pending = true;
                self.status_error = e == .error_message;
            },
        }
        self.paint();
    }
    pub fn relayout(self: *Dialog) void {
        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(self.output, &box);
        self.fit = @max(0.1, @min(1, @min(@as(f32, @floatFromInt(box.width - 24)) / 560, @as(f32, @floatFromInt(box.height - 24)) / 480)));
        self.panel_box.width = @intFromFloat(@round(560 * self.fit));
        self.panel_box.height = @intFromFloat(@round(480 * self.fit));
        self.panel_box.x = box.x + @divTrunc(box.width - self.panel_box.width, 2);
        self.panel_box.y = box.y + @divTrunc(box.height - self.panel_box.height, 2);
        self.node.node.setPosition(self.panel_box.x, self.panel_box.y);
        self.server.output_layout.getBox(null, &box);
        self.scrim.node.setPosition(box.x, box.y);
        self.scrim.setSize(box.width, box.height);
        self.paint();
    }
    fn submit(self: *Dialog) void {
        if (self.waiting) return;
        const agent = self.server.polkit orelse return;
        agent.respond(self.input.value()) catch {
            self.input.clear();
            set(&self.status, "Could not send response. Please try again.");
            self.paint();
            return;
        };
        self.input.clear();
        self.waiting = true;
        set(&self.status, "Authenticating…");
        self.paint();
    }
    /// Only the response field repeats; a held Return must not answer twice.
    pub fn keyRepeats(self: *const Dialog, keysym: xkb.Keysym, utf8: []const u8) bool {
        return self.focus == .input and !self.waiting and @import("../input/repeat_keys.zig").editing(keysym, utf8);
    }

    pub fn key(self: *Dialog, keysym: xkb.Keysym, utf8: []const u8, mods: wlr.Keyboard.ModifierMask) void {
        self.caret_edit_ms = anim.nowMs();
        const sym = @intFromEnum(keysym);
        if (sym == xkb.Keysym.Escape) return self.cancel();
        if (sym == xkb.Keysym.Tab or sym == xkb.Keysym.ISO_Left_Tab) {
            self.focus = @enumFromInt((@as(usize, @intFromEnum(self.focus)) + (if (mods.shift or sym == xkb.Keysym.ISO_Left_Tab) @as(usize, 3) else 1)) % 4);
        } else if (self.focus == .action and mods.ctrl and sym == xkb.Keysym.c) {
            @import("../clipboard.zig").copyText(self.server, self.action);
        } else if (sym == xkb.Keysym.Return or sym == xkb.Keysym.KP_Enter or (sym == xkb.Keysym.space and self.focus != .input)) {
            if (self.focus == .cancel) return self.cancel();
            if (self.focus == .input or self.focus == .unlock) return self.submit();
        } else if (self.focus == .input and !self.waiting and !mods.alt and !mods.logo) {
            if (mods.ctrl) {
                if (sym == xkb.Keysym.u) self.input.clear();
            } else switch (sym) {
                xkb.Keysym.BackSpace => self.input.backspace(),
                xkb.Keysym.Delete => self.input.delete(),
                xkb.Keysym.Left => self.input.left(),
                xkb.Keysym.Right => self.input.right(),
                xkb.Keysym.Home => self.input.cursor = 0,
                xkb.Keysym.End => self.input.cursor = self.input.len,
                else => {
                    _ = self.input.insert(utf8);
                },
            }
        }
        self.paint();
    }
    fn hit(self: *Dialog, lx: f64, ly: f64) ?Focus {
        const x = (lx - @as(f64, @floatFromInt(self.panel_box.x))) / self.fit;
        const y = (ly - @as(f64, @floatFromInt(self.panel_box.y))) / self.fit;
        if (x < 28 or x > 532) return null;
        if (y >= 126 and y <= 154) return .action;
        if (y >= field_box.y and y <= field_box.y + field_box.h) return .input;
        if (y >= cancel_box.y and y <= cancel_box.y + cancel_box.h) {
            if (x <= cancel_box.x + cancel_box.w) return .cancel;
            if (x >= unlock_box.x) return .unlock;
        }
        return null;
    }
    pub fn button(self: *Dialog, down: bool, lx: f64, ly: f64) void {
        const hit_focus = self.hit(lx, ly);
        if (down) {
            self.pressed = hit_focus;
            if (hit_focus) |f| self.focus = f;
            self.paint();
        } else {
            const pressed = self.pressed;
            self.pressed = null;
            if (pressed != null and pressed == hit_focus) switch (pressed.?) {
                .cancel => return self.cancel(),
                .unlock => return self.submit(),
                else => {},
            };
        }
    }
    fn label(r: *ui.paint.Renderer, value: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, color: [4]f32) void {
        r.drawText(x, y, w, h, .{ .content = value, .font_size = size, .color = color });
    }
    pub fn paint(self: *Dialog) void {
        const scale = self.output.scale * self.fit;
        const buf = PanelBuffer.create(560, 480, scale) catch return;
        // Echo-on prompts can rasterize a sensitive response; never pool pixels.
        buf.sensitive = true;
        var r = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        const t = ui.theme.shellPalette();
        r.palette = t;
        const dialog = ui.widgets.dialog;
        dialog.paintFrame(&r, .{ .x = 0, .y = 0, .w = 560, .h = 480 });
        dialog.paintHeader(&r, 28, 28, 504, .{
            .icon = .lock,
            .title = if (self.hidden) "Enter Password" else "Authentication",
            .subtitle = "Authentication required",
        });
        label(&r, self.message, 28, 100, 504, 28, 15, t.fg);
        if (self.focus == .action) r.fillRect(26, 129, 508, 24, .{ .color = .{ t.accent[0], t.accent[1], t.accent[2], 0.16 }, .radius = 4 });
        label(&r, self.action, 28, 128, 504, 26, 12, t.dim);
        dialog.paintInset(&r, .{ .x = 28, .y = 170, .w = 504, .h = 72 });
        ui.widgets.avatar.paint(&r, 44, 185, 42, .{});
        const name = std.mem.sliceTo(&self.account.name, 0);
        label(&r, if (name.len != 0) name else self.account.username(), 100, 181, 404, 28, 18, t.fg);
        label(&r, self.account.username(), 100, 209, 404, 22, 13, t.dim);
        label(&r, std.mem.sliceTo(&self.prompt, 0), 28, 252, 504, 24, 14, t.dim);
        const field = ui.widgets.field.paintSecret(&r, field_box, .{ .size = .lg }, .{
            .focused = self.focus == .input,
            .disabled = self.waiting,
            .revealed = !self.hidden,
            .external_caret = true,
        }, &self.input, if (self.waiting) "Waiting…" else "Enter your response");
        label(&r, std.mem.sliceTo(&self.status, 0), 28, 350, 504, 28, 13, if (self.ended or self.status_error) t.danger else t.dim);
        var attempt_text: [32]u8 = undefined;
        const attempt = std.fmt.bufPrint(&attempt_text, "Attempt {d} of 3", .{self.attempt}) catch unreachable;
        label(&r, attempt, 28, 379, 504, 20, 11, t.dim);
        const buttons = ui.widgets.button;
        buttons.paint(&r, cancel_box, .{ .size = .lg, .label = if (self.ended) "Close" else "Cancel" }, .{
            .pointer = if (self.pressed == .cancel) .press else .idle,
            .focused = self.focus == .cancel,
        });
        buttons.paint(&r, unlock_box, .{ .variant = .primary, .size = .lg, .label = "Authenticate" }, .{
            .pointer = if (self.waiting) .disabled else if (self.pressed == .unlock) .press else .idle,
            .focused = self.focus == .unlock,
        });
        buf.publish(self.node, scale, null);
        self.node.setDestSize(self.panel_box.width, self.panel_box.height);
        buf.base.drop();
        self.caret.update(anim.nowMs(), if (field.caret) |place| .{
            .caret = place,
            .origin_x = @floatFromInt(self.panel_box.x),
            .origin_y = @floatFromInt(self.panel_box.y),
            .factor = self.fit,
            .scale = self.output.scale,
            .color = t.caretColor(),
        } else null, self.caret_edit_ms);
        self.output.scheduleFrame();
    }

    /// The caret's blink and glide, from the output's frame handler.
    pub fn frame(self: *Dialog, now_ms: i64) bool {
        return self.caret.frame(now_ms);
    }
};
fn set(out: []u8, value: []const u8) void {
    @memset(out, 0);
    var n = @min(out.len - 1, value.len);
    while (n > 0 and n < value.len and value[n] & 0xc0 == 0x80) n -= 1;
    @memcpy(out[0..n], value[0..n]);
    for (out[0..n]) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
}

//! Seat-local text-input-v3 / input-method-v2 relay. The protocol objects
//! belong to wlroots; this module owns listeners, focus policy and popup nodes.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Keyboard = @import("../Keyboard.zig");
const Toplevel = @import("../Toplevel.zig");
const gpa = @import("../main.zig").gpa;
const Self = @This();

server: *Server,
inputs: wl.list.Head(TextInput, .link) = undefined,
popups: wl.list.Head(Popup, .link) = undefined,
method: ?*wlr.InputMethodV2 = null,
active: ?*TextInput = null,
done_serial: u32 = 0,
grab_generation: u64 = 0,
new_input: wl.Listener(*wlr.TextInputV3) = .init(newInput),
new_method: wl.Listener(*wlr.InputMethodV2) = .init(newMethod),
new_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) = .init(newKeyboard),
focus_change: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(focusChanged),
method_commit: wl.Listener(void) = .init(methodCommit),
method_destroy: wl.Listener(void) = .init(methodDestroy),
method_grab: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) = .init(methodGrab),
grab_destroy: wl.Listener(void) = .init(grabDestroy),
new_popup: wl.Listener(*wlr.InputPopupSurfaceV2) = .init(newPopup),
grab: ?*wlr.InputMethodV2.KeyboardGrab = null,

pub fn create(server: *Server) !*Self {
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    // Display destruction cleans up globals on an initialization failure.
    const ti = try wlr.TextInputManagerV3.create(server.wl_server);
    const im = try wlr.InputMethodManagerV2.create(server.wl_server);
    const vk = try wlr.VirtualKeyboardManagerV1.create(server.wl_server);
    self.* = .{ .server = server };
    self.inputs.init();
    self.popups.init();
    ti.events.new_text_input.add(&self.new_input);
    im.events.new_input_method.add(&self.new_method);
    vk.events.new_virtual_keyboard.add(&self.new_keyboard);
    server.input.seat.keyboard_state.events.focus_change.add(&self.focus_change);
    return self;
}

pub fn destroy(self: *Self) void {
    self.new_input.link.remove();
    self.new_method.link.remove();
    self.new_keyboard.link.remove();
    self.focus_change.link.remove();
    self.detachMethod();
    while (self.popups.first()) |popup| popup.destroy();
    while (self.inputs.first()) |input| input.destroy();
    gpa.destroy(self);
}

extern fn wlr_input_device_get_virtual_keyboard(device: *wlr.InputDevice) ?*wlr.VirtualKeyboardV1;
pub fn isVirtual(device: *wlr.InputDevice) bool {
    return wlr_input_device_get_virtual_keyboard(device) != null;
}

pub fn keyboardGrab(self: *Self, keyboard: *wlr.Keyboard) ?*wlr.InputMethodV2.KeyboardGrab {
    const input = &self.server.input;
    if (self.server.locker != null or self.server.polkit_dialog != null or self.server.switcher.active() or
        input.open_wifi != null or input.open_battery != null or input.open_calendar != null or input.open_start_menu != null or (if (input.open_control_center) |cc| cc.hasKeyboardFocus() else false) or input.open_power_menu != null) return null;
    const method = self.method orelse return null;
    const grab = self.grab orelse return null;
    if (wlr_input_device_get_virtual_keyboard(&keyboard.base)) |virtual| {
        // IMEs reinject unhandled keys with their own virtual keyboard.
        // Sending those back into the grab would create an infinite loop.
        if (virtual.resource.getClient() == method.resource.getClient()) return null;
    }
    grab.setKeyboard(keyboard);
    return grab;
}

fn newKeyboard(listener: *wl.Listener(*wlr.VirtualKeyboardV1), virtual: *wlr.VirtualKeyboardV1) void {
    const self: *Self = @fieldParentPtr("new_keyboard", listener);
    if (virtual.seat != self.server.input.seat) return;
    Keyboard.create(self.server, &virtual.keyboard.base) catch {
        virtual.resource.getClient().postNoMemory();
        return;
    };
    self.server.input.seat.setCapabilities(.{ .pointer = true, .keyboard = true });
}

fn focusChanged(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), _: *wlr.Seat.event.KeyboardFocusChange) void {
    const self: *Self = @fieldParentPtr("focus_change", listener);
    self.syncFocus();
}

fn syncFocus(self: *Self) void {
    const surface = if (self.method != null and (self.server.locker == null and self.server.polkit_dialog == null))
        self.server.input.seat.keyboard_state.focused_surface
    else
        null;
    if (self.active) |active| {
        if (surface == null or active.input.focused_surface != surface) self.deactivate();
    }
    // Leave every old input before entering the new client. A client may have
    // multiple text-input objects, but only its most recently enabled one wins.
    var it = self.inputs.iterator(.forward);
    while (it.next()) |input| {
        if (input.input.focused_surface != null and input.input.focused_surface != surface) {
            if (self.active == input) self.deactivate();
            input.input.sendLeave();
        }
    }
    if (surface) |focused| {
        it = self.inputs.iterator(.forward);
        while (it.next()) |input| {
            if (input.input.focused_surface == null and input.input.resource.getClient() == focused.resource.getClient()) {
                input.input.sendEnter(focused);
            }
        }
    }
    self.updatePopups();
}

fn deactivate(self: *Self) void {
    if (self.active == null) return;
    self.active = null;
    if (self.method) |method| {
        method.sendDeactivate();
        self.done();
    }
    self.updatePopups();
}

fn sendState(self: *Self) void {
    const input = (self.active orelse return).input;
    const method = self.method orelse return;
    if (input.active_features.surrounding_text) {
        method.sendSurroundingText(input.current.surrounding.text orelse "", input.current.surrounding.cursor, input.current.surrounding.anchor);
    }
    method.sendTextChangeCause(input.current.text_change_cause);
    if (input.active_features.content_type) method.sendContentType(input.current.content_type.hint, input.current.content_type.purpose);
    self.done();
    self.updatePopups();
}

fn done(self: *Self) void {
    (self.method orelse return).sendDone();
    self.done_serial +%= 1;
}

const TextInput = struct {
    relay: *Self,
    input: *wlr.TextInputV3,
    link: wl.list.Link = undefined,
    enable: wl.Listener(void) = .init(enabled),
    disable: wl.Listener(void) = .init(disabled),
    commit: wl.Listener(void) = .init(committed),
    destroyed: wl.Listener(void) = .init(onDestroy),

    fn enabled(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("enable", listener);
        const relay = self.relay;
        const method = relay.method orelse return;
        if (relay.server.locker != null or relay.server.polkit_dialog != null or self.input.focused_surface == null or
            self.input.focused_surface != relay.server.input.seat.keyboard_state.focused_surface) return;
        relay.deactivate();
        relay.active = self;
        method.sendActivate();
        relay.sendState();
    }

    fn disabled(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("disable", listener);
        if (self.relay.active == self) self.relay.deactivate();
    }

    fn committed(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("commit", listener);
        if (self.relay.active == self and self.input.current_enabled) self.relay.sendState();
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("destroyed", listener);
        self.destroy();
    }

    fn destroy(self: *TextInput) void {
        if (self.relay.active == self) self.relay.deactivate();
        self.enable.link.remove();
        self.disable.link.remove();
        self.commit.link.remove();
        self.destroyed.link.remove();
        self.link.remove();
        gpa.destroy(self);
    }
};

fn newInput(listener: *wl.Listener(*wlr.TextInputV3), input: *wlr.TextInputV3) void {
    const self: *Self = @fieldParentPtr("new_input", listener);
    if (input.seat != self.server.input.seat) return;
    const tracked = gpa.create(TextInput) catch {
        input.resource.getClient().postNoMemory();
        return;
    };
    tracked.* = .{ .relay = self, .input = input };
    self.inputs.append(tracked);
    input.events.enable.add(&tracked.enable);
    input.events.disable.add(&tracked.disable);
    input.events.commit.add(&tracked.commit);
    input.events.destroy.add(&tracked.destroyed);
    self.syncFocus();
}

fn newMethod(listener: *wl.Listener(*wlr.InputMethodV2), method: *wlr.InputMethodV2) void {
    const self: *Self = @fieldParentPtr("new_method", listener);
    if (self.method != null or method.seat != self.server.input.seat) {
        method.sendUnavailable();
        return;
    }
    self.method = method;
    self.done_serial = 0;
    method.events.commit.add(&self.method_commit);
    method.events.destroy.add(&self.method_destroy);
    method.events.grab_keyboard.add(&self.method_grab);
    method.events.new_popup_surface.add(&self.new_popup);
    self.syncFocus();
}

fn methodCommit(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("method_commit", listener);
    const active = self.active orelse return;
    const input = active.input;
    if (self.server.locker != null or self.server.polkit_dialog != null or !input.current_enabled or input.focused_surface == null or
        input.focused_surface != self.server.input.seat.keyboard_state.focused_surface) return;
    const method = self.method orelse return;
    if (method.current_serial != self.done_serial) return;
    const state = &method.current;
    // Empty preedit clears the previous composition, including on commit-only
    // updates. Ignore replies to a state predating the latest done/focus change.
    input.sendPreeditString(state.preedit.text orelse "", state.preedit.cursor_begin, state.preedit.cursor_end);
    if (state.commit_text) |text| input.sendCommitString(text);
    if (state.delete.before_length != 0 or state.delete.after_length != 0) {
        input.sendDeleteSurroundingText(state.delete.before_length, state.delete.after_length);
    }
    input.sendDone();
}

fn methodGrab(listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab), grab: *wlr.InputMethodV2.KeyboardGrab) void {
    const self: *Self = @fieldParentPtr("method_grab", listener);
    self.grab_generation +%= 1;
    if (self.grab_generation == 0) self.grab_generation = 1;
    self.grab = grab;
    grab.events.destroy.add(&self.grab_destroy);
    // Locked keystrokes/modifiers must never be exposed to an input method.
    if ((self.server.locker == null and self.server.polkit_dialog == null)) grab.setKeyboard(self.server.input.seat.getKeyboard());
}

fn grabDestroy(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("grab_destroy", listener);
    self.grab_destroy.link.remove();
    self.grab = null;
    if ((self.server.locker == null and self.server.polkit_dialog == null)) {
        const seat = self.server.input.seat;
        if (seat.getKeyboard()) |keyboard| seat.keyboardNotifyModifiers(&keyboard.modifiers);
    }
}

fn detachMethod(self: *Self) void {
    if (self.method == null) return;
    if (self.grab != null) {
        grabDestroy(&self.grab_destroy);
    }
    self.method_commit.link.remove();
    self.method_destroy.link.remove();
    self.method_grab.link.remove();
    self.new_popup.link.remove();
    self.active = null;
    self.method = null;
}

fn methodDestroy(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("method_destroy", listener);
    // Clear composition before leaving, so a reconnect cannot strand preedit.
    if (self.active) |active| {
        if (active.input.focused_surface != null) {
            active.input.sendPreeditString("", 0, 0);
            active.input.sendDone();
        }
    }
    self.detachMethod();
    self.syncFocus();
}

// Candidate popups are output-local overlays. Their anchor is computed from
// the source scene surface, then transformed through the window and camera.
// The IME keeps its natural logical size, like other shell overlays.
const Popup = struct {
    relay: *Self,
    popup: *wlr.InputPopupSurfaceV2,
    tree: *wlr.SceneTree,
    link: wl.list.Link = undefined,
    commit: wl.Listener(*wlr.Surface) = .init(committed),
    destroyed: wl.Listener(void) = .init(onDestroy),
    last_rectangle: ?wlr.Box = null,

    fn committed(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *Popup = @fieldParentPtr("commit", listener);
        self.relay.updatePopups();
    }
    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *Popup = @fieldParentPtr("destroyed", listener);
        self.destroy();
    }
    fn destroy(self: *Popup) void {
        self.commit.link.remove();
        self.destroyed.link.remove();
        self.tree.node.destroy();
        self.link.remove();
        gpa.destroy(self);
    }
};

fn newPopup(listener: *wl.Listener(*wlr.InputPopupSurfaceV2), popup: *wlr.InputPopupSurfaceV2) void {
    const self: *Self = @fieldParentPtr("new_popup", listener);
    const tracked = gpa.create(Popup) catch {
        popup.resource.getClient().postNoMemory();
        return;
    };
    const tree = self.server.ime_tree.createSceneTree() catch {
        gpa.destroy(tracked);
        popup.resource.getClient().postNoMemory();
        return;
    };
    _ = tree.createSceneSubsurfaceTree(popup.surface) catch {
        tree.node.destroy();
        gpa.destroy(tracked);
        popup.resource.getClient().postNoMemory();
        return;
    };
    tracked.* = .{ .relay = self, .popup = popup, .tree = tree };
    self.popups.append(tracked);
    popup.surface.events.commit.add(&tracked.commit);
    popup.events.destroy.add(&tracked.destroyed);
    self.updatePopups();
}

fn surfaceNode(tree: *wlr.SceneTree, surface: *wlr.Surface) ?*wlr.SceneNode {
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        if (node.type == .tree) {
            if (surfaceNode(@fieldParentPtr("node", node), surface)) |found| return found;
        } else if (node.type == .buffer) {
            if (wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node))) |scene_surface| {
                if (scene_surface.surface == surface) return node;
            }
        }
    }
    return null;
}

pub fn updatePopups(self: *Self) void {
    var it = self.popups.iterator(.forward);
    while (it.next()) |popup| {
        const visible = visible: {
            const shell = &self.server.input;
            if (self.server.locker != null or self.server.polkit_dialog != null or self.server.switcher.active() or
                shell.open_start_menu != null or shell.open_wifi != null or shell.open_battery != null or shell.open_calendar != null or shell.open_power_menu != null or
                (if (shell.open_control_center) |cc| cc.hasKeyboardFocus() else false)) break :visible false;
            const input = (self.active orelse break :visible false).input;
            const surface = input.focused_surface orelse break :visible false;
            if (!surface.mapped or !popup.popup.surface.mapped) break :visible false;
            const node = surfaceNode(&self.server.scene.tree, surface) orelse break :visible false;
            var sx: i32 = 0;
            var sy: i32 = 0;
            _ = node.coords(&sx, &sy);
            var scale: f64 = 1;
            var x: f64 = @floatFromInt(sx);
            var y: f64 = @floatFromInt(sy);
            if (Toplevel.fromSurface(self.server, surface)) |top| {
                if (top.minimized or !top.in_world or top.backend != .xdg) break :visible false;
                scale = top.worldScale();
                const origin = top.frameWorld(x - @as(f64, @floatFromInt(top.x)), y - @as(f64, @floatFromInt(top.y)));
                const frame = self.server.world.toLayout(@floatFromInt(top.x), @floatFromInt(top.y));
                const frame_width = @as(f64, @floatFromInt(top.chrome_width)) * top.zoom();
                const frame_height = @as(f64, @floatFromInt(top.chrome_height)) * top.zoom();
                var on_output = false;
                var outputs = self.server.outputs.iterator(.forward);
                while (outputs.next()) |out| {
                    if (!out.isAvailable()) continue;
                    var box: wlr.Box = undefined;
                    self.server.output_layout.getBox(out.wlr_output, &box);
                    if (frame.x < @as(f64, @floatFromInt(box.x + box.width)) and frame.x + frame_width > @as(f64, @floatFromInt(box.x)) and
                        frame.y < @as(f64, @floatFromInt(box.y + box.height)) and frame.y + frame_height > @as(f64, @floatFromInt(box.y))) on_output = true;
                }
                if (!on_output) break :visible false;
                const layout = self.server.world.toLayout(origin.x, origin.y);
                x = layout.x;
                y = layout.y;
                scale *= self.server.world.camera.zoom();
            } else if (wlr.LayerSurfaceV1.tryFromWlrSurface(surface.getRootSurface()) == null) break :visible false;
            const rect = if (input.active_features.cursor_rectangle) input.current.cursor_rectangle else wlr.Box{ .x = 0, .y = 0, .width = surface.current.width, .height = surface.current.height };
            // Rectangle coordinates are client-controlled signed 32-bit values.
            // Zoom and adding the scene origin can exceed that range.
            const rx: i64 = @intFromFloat(@round(x + @as(f64, @floatFromInt(rect.x)) * scale));
            const ry: i64 = @intFromFloat(@round(y + @as(f64, @floatFromInt(rect.y)) * scale));
            const rw: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(@max(0, rect.width))) * scale));
            const rh: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(@max(0, rect.height))) * scale));
            const output = @import("../Output.zig").atLayout(self.server, @floatFromInt(wireCoordinate(rx)), @floatFromInt(wireCoordinate(ry))) orelse self.server.getDefaultOutput() orelse break :visible false;
            const usable = output.usableBox();
            const pw = popup.popup.surface.current.width;
            const ph = popup.popup.surface.current.height;
            const placement = @import("ime_placement.zig").place(.{ .x = rx, .y = ry, .width = rw, .height = rh }, .{ .x = usable.x, .y = usable.y, .width = usable.width, .height = usable.height }, pw, ph);
            const px = placement.x;
            const py = placement.y;
            popup.tree.node.setPosition(wireCoordinate(px), wireCoordinate(py));
            const relative = wlr.Box{ .x = wireCoordinate(rx - px), .y = wireCoordinate(ry - py), .width = wireCoordinate(rw), .height = wireCoordinate(rh) };
            if (popup.last_rectangle == null or !std.meta.eql(popup.last_rectangle.?, relative)) {
                var box = relative;
                popup.popup.sendTextInputRectangle(&box);
                popup.last_rectangle = relative;
            }
            break :visible true;
        };
        popup.tree.node.setEnabled(visible);
    }
}

fn wireCoordinate(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub fn popupPoint(self: *Self, surface: *wlr.Surface, x: f64, y: f64) ?@import("../geometry.zig").Vec2 {
    const node = surfaceNode(self.server.ime_tree, surface) orelse return null;
    var sx: i32 = 0;
    var sy: i32 = 0;
    _ = node.coords(&sx, &sy);
    return .{ .x = x - @as(f64, @floatFromInt(sx)), .y = y - @as(f64, @floatFromInt(sy)) };
}

/// Diagnostics deliberately expose only metadata, never surrounding/preedit text.
pub fn inspect(self: *Self, allocator: std.mem.Allocator) !@import("../ipc/protocol.zig").TextInputResult {
    const Result = @import("../ipc/protocol.zig").TextInputResult;
    var result = Result{};
    result.input_method = .{ .connected = self.method != null, .active = self.active != null, .keyboard_grab = self.grab != null };
    const focused = self.server.input.seat.keyboard_state.focused_surface;
    var inputs = self.inputs.iterator(.forward);
    while (inputs.next()) |tracked| {
        const surface = focused orelse break;
        const input = tracked.input;
        if (input.resource.getClient() != surface.resource.getClient()) continue;
        const rect = input.current.cursor_rectangle;
        result.focused = .{
            .window_id = if (Toplevel.fromSurface(self.server, surface)) |top| top.id else null,
            .enabled = input.current_enabled,
            .features = @bitCast(input.active_features),
            .content_purpose = input.current.content_type.purpose,
            .content_hint = input.current.content_type.hint,
            .cursor_rectangle = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
            .surrounding_bytes = if (input.current.surrounding.text) |t| std.mem.len(t) else 0,
            .pending = input.focused_surface == null,
        };
        if (self.active == tracked) break;
    }
    var popups: std.ArrayList(std.meta.Elem(@FieldType(Result, "popups"))) = .empty;
    errdefer popups.deinit(allocator);
    var it = self.popups.iterator(.forward);
    while (it.next()) |popup| {
        var x: i32 = 0;
        var y: i32 = 0;
        const visible = popup.tree.node.coords(&x, &y);
        const output = @import("../Output.zig").atLayout(self.server, @floatFromInt(x), @floatFromInt(y));
        try popups.append(allocator, .{
            .mapped = popup.popup.surface.mapped,
            .visible = visible,
            .x = x,
            .y = y,
            .width = popup.popup.surface.current.width,
            .height = popup.popup.surface.current.height,
            .output = if (output) |out| try allocator.dupe(u8, std.mem.span(out.wlr_output.name)) else null,
        });
    }
    result.popups = try popups.toOwnedSlice(allocator);
    result.input_method.popup_count = result.popups.len;
    return result;
}

//! Seat-local text-input-v1/v3 to input-method-v2 relay.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Server = @import("../Server.zig");
const Keyboard = @import("../Keyboard.zig");
const Toplevel = @import("../Toplevel.zig");
const gpa = @import("../main.zig").gpa;
const Legacy = @import("text_input_v1.zig");
const Self = @This();

server: *Server,
inputs: wl.list.Head(TextInput, .link) = undefined,
v1_inputs: wl.list.Head(Legacy, .link) = undefined,
v1_global: ?*wl.Global = null,
popups: wl.list.Head(Popup, .link) = undefined,
method: ?*wlr.InputMethodV2 = null,
active: ?Endpoint = null,
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

pub const Endpoint = union(enum) {
    v1: *Legacy,
    v3: *TextInput,

    fn surface(self: Endpoint) ?*wlr.Surface {
        return switch (self) {
            .v1 => |v| if (v.entered) v.target else null,
            .v3 => |v| v.input.focused_surface,
        };
    }

    fn enabled(self: Endpoint) bool {
        return switch (self) {
            .v1 => |v| v.entered,
            .v3 => |v| v.input.current_enabled,
        };
    }

    fn state(self: Endpoint) *const wlr.TextInputV3.State {
        return switch (self) {
            .v1 => |v| &v.current,
            .v3 => |v| &v.input.current,
        };
    }

    fn features(self: Endpoint) wlr.TextInputV3.Features {
        return switch (self) {
            .v1 => |v| v.current.features,
            .v3 => |v| v.input.active_features,
        };
    }

    fn caret(self: Endpoint) ?wlr.Box {
        return switch (self) {
            .v1 => |v| if (v.current.features.cursor_rectangle) v.current.cursor_rectangle else null,
            .v3 => |v| if (v.cursor_rectangle_seen) v.input.current.cursor_rectangle else null,
        };
    }
};

pub fn create(server: *Server) !*Self {
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);
    // Display destruction cleans up globals on an initialization failure.
    const ti = try wlr.TextInputManagerV3.create(server.wl_server);
    const im = try wlr.InputMethodManagerV2.create(server.wl_server);
    const vk = try wlr.VirtualKeyboardManagerV1.create(server.wl_server);
    self.* = .{ .server = server };
    self.inputs.init();
    self.v1_inputs.init();
    self.popups.init();
    if (!server.greeter_mode) self.v1_global = try Legacy.createGlobal(self);
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
    if (self.v1_global) |global| global.destroy();
    while (self.v1_inputs.first()) |input| input.resource.destroy();
    while (self.popups.first()) |popup| popup.destroy();
    while (self.inputs.first()) |input| input.destroy();
    gpa.destroy(self);
}

pub fn isVirtual(device: *wlr.InputDevice) bool {
    return device.getVirtualKeyboard() != null;
}

/// Why the compositor is about to hand input to the input method. `.new_input`
/// is the ordinary delivery path and yields to compositor UI (switcher, panels)
/// that owns new key presses. `.state` covers modifier updates and the release
/// of keys the grab already received: those must keep reaching it even while an
/// overlay owns new input, or the method's mirrored keyboard keeps a released
/// modifier held and the overlay it opened can never see it end.
pub const GrabPurpose = enum { new_input, state };

pub fn keyboardGrab(self: *Self, keyboard: *wlr.Keyboard, purpose: GrabPurpose) ?*wlr.InputMethodV2.KeyboardGrab {
    const input = &self.server.input;
    if (self.server.locker != null or self.server.polkit_dialog != null) return null;
    if (purpose == .new_input and (self.server.switcher.active() or self.server.world.overview.active() or
        input.open_wifi != null or input.open_battery != null or input.open_calendar != null or input.open_start_menu != null or (if (input.open_control_center) |cc| cc.hasKeyboardFocus() else false) or input.open_power_menu != null)) return null;
    const method = self.method orelse return null;
    const grab = self.grab orelse return null;
    if (keyboard.base.getVirtualKeyboard()) |virtual| {
        // IMEs reinject unhandled keys with their own virtual keyboard.
        // Sending those back into the grab would create an infinite loop.
        if (virtual.resource.getClient() == method.resource.getClient()) return null;
    }
    grab.setKeyboard(keyboard);
    return grab;
}

/// True for the connected input method's own virtual keyboard. What it reports
/// is an echo of input the compositor forwarded to the method, not a device the
/// user is pressing, so compositor gestures and the held-modifier switcher must
/// not treat its (possibly stale) state as physical input.
pub fn isMethodEcho(self: *Self, device: *wlr.InputDevice) bool {
    const method = self.method orelse return false;
    const virtual = device.getVirtualKeyboard() orelse return false;
    return virtual.resource.getClient() == method.resource.getClient();
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

pub fn blocked(self: *Self) bool {
    return self.server.locker != null or self.server.polkit_dialog != null or self.server.shutting_down;
}

pub fn isActive(self: *Self, endpoint: Endpoint) bool {
    return std.meta.eql(self.active orelse return false, endpoint);
}

pub fn syncFocus(self: *Self) void {
    const focus = if (self.blocked()) null else self.server.input.seat.keyboard_state.focused_surface;
    const surface = if (self.method != null) focus else null;
    if (self.active) |active| {
        if (surface == null or active.surface() != surface) self.deactivate();
    }
    // V1 activates a particular surface explicitly. A request can arrive
    // before keyboard focus or before the method connects. The newest request
    // for this surface wins; an entered field loses its request on focus loss.
    var candidate: ?*Legacy = null;
    var legacy = self.v1_inputs.iterator(.forward);
    while (legacy.next()) |input| {
        const target = input.target orelse continue;
        if (self.blocked() or (input.entered and target != focus)) {
            input.release(true);
        } else if (target == focus) {
            if (candidate == null) candidate = input else input.release(true);
        }
    }
    // Leave every old input before entering the new client. A client may have
    // multiple text-input objects, but only its most recently enabled one wins.
    var it = self.inputs.iterator(.forward);
    while (it.next()) |input| {
        if (input.input.focused_surface != null and input.input.focused_surface != surface) {
            if (self.isActive(.{ .v3 = input })) self.deactivate();
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
    if (candidate) |input| {
        const newly_entered = !input.entered;
        if (newly_entered) {
            input.resource.sendEnter(input.target.?.resource);
            input.entered = true;
        }
        if (self.method != null and (newly_entered or self.active == null)) self.activate(.{ .v1 = input });
    }
    self.updatePopups();
}

pub fn activate(self: *Self, next: Endpoint) void {
    const method = self.method orelse return;
    const surface = next.surface() orelse return;
    if (self.blocked() or surface != self.server.input.seat.keyboard_state.focused_surface) return;
    if (self.active) |old| {
        if (old == .v1 and !self.isActive(next)) old.v1.release(true) else self.deactivate();
    }
    self.active = next;
    method.sendActivate();
    self.sendState();
}

pub fn deactivate(self: *Self) void {
    if (self.active == null) return;
    self.active = null;
    if (self.method) |method| {
        method.sendDeactivate();
        self.done();
    }
    self.updatePopups();
}

pub fn sendState(self: *Self) void {
    const input = self.active orelse return;
    const surface = input.surface() orelse return;
    if (self.blocked() or self.server.input.seat.keyboard_state.focused_surface != surface) return;
    const method = self.method orelse return;
    const state = input.state();
    if (input.features().surrounding_text) {
        method.sendSurroundingText(state.surrounding.text orelse "", state.surrounding.cursor, state.surrounding.anchor);
    }
    method.sendTextChangeCause(state.text_change_cause);
    if (input.features().content_type) method.sendContentType(state.content_type.hint, state.content_type.purpose);
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
    /// A commit used `set_cursor_rectangle`. `active_features` is a snapshot of
    /// the enabling commit, and clients such as Chromium send the rectangle in
    /// a later one.
    cursor_rectangle_seen: bool = false,
    enable: wl.Listener(void) = .init(enabled),
    disable: wl.Listener(void) = .init(disabled),
    commit: wl.Listener(void) = .init(committed),
    destroyed: wl.Listener(void) = .init(onDestroy),

    fn enabled(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("enable", listener);
        self.relay.activate(.{ .v3 = self });
    }

    fn disabled(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("disable", listener);
        if (self.relay.isActive(.{ .v3 = self })) self.relay.deactivate();
    }

    fn committed(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("commit", listener);
        if (self.input.current.features.cursor_rectangle) self.cursor_rectangle_seen = true;
        if (self.relay.isActive(.{ .v3 = self }) and self.input.current_enabled) self.relay.sendState();
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *TextInput = @fieldParentPtr("destroyed", listener);
        self.destroy();
    }

    fn destroy(self: *TextInput) void {
        if (self.relay.isActive(.{ .v3 = self })) self.relay.deactivate();
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
    const surface = active.surface() orelse return;
    if (self.blocked() or !active.enabled() or surface != self.server.input.seat.keyboard_state.focused_surface) return;
    const method = self.method orelse return;
    if (method.current_serial != self.done_serial) return;
    const state = &method.current;
    if (active == .v1) return active.v1.deliver(state);
    const input = active.v3.input;
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
    if (self.active) |active| switch (active) {
        .v1 => |v| v.clearPreedit(),
        .v3 => |v| if (v.input.focused_surface != null) {
            v.input.sendPreeditString("", 0, 0);
            v.input.sendDone();
        },
    };
    self.detachMethod();
    self.syncFocus();
}

// Candidate popups are output-local overlays. Their anchor is computed from
// the source scene surface, then transformed through the window and camera.
// The IME keeps its natural logical size, like other shell overlays.
const Popup = struct {
    relay: *Self,
    popup: *wlr.InputPopupSurfaceV2,
    tree: *sn.Tree,
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

/// The node showing `surface` under `tree`.
fn surfaceNode(tree: *sn.Tree, surface: *wlr.Surface) ?*sn.Node {
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        switch (node.type) {
            .tree => if (surfaceNode(@fieldParentPtr("node", node), surface)) |found| return found,
            .buffer => if (node.buffer().?.surface) |scene_surface| {
                if (scene_surface.surface == surface) return node;
            },
            .rect => {},
        }
    }
    return null;
}

pub fn updatePopups(self: *Self) void {
    var it = self.popups.iterator(.forward);
    while (it.next()) |popup| {
        const visible = visible: {
            const shell = &self.server.input;
            if (self.server.locker != null or self.server.polkit_dialog != null or self.server.switcher.active() or self.server.world.overview.active() or
                shell.open_start_menu != null or shell.open_wifi != null or shell.open_battery != null or shell.open_calendar != null or shell.open_power_menu != null or
                (if (shell.open_control_center) |cc| cc.hasKeyboardFocus() else false)) break :visible false;
            const active = self.active orelse break :visible false;
            const surface = active.surface() orelse break :visible false;
            if (!surface.mapped or !popup.popup.surface.mapped) break :visible false;
            const node = surfaceNode(&self.server.nodes.tree, surface) orelse break :visible false;
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
            const rect = active.caret() orelse wlr.Box{ .x = 0, .y = 0, .width = surface.current.width, .height = surface.current.height };
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
    if (focused) |surface| {
        if (self.focusedInput(surface)) |input| {
            const state = input.state();
            const rect = state.cursor_rectangle;
            result.focused = .{
                .window_id = if (Toplevel.fromSurface(self.server, surface)) |top| top.id else null,
                .enabled = input.enabled(),
                .features = @bitCast(input.features()),
                .content_purpose = state.content_type.purpose,
                .content_hint = state.content_type.hint,
                .cursor_rectangle = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
                .surrounding_bytes = if (state.surrounding.text) |t| std.mem.len(t) else 0,
                .pending = input.surface() == null or self.method == null,
            };
        }
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

fn focusedInput(self: *Self, surface: *wlr.Surface) ?Endpoint {
    if (self.active) |input| if (input.surface() == surface) return input;
    var legacy = self.v1_inputs.iterator(.forward);
    while (legacy.next()) |v| if (v.target == surface) return .{ .v1 = v };
    var inputs = self.inputs.iterator(.forward);
    while (inputs.next()) |v| if (v.input.resource.getClient() == surface.resource.getClient()) return .{ .v3 = v };
    return null;
}

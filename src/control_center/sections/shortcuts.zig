const std = @import("std");
const keys = @import("config").keybinds;
const saving = @import("config").shortcut_save;
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");

const names = [_][]const u8{ "Window Management", "Canvas & Focus", "Launcher", "Screenshots", "Media", "System" };
const icons = [_]ui.layout.IconId{ .display, .grid, .grid, .document, .volume, .power };
pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    groups: [6]W = undefined,
    /// How many of `groups` the page shows: all of them, or one notice
    /// when the tree could not be allocated.
    group_count: usize = 0,
    collapsed: [6]bool = @splat(false),
    editing: ?usize = null,
    original: ?keys.Keybind = null,
    candidate: ?keys.Keybind = null,
    message: []const u8 = "",
    pending_save: bool = false,
    held_keycode: ?u32 = null,
    held_sym: xkb.Keysym = .NoSymbol,
    held_mods: wlr.Keyboard.ModifierMask = .{},

    pub fn cancel(s: *Section) void {
        s.pending_save = false;
        s.held_keycode = null;
        s.editing = null;
        s.original = null;
        s.candidate = null;
        s.message = "";
    }

    pub fn release(s: *Section, keycode: u32) void {
        if (s.held_keycode == keycode) s.held_keycode = null;
    }

    pub fn modifiers(s: *Section, cc: *panel.ControlCenter, mods: wlr.Keyboard.ModifierMask) void {
        if (s.held_keycode == null) return;
        // Include modifiers pressed after the main key, retaining the chord
        // as keys are released in either order.
        const combined = keys.relevantMods(@as(wlr.Keyboard.ModifierMask, @bitCast(@as(u32, @bitCast(s.held_mods)) | @as(u32, @bitCast(mods)))));
        if (keys.pack(combined, s.held_sym) == keys.pack(s.held_mods, s.held_sym)) return;
        s.capture(cc, s.held_keycode.?, s.held_sym, @bitCast(combined));
    }

    pub fn capture(s: *Section, cc: *panel.ControlCenter, keycode: u32, sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask) void {
        switch (@intFromEnum(sym)) {
            xkb.Keysym.Escape => {
                s.cancel();
                cc.refresh();
                return;
            },
            xkb.Keysym.Super_L, xkb.Keysym.Super_R, xkb.Keysym.Control_L, xkb.Keysym.Control_R, xkb.Keysym.Shift_L, xkb.Keysym.Shift_R, xkb.Keysym.Alt_L, xkb.Keysym.Alt_R, xkb.Keysym.Caps_Lock, xkb.Keysym.Num_Lock => return,
            else => {},
        }
        const index = s.editing orelse return;
        if (index >= cc.server.config.keybinds.len) {
            s.cancel();
            return;
        }
        s.held_keycode = keycode;
        s.held_sym = sym;
        s.held_mods = @bitCast(keys.relevantMods(mods));
        const candidate: keys.Keybind = .{ .sym = keys.normalizeSym(sym), .modifiers = keys.relevantMods(mods), .action = cc.server.config.keybinds[index].action };
        s.message = "";
        s.candidate = candidate;
        for (cc.server.config.keybinds, 0..) |bind, i| {
            if (i != index and bind.action != .noop and keys.pack(bind.modifiers, bind.sym) == keys.pack(candidate.modifiers, candidate.sym)) {
                s.candidate = null;
                s.message = "Shortcut already in use. Try another.";
                break;
            }
        }
        cc.refresh();
    }

    pub fn apply(s: *Section, cc: *panel.ControlCenter) void {
        if (!s.pending_save) return;
        s.pending_save = false;
        const candidate = s.candidate orelse return;
        const index = s.editing orelse return;
        saving.save(gpa, cc.server.io, cc.server.config.path, cc.server.config.keybinds, index, candidate) catch {
            s.message = "Could not save. Check the configuration file and try again.";
            cc.refresh();
            return;
        };
        s.cancel();
        @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
        cc.refresh();
    }
};

fn group(action: keys.Action) usize {
    return switch (action) {
        .close_window, .toggle_fullscreen, .toggle_maximize, .tile_left, .tile_right, .tile_up, .tile_down => 0,
        .set_depth, .zoom_in, .zoom_out, .zoom_reset, .camera_zoom_in, .camera_zoom_out, .camera_zoom_reset, .pan_left, .pan_right, .pan_up, .pan_down, .focus_next, .focus_prev, .focus_left, .focus_right, .focus_up, .focus_down, .save_layout, .restore_layout, .undo => 1,
        .spawn, .toggle_start_menu => 2,
        .screenshot_region, .screenshot_output => 3,
        .volume_up, .volume_down, .volume_mute, .mic_mute, .brightness_up, .brightness_down, .power_profile_cycle => 4,
        else => 5,
    };
}
fn text(value: []const u8, dim: bool) W {
    return .{ .kind = .{ .text = .{ .content = value, .font_size = if (dim) 12 else 13, .weight = if (dim) 400 else 600, .color = if (dim) ui.theme.global.window_dim else ui.theme.global.window_fg } } };
}
fn button(cc: *panel.ControlCenter, id: usize, value: []const u8, icon: ?ui.layout.IconId, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .kind = .{ .button = .{ .label = value, .icon = icon, .owner = cc, .id = id, .on_click = callback } }, .height = .{ .fixed = 32 }, .width = if (icon != null) .{ .fixed = 32 } else .auto };
}
fn children(a: std.mem.Allocator, values: []const W) ![]W {
    return a.dupe(W, values);
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    buildGroups(s, cc, s.arena.allocator()) catch {
        s.groups[0] = panel.outOfMemory();
        s.group_count = 1;
        return;
    };
    s.group_count = s.groups.len;
}

fn buildGroups(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !void {
    const t = ui.theme.global;
    // Config reloads can replace string payloads and reorder bindings. Retain
    // only the key identity; cancel if that row no longer denotes the same key.
    if (s.editing) |i| {
        if (i >= cc.server.config.keybinds.len or keys.pack(cc.server.config.keybinds[i].modifiers, cc.server.config.keybinds[i].sym) != keys.pack(s.original.?.modifiers, s.original.?.sym)) s.cancel();
        if (s.candidate) |*c| c.action = cc.server.config.keybinds[i].action;
    }
    for (&s.groups, 0..) |*card, g| {
        var rows: std.ArrayList(W) = .empty;
        try rows.append(a, .{ .kind = .{ .row = .{ .owner = cc, .id = g, .on_click = collapse } }, .height = .{ .fixed = 40 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 12, .@"align" = .center, .children = try children(a, &.{
            .{ .kind = .{ .icon = .{ .id = icons[g], .color = t.window_fg } }, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
            blk: {
                var title = text(names[g], false);
                title.width = .{ .flex = 1 };
                break :blk title;
            },
            .{ .kind = .{ .icon = .{ .id = if (s.collapsed[g]) .chevron_up else .chevron_down, .color = t.window_dim } }, .width = .{ .fixed = 16 }, .height = .{ .fixed = 16 } },
        }) });
        if (!s.collapsed[g]) for (cc.server.config.keybinds, 0..) |bind, i| {
            if (bind.action == .noop or group(bind.action) != g) continue;
            const editing = s.editing == i;
            const raw = @tagName(bind.action);
            const title = try a.dupe(u8, if (bind.action == .toggle_start_menu) "Toggle Launcher" else raw);
            var capital = true;
            for (title) |*c| {
                if (c.* == '_') {
                    c.* = ' ';
                    capital = true;
                } else if (capital) {
                    c.* = std.ascii.toUpper(c.*);
                    capital = false;
                }
            }
            var desc_buf: [8192]u8 = undefined;
            const description = if (editing) (if (s.message.len > 0) s.message else "Press keys to record. Esc cancels.") else switch (bind.action) {
                .spawn => |cmd| cmd,
                .toggle_start_menu => "Open or close the application launcher.",
                .close_window => "Close the focused window.",
                .screenshot_region => "Capture a region of your screen.",
                .screenshot_output => "Capture the current display.",
                .lock_screen => "Lock the session and turn off the display.",
                else => descriptionFor(bind.action, &desc_buf),
            };
            const caption = try a.dupe(u8, description);
            const shortcut = if (editing and s.candidate == null) "Press new shortcut…" else saving.format(a, if (editing) s.candidate.? else bind) catch "Unknown key";
            var controls: std.ArrayList(W) = .empty;
            try controls.append(a, .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 3, .children = try children(a, &.{ text(title, false), text(caption, true) }) });
            var chip = button(cc, i, shortcut, null, edit);
            chip.name = "shortcut";
            chip.width = .{ .fixed = if (cc.panel_box.width < 660) 140 else 190 };
            if (editing) chip.kind.button.variant = .primary;
            try controls.append(a, chip);
            if (editing) {
                var confirm = button(cc, i, "Save shortcut", .checkmark, confirmClicked);
                confirm.name = "save";
                confirm.kind.button.variant = .primary;
                if (s.candidate == null) confirm.kind.button.state = .disabled;
                try controls.append(a, confirm);
                var cancel_btn = button(cc, i, "Cancel", .close, cancelClicked);
                cancel_btn.name = "cancel";
                try controls.append(a, cancel_btn);
            } else {
                var edit_btn = button(cc, i, "Edit shortcut", .edit, edit);
                edit_btn.name = "edit";
                try controls.append(a, edit_btn);
            }
            try rows.append(a, .{ .kind = .{ .rect = .{ .color = t.window_divider } }, .height = .{ .fixed = 1 }, .width = .{ .percent = 1 } });
            try rows.append(a, .{ .kind = .container, .direction = .row, .height = .{ .fixed = 60 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 8, .@"align" = .center, .children = controls.items });
        };
        card.* = .{ .name = "shortcuts", .kind = .{ .rect = .{ .color = t.settings_card_bg, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.window_divider } }, .direction = .column, .width = .{ .percent = 1 }, .children = rows.items };
    }
}
fn owner(p: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(p.?));
}
fn edit(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.editing = i;
    cc.shortcuts.original = cc.server.config.keybinds[i];
    cc.refresh();
}
fn collapse(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.collapsed[i] = !cc.shortcuts.collapsed[i];
    cc.shortcuts.cancel();
    cc.refresh();
}
fn cancelClicked(p: ?*anyopaque, _: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.refresh();
}
fn confirmClicked(p: ?*anyopaque, _: usize) void {
    owner(p).shortcuts.pending_save = true;
}

fn descriptionFor(action: keys.Action, buf: []u8) []const u8 {
    return switch (action) {
        .toggle_fullscreen => "Enter or leave fullscreen.",
        .toggle_maximize => "Maximize or restore the focused window.",
        .tile_left => "Snap the focused window to the left half.",
        .tile_right => "Snap the focused window to the right half.",
        .tile_up => "Snap the focused window to a top quarter, or maximize it.",
        .tile_down => "Snap the focused window to a bottom quarter, or restore it.",
        .set_depth => |n| std.fmt.bufPrint(buf, "Move the window to depth {d}.", .{n}) catch "Change window depth.",
        .zoom_in => "Increase the focused window's size.",
        .zoom_out => "Decrease the focused window's size.",
        .zoom_reset => "Restore the focused window's size.",
        .camera_zoom_in => "Zoom into the desktop canvas.",
        .camera_zoom_out => "Zoom out of the desktop canvas.",
        .camera_zoom_reset => "Restore the desktop zoom.",
        .pan_left => "Scroll to the desktop on the left.",
        .pan_right => "Scroll to the desktop on the right.",
        .pan_up => "Scroll to the desktop above.",
        .pan_down => "Scroll to the desktop below.",
        .focus_next => "Switch to the next window.",
        .focus_prev => "Switch to the previous window.",
        .focus_left => "Focus the window to the left.",
        .focus_right => "Focus the window to the right.",
        .focus_up => "Focus the window above.",
        .focus_down => "Focus the window below.",
        .save_layout => |v| std.fmt.bufPrint(buf, "Save layout: {s}", .{v}) catch "Save the window layout.",
        .restore_layout => |v| std.fmt.bufPrint(buf, "Restore layout: {s}", .{v}) catch "Restore a saved layout.",
        .undo => "Undo the last layout change.",
        .restore_shortcuts => "Take shortcuts back from a virtual machine or remote desktop.",
        .volume_up => "Increase system volume.",
        .volume_down => "Decrease system volume.",
        .volume_mute => "Mute or unmute system audio.",
        .mic_mute => "Mute or unmute the microphone.",
        .brightness_up => "Increase display brightness.",
        .brightness_down => "Decrease display brightness.",
        .power_profile_cycle => "Switch to the next power profile.",
        .quit => "Log out of the desktop session.",
        .poweroff, .poweroff_auto => "Shut down the computer.",
        .reboot, .reboot_auto => "Restart the computer.",
        .@"suspend", .suspend_auto => "Put the computer to sleep.",
        .restart_shell => "Restart the desktop shell.",
        else => "",
    };
}

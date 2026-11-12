const i18n = @import("i18n");
const std = @import("std");
const keys = @import("config").keybinds;
const saving = @import("config").shortcut_save;
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");

const names = [_]i18n.Message{ i18n.msg("Window Management"), i18n.msg("Canvas & Focus"), i18n.msg("Launcher"), i18n.msg("Screenshots"), i18n.msg("Media"), i18n.msg("System") };
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
        switch (sym) {
            xkb.Keysym.Escape => {
                s.cancel();
                cc.refresh();
                return;
            },
            xkb.Keysym.Super_L, xkb.Keysym.Super_R, xkb.Keysym.Control_L, xkb.Keysym.Control_R, xkb.Keysym.Shift_L, xkb.Keysym.Shift_R, xkb.Keysym.Alt_L, xkb.Keysym.Alt_R, xkb.Keysym.Caps_Lock, xkb.Keysym.Num_Lock => return,
            else => {},
        }
        const index = s.editing orelse return;
        if (index >= cc.server.config.activeKeybinds().len) {
            s.cancel();
            return;
        }
        s.held_keycode = keycode;
        s.held_sym = sym;
        s.held_mods = @bitCast(keys.relevantMods(mods));
        const candidate: keys.Keybind = .{ .sym = keys.normalizeSym(sym), .modifiers = keys.relevantMods(mods), .action = cc.server.config.activeKeybinds()[index].action };
        s.message = "";
        s.candidate = candidate;
        for (cc.server.config.activeKeybinds(), 0..) |bind, i| {
            if (i != index and bind.action != .noop and keys.pack(bind.modifiers, bind.sym) == keys.pack(candidate.modifiers, candidate.sym)) {
                s.candidate = null;
                s.message = i18n.tr("Shortcut already in use. Try another.");
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
        saving.saveMode(gpa, cc.server.io, cc.server.config.path, cc.server.config.activeKeybinds(), index, candidate, cc.server.config.compositor.desktop_mode) catch {
            s.message = i18n.tr("Could not save. Check the configuration file and try again.");
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
        .toggle_floating, .toggle_split, .toggle_workspace_tiling, .swap_left, .swap_right, .swap_up, .swap_down, .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down, .close_window, .toggle_fullscreen, .toggle_maximize, .tile_left, .tile_right, .tile_up, .tile_down => 0,
        .set_depth, .zoom_in, .zoom_out, .zoom_reset, .camera_zoom_in, .camera_zoom_out, .camera_zoom_reset, .pan_left, .pan_right, .pan_up, .pan_down, .focus_next, .focus_prev, .focus_left, .focus_right, .focus_up, .focus_down, .save_layout, .restore_layout, .undo => 1,
        .spawn, .toggle_start_menu, .input_source_next, .input_source_prev => 2,
        .screenshot_region, .screenshot_output => 3,
        .volume_up, .volume_down, .volume_mute, .mic_mute, .brightness_up, .brightness_down, .power_profile_cycle => 4,
        else => 5,
    };
}
fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = if (dim) 12 else 13, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
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
    const t = panel.palette();
    // Config reloads can replace string payloads and reorder bindings. Retain
    // only the key identity; cancel if that row no longer denotes the same key.
    if (s.editing) |i| {
        if (i >= cc.server.config.activeKeybinds().len or keys.pack(cc.server.config.activeKeybinds()[i].modifiers, cc.server.config.activeKeybinds()[i].sym) != keys.pack(s.original.?.modifiers, s.original.?.sym)) s.cancel();
        if (s.candidate) |*c| c.action = cc.server.config.activeKeybinds()[i].action;
    }
    for (&s.groups, 0..) |*card, g| {
        var rows: std.ArrayList(W) = .empty;
        if (g == 0) {
            try rows.append(a, text(if (cc.server.world.workspaces.active) i18n.tr("Workspaces · Hyprland-style preset") else i18n.tr("Canvas · RediWM preset"), false));
            if (cc.server.world.workspaces.active) try rows.append(a, text(i18n.tr("Super+Q opens Terminal; Super+M opens Power. Arrows focus; numbers switch workspaces."), true));
        }
        try rows.append(a, .{ .kind = .{ .row = .{ .owner = cc, .id = g, .on_click = collapse } }, .height = .{ .fixed = 40 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 12, .@"align" = .center, .children = try children(a, &.{
            .{ .kind = .{ .icon = .{ .id = icons[g], .color = t.window_fg } }, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } },
            blk: {
                var title = text(names[g].get(), false);
                title.width = .{ .flex = 1 };
                break :blk title;
            },
            .{ .kind = .{ .icon = .{ .id = if (s.collapsed[g]) .chevron_up else .chevron_down, .color = t.window_dim } }, .width = .{ .fixed = 16 }, .height = .{ .fixed = 16 } },
        }) });
        if (!s.collapsed[g]) for (cc.server.config.activeKeybinds(), 0..) |bind, i| {
            if (group(bind.action) != g) continue;
            const editing = s.editing == i;
            const title = actionTitle(bind.action);
            var desc_buf: [8192]u8 = undefined;
            const description = if (editing) (if (s.message.len > 0) s.message else i18n.tr("Press keys to record. Esc cancels.")) else switch (bind.action) {
                .spawn => |cmd| cmd,
                .toggle_start_menu => i18n.tr("Open or close the application launcher."),
                .close_window => i18n.tr("Close the focused window."),
                .screenshot_region => i18n.tr("Capture a region of your screen."),
                .screenshot_output => i18n.tr("Capture the current display."),
                .lock_screen => i18n.tr("Lock the session and turn off the display."),
                else => descriptionFor(bind.action, &desc_buf),
            };
            const caption = try a.dupe(u8, description);
            const shortcut = if (editing and s.candidate == null) i18n.tr("Press new shortcut…") else saving.format(a, if (editing) s.candidate.? else bind) catch i18n.tr("Unknown key");
            var controls: std.ArrayList(W) = .empty;
            try controls.append(a, .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 3, .children = try children(a, &.{ text(title, false), text(caption, true) }) });
            var chip = button(cc, i, shortcut, null, edit);
            chip.name = "shortcut";
            chip.width = .{ .fixed = if (cc.panel_box.width < 660) 140 else 190 };
            if (editing) chip.kind.button.variant = .primary;
            try controls.append(a, chip);
            if (editing) {
                var confirm = button(cc, i, i18n.tr("Save shortcut"), .checkmark, confirmClicked);
                confirm.name = "save";
                confirm.kind.button.variant = .primary;
                if (s.candidate == null) confirm.kind.button.state = .disabled;
                try controls.append(a, confirm);
                var cancel_btn = button(cc, i, i18n.tr("Cancel"), .close, cancelClicked);
                cancel_btn.name = "cancel";
                try controls.append(a, cancel_btn);
            } else {
                var edit_btn = button(cc, i, i18n.tr("Edit shortcut"), .edit, edit);
                edit_btn.name = "edit";
                try controls.append(a, edit_btn);
                if (bind.action != .noop) {
                    var disable = button(cc, i, i18n.tr("Disable shortcut"), .close, disableClicked);
                    disable.name = "disable";
                    try controls.append(a, disable);
                }
            }
            try rows.append(a, .{ .kind = .{ .rect = .{ .color = t.window_divider } }, .height = .{ .fixed = 1 }, .width = .{ .percent = 1 } });
            try rows.append(a, .{ .kind = .container, .direction = .row, .height = .{ .fixed = 60 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(12, 0), .gap = 8, .@"align" = .center, .children = controls.items });
        };
        card.* = .{ .name = "shortcuts", .kind = .{ .rect = .{ .color = t.settings_card_bg, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.window_divider, .relief = t.settings_card_relief } }, .direction = .column, .width = .{ .percent = 1 }, .children = rows.items };
    }
}
fn owner(p: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(p.?));
}
fn edit(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    cc.shortcuts.cancel();
    cc.shortcuts.editing = i;
    cc.shortcuts.original = cc.server.config.activeKeybinds()[i];
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
        .toggle_floating => i18n.tr("Toggle the focused window between floating and automatic tiling."),
        .toggle_split => i18n.tr("Rotate the nearest tiled split."),
        .toggle_workspace_tiling => i18n.tr("Toggle automatic tiling for the current workspace."),
        .swap_left => i18n.tr("Swap the focused tile left."),
        .swap_right => i18n.tr("Swap the focused tile right."),
        .swap_up => i18n.tr("Swap the focused tile up."),
        .swap_down => i18n.tr("Swap the focused tile down."),
        .resize_split_left => i18n.tr("Move the relevant split divider left."),
        .resize_split_right => i18n.tr("Move the relevant split divider right."),
        .resize_split_up => i18n.tr("Move the relevant split divider up."),
        .resize_split_down => i18n.tr("Move the relevant split divider down."),
        .workspace => |n| i18n.fmt(buf, i18n.tr("Switch to workspace {n}."), .{ .n = n }) catch i18n.tr("Switch workspace."),
        .move_to_workspace => |n| i18n.fmt(buf, i18n.tr("Move the window to workspace {n} and follow it."), .{ .n = n }) catch i18n.tr("Move to workspace."),
        .workspace_next => i18n.tr("Cycle to the next existing workspace."),
        .workspace_prev => i18n.tr("Cycle to the previous existing workspace."),
        .toggle_power_menu => i18n.tr("Open the session and power menu."),
        .open_system_monitor => i18n.tr("Open System Monitor, or restore and focus its window."),
        .noop => i18n.tr("Disabled shortcut."),
        .toggle_fullscreen => i18n.tr("Enter or leave fullscreen."),
        .toggle_maximize => i18n.tr("Maximize or restore the focused window."),
        .tile_left => i18n.tr("Snap the focused window to the left half."),
        .tile_right => i18n.tr("Snap the focused window to the right half."),
        .tile_up => i18n.tr("Snap the focused window to a top quarter, or maximize it."),
        .tile_down => i18n.tr("Snap the focused window to a bottom quarter, or restore it."),
        .set_depth => |n| i18n.fmt(buf, i18n.tr("Move the window to depth {depth}."), .{ .depth = n }) catch i18n.tr("Change window depth."),
        .zoom_in => i18n.tr("Increase the focused window's size."),
        .zoom_out => i18n.tr("Decrease the focused window's size."),
        .zoom_reset => i18n.tr("Restore the focused window's size."),
        .camera_zoom_in => i18n.tr("Zoom into the desktop canvas."),
        .camera_zoom_out => i18n.tr("Zoom out of the desktop canvas."),
        .camera_zoom_reset => i18n.tr("Restore the desktop zoom."),
        .pan_left => i18n.tr("Scroll to the desktop on the left."),
        .pan_right => i18n.tr("Scroll to the desktop on the right."),
        .pan_up => i18n.tr("Scroll to the desktop above."),
        .pan_down => i18n.tr("Scroll to the desktop below."),
        .focus_next => i18n.tr("Switch to the next window."),
        .focus_prev => i18n.tr("Switch to the previous window."),
        .focus_left => i18n.tr("Focus the window to the left."),
        .focus_right => i18n.tr("Focus the window to the right."),
        .focus_up => i18n.tr("Focus the window above."),
        .focus_down => i18n.tr("Focus the window below."),
        .save_layout => |v| i18n.fmt(buf, i18n.tr("Save layout: {name}"), .{ .name = v }) catch i18n.tr("Save the window layout."),
        .restore_layout => |v| i18n.fmt(buf, i18n.tr("Restore layout: {name}"), .{ .name = v }) catch i18n.tr("Restore a saved layout."),
        .undo => i18n.tr("Undo the last layout change."),
        .restore_shortcuts => i18n.tr("Take shortcuts back from a virtual machine or remote desktop."),
        .volume_up => i18n.tr("Increase system volume."),
        .volume_down => i18n.tr("Decrease system volume."),
        .volume_mute => i18n.tr("Mute or unmute system audio."),
        .mic_mute => i18n.tr("Mute or unmute the microphone."),
        .brightness_up => i18n.tr("Increase display brightness."),
        .brightness_down => i18n.tr("Decrease display brightness."),
        .power_profile_cycle => i18n.tr("Switch to the next power profile."),
        .input_source_next => i18n.tr("Switch to the next keyboard layout or input method."),
        .input_source_prev => i18n.tr("Switch to the previous keyboard layout or input method."),
        .quit => i18n.tr("Log out of the desktop session."),
        .poweroff, .poweroff_auto => i18n.tr("Shut down the computer."),
        .reboot, .reboot_auto => i18n.tr("Restart the computer."),
        .@"suspend", .suspend_auto => i18n.tr("Put the computer to sleep."),
        .restart_shell => i18n.tr("Restart the desktop shell."),
        else => "",
    };
}

fn disableClicked(p: ?*anyopaque, i: usize) void {
    const cc = owner(p);
    const bind = cc.server.config.activeKeybinds()[i];
    cc.shortcuts.editing = i;
    cc.shortcuts.original = bind;
    cc.shortcuts.candidate = .{ .sym = bind.sym, .modifiers = bind.modifiers, .action = .noop };
    cc.shortcuts.pending_save = true;
}

fn actionTitle(action: keys.Action) []const u8 {
    return switch (action) {
        .toggle_floating => i18n.tr("Toggle Floating"),
        .toggle_split => i18n.tr("Toggle Split"),
        .toggle_workspace_tiling => i18n.tr("Toggle Workspace Tiling"),
        .swap_left => i18n.tr("Swap Left"),
        .swap_right => i18n.tr("Swap Right"),
        .swap_up => i18n.tr("Swap Up"),
        .swap_down => i18n.tr("Swap Down"),
        .resize_split_left => i18n.tr("Resize Split Left"),
        .resize_split_right => i18n.tr("Resize Split Right"),
        .resize_split_up => i18n.tr("Resize Split Up"),
        .resize_split_down => i18n.tr("Resize Split Down"),
        .noop => i18n.tr("Noop"),
        .workspace => i18n.tr("Workspace"),
        .move_to_workspace => i18n.tr("Move To Workspace"),
        .workspace_next => i18n.tr("Workspace Next"),
        .workspace_prev => i18n.tr("Workspace Prev"),
        .toggle_power_menu => i18n.tr("Toggle Power Menu"),
        .volume_up => i18n.tr("Volume Up"),
        .volume_down => i18n.tr("Volume Down"),
        .volume_mute => i18n.tr("Volume Mute"),
        .mic_mute => i18n.tr("Mic Mute"),
        .brightness_up => i18n.tr("Brightness Up"),
        .brightness_down => i18n.tr("Brightness Down"),
        .power_profile_cycle => i18n.tr("Power Profile Cycle"),
        .input_source_next => i18n.tr("Next Input Source"),
        .input_source_prev => i18n.tr("Previous Input Source"),
        .spawn => i18n.tr("Spawn"),
        .close_window => i18n.tr("Close Window"),
        .toggle_fullscreen => i18n.tr("Toggle Fullscreen"),
        .toggle_maximize => i18n.tr("Toggle Maximize"),
        .tile_left => i18n.tr("Tile Left"),
        .tile_right => i18n.tr("Tile Right"),
        .tile_up => i18n.tr("Tile Up"),
        .tile_down => i18n.tr("Tile Down"),
        .toggle_start_menu => i18n.tr("Toggle Launcher"),
        .open_system_monitor => i18n.tr("Open System Monitor"),
        .set_depth => i18n.tr("Set Depth"),
        .zoom_in => i18n.tr("Zoom In"),
        .zoom_out => i18n.tr("Zoom Out"),
        .zoom_reset => i18n.tr("Zoom Reset"),
        .camera_zoom_in => i18n.tr("Camera Zoom In"),
        .camera_zoom_out => i18n.tr("Camera Zoom Out"),
        .camera_zoom_reset => i18n.tr("Camera Zoom Reset"),
        .pan_left => i18n.tr("Pan Left"),
        .pan_right => i18n.tr("Pan Right"),
        .pan_up => i18n.tr("Pan Up"),
        .pan_down => i18n.tr("Pan Down"),
        .focus_next => i18n.tr("Focus Next"),
        .focus_prev => i18n.tr("Focus Prev"),
        .focus_left => i18n.tr("Focus Left"),
        .focus_right => i18n.tr("Focus Right"),
        .focus_up => i18n.tr("Focus Up"),
        .focus_down => i18n.tr("Focus Down"),
        .lock_screen => i18n.tr("Lock Screen"),
        .quit => i18n.tr("Quit"),
        .poweroff => i18n.tr("Poweroff"),
        .reboot => i18n.tr("Reboot"),
        .@"suspend" => i18n.tr("Suspend"),
        .poweroff_auto => i18n.tr("Poweroff Auto"),
        .reboot_auto => i18n.tr("Reboot Auto"),
        .suspend_auto => i18n.tr("Suspend Auto"),
        .restart_shell => i18n.tr("Restart Shell"),
        .screenshot_region => i18n.tr("Screenshot Region"),
        .screenshot_output => i18n.tr("Screenshot Output"),
        .save_layout => i18n.tr("Save Layout"),
        .restore_layout => i18n.tr("Restore Layout"),
        .undo => i18n.tr("Undo"),
        .restore_shortcuts => i18n.tr("Restore Shortcuts"),
    };
}

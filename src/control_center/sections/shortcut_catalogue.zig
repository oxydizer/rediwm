const std = @import("std");
const i18n = @import("i18n");
const config = @import("config");
const keys = config.keybinds;

fn applicable(action: keys.Action, mode: config.loader.DesktopMode) bool {
    return switch (action) {
        .set_depth, .zoom_in, .zoom_out, .zoom_reset, .camera_zoom_in, .camera_zoom_out, .camera_zoom_reset, .pan_left, .pan_right, .pan_up, .pan_down => !mode.tiled(),
        .toggle_floating, .toggle_split, .toggle_workspace_tiling, .swap_left, .swap_right, .swap_up, .swap_down, .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down, .consume_left, .consume_right, .cycle_column_width, .workspace, .move_to_workspace, .workspace_next, .workspace_prev => mode.tiled(),
        else => true,
    };
}

/// Action tags provide a stable order. Numeric preset slots and configured
/// payloads are ordered by identity within each tag.
pub fn actions(a: std.mem.Allocator, mode: config.loader.DesktopMode, binds: []const keys.Keybind) ![]keys.Action {
    var result: std.ArrayList(keys.Action) = .empty;
    inline for (@typeInfo(keys.Action).@"union".field_names) |name| {
        if (comptime @FieldType(keys.Action, name) == void and !std.mem.eql(u8, name, "noop")) {
            const action = @unionInit(keys.Action, name, {});
            if (applicable(action, mode)) try result.append(a, action);
        }
    }
    try result.appendSlice(a, &keys.launcher_actions);
    if (mode.tiled()) {
        for (1..11) |n| {
            try result.append(a, .{ .workspace = @intCast(n) });
            try result.append(a, .{ .move_to_workspace = @intCast(n) });
        }
    } else {
        for (0..5) |n| try result.append(a, .{ .set_depth = @intCast(n) });
    }
    for (binds) |bind| {
        if (bind.action == .noop) continue;
        for (result.items) |action| {
            if (keys.actionEql(action, bind.action)) break;
        } else try result.append(a, bind.action);
    }
    std.mem.sort(keys.Action, result.items, {}, lessThan);
    return result.items;
}

fn lessThan(_: void, a: keys.Action, b: keys.Action) bool {
    if (a == .close_window or b == .close_window) return a == .close_window and b != .close_window;
    const x = @backingInt(std.meta.activeTag(a));
    const y = @backingInt(std.meta.activeTag(b));
    if (x != y) return x < y;
    return switch (a) {
        .workspace => |n| n < b.workspace,
        .move_to_workspace => |n| n < b.move_to_workspace,
        .set_depth => |n| n < b.set_depth,
        .spawn => |s| std.mem.lessThan(u8, s, b.spawn),
        .save_layout => |s| std.mem.lessThan(u8, s, b.save_layout),
        .restore_layout => |s| std.mem.lessThan(u8, s, b.restore_layout),
        else => false,
    };
}

/// A later spelling of the same chord wins in the runtime lookup.
pub fn effectiveIndices(a: std.mem.Allocator, binds: []const keys.Keybind) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    for (binds, 0..) |bind, i| {
        const chord = keys.pack(bind.modifiers, bind.sym);
        for (binds[i + 1 ..]) |later| {
            if (keys.pack(later.modifiers, later.sym) == chord) break;
        } else try indices.append(a, i);
    }
    std.mem.sort(usize, indices.items, binds, chordLessThan);
    return indices.items;
}

fn chordLessThan(binds: []const keys.Keybind, x: usize, y: usize) bool {
    return keys.pack(binds[x].modifiers, binds[x].sym) < keys.pack(binds[y].modifiers, binds[y].sym);
}

test "catalogue order and action identities survive binding removal and reorder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = (try keys.parseKeybind("q")).sym;
    const f = (try keys.parseKeybind("f")).sym;
    const f4 = (try keys.parseKeybind("F4")).sym;
    const configured: []const keys.Keybind = &.{
        .{ .sym = q, .action = .close_window },
        .{ .sym = f, .action = .toggle_fullscreen },
        .{ .sym = f4, .action = .close_window },
    };
    const empty = try actions(a, .canvas, &.{});
    const joined = try actions(a, .canvas, configured);
    const reordered = try actions(a, .canvas, configured[1..]);
    try std.testing.expectEqual(empty.len, joined.len);
    for (empty, joined, reordered) |x, y, z| {
        try std.testing.expect(keys.actionEql(x, y) and keys.actionEql(x, z));
    }
    try std.testing.expectEqual(@as(usize, 3), (try effectiveIndices(a, configured)).len);
    const disabled: []const keys.Keybind = &.{ configured[0], .{ .sym = q, .action = .noop } };
    try std.testing.expectEqualSlices(usize, &.{1}, try effectiveIndices(a, disabled));
    try std.testing.expect(applicable(.{ .set_depth = 0 }, .canvas));
    try std.testing.expect(!applicable(.{ .set_depth = 0 }, .workspaces));
    try std.testing.expect(applicable(.{ .workspace = 1 }, .workspaces));
}

pub fn group(action: keys.Action) usize {
    return switch (action) {
        .toggle_floating, .toggle_split, .toggle_workspace_tiling, .swap_left, .swap_right, .swap_up, .swap_down, .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down, .consume_left, .consume_right, .cycle_column_width, .toggle_desktop_mode, .close_window, .toggle_fullscreen, .toggle_maximize, .tile_left, .tile_right, .tile_up, .tile_down => 0,
        .toggle_overview, .set_depth, .zoom_in, .zoom_out, .zoom_reset, .camera_zoom_in, .camera_zoom_out, .camera_zoom_reset, .pan_left, .pan_right, .pan_up, .pan_down, .focus_next, .focus_prev, .focus_left, .focus_right, .focus_up, .focus_down, .save_layout, .restore_layout, .undo => 1,
        .toggle_start_menu, .input_source_next, .input_source_prev => 2,
        .screenshot_region, .screenshot_output => 3,
        .volume_up, .volume_down, .volume_mute, .mic_mute, .brightness_up, .brightness_down, .power_profile_cycle => 4,
        .workspace, .move_to_workspace, .workspace_next, .workspace_prev => 6,
        .spawn => if (keys.isBuiltIn(action)) 2 else 7,
        .noop => 8,
        else => 5,
    };
}
pub fn description(action: keys.Action, buf: []u8) []const u8 {
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
        .consume_left => i18n.tr("Scrolling: join the column to the left, or leave a shared column."),
        .consume_right => i18n.tr("Scrolling: join the column to the right, or leave a shared column."),
        .cycle_column_width => i18n.tr("Scrolling: step the focused column through the preset widths."),
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
        .toggle_overview => i18n.tr("Spread all canvas windows into a grid, including minimized windows. On a scrolling workspace, show its whole strip."),
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
        .toggle_desktop_mode => i18n.tr("Switch between Canvas and Workspaces."),
        .quit => i18n.tr("Log out of the desktop session."),
        .poweroff, .poweroff_auto => i18n.tr("Shut down the computer."),
        .reboot, .reboot_auto => i18n.tr("Restart the computer."),
        .@"suspend", .suspend_auto => i18n.tr("Put the computer to sleep."),
        .restart_shell => i18n.tr("Restart the desktop shell."),
        .spawn => |cmd| cmd,
        .toggle_start_menu => i18n.tr("Open or close the application launcher."),
        .close_window => i18n.tr("Close the focused window."),
        .screenshot_region => i18n.tr("Capture a region of your screen."),
        .screenshot_output => i18n.tr("Capture the current display."),
        .lock_screen => i18n.tr("Lock the session and turn off the display."),
    };
}

pub fn title(action: keys.Action, buf: []u8) []const u8 {
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
        .consume_left => i18n.tr("Consume or Expel Left"),
        .consume_right => i18n.tr("Consume or Expel Right"),
        .cycle_column_width => i18n.tr("Cycle Column Width"),
        .noop => i18n.tr("Noop"),
        .workspace => |n| i18n.fmt(buf, i18n.tr("Workspace {n}"), .{ .n = n }) catch i18n.tr("Workspace"),
        .move_to_workspace => |n| i18n.fmt(buf, i18n.tr("Move To Workspace {n}"), .{ .n = n }) catch i18n.tr("Move To Workspace"),
        .workspace_next => i18n.tr("Workspace Next"),
        .workspace_prev => i18n.tr("Workspace Prev"),
        .toggle_desktop_mode => i18n.tr("Switch Desktop Mode"),
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
        .spawn => |cmd| if (std.mem.eql(u8, cmd, "default-terminal"))
            i18n.tr("Open Terminal")
        else if (std.mem.eql(u8, cmd, "default-file-manager"))
            i18n.tr("Open File Manager")
        else if (std.mem.eql(u8, cmd, "firefox"))
            i18n.tr("Open Firefox")
        else
            i18n.tr("Spawn"),
        .close_window => i18n.tr("Close Window"),
        .toggle_fullscreen => i18n.tr("Toggle Fullscreen"),
        .toggle_maximize => i18n.tr("Toggle Maximize"),
        .tile_left => i18n.tr("Tile Left"),
        .tile_right => i18n.tr("Tile Right"),
        .tile_up => i18n.tr("Tile Up"),
        .tile_down => i18n.tr("Tile Down"),
        .toggle_start_menu => i18n.tr("Toggle Launcher"),
        .open_system_monitor => i18n.tr("Open System Monitor"),
        .set_depth => |n| i18n.fmt(buf, i18n.tr("Set Depth {depth}"), .{ .depth = n }) catch i18n.tr("Set Depth"),
        .zoom_in => i18n.tr("Zoom In"),
        .zoom_out => i18n.tr("Zoom Out"),
        .zoom_reset => i18n.tr("Zoom Reset"),
        .toggle_overview => i18n.tr("Window Overview"),
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

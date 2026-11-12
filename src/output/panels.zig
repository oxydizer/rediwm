//! Output panels: start menu, control center, power menu and taskbar popups.

const std = @import("std");
const Output = @import("../Output.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const StartMenu = @import("../start_menu/panel.zig").StartMenu;
const PowerMenu = @import("../power_menu.zig").PowerMenu;
const Taskbar = @import("../Taskbar.zig");
const anim = @import("ui").anim;
const log = std.log.scoped(.output);

/// Opens (creating one if needed), closes, or cancels-and-reopens the
/// start menu, and keeps the taskbar's start button state in sync either
/// way. The single entry point for the start button's click handler.
pub fn toggleStartMenu(output: *Output) void {
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.start_menu) |sm| {
        if (sm.state != .closing) {
            output.closeStartMenu();
            return;
        }
    }
    output.openStartMenu();
}

/// Opens the start menu, reversing an in-flight close rather than waiting for
/// it to finish — the panel is still alive, so there is nothing to rebuild.
///
/// Every "open" path has to come through here. `closeStartMenu` drops
/// `input.open_start_menu` immediately, so that keystrokes during the close
/// slide reach the window underneath rather than a panel that is going away;
/// restoring it is therefore part of opening, and a caller that only called
/// `StartMenu.reopen` got a visible menu that no key could reach.
pub fn openStartMenu(output: *Output) void {
    output.openMenu(.start);
}

/// The keyboard launcher shares catalogue, focus and lifetime with Start.
pub fn toggleAppLauncher(output: *Output) void {
    if (output.start_menu) |sm| {
        if (sm.mode == .launcher and sm.state != .closing) {
            output.closeStartMenu();
            return;
        }
    }
    output.openMenu(.launcher);
}

pub fn openMenu(output: *Output, mode: StartMenu.Mode) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.server.input.open_start_menu) |other| {
        if (other.wlr_output != output.wlr_output) {
            if (Output.fromWlr(other.wlr_output)) |owner| owner.closeStartMenu();
        }
    }
    if (output.start_menu) |sm| {
        if (sm.mode != mode) {
            sm.mode = mode;
            sm.buildTree();
            sm.relayout();
        } else if (sm.state != .closing) return;
        sm.reopen();
    } else {
        if (output.power_menu != null) output.closePowerMenu();
        output.start_menu = StartMenu.createMode(output.server, output.wlr_output, mode) catch |err| blk: {
            log.err("openStartMenu: could not create panel: {}", .{err});
            break :blk null;
        };
    }
    output.server.input.open_start_menu = output.start_menu;
    if (output.start_menu) |sm| sm.buffer_node.node.raiseToTop();
    if (output.taskbar) |bar| {
        bar.start.open = true;
        bar.start.open_amt.retargetTo(Taskbar.nowMs(), 1, anim.curveFor(.start_button));
        bar.markDirty(Taskbar.paint_start);
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn closeStartMenu(output: *Output) void {
    const sm = output.start_menu orelse return;
    output.server.input.dock_drag.cancel(&output.server.input);
    sm.beginClose();
    if (output.server.input.open_start_menu == sm) {
        output.server.input.open_start_menu = null;
    }
    if (output.taskbar) |bar| {
        bar.start.open = false;
        bar.start.open_amt.retargetTo(Taskbar.nowMs(), 0, anim.curveFor(.start_button));
        bar.markDirty(Taskbar.paint_start);
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn syncStartMenu(output: *Output) void {
    if (output.start_menu) |sm| sm.relayout();
}

/// Opens or raises settings, reversing an in-flight close if needed.
/// Opens the settings window on this output, or raises (and restores) the
/// existing one wherever it is. It keeps its page, position and size.
pub fn toggleControlCenter(output: *Output) void {
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.start_menu != null) output.closeStartMenu();
    if (output.power_menu != null) output.closePowerMenu();
    if (output.server.input.open_control_center) |cc| {
        cc.present();
    } else {
        _ = ControlCenter.create(output.server, output.wlr_output) catch |err| {
            log.err("openControlCenter: could not create settings window: {}", .{err});
        };
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

/// Opens Settings on its Network page.
pub fn openNetworkSettings(output: *Output) void {
    output.toggleControlCenter();
    if (output.server.input.open_control_center) |cc| cc.selectPage(.network);
}

/// Opens Settings on its Region & Language page (the input source list).
pub fn openInputSettings(output: *Output) void {
    output.toggleControlCenter();
    if (output.server.input.open_control_center) |cc| cc.selectPage(.region);
}

/// Closes the settings window, like its titlebar close button.
pub fn closeControlCenter(output: *Output) void {
    const cc = output.server.input.open_control_center orelse return;
    cc.close();
    output.wlr_output.scheduleFrame();
}

/// Opens (creating one if needed) or closes the power menu modal, and closes
/// the start menu first — the single entry point for the
/// start menu's power button click handler.
pub fn openPowerMenu(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.power_menu != null) return;
    if (output.start_menu != null) output.closeStartMenu();
    output.power_menu = PowerMenu.create(output.server, output.wlr_output) catch |err| blk: {
        log.err("openPowerMenu: could not create panel: {}", .{err});
        break :blk null;
    };
    output.server.input.open_power_menu = output.power_menu;
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn closePowerMenu(output: *Output) void {
    const pm = output.power_menu orelse return;
    pm.beginClose();
    if (output.server.input.open_power_menu == pm) {
        output.server.input.open_power_menu = null;
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn syncPowerMenu(output: *Output) void {
    if (output.server.polkit_dialog) |dialog| dialog.relayout();
    if (output.power_menu) |pm| pm.relayout();
}

pub fn closeCalendar(output: *Output) void {
    const calendar = output.calendar orelse return;
    output.calendar = null;
    calendar.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleCalendar(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.calendar != null) {
        output.closeCalendar();
        return;
    }
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    output.closeStartMenu();
    output.closePowerMenu();
    output.calendar = @import("../calendar.zig").Calendar.create(output) catch return;
    output.server.input.open_calendar = output.calendar;
}

pub fn closeBattery(output: *Output) void {
    const popup = output.battery_popup orelse return;
    output.battery_popup = null;
    popup.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleBattery(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.battery_popup != null) {
        output.closeBattery();
        return;
    }
    if (output.server.input.open_battery) |other| other.output.closeBattery();
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    output.closeStartMenu();
    output.closePowerMenu();
    output.battery_popup = @import("../battery_popup.zig").Popup.create(output) catch return;
    output.server.input.open_battery = output.battery_popup;
}

pub fn closeWifi(output: *Output) void {
    const popup = output.wifi_popup orelse return;
    output.wifi_popup = null;
    popup.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleWifi(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.wifi_popup != null) {
        output.closeWifi();
        return;
    }
    if (output.server.input.open_wifi) |other| other.output.closeWifi();
    if (output.server.input.open_battery) |other| other.output.closeBattery();
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    if (output.server.input.open_start_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closeStartMenu();
    if (output.server.input.open_power_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closePowerMenu();
    if (output.server.tray) |tray| tray.closeMenu();
    output.wifi_popup = @import("../network/popup.zig").Popup.create(output) catch return;
    output.server.input.open_wifi = output.wifi_popup;
    if (output.server.network) |manager| manager.opened();
}

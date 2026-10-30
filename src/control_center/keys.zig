//! Page selection, search pages and keyboard navigation.

const std = @import("std");
const wlr = @import("wlroots");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const ui = @import("ui");
const appearance_section = @import("sections/appearance.zig");
const users_section = @import("sections/users.zig");
const bluetooth_section = @import("sections/bluetooth.zig");
const network_section = @import("sections/network.zig");
const settings_search = @import("search.zig");
const Page = @import("search_index.zig").Page;
const panel = @import("panel.zig");
const default_width = panel.default_width;
const ControlCenter = @import("ControlCenter.zig");

pub fn selectPage(cc: *ControlCenter, page: Page) void {
    if (cc.search.query().len > 0) settings_search.clear(cc);
    cc.search.built_empty = false;
    cc.search.restore_scroll = false;
    cc.selectSearchPage(page);
}

/// Search and filtered sidebar navigation keep the query and its focus.
pub fn selectSearchPage(cc: *ControlCenter, page: Page) void {
    cc.shortcuts.cancel();
    // The service list is only kept live while its page is on screen.
    if (cc.page == .services and page != .services) if (cc.systemd_client) |client| client.hide();
    if (cc.page == .printers and page != .printers) cc.printers.hide();
    if (cc.page == .network and page != .network) cc.network.clearForm();
    if (cc.page == .bluetooth and page != .bluetooth) {
        if (cc.server.bluetooth) |m| m.closed();
        cc.bluetooth.clearPin();
    }
    if (cc.page != page) if (cc.navIndex(page)) |row| cc.nav_selection.retargetTo(anim.nowMs(), @floatFromInt(row), anim.curveFor(.start_glide));
    cc.page = page;
    if (page == .power) cc.server.keyboard_brightness.query(cc.server);
    if (page == .bluetooth and !cc.server.greeter_mode) {
        if (cc.panel_box.width == default_width) _ = cc.toplevel.requestSize(1120, cc.panel_box.height);
        if (cc.server.bluetooth) |m| m.opened() else cc.server.bluetooth = @import("../bluetooth.zig").Manager.create(cc.server) catch null;
    }
    if (page == .network or page == .printers) {
        // Start wide enough for the two columns; narrower resized windows
        // stack them and keep the same controls accessible.
        if (cc.panel_box.width == default_width) _ = cc.toplevel.requestSize(1120, cc.panel_box.height);
        if (page == .network) if (cc.server.network) |manager| manager.opened();
    }
    if (cc.panel_box.width < cc.minimumWidth() or cc.panel_box.height < cc.minimumHeight()) {
        _ = cc.toplevel.requestSize(@max(cc.panel_box.width, cc.minimumWidth()), @max(cc.panel_box.height, cc.minimumHeight()));
    }
    cc.relayout();
    cc.scheduleFrame();
}

pub fn refresh(cc: *ControlCenter) void {
    cc.refresh_pending = true;
    cc.scheduleFrame();
}

pub fn selectDisplayOutput(cc: *ControlCenter, name: []const u8) void {
    cc.selected_output_name_len = @min(name.len, cc.selected_output_name.len);
    @memcpy(cc.selected_output_name[0..cc.selected_output_name_len], name[0..cc.selected_output_name_len]);
    cc.refresh();
}

pub fn selectedDisplayOutput(cc: *ControlCenter) ?*wlr.Output {
    if (cc.selected_output_name_len > 0) {
        const name = cc.selected_output_name[0..cc.selected_output_name_len];
        if (cc.server.findOutputByName(name)) |output| return output.wlr_output;
    }
    return cc.wlr_output;
}

/// A search only covers the current page when there are no matches.
pub fn showingPage(cc: *const ControlCenter, page: Page) bool {
    return !cc.is_welcome and !cc.search.empty() and cc.page == page;
}

pub fn focusSearch(cc: *ControlCenter) void {
    settings_search.focus(cc);
}

pub fn selectKey(cc: *ControlCenter, key: ui.input.Key, shift: bool) bool {
    if (settings_search.key(cc, key, shift)) return true;
    if (cc.page != .input and cc.page != .displays and cc.page != .appearance and cc.page != .desktop and cc.page != .general and cc.page != .users and cc.page != .services and cc.page != .printers and cc.page != .network and cc.page != .bluetooth and cc.page != .region and cc.page != .power) return false;
    const dispatcher = &ui.input.current;
    if (cc.page == .appearance) {
        if (appearance_section.itemKey(&cc.appearance, key)) return true;
        if (key == .tab) {
            _ = dispatcher.focusNext(&cc.root, shift);
            cc.requestWidgetRepaint();
            return true;
        }
        if (dispatcher.focused) |widget| {
            if (widget.kind == .checkbox and (key == .enter or (key == .char and std.mem.eql(u8, key.char, " ")))) {
                @import("ui").widgets.checkbox.toggle(widget);
                cc.requestWidgetRepaint();
                return true;
            }
        }
    }
    if (cc.is_welcome or cc.page == .input or cc.page == .users or cc.page == .services or cc.page == .printers or cc.page == .network or cc.page == .bluetooth or cc.page == .region or cc.page == .power) {
        const focused = dispatcher.focused;
        if (cc.page == .bluetooth and bluetooth_section.key(cc, key)) return true;
        if (cc.page == .network and (focused == null or focused.?.kind != .select or !focused.?.kind.select.open)) {
            if (network_section.key(cc, key)) return true;
        }
        if (key == .tab) {
            if (focused) |widget| {
                if (widget.kind == .select and widget.kind.select.open) {
                    _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                }
            }
            _ = dispatcher.focusNext(&cc.root, shift);
            cc.requestWidgetRepaint();
            return true;
        }
        if (cc.page == .users and key == .escape and cc.users.form != .none) {
            if (focused) |widget| {
                if (widget.kind == .select and widget.kind.select.open) {
                    _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                    cc.requestWidgetRepaint();
                    return true;
                }
            }
            if (users_section.escapeForm(cc)) return true;
        }
        if (focused) |widget| {
            const activate = key == .enter or (key == .char and std.mem.eql(u8, key.char, " "));
            if (activate and widget.kind == .button) {
                const button = widget.kind.button;
                if (button.state == .disabled) return true;
                if (button.on_click) |callback| callback(button.owner, button.id);
                cc.requestWidgetRepaint();
                return true;
            }
            if (activate and widget.kind == .row) {
                const row = widget.kind.row;
                if (row.state != .disabled) if (row.on_click) |callback| callback(row.owner, row.id);
                cc.applyPending();
                cc.requestWidgetRepaint();
                return true;
            }
            if (activate and widget.kind == .checkbox) {
                if (widget.kind.checkbox.disabled) return true;
                widget.kind.checkbox.checked = !widget.kind.checkbox.checked;
                const data = widget.kind.checkbox;
                widget.markDirty();
                data.on_change(data.owner, data.id, data.checked);
                cc.requestWidgetRepaint();
                return true;
            }
            if (activate and widget.kind == .toggle) {
                ui.widgets.toggle.toggle(widget);
                cc.requestWidgetRepaint();
                return true;
            }
            if (widget.kind == .text_input or widget.kind == .secret_input) {
                _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                cc.requestWidgetRepaint();
                return true;
            }
            if (widget.kind == .select and widget.kind.select.open) {
                _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
                cc.applyPending();
                cc.requestWidgetRepaint();
                return true;
            }
        }
        if (focused) |widget| {
            if (widget.kind != .select) return false;
        } else return false;
    }
    if (key == .tab and cc.page == .displays) {
        var index: usize = if (shift) 0 else 4;
        for (0..5) |i| {
            if (dispatcher.focused == &cc.display.row_children[i][1]) index = i;
        }
        for (0..5) |_| {
            index = if (shift) (index + 4) % 5 else (index + 1) % 5;
            const next = &cc.display.row_children[index][1];
            if (next.kind == .select and !next.kind.select.disabled) {
                dispatcher.focus(&cc.root, next);
                break;
            }
        }
        cc.requestWidgetRepaint();
        return true;
    }
    const focused = dispatcher.focused orelse return false;
    if (focused.kind != .select) return false;
    if (key == .escape and !focused.kind.select.open) return false;
    _ = dispatcher.keyEvent(gpa, key, .{ .shift = shift }) catch return true;
    cc.applyPending();
    cc.requestWidgetRepaint();
    return true;
}

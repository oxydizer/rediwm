//! Appearance app colours: applying the accent to GTK and Qt apps and reporting the result.

const i18n = @import("i18n");
const std = @import("std");
const layout = @import("ui").layout;
const theme = @import("ui").theme;
const Widget = layout.Widget;
const manager = @import("../../config_runtime/app_colors.zig");
const setting_save = @import("config").setting_save;
const main = @import("../../main.zig");
const section = @import("appearance_dock.zig").section;
const Section = @import("appearance.zig").Section;

pub fn appColorsNote(s: *Section, a: std.mem.Allocator, color: [4]f32) Widget {
    const message = status(s);
    const text = @import("ui").text;
    const width: f32 = @floatFromInt(@max(120, s.cc.panel_box.width - @as(i32, if (s.cc.panel_box.width < 660) 70 else 238) - 100));
    var lines: std.ArrayList(Widget) = .empty;
    var start: usize = 0;
    var words = std.mem.tokenizeScalar(u8, message, ' ');
    var end: usize = 0;
    while (words.next()) |word| {
        const next = @intFromPtr(word.ptr) - @intFromPtr(message.ptr) + word.len;
        const measured = text.measureWidthF(message[start..next], .manrope, theme.global.settings_description_size, 1) catch 0;
        if (end > start and measured > width) {
            lines.append(a, .{ .name = std.fmt.allocPrint(a, "app_colors_status_{d}", .{lines.items.len}) catch "app_colors_status_line", .kind = .{ .text = .{ .content = message[start..end], .font_size = theme.global.settings_description_size, .color = color } } }) catch break;
            start = next - word.len;
        }
        end = next;
    }
    if (end > start) lines.append(a, .{ .name = std.fmt.allocPrint(a, "app_colors_status_{d}", .{lines.items.len}) catch "app_colors_status_line", .kind = .{ .text = .{ .content = message[start..end], .font_size = theme.global.settings_description_size, .color = color } } }) catch {};
    return .{ .name = "app_colors_status", .kind = .container, .direction = .column, .gap = 2, .children = lines.toOwnedSlice(a) catch &.{} };
}

pub fn onApplyAppColors(owner: ?*anyopaque, id: usize) void {
    const s = section(owner);
    const server = s.cc.server;
    if (server.app_colors.job != null or server.config.compositor.follow_app_colors) return;
    s.app_colors_message = "";
    manager.start(server, if (id == 0) .gtk else .qt) catch |err| manager.fail(server, err);
}

pub fn onFollowChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s = section(owner);
    const server = s.cc.server;
    if (server.greeter_mode) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "follow_app_colors", on) catch |err| {
        s.app_colors_message = i18n.fmt(&s.app_colors_message_buf, i18n.tr("Could not save application color preference: {reason}."), .{ .reason = @errorName(err) }) catch "";
        s.cc.refresh();
        return;
    };
    server.config.compositor.follow_app_colors = on;
    s.app_colors_message = "";
    manager.sync(server);
    s.cc.refresh();
}

fn status(s: *Section) []const u8 {
    if (s.app_colors_message.len > 0) return s.app_colors_message;
    const state = &s.cc.server.app_colors;
    if (state.job != null) return i18n.tr("Applying app colors…");
    if (state.failure) |err| return failure(s, err);
    if (s.cc.server.config.compositor.follow_app_colors) {
        if (state.result) |result| {
            if (result.qt_error) |err| return failure(s, err);
            if (!result.gtk_notified) return i18n.tr("Following application colors. GTK live updates are unavailable; restart GTK apps after theme changes. Choose GTK in Brave or Chrome, System theme in Firefox, or Linux in Falkon.");
            if (!result.support.qt5 and !result.support.qt6) return i18n.tr("Following GTK colors. Install qt5ct or qt6ct to include Qt apps. Choose GTK in Brave or Chrome, or System theme in Firefox; restart apps once if needed.");
        }
        return i18n.tr("Following the main theme. Choose GTK in Brave or Chrome, System theme in Firefox, or Linux in Falkon. Restart apps once if needed; apps with their own styles may differ.");
    }
    if (state.result) |result| {
        switch (state.action orelse return "") {
            .gtk => return i18n.tr("GTK colors applied. Restart GTK apps. Apps with their own styles or sandbox settings may differ."),
            .qt => return if (result.support.qt5 and result.support.qt6)
                i18n.tr("Qt 5 and Qt 6 colors applied. Restart apps; sign in again if their colors do not change.")
            else if (result.support.qt6)
                i18n.tr("Qt 6 colors applied. Install qt5ct for Qt 5 apps. Restart apps; sign in again if their colors do not change.")
            else
                i18n.tr("Qt 5 colors applied. Install qt6ct for Qt 6 apps. Restart apps; sign in again if their colors do not change."),
            .follow => return i18n.tr("Automatic updates are off. Applications keep the last applied colors."),
        }
    }
    return i18n.tr("Uses the main theme. Apply again after changing it; restart apps to see the colors.");
}

fn failure(s: *Section, err: anyerror) []const u8 {
    return switch (err) {
        error.QtToolsMissing => i18n.tr("Install qt5ct for Qt 5 apps or qt6ct for Qt 6 apps, then apply again."),
        error.ManagedSymlink => i18n.tr("A toolkit config folder is a symlink. Apply the colors in its real location, or make it a regular folder."),
        error.InvalidManagedCss => i18n.tr("The RediWM block in gtk.css is incomplete. Repair it before applying colors."),
        else => i18n.fmt(&s.app_colors_message_buf, i18n.tr("Could not apply app colors: {reason}. Check your configuration files and permissions."), .{ .reason = @errorName(err) }) catch i18n.tr("Could not apply app colors. Check your configuration files and permissions."),
    };
}

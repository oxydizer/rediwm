//! Files' folder tabs in the compositor's titlebar (`ui/client_tabs.zig`). The
//! strip exists only under server-side decorations and outside a file chooser;
//! otherwise Files has no tabs to show, and the tab keys do nothing.
const std = @import("std");
const ClientTabs = @import("ui").client_tabs;
const Client = @import("Client.zig");
const app_tabs = @import("app_tabs.zig");

pub fn attach(self: *Client) void {
    self.tabs.attach(self.surface, .{
        .ctx = self,
        .select = select,
        .close = close,
        .new_tab = newTab,
        .move = move,
        .leading = leading,
    });
}

fn client(ctx: *anyopaque) *Client {
    return @ptrCast(@alignCast(ctx));
}

fn select(ctx: *anyopaque, id: u32) void {
    const app = &client(ctx).app;
    const i = app.findFolderTab(id) orelse return;
    app.switchTab(i);
}

fn close(ctx: *anyopaque, id: u32) void {
    const app = &client(ctx).app;
    const i = app.findFolderTab(id) orelse return;
    app.closeTab(i);
}

fn newTab(ctx: *anyopaque) void {
    client(ctx).app.newTab();
}

fn move(ctx: *anyopaque, id: u32, index: u32) void {
    const app = &client(ctx).app;
    const from = app.findFolderTab(id) orelse return;
    app.moveTab(from, index);
}

/// The application icon in the titlebar opens the application menu under it.
fn leading(ctx: *anyopaque, x: i32, _: i32, _: i32, _: i32) void {
    client(ctx).app.toggleAppMenu(@floatFromInt(@max(0, x)));
}

/// Shows the strip in the titlebar or takes it back, and keeps it current.
/// Cheap to call often: an unchanged strip sends nothing.
pub fn sync(self: *Client) void {
    const app = &self.app;
    const want = self.tabs.strip != null and self.decoration_mode == .server_side and app.chooser == null;
    app.tabs_visible = want;
    if (self.tabs.strip == null) return;
    if (!want) {
        self.tabs.publish(&.{}, 0, false);
        return;
    }
    app.ensureTabs();
    var list: [app_tabs.max_tabs]ClientTabs.Tab = undefined;
    const count = @min(app.tabs.items.len, app_tabs.max_tabs);
    for (app.tabs.items[0..count], 0..) |t, i| {
        const title = app.tabTitle(i);
        list[i] = .{ .id = @truncate(t.id), .title = if (std.unicode.utf8ValidateSlice(title)) title else "?" };
    }
    self.tabs.publish(list[0..count], @truncate(app.tabs.items[@min(app.tab_selected, count - 1)].id), true);
}

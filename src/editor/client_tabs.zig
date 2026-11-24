//! The editor's tabs in the compositor's titlebar (`ui/client_tabs.zig`). The
//! strip exists only under server-side decorations; otherwise, or with more
//! tabs than the protocol carries, the window keeps drawing its own.
const std = @import("std");
const ClientTabs = @import("ui").client_tabs;
const i18n = @import("i18n");
const tr = i18n.tr;
const main_mod = @import("main.zig");
const Client = main_mod.Client;

/// The protocol's limit on tabs in one commit.
const max_tabs = 128;

pub fn attach(self: *Client) void {
    self.tabs.attach(self.surface, .{
        .ctx = self,
        .select = select,
        .close = close,
        .new_tab = newTab,
        .move = move,
        .leading = leading,
        .tear_off = tearOff,
        .drop_on = dropOn,
    });
}

fn client(ctx: *anyopaque) *Client {
    return @ptrCast(@alignCast(ctx));
}

fn select(ctx: *anyopaque, id: u32) void {
    const app = &client(ctx).app;
    if (app.close_tab != null) return;
    const i = app.findTab(id) orelse return;
    app.selected = i;
    app.changed();
}

fn close(ctx: *anyopaque, id: u32) void {
    const app = &client(ctx).app;
    if (app.close_tab != null) return;
    const i = app.findTab(id) orelse return;
    app.selected = i;
    app.changed();
    app.closeSelected();
}

fn newTab(ctx: *anyopaque) void {
    client(ctx).app.act(.new);
}

/// Moves the tab so that it ends at `index`; the selection stays on the same tab.
fn move(ctx: *anyopaque, id: u32, index: u32) void {
    const app = &client(ctx).app;
    if (app.close_tab != null or app.tabs.items.len == 0) return;
    const from = app.findTab(id) orelse return;
    const to = @min(@as(usize, index), app.tabs.items.len - 1);
    if (from == to) return;
    const selected_id = app.tabs.items[app.selected].id;
    const tab = app.tabs.orderedRemove(from);
    app.tabs.insertAssumeCapacity(to, tab);
    app.selected = app.findTab(selected_id) orelse 0;
    app.changed();
}

/// The strip asked for this tab in a window of its own. The event loop opens it:
/// a window cannot be made from inside an event.
fn tearOff(ctx: *anyopaque, id: u32, _: i32, _: i32) void {
    const app = &client(ctx).app;
    if (!app.movable() or app.tabs.items.len < 2 or app.findTab(id) == null) return;
    app.tear_tab = id;
}

/// The tab was dropped on another of this program's windows.
fn dropOn(ctx: *anyopaque, id: u32, target: ?*@import("wayland").client.rediwm.TitlebarTabsV1, index: u32) void {
    const from = client(ctx);
    const strip = target orelse return;
    const to = for (main_mod.open_windows.items) |w| {
        if (w.tabs.strip == strip) break w;
    } else return;
    if (to == from or !from.app.movable() or !to.app.movable() or to.app.closed) return;
    const tab = from.app.takeTab(id) orelse return;
    to.app.adoptTab(tab, index) catch {
        tab.deinit();
        return;
    };
}

fn leading(ctx: *anyopaque, x: i32, _: i32, _: i32, _: i32) void {
    const app = &client(ctx).app;
    // The button's own press closes an open menu rather than reopening it.
    app.openMenuAt(@floatFromInt(@max(0, x)));
}

/// Shows the strip in the titlebar or takes it back, and keeps it current.
/// Cheap to call often: an unchanged strip sends nothing.
pub fn sync(self: *Client) void {
    const app = &self.app;
    const want = self.tabs.strip != null and self.decoration_mode == .server_side and
        !self.fullscreen and app.tabs.items.len > 0 and app.tabs.items.len <= max_tabs;
    if (app.strip_in_titlebar != want) {
        app.strip_in_titlebar = want;
        app.dirty = true;
        // Sizes and the view's top depend on it.
        app.changed();
    }
    if (self.tabs.strip == null) return;
    if (!want) {
        self.tabs.publish(&.{}, 0, false);
        return;
    }
    var list: [max_tabs]ClientTabs.Tab = undefined;
    for (app.tabs.items, 0..) |t, i| {
        const name = t.name();
        list[i] = .{
            .id = @truncate(t.id),
            .title = if (std.unicode.utf8ValidateSlice(name)) name else tr("Text file"),
            .modified = t.doc.modified(),
        };
    }
    self.tabs.publish(list[0..app.tabs.items.len], @truncate(app.tabs.items[app.selected].id), true);
}

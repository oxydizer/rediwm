//! Client side of rediwm_titlebar_tabs_v1: an app publishes its tabs and the
//! compositor paints them in the titlebar and sends the user's actions back.
//! Mirrors `client_cursor.zig`: call `bind` from the registry handler, `attach`
//! once the wl_surface exists, `publish` whenever the tabs change, and
//! `deinit` on shutdown. The strip only exists under server-side decorations,
//! so an app keeps drawing its own tabs when `available()` is false or the
//! titlebar is its own.
const std = @import("std");
const wl = @import("wayland").client.wl;
const rediwm = @import("wayland").client.rediwm;
const Self = @This();

pub const max_title = 256;
pub const flag_modified: u32 = 1;
pub const flag_attention: u32 = 2;

/// Ids are the app's own and must not be zero.
pub const Tab = struct {
    id: u32,
    title: []const u8,
    modified: bool = false,
    attention: bool = false,
    /// An icon-theme name shown before the title; empty for the application's icon.
    icon: []const u8 = "",
};

/// What the user did in the strip. The app changes its state and publishes the
/// result; the compositor never changes the selection itself.
pub const Handler = struct {
    ctx: *anyopaque,
    select: *const fn (ctx: *anyopaque, id: u32) void,
    close: *const fn (ctx: *anyopaque, id: u32) void,
    new_tab: *const fn (ctx: *anyopaque) void,
    /// `index` is where the tab lands once removed from its old place.
    move: *const fn (ctx: *anyopaque, id: u32, index: u32) void,
    /// The leading button's rectangle in surface coordinates (y is negative).
    leading: *const fn (ctx: *anyopaque, x: i32, y: i32, width: i32, height: i32) void,
    /// The tab was dragged out and dropped in empty space: open a window for it.
    /// `x`, `y` are the pointer in layout coordinates. Needs a compositor
    /// that offers version 2; set together with `drop_on`.
    tear_off: ?*const fn (ctx: *anyopaque, id: u32, x: i32, y: i32) void = null,
    /// The tab was dropped on `target`, another strip of this client, at `index`.
    drop_on: ?*const fn (ctx: *anyopaque, id: u32, target: ?*rediwm.TitlebarTabsV1, index: u32) void = null,
};

manager: ?*rediwm.TitlebarTabsManagerV1 = null,
strip: ?*rediwm.TitlebarTabsV1 = null,
handler: ?Handler = null,
/// Hash of what was last committed, so an unchanged strip sends nothing.
last: ?u64 = null,

pub fn bind(self: *Self, registry: *wl.Registry, name: u32, interface: []const u8, version: u32) void {
    if (std.mem.eql(u8, interface, "rediwm_titlebar_tabs_manager_v1") and self.manager == null) {
        self.manager = registry.bind(name, rediwm.TitlebarTabsManagerV1, @min(version, 2)) catch null;
    }
}

/// Whether the compositor offers the strip.
pub fn available(self: *const Self) bool {
    return self.manager != null;
}

/// Creates the strip for `surface`. Call once, before or after the xdg role.
/// `handler.ctx` must outlive the strip.
pub fn attach(self: *Self, surface: *wl.Surface, handler: Handler) void {
    const manager = self.manager orelse return;
    if (self.strip != null) return;
    const strip = manager.getTitlebarTabs(surface) catch return;
    strip.setListener(*Self, event, self);
    self.strip = strip;
    self.handler = handler;
    if (strip.getVersion() >= 2 and (handler.tear_off != null or handler.drop_on != null)) strip.setDetachable(1);
    self.last = null;
}

/// Replaces the strip. Sends nothing when it equals the last one published.
/// An empty `tabs` removes the strip. `selected` must be one of the ids.
pub fn publish(self: *Self, tabs: []const Tab, selected: u32, leading: bool) void {
    const strip = self.strip orelse return;
    const digest = signature(tabs, selected, leading);
    if (self.last) |last| if (last == digest) return;
    self.last = digest;
    var buf: [max_title + 1]u8 = undefined;
    var icon_buf: [max_title + 1]u8 = undefined;
    for (tabs) |tab| {
        const title = cString(&buf, tab.title);
        const icon = cString(&icon_buf, tab.icon);
        var flags: u32 = 0;
        if (tab.modified) flags |= flag_modified;
        if (tab.attention) flags |= flag_attention;
        strip.addTab(tab.id, title, if (icon.len > 0) icon else null, flags);
    }
    if (tabs.len > 0) strip.setSelected(selected);
    strip.setLeadingButton(@intFromBool(leading));
    strip.commit();
}

pub fn deinit(self: *Self) void {
    if (self.strip) |strip| strip.destroy();
    if (self.manager) |manager| manager.destroy();
    self.* = .{};
}

fn event(_: *rediwm.TitlebarTabsV1, ev: rediwm.TitlebarTabsV1.Event, self: *Self) void {
    const h = self.handler orelse return;
    switch (ev) {
        .select => |e| h.select(h.ctx, e.id),
        .close => |e| h.close(h.ctx, e.id),
        .new_tab => h.new_tab(h.ctx),
        .move => |e| h.move(h.ctx, e.id, e.index),
        .leading_activated => |e| h.leading(h.ctx, e.x, e.y, e.width, e.height),
        .tear_off => |e| if (h.tear_off) |f| f(h.ctx, e.id, e.x, e.y),
        .drop_on => |e| if (h.drop_on) |f| f(h.ctx, e.id, e.target, e.index),
    }
}

/// `text` cut to `max_title` bytes on a character boundary, NUL-terminated in `buf`.
fn cString(buf: *[max_title + 1]u8, text: []const u8) [:0]const u8 {
    var end = @min(text.len, max_title);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], text[0..end]);
    // The wire format cannot carry an interior NUL: stop at the first one.
    const len = std.mem.indexOfScalar(u8, buf[0..end], 0) orelse end;
    buf[len] = 0;
    return buf[0..len :0];
}

fn signature(tabs: []const Tab, selected: u32, leading: bool) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&selected));
    h.update(std.mem.asBytes(&leading));
    for (tabs) |tab| {
        h.update(std.mem.asBytes(&tab.id));
        h.update(std.mem.asBytes(&tab.modified));
        h.update(std.mem.asBytes(&tab.attention));
        // Titles are length-prefixed so "ab","c" differs from "a","bc".
        const n: u32 = @intCast(tab.title.len);
        h.update(std.mem.asBytes(&n));
        h.update(tab.title);
        h.update(tab.icon);
        h.update(&.{0});
    }
    return h.final();
}

test "titles are cut on a character boundary and terminated" {
    var buf: [max_title + 1]u8 = undefined;
    try std.testing.expectEqualStrings("héllo", cString(&buf, "héllo"));
    var long: [max_title + 2]u8 = undefined;
    @memset(&long, 'a');
    long[max_title - 1] = 0xC3; // a two byte character straddling the limit
    long[max_title] = 0xA9;
    const cut = cString(&buf, &long);
    try std.testing.expectEqual(@as(usize, max_title - 1), cut.len);
    try std.testing.expectEqual(@as(u8, 'a'), cut[0]);
}

test "an interior NUL ends the title" {
    var buf: [max_title + 1]u8 = undefined;
    try std.testing.expectEqualStrings("ab", cString(&buf, "ab\x00cd"));
}

test "the signature changes with any visible field" {
    const a = [_]Tab{.{ .id = 1, .title = "ab" }, .{ .id = 2, .title = "c" }};
    const b = [_]Tab{.{ .id = 1, .title = "a" }, .{ .id = 2, .title = "bc" }};
    try std.testing.expect(signature(&a, 1, false) != signature(&b, 1, false));
    try std.testing.expect(signature(&a, 1, false) != signature(&a, 2, false));
    try std.testing.expect(signature(&a, 1, false) != signature(&a, 1, true));
    try std.testing.expectEqual(signature(&a, 1, false), signature(&a, 1, false));
}

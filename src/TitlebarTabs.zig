//! rediwm_titlebar_tabs_v1: an application publishes the tabs of its window and
//! the compositor paints them in the titlebar (`chrome_tabs.zig`, geometry and
//! hit testing in `ui/widgets/title_tabs.zig`). Like the KDE decoration
//! manager, the object belongs to a wl_surface and can precede its shell role.
//! The compositor never changes what is selected: clicks go back to the
//! application as events and the strip changes when it commits.
const std = @import("std");
const wl = @import("wayland").server.wl;
const rediwm = @import("wayland").server.rediwm;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const chrome_tabs = @import("chrome_tabs.zig");
const scene_data = @import("scene_data.zig");
const window_tabs = @import("window_tabs.zig");
const gpa = @import("main.zig").gpa;

const TitlebarTabs = @This();
const Resource = rediwm.TitlebarTabsV1;
const ManagerResource = rediwm.TitlebarTabsManagerV1;

pub const max_tabs = window_tabs.max_tabs;
/// Longest title kept, in bytes.
pub const max_title = 256;
pub const flag_modified: u32 = 1;
pub const flag_attention: u32 = 2;

const Item = struct {
    id: u32,
    /// What the strip shows: the title, behind a bullet when modified.
    title: []u8,
    attention: bool,
};

resource: *Resource,
surface: ?*wlr.Surface,
toplevel: ?*Toplevel = null,
link: wl.list.Link = undefined,
surface_destroy: wl.Listener(*wlr.Surface) = .init(handleSurfaceDestroy),
pending: std.ArrayList(Item) = .empty,
pending_selected: ?u32 = null,
items: std.ArrayList(Item) = .empty,
selected: u32 = 0,

pub const Manager = struct {
    global: *wl.Global,
    strips: wl.list.Head(TitlebarTabs, .link) = undefined,

    pub fn init(self: *Manager, server: *Server) !void {
        self.* = .{ .global = try wl.Global.create(server.wl_server, ManagerResource, 1, *Manager, self, bind) };
        self.strips.init();
    }

    pub fn deinit(self: *Manager) void {
        self.global.destroy();
        while (self.strips.first()) |strip| strip.resource.destroy();
    }

    /// Called for each new toplevel: adopts a strip created before the shell role.
    pub fn attach(self: *Manager, toplevel: *Toplevel) void {
        var it = self.strips.iterator(.forward);
        while (it.next()) |strip| {
            if (strip.surface == toplevel.surface()) {
                strip.toplevel = toplevel;
                toplevel.titlebar_tabs = strip;
                return;
            }
        }
    }

    fn bind(client: *wl.Client, self: *Manager, version: u32, id: u32) void {
        const resource = ManagerResource.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        resource.setHandler(*Manager, handleRequest, null, self);
    }

    fn handleRequest(manager: *ManagerResource, request: ManagerResource.Request, self: *Manager) void {
        switch (request) {
            .destroy => manager.destroy(),
            .get_titlebar_tabs => |args| {
                const surface = wlr.Surface.fromWlSurface(args.surface);
                var it = self.strips.iterator(.forward);
                while (it.next()) |existing| {
                    if (existing.surface == surface) {
                        manager.postError(.already_constructed, "surface already has titlebar tabs");
                        return;
                    }
                }
                const strip = gpa.create(TitlebarTabs) catch {
                    manager.getClient().postNoMemory();
                    return;
                };
                const resource = Resource.create(manager.getClient(), 1, args.id) catch {
                    gpa.destroy(strip);
                    manager.getClient().postNoMemory();
                    return;
                };
                strip.* = .{ .resource = resource, .surface = surface };
                self.strips.append(strip);
                surface.events.destroy.add(&strip.surface_destroy);
                resource.setHandler(*TitlebarTabs, handleStripRequest, handleDestroy, strip);
                // Only the exact toplevel surface may receive chrome. Never
                // walk popup parents or subsurface roots here.
                if (wlr.XdgSurface.tryFromWlrSurface(surface)) |xdg| {
                    if (scene_data.xdgSceneTree(xdg)) |tree| {
                        if (scene_data.SceneData.fromNodeOrParents(&tree.node)) |data| {
                            if (data.role == .toplevel and data.role.toplevel.surface() == surface) {
                                strip.toplevel = data.role.toplevel;
                                data.role.toplevel.titlebar_tabs = strip;
                            }
                        }
                    }
                }
            },
        }
    }
};

/// Whether a strip is shown (a committed list with at least one tab).
pub fn active(self: *const TitlebarTabs) bool {
    return self.items.items.len > 0;
}

/// The committed tabs into `storage` and `strip`; returns the index of the
/// selected tab (0 when none is).
pub fn fill(self: *const TitlebarTabs, storage: *[window_tabs.max_tabs]chrome_tabs.Tab, strip: *chrome_tabs.Strip) usize {
    var current: usize = 0;
    for (self.items.items, 0..) |item, i| {
        const is_selected = item.id == self.selected;
        storage[i] = .{ .id = item.id, .title = item.title, .active = is_selected, .attention = item.attention };
        if (is_selected) current = i;
    }
    strip.tabs = storage[0..self.items.items.len];
    return current;
}

pub fn sendSelect(self: *TitlebarTabs, id: u64) void {
    self.resource.sendSelect(@intCast(id));
}

pub fn sendClose(self: *TitlebarTabs, id: u64) void {
    self.resource.sendClose(@intCast(id));
}

pub fn sendNewTab(self: *TitlebarTabs) void {
    self.resource.sendNewTab();
}

/// Asks the application to select the neighbouring tab, wrapping around.
pub fn step(self: *TitlebarTabs, forward: bool) void {
    const n = self.items.items.len;
    if (n < 2) return;
    for (self.items.items, 0..) |item, i| {
        if (item.id != self.selected) continue;
        const next = if (forward) (i + 1) % n else (i + n - 1) % n;
        self.resource.sendSelect(self.items.items[next].id);
        return;
    }
}

fn handleStripRequest(resource: *Resource, request: Resource.Request, self: *TitlebarTabs) void {
    switch (request) {
        .destroy => resource.destroy(),
        .add_tab => |args| self.addTab(args.id, std.mem.span(args.title), args.flags),
        .set_selected => |args| self.pending_selected = args.id,
        .commit => self.commit(),
    }
}

fn addTab(self: *TitlebarTabs, id: u32, raw: []const u8, flags: u32) void {
    if (id == 0) {
        self.resource.postError(.invalid_id, "tab ids must not be zero");
        return;
    }
    if (self.pending.items.len >= max_tabs) {
        self.resource.postError(.too_many_tabs, "too many tabs");
        return;
    }
    for (self.pending.items) |item| {
        if (item.id == id) {
            self.resource.postError(.duplicate_id, "duplicate tab id");
            return;
        }
    }
    const title = displayTitle(raw, flags & flag_modified != 0) catch {
        self.resource.getClient().postNoMemory();
        return;
    };
    self.pending.append(gpa, .{ .id = id, .title = title, .attention = flags & flag_attention != 0 }) catch {
        gpa.free(title);
        self.resource.getClient().postNoMemory();
    };
}

/// The text a tab shows: cut to `max_title` bytes on a character boundary,
/// replaced when not valid UTF-8, behind a bullet when modified. A bullet
/// leads so that a long title never pushes it out of the tab.
fn displayTitle(raw: []const u8, modified: bool) std.mem.Allocator.Error![]u8 {
    var end = @min(raw.len, max_title);
    while (end > 0 and end < raw.len and (raw[end] & 0xC0) == 0x80) end -= 1;
    var text = raw[0..end];
    if (!std.unicode.utf8ValidateSlice(text)) text = "?";
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ if (modified) "\u{2022} " else "", text });
}

fn commit(self: *TitlebarTabs) void {
    if (self.pending.items.len > 0) {
        const wanted = self.pending_selected orelse {
            self.resource.postError(.unknown_selected, "commit without a selected tab");
            return;
        };
        var found = false;
        for (self.pending.items) |item| {
            if (item.id == wanted) found = true;
        }
        if (!found) {
            self.resource.postError(.unknown_selected, "selected tab is not in the strip");
            return;
        }
        self.selected = wanted;
    }
    freeItems(&self.items);
    self.items.deinit(gpa);
    self.items = self.pending;
    self.pending = .empty;
    self.pending_selected = null;
    if (self.toplevel) |toplevel| toplevel.syncChrome(false, Toplevel.nowMs()) catch {};
}

fn freeItems(list: *std.ArrayList(Item)) void {
    for (list.items) |item| gpa.free(item.title);
    list.clearRetainingCapacity();
}

fn detach(self: *TitlebarTabs) void {
    if (self.toplevel) |toplevel| toplevel.titlebar_tabs = null;
    self.toplevel = null;
}

fn handleSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *TitlebarTabs = @fieldParentPtr("surface_destroy", listener);
    self.surface_destroy.link.remove();
    self.surface = null;
    self.detach();
    // The protocol resource may outlive the wl_surface; leave it inert.
}

fn handleDestroy(_: *Resource, self: *TitlebarTabs) void {
    const toplevel = self.toplevel;
    self.detach();
    if (self.surface != null) self.surface_destroy.link.remove();
    self.link.remove();
    freeItems(&self.items);
    self.items.deinit(gpa);
    freeItems(&self.pending);
    self.pending.deinit(gpa);
    gpa.destroy(self);
    if (toplevel) |top| top.syncChrome(true, Toplevel.nowMs()) catch {};
}

//! Input sources: the configured keyboard layouts (XKB groups, in config
//! order) followed by the input methods of Fcitx5's current group while Fcitx
//! runs. One source is active. The taskbar indicator, its menu, the
//! `input_source_*` bindings, the lock screen and IPC all act through here.
//!
//! The active layout is one group for every keyboard that uses the config
//! keymap. Switching sets it on all of them; a keyboard that switches by
//! itself (an XKB `grp:` toggle) moves the global group, and the others follow
//! from an idle callback, never from inside a keyboard's own signal.
const std = @import("std");
const wl = @import("wayland").server.wl;

const Server = @import("Server.zig");
const Keyboard = @import("Keyboard.zig");
const config_sources = @import("config").input_sources;
const registry = @import("input_sources/registry.zig");
const labels = @import("input_sources/labels.zig");
const fcitx = @import("input_sources/fcitx.zig");
const text_input = @import("input/text_input.zig");
const gpa = @import("main.zig").gpa;

const log = std.log.scoped(.input_sources);

pub const Kind = enum { xkb, fcitx };

pub const Source = struct {
    kind: Kind,
    /// `de(nodeadkeys)` for a layout, Fcitx's unique name for a method.
    id: []const u8,
    /// What Settings and the menu show: "German (no dead keys)", "Mozc".
    name: []const u8,
    /// The indicator text.
    label: []const u8,
    /// The XKB group of a layout.
    group: u32 = 0,
};

pub const Manager = struct {
    server: *Server,
    /// Layout strings, replaced by `reload`.
    layout_arena: std.heap.ArenaAllocator = .init(gpa),
    /// The combined list, replaced by every `rebuild`.
    list_arena: std.heap.ArenaAllocator = .init(gpa),
    layouts: [config_sources.max_layouts]config_sources.Layout = undefined,
    layout_count: usize = 0,
    list: []Source = &.{},
    active_group: u32 = 0,

    catalog: ?registry.Catalog = null,
    catalog_failed: bool = false,
    job: ?*registry.Job = null,
    job_source: ?*wl.EventSource = null,

    fcitx: ?*fcitx.Client = null,
    sync_idle: ?*wl.EventSource = null,

    /// What was last announced, so a repeated state notifies nobody.
    announced_index: ?usize = null,
    announced_label: labels.Text = .{},
    announced_count: usize = 0,
    generation: u64 = 0,

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        self.* = .{ .server = server };
        self.reload();
        return self;
    }

    pub fn deinit(self: *Manager) void {
        if (self.sync_idle) |source| source.remove();
        if (self.job_source) |source| source.remove();
        if (self.job) |job| if (job.finish()) |found| {
            var catalog = found;
            catalog.deinit();
        };
        if (self.fcitx) |client| client.destroy();
        if (self.catalog) |*catalog| catalog.deinit();
        self.list_arena.deinit();
        self.layout_arena.deinit();
        gpa.destroy(self);
    }

    /// Optional services, after the first desktop frame and never in the greeter.
    pub fn startServices(self: *Manager) void {
        if (self.server.greeter_mode or self.fcitx != null) return;
        const client = fcitx.Client.create(gpa, self.server.wl_server.getEventLoop(), self.server.environ) catch return;
        client.on_change = fcitxChanged;
        client.change_owner = self;
        self.fcitx = client;
    }

    pub fn sources(self: *const Manager) []const Source {
        return self.list;
    }

    pub fn layoutCount(self: *const Manager) usize {
        return self.layout_count;
    }

    pub fn configuredLayouts(self: *const Manager) []const config_sources.Layout {
        return self.layouts[0..self.layout_count];
    }

    /// The source in effect: an active Fcitx method, else the active layout.
    pub fn activeIndex(self: *const Manager) ?usize {
        if (self.list.len == 0) return null;
        if (self.fcitx) |client| if (client.activeMethod()) |method| {
            const index = self.layout_count + method;
            if (index < self.list.len) return index;
        };
        return @min(self.active_group, self.layout_count -| 1);
    }

    pub fn activeLabel(self: *const Manager) []const u8 {
        const index = self.activeIndex() orelse return "";
        return self.list[index].label;
    }

    /// The active layout's text, whatever Fcitx does: what the lock screen
    /// types with, since input methods never reach it.
    pub fn activeLayoutLabel(self: *const Manager) []const u8 {
        if (self.list.len == 0) return "";
        return self.list[@min(self.active_group, self.layout_count -| 1)].label;
    }

    /// More than one thing to switch between; drives the automatic taskbar item.
    pub fn switchable(self: *const Manager) bool {
        return self.list.len > 1;
    }

    pub fn fcitxRunning(self: *const Manager) bool {
        const client = self.fcitx orelse return false;
        return client.running();
    }

    // ---- configuration --------------------------------------------------

    /// Re-reads the layouts from the config. The active layout keeps its place
    /// by identity when the list is reordered.
    pub fn reload(self: *Manager) void {
        var previous: ?config_sources.Layout = null;
        var previous_buf: [2][64]u8 = undefined;
        if (self.active_group < self.layout_count) {
            const old = self.layouts[self.active_group];
            const layout_len = @min(old.layout.len, 64);
            const variant_len = @min(old.variant.len, 64);
            @memcpy(previous_buf[0][0..layout_len], old.layout[0..layout_len]);
            @memcpy(previous_buf[1][0..variant_len], old.variant[0..variant_len]);
            previous = .{ .layout = previous_buf[0][0..layout_len], .variant = previous_buf[1][0..variant_len] };
        }
        _ = self.layout_arena.reset(.retain_capacity);
        const a = self.layout_arena.allocator();
        const split = config_sources.split(self.server.config.input);
        self.layout_count = 0;
        for (split.slice()) |layout| {
            self.layouts[self.layout_count] = .{
                .layout = a.dupe(u8, layout.layout) catch break,
                .variant = a.dupe(u8, layout.variant) catch break,
                .label = a.dupe(u8, layout.label) catch break,
            };
            self.layout_count += 1;
        }
        if (self.layout_count == 0) {
            // XKB's own fallback, so the indicator names what is really typed.
            const environ = self.server.environ;
            self.layouts[0] = .{
                .layout = a.dupe(u8, environ.getPosix("XKB_DEFAULT_LAYOUT") orelse "us") catch "us",
                .variant = a.dupe(u8, environ.getPosix("XKB_DEFAULT_VARIANT") orelse "") catch "",
            };
            if (std.mem.indexOfScalar(u8, self.layouts[0].layout, ',')) |comma| self.layouts[0].layout = self.layouts[0].layout[0..comma];
            if (std.mem.indexOfScalar(u8, self.layouts[0].variant, ',')) |comma| self.layouts[0].variant = self.layouts[0].variant[0..comma];
            self.layout_count = 1;
        }
        var group: u32 = 0;
        if (previous) |old| {
            for (self.configuredLayouts(), 0..) |layout, i| if (layout.eql(old)) {
                group = @intCast(i);
                break;
            };
        }
        self.active_group = group;
        if (self.layout_count > 1) self.wantCatalog();
        self.rebuild();
        self.scheduleSync();
    }

    /// Starts the registry load once; Settings asks for it too.
    pub fn wantCatalog(self: *Manager) void {
        if (self.catalog != null or self.job != null or self.catalog_failed) return;
        const job = registry.Job.start() catch |err| {
            log.warn("could not start the layout catalogue: {}", .{err});
            self.catalog_failed = true;
            return;
        };
        self.job_source = self.server.wl_server.getEventLoop().addFd(*Manager, job.fd, .{ .readable = true }, catalogReady, self) catch {
            if (job.finish()) |found| self.catalog = found else self.catalog_failed = true;
            self.rebuild();
            return;
        };
        self.job = job;
    }

    pub fn catalogState(self: *const Manager) enum { loading, ready, unavailable } {
        if (self.catalog != null) return .ready;
        if (self.catalog_failed) return .unavailable;
        return .loading;
    }

    fn catalogReady(_: c_int, _: wl.EventMask, self: *Manager) c_int {
        if (self.job_source) |source| source.remove();
        self.job_source = null;
        const job = self.job orelse return 0;
        self.job = null;
        if (job.finish()) |found| self.catalog = found else self.catalog_failed = true;
        self.rebuild();
        if (self.server.input.open_control_center) |cc| cc.refresh();
        return 0;
    }

    /// A layout's description from the catalogue, or its XKB spelling.
    pub fn describe(self: *const Manager, a: std.mem.Allocator, layout: config_sources.Layout) []const u8 {
        if (self.catalog) |*catalog| if (catalog.find(layout.layout, layout.variant)) |entry| {
            if (entry.description.len > 0) return entry.description;
        };
        var buf: [160]u8 = undefined;
        return a.dupe(u8, layout.format(&buf)) catch layout.layout;
    }

    fn rebuild(self: *Manager) void {
        self.list = &.{};
        _ = self.list_arena.reset(.retain_capacity);
        const a = self.list_arena.allocator();
        const methods: []const fcitx.Method = if (self.fcitx) |client| (if (client.running()) client.methods else &.{}) else &.{};
        const total = self.layout_count + methods.len;
        const list = a.alloc(Source, total) catch {
            self.list = &.{};
            return;
        };
        var texts: [config_sources.max_layouts + 32]labels.Text = undefined;
        var explicit: [config_sources.max_layouts + 32]bool = @splat(false);
        const n = @min(total, texts.len);
        for (self.configuredLayouts(), 0..) |layout, i| {
            if (layout.label.len > 0) {
                texts[i] = .{};
                texts[i].set(layout.label);
                explicit[i] = true;
            } else {
                const brief = if (self.catalog) |*catalog| (if (catalog.find(layout.layout, layout.variant)) |entry| entry.brief else "") else "";
                texts[i] = labels.base(brief, layout.layout);
            }
            var buf: [160]u8 = undefined;
            list[i] = .{
                .kind = .xkb,
                .id = a.dupe(u8, layout.format(&buf)) catch layout.layout,
                .name = self.describe(a, layout),
                .label = "",
                .group = @intCast(i),
            };
        }
        for (methods, 0..) |method, j| {
            const i = self.layout_count + j;
            if (i >= n) break;
            if (method.label.len > 0) {
                texts[i] = .{};
                texts[i].set(method.label);
                explicit[i] = true;
            } else texts[i] = labels.base(method.language, method.name);
            // The client's strings go with its next refresh; keep our own.
            list[i] = .{ .kind = .fcitx, .id = a.dupe(u8, method.name) catch "", .name = a.dupe(u8, method.display) catch "", .label = "" };
        }
        labels.disambiguate(texts[0..n], explicit[0..n]);
        for (list[0..n], 0..) |*source, i| source.label = a.dupe(u8, texts[i].slice()) catch "";
        self.list = list[0..n];
        self.announce();
    }

    fn fcitxChanged(owner: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner orelse return));
        self.rebuild();
    }

    // ---- switching ----------------------------------------------------------

    pub fn select(self: *Manager, index: usize) bool {
        if (index >= self.list.len) return false;
        const source = self.list[index];
        switch (source.kind) {
            .xkb => {
                if (self.fcitx) |client| client.deactivate();
                self.setGroup(source.group);
            },
            .fcitx => if (self.fcitx) |client| client.select(source.id),
        }
        self.announce();
        return true;
    }

    pub fn cycle(self: *Manager, forward: bool) void {
        if (self.list.len < 2) return;
        const current = self.activeIndex() orelse 0;
        const count = self.list.len;
        _ = self.select(if (forward) (current + 1) % count else (current + count - 1) % count);
    }

    /// Layouts only: the lock screen and anything that must not hand keys to
    /// an input method.
    pub fn cycleLayouts(self: *Manager) void {
        if (self.layout_count < 2) return;
        self.setGroup(@intCast((self.active_group + 1) % self.layout_count));
        self.announce();
    }

    fn setGroup(self: *Manager, group: u32) void {
        if (group >= self.layout_count) return;
        self.active_group = group;
        self.syncKeyboards();
    }

    /// Keyboards that use the config keymap; virtual and synthetic ones carry
    /// their own.
    fn follows(self: *const Manager, keyboard: *Keyboard) bool {
        if (keyboard.synthetic or text_input.isVirtual(keyboard.device)) return false;
        const kb = keyboard.device.toKeyboard();
        const keymap = kb.keymap orelse return false;
        return keymap.numLayouts() == self.layout_count;
    }

    fn syncKeyboards(self: *Manager) void {
        if (self.sync_idle) |source| source.remove();
        self.sync_idle = null;
        // The active keyboard last, so the seat ends on the keyboard in use.
        var it = self.server.input.keyboards.iterator(.forward);
        while (it.next()) |keyboard| if (keyboard != self.server.layout_keyboard) self.apply(keyboard);
        if (self.server.layout_keyboard) |keyboard| self.apply(keyboard);
    }

    fn apply(self: *Manager, keyboard: *Keyboard) void {
        if (!self.follows(keyboard)) return;
        const kb = keyboard.device.toKeyboard();
        if (kb.modifiers.group == self.active_group) return;
        kb.setLayoutGroup(self.active_group);
    }

    pub fn scheduleSync(self: *Manager) void {
        if (self.sync_idle != null) return;
        self.sync_idle = self.server.wl_server.getEventLoop().addIdle(*Manager, syncIdle, self) catch null;
    }

    fn syncIdle(self: *Manager) void {
        self.sync_idle = null;
        self.syncKeyboards();
    }

    /// A keyboard's group changed or it became the one in use (layouts.zig).
    pub fn observe(self: *Manager, keyboard: *Keyboard, group: ?u32, became_active: bool) void {
        if (!self.follows(keyboard)) return;
        if (became_active) {
            // A keyboard picked up after another follows the global layout.
            if (group != self.active_group) self.scheduleSync();
            return;
        }
        const value = group orelse return;
        if (value == self.active_group or value >= self.layout_count) return;
        self.active_group = value;
        self.scheduleSync();
        self.announce();
    }

    // ---- notification -------------------------------------------------------

    /// Tells everything that shows the active source, once per real change.
    pub fn announce(self: *Manager) void {
        const index = self.activeIndex();
        const label = self.activeLabel();
        const count = self.list.len;
        if (index == self.announced_index and count == self.announced_count and std.mem.eql(u8, label, self.announced_label.slice())) return;
        const presence_changed = (count > 1) != (self.announced_count > 1);
        self.announced_index = index;
        self.announced_count = count;
        self.announced_label.set(label);
        self.generation +%= 1;
        var outputs = self.server.outputs.iterator(.forward);
        while (outputs.next()) |output| if (output.taskbar) |bar| bar.applyInputSource(presence_changed);
        self.server.input.window_menu.sourcesChanged();
        if (self.server.locker) |lock| lock.inputSourceChanged();
        @import("ipc/events.zig").onInputSourceChanged(self.server);
        if (self.server.input.open_control_center) |cc| if (cc.page == .input) cc.refresh();
    }
};

test {
    _ = registry;
    _ = labels;
    _ = fcitx;
    _ = @import("control_center/sections/input_sources.zig");
}

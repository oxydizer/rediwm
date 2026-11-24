//! A window's life on the process's one Wayland connection: creating it, one
//! step of its loop, and taking it down. Every window is a `Client` with its
//! own registry bindings, surface and `App`; they share the display only.

const std = @import("std");
const wl = @import("wayland").client.wl;
const ClientCursor = @import("ui").client_cursor;
const key_repeat = @import("ui").key_repeat;
const c = @import("../files/c.zig").api;
const app_mod = @import("app.zig");
const client_tabs = @import("client_tabs.zig");
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const OutputInfo = main_mod.OutputInfo;
const Setup = main_mod.Setup;
const a = std.heap.c_allocator;

/// Opens a window. The primary one owns the drafts. A failed creation leaks
/// what it had made: the first window failing ends the process, and a later
/// one failing is rare enough to cost a few proxies.
pub fn create(display: *wl.Display, setup: Setup, primary: bool, paths: []const [:0]const u8) !*Client {
    const self = try a.create(Client);
    errdefer a.destroy(self);
    self.* = .{ .display = display, .app = try app_mod.App.init(setup.io) };
    self.app.environ = setup.environ;
    self.app.join();
    if (primary) self.app.openDrafts(setup.environ);
    for (paths) |path| self.app.open(path);
    self.ime = .{ .app = &self.app };
    self.locale = @import("ui").compose.localeFromEnviron(setup.environ);
    self.clipboard = .{ .app = &self.app };

    const registry = try display.getRegistry();
    self.registry = registry;
    registry.setListener(*Client, Client.registryEvent, self);

    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingWaylandGlobals;
    }

    if (self.output_manager) |manager| {
        for (self.outputs.items) |info| {
            info.logical = try manager.getXdgOutput(info.proxy);
            info.logical.?.setListener(*OutputInfo, Client.logicalOutputEvent, info);
        }
        if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    }

    if (self.seat) |seat| {
        try self.clipboard.setup(seat);
        try self.ime.setup(seat);
    }

    self.surface = try self.compositor.?.createSurface();
    self.surface.setListener(*Client, Client.surfaceEvent, self);
    self.ime.surface = self.surface;

    self.cursor_surface = try self.compositor.?.createSurface();
    if (self.cursor_shape.manager == null) self.cursor_theme = ClientCursor.loadFallback(self.shm.?);

    // Before the shell role, like the decoration: the compositor adopts the strip
    // when the toplevel appears. It stays hidden until `client_tabs.sync` commits.
    client_tabs.attach(self);

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, self);

    self.xdg_toplevel.setAppId("rediwm-editor");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    // Real min size is set from xdgToplevelEvent once the decoration mode
    // (and thus titlebar height) is known; this is just a safe pre-configure
    // default sized for the worst case (self-decorated).
    self.xdg_toplevel.setMinSize(520, 240 + self.titlebarHeight());

    // Prefer the shared compositor chrome. The app keeps its menu in the tab
    // bar with SSD, or in its fallback header when it must self-decorate.
    if (self.decoration_manager) |mgr| {
        if (!setup.force_csd) {
            self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
            if (self.decoration) |dec| {
                dec.setListener(*Client, Client.decorationEvent, self);
                dec.setMode(.server_side);
            }
        }
    }

    // Initial commit to start xdg configuration sequence
    self.surface.commit();
    return self;
}

/// One turn of this window's part of the loop: tabs, closing, the bars, the
/// caret and a frame. A window that is closing ends with `running` false.
pub fn step(self: *Client) !void {
    client_tabs.sync(self);
    if (self.app.closed) {
        self.close();
        return;
    }
    self.clipboard.sync(self.input_serial);
    self.app.stepBar(key_repeat.nowMs());
    if (!self.app.closed) self.ime.sync(self.titlebarHeight());
    if (self.app.closed) self.close();
    if (!self.running) return;

    if (self.app.title_changed) {
        self.xdg_toplevel.setTitle(self.app.getTitle());
        self.app.title_changed = false;
    }

    const now = key_repeat.nowMs();
    const caret_state = self.app.caretState();
    const restart = self.caret_state == null or !std.meta.eql(self.caret_state.?, caret_state);
    const snap = if (self.caret_state) |before| !before.active or before.tab != caret_state.tab or before.find != caret_state.find or
        before.top != caret_state.top or before.dy != caret_state.dy or before.scroll_x != caret_state.scroll_x or
        before.width != caret_state.width or before.height != caret_state.height or before.scale != caret_state.scale else true;
    self.caret_state = caret_state;
    self.app.stepReflow(now);
    self.app.stepCaret(now, caret_state.active, restart, snap);
    try self.render();
}

/// Takes the window down and frees it. Its `App` writes the drafts if it owns them.
pub fn destroy(self: *Client) void {
    // Every object bound here has a listener that points at this window. The
    // connection outlives it, so each one goes first, or the next event for it
    // lands in freed memory.
    if (self.keyboard) |k| if (k.getVersion() >= 3) k.release() else k.destroy();
    if (self.pointer) |p| if (p.getVersion() >= 3) p.release() else p.destroy();
    if (self.seat) |seat| if (seat.getVersion() >= 5) seat.release() else seat.destroy();
    self.keyboard = null;
    self.pointer = null;
    self.seat = null;
    if (self.frame_callback) |callback| callback.destroy();
    self.frame_callback = null;
    if (self.activation) |activation| activation.destroy();
    self.activation = null;
    for (self.outputs.items) |info| {
        if (info.logical) |logical| logical.destroy();
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    if (self.xkb_state) |state| c.xkb_state_unref(state);
    if (self.xkb_context) |context| c.xkb_context_unref(context);

    if (self.decoration) |dec| dec.destroy();
    self.xdg_toplevel.destroy();
    self.xdg_surface.destroy();
    if (self.wm_base) |wm| wm.destroy();
    self.wm_base = null;
    self.tabs.deinit();
    if (self.cursor_theme) |theme_ptr| theme_ptr.destroy();
    self.cursor_shape.deinit();
    self.cursor_surface.destroy();
    self.surface.destroy();
    if (self.registry) |registry| registry.destroy();
    for (self.buffers) |slot| {
        if (slot) |buffer| buffer.destroy();
    }
    self.app.deinit();
    self.clipboard.deinit();
    self.compose.deinit();
    self.ime.deinit();
    a.destroy(self);
}

// xdg-shell adapter for a managed Toplevel. Protocol listeners and
// xdg-specific configure bookkeeping live here; shared window policy stays
// on Toplevel.
const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Toplevel = @import("Toplevel.zig");

const Adapter = @This();

window: *Toplevel,
xdg_toplevel: *wlr.XdgToplevel,

commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
destroy: wl.Listener(void) = .init(handleDestroy),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),
request_maximize: wl.Listener(void) = .init(handleRequestMaximize),
request_fullscreen: wl.Listener(void) = .init(handleRequestFullscreen),
request_minimize: wl.Listener(void) = .init(handleRequestMinimize),
set_title: wl.Listener(void) = .init(handleSetTitle),
set_app_id: wl.Listener(void) = .init(handleSetAppId),
set_parent: wl.Listener(void) = .init(handleSetParent),

pub fn listen(self: *Adapter) void {
    const xdg_surface = self.xdg_toplevel.base;
    xdg_surface.surface.events.commit.add(&self.commit);
    xdg_surface.surface.events.map.add(&self.map);
    xdg_surface.surface.events.unmap.add(&self.unmap);
    self.xdg_toplevel.events.destroy.add(&self.destroy);
    self.xdg_toplevel.events.request_move.add(&self.request_move);
    self.xdg_toplevel.events.request_resize.add(&self.request_resize);
    self.xdg_toplevel.events.request_maximize.add(&self.request_maximize);
    self.xdg_toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    self.xdg_toplevel.events.request_minimize.add(&self.request_minimize);
    self.xdg_toplevel.events.set_title.add(&self.set_title);
    self.xdg_toplevel.events.set_app_id.add(&self.set_app_id);
    self.xdg_toplevel.events.set_parent.add(&self.set_parent);
}

pub fn unlisten(self: *Adapter) void {
    self.commit.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.destroy.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.request_maximize.link.remove();
    self.request_fullscreen.link.remove();
    self.request_minimize.link.remove();
    self.set_title.link.remove();
    self.set_app_id.link.remove();
    self.set_parent.link.remove();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const adapter: *Adapter = @fieldParentPtr("commit", listener);
    if (adapter.xdg_toplevel.base.initial_commit) {
        adapter.window.resolveInitialRules();
        adapter.window.configureInitialXdgState();
    }
    adapter.window.handleSurfaceCommit();
    // Maximized/fullscreen become current only when the client commits.
    if (adapter.window.wlr_foreign) |handle| handle.syncState();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("map", listener);
    adapter.window.handleMapped();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("unmap", listener);
    adapter.window.handleUnmapped();
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("destroy", listener);
    const toplevel = adapter.window;
    adapter.unlisten();
    toplevel.destroy();
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_title", listener);
    adapter.window.handleIdentityChanged();
}

fn handleSetAppId(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_app_id", listener);
    adapter.window.handleIdentityChanged();
}

fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    _: *wlr.XdgToplevel.event.Move,
) void {
    const adapter: *Adapter = @fieldParentPtr("request_move", listener);
    adapter.window.beginMove();
}

fn handleRequestResize(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
    event: *wlr.XdgToplevel.event.Resize,
) void {
    const adapter: *Adapter = @fieldParentPtr("request_resize", listener);
    const toplevel = adapter.window;
    const surface = adapter.xdg_toplevel.base.surface;
    if (!toplevel.server.input.seat.validatePointerGrabSerial(surface, event.serial)) return;
    toplevel.server.input.startResize(toplevel, event.edges, null, 0x110);
}

fn handleRequestMaximize(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_maximize", listener);
    if (!adapter.window.isInitialized()) return;
    adapter.window.setMaximized(adapter.xdg_toplevel.requested.maximized);
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_fullscreen", listener);
    if (!adapter.window.isInitialized()) return;
    adapter.window.setFullscreen(adapter.xdg_toplevel.requested.fullscreen);
}

fn handleRequestMinimize(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_minimize", listener);
    if (adapter.window.isMapped()) adapter.window.minimize();
}

fn handleSetParent(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_parent", listener);
    const top = adapter.window;
    top.server.window_tabs.reconcile(top);
    top.syncForeign();
    if (top.in_world) @import("window_tabs.zig").refreshVisibility(top.server);
}

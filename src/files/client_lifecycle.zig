//! A window's life on the process's one Wayland connection: creating it, one
//! step of its loop, the descriptors it waits on, and taking it down. Every
//! window is a `Client` with its own registry bindings, surface, `App` and
//! listing worker; the windows share the display and the process's I/O
//! service and nothing else, so
//! the compositor sees one client, which is what lets a tab move between them.

const std = @import("std");
const wl = @import("wayland").client.wl;
const ClientCursor = @import("ui").client_cursor;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const io_service_mod = @import("io_service.zig");
const worker_mod = @import("worker.zig");
const reaper_mod = @import("reaper.zig");
const transfer = @import("transfer.zig");
const client_tabs = @import("client_tabs.zig");
const terminal_c = @import("terminal/model.zig").c;
const main = @import("main.zig");
const Client = main.Client;
const Setup = main.Setup;
const Launch = main.Launch;
const a = std.heap.c_allocator;

/// Poll entries one window owns. Entry 0 of the block is unused: the display
/// is polled once for all windows, ahead of them.
pub const poll_slots = 26;

/// Opens a window. A failed creation leaks what it had made: the first window
/// failing ends the process, and a later one failing is rare enough to cost a
/// few proxies.
pub fn create(
    display: *wl.Display,
    setup: Setup,
    launch: Launch,
    service: *io_service_mod.Service,
) !*Client {
    var io_handle = try service.registerWindow();
    errdefer io_handle.close();

    const worker = try worker_mod.Worker.init(a, setup.io, setup.environ, launch.dir);
    errdefer worker.deinit();

    const app = try app_mod.App.init(
        a,
        setup.io,
        setup.environ,
        worker.theme_cfg,
        worker,
        launch.dir,
        setup.home_dir,
    );

    const self = try a.create(Client);
    errdefer a.destroy(self);
    self.* = .{
        .display = display,
        .app = app,
        .locale = @import("ui").compose.localeFromEnviron(setup.environ),
        .worker = worker,
        .io_handle = io_handle,
    };
    self.ime = .{ .app = &self.app };
    self.app.reaper = setup.reaper;
    self.app.folder_views = setup.folder_views;
    self.app.applyFolderView();
    self.app.service.handle = io_handle;
    self.app.requestPinKinds();
    if (launch.chooser) |options| try self.app.configureChooser(options);
    if (launch.selected_file) |path| self.app.selectOnLoad(path);
    self.app.startDevices();
    self.app.startAudio();
    if (launch.chooser == null) self.app.startTorrents();
    if (launch.torrent_source) |source| {
        // A torrent file opens as a folder; a magnet asks where it goes.
        if (source.len > 0 and source[0] == '/') self.app.browseTorrent(source) else self.app.torrentSource(source);
    }
    if (launch.torrent_id) |id| self.app.browse_pending = self.app.allocator.dupe(u8, id) catch null;

    const registry = try display.getRegistry();
    self.registry = registry;
    registry.setListener(*Client, Client.registryEvent, self);

    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.seat) |seat| try self.ime.setup(seat);
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingWaylandGlobals;
    }

    if (self.data_manager) |manager| {
        if (self.seat) |seat| {
            self.data_device = manager.getDataDevice(seat) catch null;
            if (self.data_device) |device| device.setListener(*Client, Client.dataEvent, self);
        }
    }

    self.surface = try self.compositor.?.createSurface();
    self.surface.setListener(*Client, Client.surfaceEvent, self);
    // The seat names the surface in its enter and leave events, and only this
    // window's own count.
    self.ime.surface = self.surface;

    self.cursor_surface = try self.compositor.?.createSurface();
    if (self.cursor_shape.manager == null) self.cursor_theme = ClientCursor.loadFallback(self.shm.?);

    // Before the shell role: the compositor adopts the strip when the toplevel appears.
    client_tabs.attach(self);

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, self);

    self.xdg_toplevel.setAppId(if (launch.chooser != null) "rediwm-file-chooser" else "rediwm-files");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    // Real min size is set from xdgToplevelEvent once the decoration mode
    // (and thus titlebar height) is known; this is just a safe pre-configure
    // default sized for the worst case (self-decorated).
    self.xdg_toplevel.setMinSize(if (launch.chooser != null) 600 else 360, 214 + self.app.footerHeight() + main.CSD_TITLEBAR_H);
    if (launch.chooser) |options| self.attachToParent(options);

    // Prefer server-side decorations; the compositor may still tell us via
    // decorationEvent to self-decorate (e.g. it has no SSD implementation),
    // and if zxdg_decoration_manager_v1 isn't advertised at all we already
    // default to self-decorating (see wantsCsd).
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

/// One turn of this window's part of the loop: its background work, the tab
/// strip, the cursor, and a frame.
pub fn step(self: *Client) !void {
    self.openEditor();
    try self.handleClipboard();
    self.app.stepTorrents();
    @import("app_torrent_browse.zig").stepPending(&self.app);
    @import("app_torrent_browse.zig").step(&self.app);
    self.app.sync();
    self.app.stepService();
    self.stepArchiveDrag();
    self.app.stepThumbs();
    client_tabs.sync(self);
    self.app.stepWheel(app_mod.nowMs());
    self.app.stepSelection(app_mod.nowMs());
    self.app.stepLayout(app_mod.nowMs());
    self.app.terminalStep(app_mod.nowMs());
    self.app.terminalFinishClose(app_mod.nowMs());
    self.ime.sync(self.titlebarHeight());
    self.app.stepHover(app_mod.nowMs());
    self.app.stepTransferHoverPriority(app_mod.nowMs());
    self.app.stepScrollbar(app_mod.nowMs());
    self.app.stepScanNotice(app_mod.nowMs());
    self.app.stepAudio(app_mod.nowMs());
    self.refreshCursor();

    if (self.app.title_changed) {
        self.xdg_toplevel.setTitle(self.app.getTitle());
        self.app.title_changed = false;
    }

    try self.render();
}

/// Whether the window has ended: closed by the user, or a chooser's answer given.
pub fn finished(self: *const Client) bool {
    return !self.running or self.app.closed or self.app.chooser_done;
}

/// Fills this window's block of the poll array.
pub fn pollFill(self: *Client, fds: *[poll_slots]c.struct_pollfd) void {
    fds.* = @splat(.{ .fd = -1, .events = c.POLLIN, .revents = 0 });
    fds[1].fd = self.app.preview_return_fd orelse -1;
    fds[2].fd = if (self.receiving) |receive| receive.fd else -1;
    fds[3].fd = self.app.worker.wake_main;
    fds[4].fd = if (self.app.dirsize_pool) |p| p.done_fd else -1;
    fds[5].fd = self.app.thumbWakeFd();
    // Slots 6..13 belong to the clipboard sends (at most eight).
    // Slot 18 is free: it held the retired JobRunner wake fd.
    fds[14].fd = self.app.devicesWakeFd();
    fds[15].fd = if (self.drop_receiving) |receive| receive.fd else -1;
    fds[16].fd = self.app.children.fd;
    fds[17].fd = self.app.extract_picker_fd orelse -1;
    if (self.app.terminal.session) |session| {
        fds[19] = .{ .fd = terminal_c.ft_pty(session), .events = @intCast(c.POLLIN | @as(c_int, if (terminal_c.ft_wants_write(session)) c.POLLOUT else 0)), .revents = 0 };
        fds[20] = .{ .fd = terminal_c.ft_channel(session), .events = @intCast(c.POLLIN | @as(c_int, if (terminal_c.ft_wants_request(session)) c.POLLOUT else 0)), .revents = 0 };
        fds[21].fd = terminal_c.ft_exit_fd(session);
    }
    fds[22].fd = self.app.torrents.fd;
    fds[23].fd = self.app.audioWakeFd();
    // Slots 24 and 25 are free: they held the window Runtime's wake fds.
    for (self.sends.items, 0..) |send, i| fds[i + 6] = .{ .fd = send.fd, .events = c.POLLOUT, .revents = 0 };
}

/// Acts on what the poll reported for this window. `fds` is the block
/// `pollFill` gave out; the sends are the same ones, since nothing ran between.
pub fn pollDrain(self: *Client, fds: *const [poll_slots]c.struct_pollfd) void {
    if (self.app.terminal.session) |session| terminal_c.ft_io(session, fds[19].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0, fds[19].revents & c.POLLOUT != 0, fds[20].revents != 0, fds[21].revents != 0);
    if (fds[22].revents != 0) {
        self.app.torrents.drain();
        self.app.invalidate();
    }
    if (fds[3].revents & c.POLLIN != 0) self.app.worker.drainMain();
    if (fds[4].revents & c.POLLIN != 0) {
        if (self.app.dirsize_pool) |p| p.drainDone();
    }
    if (fds[5].revents & c.POLLIN != 0) self.app.drainThumbs();
    if (fds[14].revents & c.POLLIN != 0) self.app.drainDevices();
    if (fds[23].revents & c.POLLIN != 0) self.app.drainAudio();
    if (fds[16].revents != 0) while (self.app.children.next() != null) {};
    if (fds[17].revents != 0) self.app.extractionFolderReady();
    if (fds[1].revents != 0) self.previewReturned();
    if (self.receiving != null and (fds[2].revents != 0 or app_mod.nowMs() - self.receiving.?.started > transfer.timeout_ms)) self.receiveClipboard();
    if (self.drop_receiving != null and (fds[15].revents != 0 or app_mod.nowMs() - self.drop_receiving.?.started > transfer.timeout_ms)) self.receiveDrop();
    var si = self.sends.items.len;
    while (si > 0) {
        si -= 1;
        const send = &self.sends.items[si];
        const expired = app_mod.nowMs() - send.started > transfer.timeout_ms;
        if (expired or (fds[si + 6].revents != 0 and (send.write() catch true))) {
            send.deinit();
            _ = self.sends.orderedRemove(si);
        }
    }
}

/// Takes the window down and frees it.
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
    if (self.activation) |activation| activation.destroy();
    self.activation = null;

    for (self.offers.items) |o| {
        o.proxy.destroy();
        a.destroy(o);
    }
    self.offers.deinit(a);
    for (self.outputs.items) |info| {
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    self.destroyClipboardSource();
    self.destroyDragSource();
    if (self.data_device) |device| device.release();
    self.data_device = null;
    if (self.xkb_state) |state| c.xkb_state_unref(state);
    if (self.xkb_context) |context| c.xkb_context_unref(context);

    if (self.decoration) |dec| dec.destroy();
    self.detachParent();
    self.xdg_toplevel.destroy();
    self.xdg_surface.destroy();
    if (self.wm_base) |wm| wm.destroy();
    self.wm_base = null;
    if (self.importer) |importer| importer.destroy();
    self.importer = null;
    if (self.wm_dialog) |manager| manager.destroy();
    self.wm_dialog = null;
    self.tabs.deinit();
    if (self.cursor_theme) |theme_ptr| theme_ptr.destroy();
    self.cursor_shape.deinit();
    self.cursor_surface.destroy();
    self.surface.destroy();
    if (self.registry) |registry| registry.destroy();

    self.cancelPendingArchiveDrag();
    self.clearDragIcon();
    self.cancelReceive();
    if (self.drop_receiving) |*receive| receive.deinit();
    for (self.sends.items) |*send| send.deinit();
    self.sends.deinit(a);
    if (self.frame_callback) |callback| callback.destroy();
    for (self.buffers.items) |buffer| buffer.destroy();
    self.buffers.deinit(a);
    self.retained.deinit(a);

    self.app.deinit();
    self.compose.deinit();
    self.ime.deinit();
    // Never fails and never waits on the Service mutex.
    self.io_handle.close();
    // Last: the Trash count may still write this worker's `wake_main`, and the
    // reaper finishes in order (`reaper.zig`).
    reaper_mod.retire(self.app.reaper, self.worker, worker_mod.Worker.deinit);
    a.destroy(self);
}

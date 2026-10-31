const std = @import("std");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const worker_mod = @import("worker.zig");
const transfer = @import("transfer.zig");
const clipboard_mod = @import("clipboard.zig");
const theme = @import("../icon_theme.zig");
const Allocator = std.mem.Allocator;
const a = std.heap.c_allocator;
const terminal_c = @import("terminal/model.zig").c;

pub const Offer = struct {
    proxy: *wl.DataOffer,
    uri: bool = false,
    files: bool = false,
    gnome: bool = false,
    text: bool = false,
    utf8: bool = false,
    action: wl.DataDeviceManager.DndAction = .{},
};

// A window with no server-side decorations must draw its own titlebar so it
// stays usable (movable, closable) on compositors that don't implement
// zxdg-decoration, e.g. GNOME/Mutter. See plan-file-manager.md section 1.
pub const CSD_TITLEBAR_H: i32 = 32;
pub const RESIZE_MARGIN: f64 = 6;

pub const DecorationMode = enum { unknown, client_side, server_side };

pub const OutputInfo = struct {
    client: *Client,
    proxy: *wl.Output,
    name: u32,
    scale: i32 = 1,
};

pub const ClipboardSource = struct {
    client: *Client,
    proxy: *wl.DataSource,
    uris: []const u8,
    gnome: []const u8,
    text: bool = false,
};

pub const Client = @import("Client.zig");

/// A drag icon whose buffers remain alive until the drag ends.
pub const DragIcon = struct {
    surface: *wl.Surface,
    buffer: *Buffer,
    retired: std.ArrayList(*Buffer) = .empty,
    copy: bool = false,

    pub fn create(client: *Client) !DragIcon {
        const surface = try client.compositor.?.createSurface();
        errdefer surface.destroy();
        const buffer = try Buffer.create(client, 48 * client.scale, 56 * client.scale);
        errdefer buffer.destroy();
        buffer.counts_frame = false;

        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(client.scale), @floatFromInt(client.scale));
        drawFile(client, cr);
        c.cairo_surface_flush(buffer.image);

        surface.setBufferScale(client.scale);
        surface.attach(buffer.wl_buffer, 0, 0);
        surface.damageBuffer(0, 0, buffer.w, buffer.h);
        return .{ .surface = surface, .buffer = buffer };
    }

    pub fn update(self: *DragIcon, client: *Client, copy: bool) !void {
        if (self.copy == copy) return;

        const buffer = try Buffer.create(client, 48 * client.scale, 56 * client.scale);
        errdefer buffer.destroy();
        buffer.counts_frame = false;

        const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(client.scale), @floatFromInt(client.scale));
        drawFile(client, cr);
        if (copy) drawCopyBadge(cr);
        c.cairo_surface_flush(buffer.image);

        try self.retired.append(a, self.buffer);
        self.buffer = buffer;
        self.copy = copy;

        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damageBuffer(0, 0, buffer.w, buffer.h);
        self.surface.commit();
    }

    fn drawFile(client: *Client, cr: *c.cairo_t) void {
        // Transparent padding places the file below and to the right of the pointer.
        for (client.app.items.items) |item| {
            if (!item.selected or item.missing) continue;
            client.app.drawItemIcon(cr, item, 8, 16, 32);
            break;
        }
    }

    fn drawCopyBadge(cr: *c.cairo_t) void {
        c.cairo_arc(cr, 36, 44, 8, 0, 2 * std.math.pi);
        c.cairo_set_source_rgba(cr, 0.08, 0.48, 0.24, 1);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 1);
        c.cairo_set_line_width(cr, 1.5);
        c.cairo_stroke(cr);

        c.cairo_move_to(cr, 32.5, 44);
        c.cairo_line_to(cr, 39.5, 44);
        c.cairo_move_to(cr, 36, 40.5);
        c.cairo_line_to(cr, 36, 47.5);
        c.cairo_set_line_width(cr, 2);
        c.cairo_stroke(cr);
    }

    pub fn destroy(self: *DragIcon) void {
        self.surface.destroy();
        self.buffer.destroy();
        for (self.retired.items) |buffer| buffer.destroy();
        self.retired.deinit(a);
    }
};

pub const Buffer = struct {
    client: *Client,
    wl_buffer: *wl.Buffer,
    image: *c.cairo_surface_t,
    memory: *anyopaque,
    len: usize,
    w: i32,
    h: i32,
    busy: bool = false,
    counts_frame: bool = true,

    pub fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create("rediwm-files", c.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(len)) != 0) return error.ShmFailed;
        const memory = c.mmap(null, len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == c.MAP_FAILED) return error.ShmFailed;
        errdefer _ = c.munmap(memory, len);

        const pool = try client.shm.?.createPool(fd, @intCast(len));
        defer pool.destroy();

        const buffer = try pool.createBuffer(0, w, h, w * 4, .argb8888);
        errdefer buffer.destroy();

        const image = c.cairo_image_surface_create_for_data(
            @ptrCast(memory),
            c.CAIRO_FORMAT_ARGB32,
            w,
            h,
            w * 4,
        ) orelse return error.CairoFailed;
        errdefer c.cairo_surface_destroy(image);

        const self = try a.create(Buffer);
        self.* = .{
            .client = client,
            .wl_buffer = buffer,
            .image = image,
            .memory = memory.?,
            .len = len,
            .w = w,
            .h = h,
        };
        buffer.setListener(*Buffer, released, self);
        return self;
    }

    fn released(_: *wl.Buffer, _: wl.Buffer.Event, self: *Buffer) void {
        self.busy = false;
        if (self.counts_frame) self.client.outstanding -= 1;
    }
    pub fn destroy(self: *Buffer) void {
        self.wl_buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

pub fn run(init: std.process.Init, target_dir: []const u8, selected_file: ?[]const u8, chooser: ?@import("chooser.zig").Options, torrent_source: ?[]const u8, transfers: bool) !void {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);

    const home_dir = init.minimal.environ.getPosix("HOME") orelse "/";
    // Test-only escape hatch: skip decoration negotiation to exercise the
    // same fallback as a compositor without xdg-decoration support.
    const force_csd = init.minimal.environ.getPosix("REDIWM_FILES_FORCE_CSD") != null;
    // The worker follows later edits.
    @import("settings.zig").loadTheme(init.gpa, init.io, init.minimal.environ);
    defer @import("settings.zig").deinitTheme();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const worker = try worker_mod.Worker.init(a, init.io, init.minimal.environ, target_dir);
    defer worker.deinit();

    const app = try app_mod.App.init(
        a,
        init.io,
        init.minimal.environ,
        worker.theme_cfg,
        worker,
        target_dir,
        home_dir,
    );

    var self = Client{
        .display = display,
        .app = app,
        .locale = @import("ui").compose.localeFromEnviron(init.minimal.environ),
    };
    self.ime = .{ .app = &self.app };
    defer self.ime.deinit();
    defer self.compose.deinit();
    defer self.app.deinit();
    if (chooser) |options| try self.app.configureChooser(options);
    if (selected_file) |path| self.app.selectOnLoad(path);
    self.app.startDevices();
    if (chooser == null) self.app.startTorrents();
    if (transfers) self.app.openTransfers();
    if (torrent_source) |source| self.app.torrentSource(source);
    defer {
        self.clearDragIcon();
        self.cancelReceive();
        if (self.drop_receiving) |*receive| receive.deinit();
        for (self.sends.items) |*send| send.deinit();
        self.sends.deinit(a);
        for (self.buffers.items) |buffer| buffer.destroy();
        self.buffers.deinit(a);
        self.retained.deinit(a);
    }

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Client, Client.registryEvent, &self);

    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    if (self.seat) |seat| try self.ime.setup(seat);
    if (self.compositor == null or self.shm == null or self.wm_base == null) {
        return error.MissingWaylandGlobals;
    }

    if (self.data_manager) |manager| {
        if (self.seat) |seat| {
            self.data_device = manager.getDataDevice(seat) catch null;
            if (self.data_device) |device| device.setListener(*Client, Client.dataEvent, &self);
        }
    }

    self.surface = try self.compositor.?.createSurface();
    defer self.surface.destroy();
    self.surface.setListener(*Client, Client.surfaceEvent, &self);

    self.cursor_surface = try self.compositor.?.createSurface();
    defer self.cursor_surface.destroy();
    defer self.cursor_shape.deinit();
    if (self.cursor_shape.manager == null) self.cursor_theme = ClientCursor.loadFallback(self.shm.?);
    defer if (self.cursor_theme) |theme_ptr| theme_ptr.destroy();

    self.xdg_surface = try self.wm_base.?.getXdgSurface(self.surface);
    defer self.xdg_surface.destroy();
    self.xdg_surface.setListener(*Client, Client.xdgSurfaceEvent, &self);

    self.xdg_toplevel = try self.xdg_surface.getToplevel();
    defer self.xdg_toplevel.destroy();
    self.xdg_toplevel.setListener(*Client, Client.xdgToplevelEvent, &self);

    self.xdg_toplevel.setAppId(if (chooser != null) "rediwm-file-chooser" else "rediwm-files");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    // Real min size is set from xdgToplevelEvent once the decoration mode
    // (and thus titlebar height) is known; this is just a safe pre-configure
    // default sized for the worst case (self-decorated).
    self.xdg_toplevel.setMinSize(if (chooser != null) 600 else 360, 214 + self.app.footerHeight() + CSD_TITLEBAR_H);

    // Prefer server-side decorations; the compositor may still tell us via
    // decorationEvent to self-decorate (e.g. it has no SSD implementation),
    // and if zxdg_decoration_manager_v1 isn't advertised at all we already
    // default to self-decorating (see wantsCsd).
    if (self.decoration_manager) |mgr| {
        if (!force_csd) {
            self.decoration = mgr.getToplevelDecoration(self.xdg_toplevel) catch null;
            if (self.decoration) |dec| {
                dec.setListener(*Client, Client.decorationEvent, &self);
                dec.setMode(.server_side);
            }
        }
    }
    defer if (self.decoration) |dec| dec.destroy();

    // Initial commit to start xdg configuration sequence
    self.surface.commit();

    while (self.running and !self.app.closed and !self.app.chooser_done) {
        self.openEditor();
        try self.handleClipboard();
        self.app.stepTorrents();
        self.app.sync();
        self.app.stepThumbs();
        self.app.stepWheel(app_mod.nowMs());
        self.app.stepSelection(app_mod.nowMs());
        self.app.stepLayout(app_mod.nowMs());
        self.app.terminalStep(app_mod.nowMs());
        self.app.terminalFinishClose(app_mod.nowMs());
        self.ime.sync(self.titlebarHeight());
        self.app.stepHover(app_mod.nowMs());
        self.app.stepScrollbar(app_mod.nowMs());
        self.app.stepScanNotice(app_mod.nowMs());
        self.refreshCursor();

        if (self.app.title_changed) {
            self.xdg_toplevel.setTitle(self.app.getTitle());
            self.app.title_changed = false;
        }

        try self.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }

        if (self.app.chooser_done or self.app.closed) {
            display.cancelRead();
            break;
        }
        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds: [23]c.struct_pollfd = @splat(.{ .fd = -1, .events = c.POLLIN, .revents = 0 });
        fds[0] = .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 };
        fds[1].fd = self.app.preview_return_fd orelse -1;
        fds[2].fd = if (self.receiving) |receive| receive.fd else -1;
        fds[3].fd = self.app.worker.wake_main;
        fds[4].fd = if (self.app.dirsize_pool) |p| p.done_fd else -1;
        fds[5].fd = self.app.thumbWakeFd();
        // Slots 6..13 belong to the clipboard sends (at most eight).
        fds[14].fd = self.app.devicesWakeFd();
        fds[15].fd = if (self.drop_receiving) |receive| receive.fd else -1;
        fds[16].fd = self.app.children.fd;
        fds[17].fd = self.app.extract_picker_fd orelse -1;
        fds[18].fd = if (self.app.job_runner) |runner| runner.wake_fd else -1;
        if (self.app.terminal.session) |session| {
            fds[19] = .{ .fd = terminal_c.ft_pty(session), .events = @intCast(c.POLLIN | @as(c_int, if (terminal_c.ft_wants_write(session)) c.POLLOUT else 0)), .revents = 0 };
            fds[20] = .{ .fd = terminal_c.ft_channel(session), .events = @intCast(c.POLLIN | @as(c_int, if (terminal_c.ft_wants_request(session)) c.POLLOUT else 0)), .revents = 0 };
            fds[21].fd = terminal_c.ft_exit_fd(session);
        }
        fds[22].fd = self.app.torrents.fd;
        const send_count = self.sends.items.len;
        for (self.sends.items, 0..) |send, i| fds[i + 6] = .{ .fd = send.fd, .events = c.POLLOUT, .revents = 0 };

        const result = c.poll(&fds, fds.len, self.pollTimeout());
        if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }

        if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
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
        if (fds[16].revents != 0) while (self.app.children.next() != null) {};
        if (fds[18].revents != 0) if (self.app.job_runner) |runner| runner.drain();
        if (fds[17].revents != 0) self.app.extractionFolderReady();
        if (fds[1].revents != 0) self.previewReturned();
        if (self.receiving != null and (fds[2].revents != 0 or app_mod.nowMs() - self.receiving.?.started > transfer.timeout_ms)) self.receiveClipboard();
        if (self.drop_receiving != null and (fds[15].revents != 0 or app_mod.nowMs() - self.drop_receiving.?.started > transfer.timeout_ms)) self.receiveDrop();
        var si = send_count;
        while (si > 0) {
            si -= 1;
            const send = &self.sends.items[si];
            const expired = app_mod.nowMs() - send.started > transfer.timeout_ms;
            if (expired or (fds[si + 6].revents != 0 and (send.write() catch true))) {
                send.deinit();
                _ = self.sends.orderedRemove(si);
            }
        }
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        // After dispatch: a release read by this poll ends the repeat first.
        self.repeatDue();
    }

    if (chooser != null) {
        const result: @import("chooser.zig").Result = .{
            .paths = if (self.app.chooser_accepted) self.app.chooser_paths.items else &.{},
            .filter_index = self.app.chooser.?.filter_index,
            .choices = self.app.chooser_choices.items,
        };
        const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
        defer a.free(bytes);
        try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    }
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
    if (self.clipboard_source) |clip| {
        clip.proxy.destroy();
        a.free(clip.uris);
        a.free(clip.gnome);
        a.destroy(clip);
    }
    if (self.drag_source) |clip| {
        clip.proxy.destroy();
        a.free(clip.uris);
        a.free(clip.gnome);
        a.destroy(clip);
    }
    if (self.data_device) |device| device.release();

    if (self.xkb_state) |state| c.xkb_state_unref(state);
    if (self.xkb_context) |context| c.xkb_context_unref(context);
}

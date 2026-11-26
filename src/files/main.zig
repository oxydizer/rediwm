const std = @import("std");
const platform = @import("platform");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const io_service_mod = @import("io_service.zig");
const io_coordinator_mod = @import("io_coordinator.zig");
const io_endpoint = @import("io_endpoint.zig");
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
    staging_lease: ?clipboard_mod.StagingLease = null,
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
    /// `Client.commit_seq` of the image this buffer holds; 0 = unknown.
    seq: u64 = 0,

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

/// What every window of the process shares when it is created.
pub const Setup = struct {
    io: std.Io,
    environ: std.process.Environ,
    home_dir: []const u8,
    force_csd: bool,
    /// Joins the helper threads of windows that close (`reaper.zig`).
    reaper: *@import("reaper.zig").Reaper,
    /// Each folder's remembered view (`folder_views.zig`).
    folder_views: *@import("folder_views.zig").Store,
};

/// What one window opens with. Only the first window has more than a folder.
pub const Launch = struct {
    dir: []const u8,
    selected_file: ?[]const u8 = null,
    chooser: ?@import("chooser.zig").Options = null,
    torrent_source: ?[]const u8 = null,
    transfers: bool = false,
};

/// What the poll array has room for: the display plus a block per window.
pub const max_windows = 16;

/// Every open window, in the order they were opened. The tab strip handlers
/// look windows up here to move a tab between them.
pub var open_windows: std.ArrayList(*Client) = .empty;

pub fn run(init: std.process.Init, target_dir: []const u8, selected_file: ?[]const u8, chooser: ?@import("chooser.zig").Options, torrent_source: ?[]const u8, transfers: bool) !void {
    platform.process.ignoreBrokenPipes();
    // This thread runs the event loop for every window (plan §1).
    @import("io_thread_guard.zig").markCurrent(.ui);

    // One Files per display (S6): a launch while one runs becomes a window of
    // it. A chooser answers on its own stdout, so it is always a process of
    // its own, and never the one others hand over to. Claimed first, so a
    // handed-over launch exits before doing anything else.
    var instance: ?struct { fd: c_int, paths: io_endpoint.Paths } = null;
    if (chooser == null and torrent_source == null) claim: {
        var paths = io_endpoint.Paths.fromEnviron(a, init.minimal.environ) catch break :claim;
        switch (io_endpoint.claim(a, &paths, .{
            .path = target_dir,
            .select = selected_file,
            .transfers = transfers,
            .activation_token = init.minimal.environ.getPosix("XDG_ACTIVATION_TOKEN"),
        })) {
            .handed_over => {
                paths.deinit(a);
                return;
            },
            .standalone => paths.deinit(a),
            .instance => |fd| instance = .{ .fd = fd, .paths = paths },
        }
    }
    // Until the endpoint takes it over: the socket goes if we fail first.
    defer if (instance) |*held| {
        _ = c.close(held.fd);
        _ = c.unlink(held.paths.socket);
        held.paths.deinit(a);
    };

    const home_dir = init.minimal.environ.getPosix("HOME") orelse "/";
    // Test-only escape hatch: skip decoration negotiation to exercise the
    // same fallback as a compositor without xdg-decoration support.
    const force_csd = init.minimal.environ.getPosix("REDIWM_FILES_FORCE_CSD") != null;
    // The worker follows later edits.
    @import("app_kit").settings.loadTheme(init.gpa, init.io, init.minimal.environ);
    defer @import("app_kit").settings.deinitTheme();

    // The Service and Coordinator outlive every window and the compositor
    // connection. On the way out the windows go first, then the connection,
    // then the coordinator drains accepted work headless (threading §10).
    // Clients receive only their own non-owning Service handle.
    var service: io_service_mod.Service = .{};
    try service.init();
    var coordinator_ready = false;
    errdefer if (!coordinator_ready) service.deinit();

    var coordinator: io_coordinator_mod.Coordinator = undefined;
    try coordinator.init(a, init.io, &service);
    coordinator_ready = true;
    defer {
        coordinator.deinit();
        service.deinit();
    }

    // The endpoint serves launches and the shell panel's subscriptions. Its
    // defer runs before the coordinator's drain: no launch is told yes, and
    // no subscriber holds a table slot, once that starts.
    const endpoint: ?*io_endpoint.Endpoint = if (instance) |*held| blk: {
        defer {
            held.paths.deinit(a);
            instance = null;
        }
        const created = a.create(io_endpoint.Endpoint) catch {
            _ = c.close(held.fd);
            _ = c.unlink(held.paths.socket);
            break :blk null;
        };
        created.start(a, held.fd, held.paths.socket, &service) catch |err| {
            std.log.warn("rediwm-files: cannot serve other launches: {}", .{err});
            _ = c.unlink(held.paths.socket);
            a.destroy(created);
            break :blk null;
        };
        break :blk created;
    } else null;
    defer if (endpoint) |e| {
        e.deinit();
        a.destroy(e);
    };

    // Closing windows hand their helper threads here. It is finished after the
    // windows and the compositor connection are gone (threading §10, U16).
    var reaper: @import("reaper.zig").Reaper = undefined;
    try reaper.start();
    defer reaper.deinit();

    // Read once here; its own thread saves it, last after the windows close.
    const folder_views = @import("folder_views.zig");
    var views: folder_views.Store = undefined;
    const views_path = folder_views.statePath(a, init.minimal.environ) catch null;
    defer if (views_path) |p| a.free(p);
    try views.start(init.io, views_path);
    defer views.deinit();

    // One connection for every window: the compositor sees one client, which
    // is what lets a tab move from one of its windows to another.
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const setup: Setup = .{ .io = init.io, .environ = init.minimal.environ, .home_dir = home_dir, .force_csd = force_csd, .reaper = &reaper, .folder_views = &views };

    const windows = &open_windows;
    defer {
        for (windows.items) |window| window.destroy();
        windows.deinit(a);
    }
    try windows.append(a, try Client.create(display, setup, .{
        .dir = target_dir,
        .selected_file = selected_file,
        .chooser = chooser,
        .torrent_source = torrent_source,
        .transfers = transfers,
    }, &service));

    // A file chooser is one window and ends with its answer; it is printed
    // from the window before it goes.
    var chooser_window: ?*Client = null;
    outer: while (true) {
        var index: usize = 0;
        var ended = false;
        while (index < windows.items.len) {
            const window = windows.items[index];
            if (window.finished()) {
                if (chooser != null) {
                    chooser_window = window;
                    break :outer;
                }
                window.destroy();
                _ = windows.orderedRemove(index);
                continue;
            }
            try window.step();
            // Stepping can end the window (its last tab closed): do not wait in
            // the poll for an event that will not come.
            if (window.finished()) ended = true;
            index += 1;
        }
        if (windows.items.len == 0) {
            if (chooser != null) break;
            // No window, but work in hand: stay, headless, so a launch can
            // still open a window here and show it (architecture §13).
            const serving = if (endpoint) |e| e.serving() else false;
            if (!serving or service.isWorkIdle()) {
                // Stop serving first, then open what was accepted before that:
                // those launchers were told yes and have exited.
                if (endpoint) |e| e.stop();
                if (openRequested(endpoint, windows, display, setup, &service) == 0) break;
                continue;
            }
        }
        if (ended) continue;

        // New Window: opened here, outside the loop above, so the list is not
        // changing under it.
        var opened = false;
        for (windows.items) |window| {
            const path = window.app.new_window orelse continue;
            window.app.new_window = null;
            defer window.app.allocator.free(path);
            if (windows.items.len >= max_windows) {
                window.app.setStatusNotice(@import("i18n").tr("Could not open new window"), true);
                break;
            }
            if (Client.create(display, setup, .{ .dir = path }, &service)) |created| {
                windows.append(a, created) catch created.destroy();
                opened = true;
            } else |err| {
                std.log.warn("rediwm-files: cannot open a window: {}", .{err});
                window.app.setStatusNotice(@import("i18n").tr("Could not open new window"), true);
            }
            break; // the list may have grown; one a turn is plenty
        }

        // Launches handed over by the endpoint.
        if (openRequested(endpoint, windows, display, setup, &service) > 0) continue;

        // Tear-off: the tab leaves for a window of its own, where the compositor
        // is about to place it (it was told at the same moment as this program).
        for (windows.items) |window| {
            const id = window.app.tear_tab orelse continue;
            window.app.tear_tab = null;
            if (windows.items.len >= max_windows or !window.app.movable() or window.app.tabs.items.len < 2) continue;
            const at = window.app.findFolderTab(id) orelse continue;
            const created = Client.create(display, setup, .{ .dir = window.app.tabStart(at) }, &service) catch |err| {
                std.log.warn("rediwm-files: cannot open a window: {}", .{err});
                continue;
            };
            const tab = window.app.takeTab(id) orelse {
                created.destroy();
                continue;
            };
            created.app.replaceBlank(tab) catch {
                created.app.discardTab(tab);
                created.destroy();
                continue;
            };
            windows.append(a, created) catch created.destroy();
            opened = true;
            break;
        }
        if (opened) continue;

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }

        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        // The last two slots are the I/O service's update wake, shared by every
        // window, and the endpoint's open wake.
        var fds: [1 + max_windows * Client.poll_slots + 2]c.struct_pollfd = undefined;
        fds[0] = .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 };
        var timeout: c_int = -1;
        for (windows.items, 0..) |window, i| {
            window.pollFill(fds[1 + i * Client.poll_slots ..][0..Client.poll_slots]);
            const wait = window.pollTimeout();
            if (wait >= 0) timeout = if (timeout < 0) wait else @min(timeout, wait);
        }

        const service_slot = 1 + windows.items.len * Client.poll_slots;
        fds[service_slot] = .{ .fd = service.updateWakeFd(), .events = c.POLLIN, .revents = 0 };
        // Launches handed over by the endpoint; drained by `openRequested`.
        const endpoint_fd: c_int = if (endpoint) |e| (if (e.serving()) e.openWakeFd() else -1) else -1;
        fds[service_slot + 1] = .{ .fd = endpoint_fd, .events = c.POLLIN, .revents = 0 };
        const result = c.poll(&fds, @intCast(service_slot + 2), timeout);
        if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }

        if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
        for (windows.items, 0..) |window, i| window.pollDrain(fds[1 + i * Client.poll_slots ..][0..Client.poll_slots]);
        if (fds[service_slot].revents & c.POLLIN != 0) {
            _ = service.drainUpdateWake();
            for (windows.items) |window| window.app.serviceUpdated();
        }
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        // After dispatch: a release read by this poll ends the repeat first.
        for (windows.items) |window| window.repeatDue();
    }

    if (chooser != null) {
        const window = chooser_window orelse windows.items[0];
        const result: @import("chooser.zig").Result = .{
            .paths = if (window.app.chooser_accepted) window.app.chooser_paths.items else &.{},
            .filter_index = window.app.chooser.?.filter_index,
            .choices = window.app.chooser_choices.items,
        };
        const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
        defer a.free(bytes);
        try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    }
}

/// Opens a window for each launch the endpoint handed over. Returns how many
/// it opened. A launch beyond `max_windows` is dropped with a notice.
fn openRequested(endpoint: ?*io_endpoint.Endpoint, windows: *std.ArrayList(*Client), display: *wl.Display, setup: Setup, service: *io_service_mod.Service) usize {
    const e = endpoint orelse return 0;
    var opened: usize = 0;
    while (e.takeOpen()) |taken| {
        var request = taken;
        defer request.deinit(a);
        if (windows.items.len >= max_windows) {
            if (windows.items.len > 0) windows.items[0].app.setStatusNotice(@import("i18n").tr("Could not open new window"), true);
            continue;
        }
        const created = Client.create(display, setup, .{
            .dir = request.dir,
            .selected_file = request.select,
            .transfers = request.transfers,
        }, service) catch |err| {
            std.log.warn("rediwm-files: cannot open a window: {}", .{err});
            continue;
        };
        windows.append(a, created) catch {
            created.destroy();
            continue;
        };
        if (request.activation_token) |token| created.activateWith(token);
        opened += 1;
    }
    return opened;
}

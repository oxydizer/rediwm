// Standalone text editor; decoration negotiation follows files/main.zig.
const std = @import("std");
const platform = @import("platform");
const ClientCursor = @import("ui").client_cursor;
const ClientTabs = @import("ui").client_tabs;
const client_tabs = @import("client_tabs.zig");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("../files/c.zig").api;
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const button_widget = @import("ui").widgets.button;
const IconId = @import("ui").layout.IconId;
const client_window = @import("client_window.zig");
const client_input = @import("client_input.zig");
const client_render = @import("client_render.zig");
const client_lifecycle = @import("client_lifecycle.zig");
const a = std.heap.c_allocator;

// The fallback client-side header owns the menu and window controls.
pub const RESIZE_MARGIN: f64 = 6;

const DecorationMode = enum { unknown, client_side, server_side };

pub const OutputInfo = struct {
    client: *Client,
    proxy: *wl.Output,
    name: u32,
    scale: i32 = 1,
    logical: ?*zxdg.OutputV1 = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
};

pub const Client = struct {
    display: *wl.Display,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    output_manager: ?*zxdg.OutputManagerV1 = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    scale: i32 = 1,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    input_serial: u32 = 0,
    wm_base: ?*xdg.WmBase = null,
    activation: ?*xdg.ActivationV1 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    xdg_toplevel: *xdg.Toplevel = undefined,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    decoration_mode: DecorationMode = .unknown,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    cursor_shape: ClientCursor = .{},
    tabs: ClientTabs = .{},
    cursor_surface: *wl.Surface = undefined,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_serial: u32 = 0,
    cursor_name: [*:0]const u8 = "",
    inside: bool = false,
    configured: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    last_title_click: i64 = 0,
    running: bool = true,
    outstanding: usize = 0,
    buffers: [2]?*Buffer = @splat(null),
    applied_scale: i32 = 0,
    /// Pending `wl_surface.frame` callback of the last commit. Glow-only
    /// frames wait for it, so they follow the display, not the pointer rate.
    frame_callback: ?*wl.Callback = null,
    xkb_context: ?*c.xkb_context = null,
    xkb_state: ?*c.xkb_state = null,
    key_repeat: key_repeat.KeyRepeat = .{},
    app: app_mod.App,
    caret_state: ?app_mod.App.CaretState = null,
    clipboard: @import("clipboard.zig").Clipboard = undefined,
    ime: @import("ime.zig").Ime = undefined,
    compose: @import("ui").compose.Compose = .{},
    /// LC_CTYPE of the session; picks the Compose table (´+c is ç in pt_BR).
    locale: []const u8 = "",

    pub const create = client_lifecycle.create;
    pub const step = client_lifecycle.step;
    pub const destroy = client_lifecycle.destroy;
    pub const registryEvent = client_window.registryEvent;
    pub const close = client_window.close;
    pub const logicalOutputEvent = client_window.logicalOutputEvent;
    pub const recomputeScale = client_window.recomputeScale;
    pub const removeEnteredOutput = client_window.removeEnteredOutput;
    pub const surfaceEvent = client_window.surfaceEvent;
    pub const xdgSurfaceEvent = client_window.xdgSurfaceEvent;
    pub const wantsCsd = client_window.wantsCsd;
    pub const titlebarHeight = client_window.titlebarHeight;
    pub const decorationEvent = client_window.decorationEvent;
    pub const xdgToplevelEvent = client_window.xdgToplevelEvent;

    pub const pointerEvent = client_input.pointerEvent;
    pub const updateCursor = client_input.updateCursor;
    pub const handlePointerMotion = client_input.handlePointerMotion;
    pub const handlePointerButton = client_input.handlePointerButton;
    pub const HeaderControl = client_input.HeaderControl;
    pub const headerButton = client_input.headerButton;
    pub const overHeaderButton = client_input.overHeaderButton;
    pub const toggleMaximized = client_input.toggleMaximized;
    pub const handleTitlebarClick = client_input.handleTitlebarClick;
    pub const deliverKey = client_input.deliverKey;
    pub const appRepeats = client_input.appRepeats;
    pub const repeatDue = client_input.repeatDue;
    pub const keyboardEvent = client_input.keyboardEvent;
    pub const setCursor = client_input.setCursor;

    pub const acquireBuffer = client_render.acquireBuffer;
    pub const render = client_render.render;
    pub const renderTitlebar = client_render.renderTitlebar;
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

    pub fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create("rediwm-editor", c.MFD_CLOEXEC);
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
        if (c.cairo_surface_status(image) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

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
        self.client.outstanding -= 1;
    }
    pub fn destroy(self: *Buffer) void {
        self.wl_buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

/// What every window of the process shares when it is created.
pub const Setup = struct { io: std.Io, environ: std.process.Environ, force_csd: bool };

pub fn run(init: std.process.Init, paths: []const [:0]const u8, instance: *@import("instance.zig").Instance, initial_token: []const u8) !void {
    platform.process.ignoreBrokenPipes();
    const force_csd = init.minimal.environ.getPosix("REDIWM_EDITOR_FORCE_CSD") != null;
    @import("../files/settings.zig").loadTheme(init.gpa, init.io, init.minimal.environ);
    defer @import("../files/settings.zig").deinitTheme();
    // Use the same persisted caret and motion preferences as shell fields.
    if (@import("config").loader.loadDefault(init.gpa, init.io, init.minimal.environ)) |loaded| {
        var cfg = loaded;
        defer cfg.deinit();
        @import("ui").input.caret_config = .{
            .blink_ms = cfg.input.caret_blink_ms,
            .blink_timeout_s = cfg.input.caret_blink_timeout,
            .motion_ms = cfg.input.caret_motion_ms,
        };
        @import("ui").anim.applySettings(cfg.animations);
    } else |_| {}
    // One connection for every window: the compositor sees one client, which
    // is what lets a tab move from one of its windows to another.
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const setup: Setup = .{ .io = init.io, .environ = init.minimal.environ, .force_csd = force_csd };

    var windows: std.ArrayList(*Client) = .empty;
    defer {
        for (windows.items) |window| window.destroy();
        windows.deinit(a);
    }
    // The first window owns the drafts; it is also where the instance socket's
    // requests and the activation token go.
    try windows.append(a, try Client.create(display, setup, true, paths));

    var pending_token = try a.dupeSentinel(u8, initial_token, 0);
    defer a.free(pending_token);
    while (windows.items.len > 0) {
        for (windows.items) |window| window.app.sync();
        windows.items[0].app.stepDrafts(key_repeat.nowMs());
        // The session is ending: leave without asking; `deinit` writes the drafts.
        if (windows.items[0].app.signaled()) for (windows.items) |window| {
            window.app.closed = true;
        };
        var index: usize = 0;
        while (index < windows.items.len) {
            const window = windows.items[index];
            try window.step();
            if (!window.running) {
                window.destroy();
                _ = windows.orderedRemove(index);
                continue;
            }
            if (index == 0 and window.configured and window.applied_scale > 0 and pending_token.len > 0) {
                if (window.activation) |activation| activation.activate(pending_token, window.surface);
                a.free(pending_token);
                pending_token = try a.dupeSentinel(u8, "", 0);
            }
            index += 1;
        }
        if (windows.items.len == 0) break;

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }

        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds: [128]c.struct_pollfd = @splat(.{ .fd = -1, .events = 0, .revents = 0 });
        fds[0] = .{ .fd = display.getFd(), .events = @intCast(c.POLLIN | @as(c_int, if (flushed == .AGAIN) c.POLLOUT else 0)), .revents = 0 };
        fds[1] = .{ .fd = instance.fd, .events = c.POLLIN, .revents = 0 };
        fds[2] = .{ .fd = windows.items[0].app.draftWake(), .events = c.POLLIN, .revents = 0 };
        var fd_count: usize = 3;
        const poll_now = key_repeat.nowMs();
        var timeout: c_int = -1;
        for (windows.items) |window| {
            fds[fd_count] = .{ .fd = if (window.app.operation) |job| job.fd else -1, .events = c.POLLIN, .revents = 0 };
            fd_count += 1;
            fd_count += window.clipboard.addPoll(fds[fd_count..]);
            if (window.key_repeat.timeoutMs(poll_now)) |wait| {
                const ms: c_int = @intCast(@min(wait, 60_000));
                timeout = if (timeout < 0) ms else @min(timeout, ms);
            }
            if (window.app.barTimeout(poll_now)) |wait| timeout = if (timeout < 0) @intCast(wait) else @min(timeout, @as(c_int, @intCast(wait)));
            timeout = window.app.caret.timeout(poll_now, window.clipboard.timeout(timeout));
        }
        if (windows.items[0].app.draftTimeout(poll_now)) |wait| {
            const ms: c_int = @intCast(@min(wait, 60_000));
            timeout = if (timeout < 0) ms else @min(timeout, ms);
        }
        const result = c.poll(&fds, @intCast(fd_count), timeout);
        if (result > 0 and (fds[0].revents & c.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }
        if ((fds[0].revents & (c.POLLERR | c.POLLHUP)) != 0) return error.DisplayFailed;
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        if (fds[2].revents & c.POLLIN != 0) windows.items[0].app.drainDrafts();
        if (fds[1].revents & c.POLLIN != 0) {
            var request_buf: [16384]u8 = undefined;
            if (instance.receive(&request_buf)) |bytes| {
                if (std.json.parseFromSlice(@import("instance.zig").Request, a, bytes, .{})) |parsed| {
                    defer parsed.deinit();
                    const req = parsed.value;
                    // Requests go to the window the user is in, else the first.
                    var target = windows.items[0];
                    for (windows.items) |window| {
                        if (window.app.focused) target = window;
                    }
                    if (req.path.len == 0) target.app.newTab() catch {} else if (std.fs.path.isAbsolute(req.path) and std.mem.indexOfScalar(u8, req.path, 0) == null) target.app.open(req.path);
                    if (req.token.len > 0 and std.mem.indexOfScalar(u8, req.token, 0) == null) {
                        const owned = try a.dupeSentinel(u8, req.token, 0);
                        a.free(pending_token);
                        pending_token = owned;
                    }
                } else |_| {}
            }
        }
        for (windows.items) |window| {
            if (window.app.closed) continue;
            window.clipboard.dispatch();
            window.repeatDue();
        }
    }
}

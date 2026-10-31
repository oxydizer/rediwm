//! Wayland client lifecycle, buffer presentation, decoration negotiation and input loop for rediwm-pdf.
const std = @import("std");
const ClientCursor = @import("ui").client_cursor;
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const c = @import("c.zig");
const app_mod = @import("app.zig");
const key_repeat = @import("ui").key_repeat;
const ui_theme = @import("ui").theme;
const shell_ui = @import("ui").cairo;
const shell_text = @import("ui").text;
const client_window = @import("client_window.zig");
const client_input = @import("client_input.zig");
const client_render = @import("client_render.zig");
const client_print = @import("client_print.zig");

// `sandbox.c` calls the exported syscall policy.
comptime {
    _ = @import("syscall_policy.zig");
}

const a = std.heap.c_allocator;

pub const CSD_TITLEBAR_H: i32 = 32;
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
    data_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    clipboard_source: ?*ClipboardSource = null,
    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    xdg_toplevel: *xdg.Toplevel = undefined,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    decoration_mode: DecorationMode = .unknown,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    cursor_shape: ClientCursor = .{},
    cursor_surface: *wl.Surface = undefined,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_serial: u32 = 0,
    cursor_name: [*:0]const u8 = "",
    inside: bool = false,
    configured: bool = false,
    running: bool = true,
    outstanding: usize = 0,
    buffers: [2]?*Buffer = @splat(null),
    applied_scale: i32 = 0,
    xkb_context: ?*c.api.xkb_context = null,
    xkb_state: ?*c.api.xkb_state = null,
    key_repeat: key_repeat.KeyRepeat = .{},
    compose: @import("ui").compose.Compose = .{},
    /// LC_CTYPE of the session; picks the Compose table (´+c is ç in pt_BR).
    locale: []const u8 = "",
    /// Socket to the unsandboxed print helper, or -1 without one.
    print_fd: c_int = -1,
    app: app_mod.App,

    pub const registryEvent = client_window.registryEvent;
    const logicalOutputEvent = client_window.logicalOutputEvent;
    const surfaceEvent = client_window.surfaceEvent;
    pub const removeEnteredOutput = client_window.removeEnteredOutput;
    pub const recomputeScale = client_window.recomputeScale;
    const xdgSurfaceEvent = client_window.xdgSurfaceEvent;
    pub const wantsCsd = client_window.wantsCsd;
    pub const titlebarHeight = client_window.titlebarHeight;
    const decorationEvent = client_window.decorationEvent;
    const xdgToplevelEvent = client_window.xdgToplevelEvent;

    pub const pointerEvent = client_input.pointerEvent;
    pub const updateCursor = client_input.updateCursor;
    pub const handlePointerMotion = client_input.handlePointerMotion;
    pub const handlePointerButton = client_input.handlePointerButton;
    pub const handleTitlebarClick = client_input.handleTitlebarClick;
    pub const deliverKey = client_input.deliverKey;
    pub const appRepeats = client_input.appRepeats;
    const repeatDue = client_input.repeatDue;
    pub const keyboardEvent = client_input.keyboardEvent;
    pub const setCursor = client_input.setCursor;

    pub const acquireBuffer = client_render.acquireBuffer;
    pub const render = client_render.render;
    pub const renderTitlebar = client_render.renderTitlebar;

    const requestPrint = client_print.requestPrint;
    const readPrintReplies = client_print.readPrintReplies;
    pub const closePrint = client_print.closePrint;
    const publishClipboard = client_print.publishClipboard;
};

pub const ClipboardSource = struct {
    client: *Client,
    proxy: *wl.DataSource,
    text: [:0]const u8,

    pub fn destroy(self: *ClipboardSource) void {
        self.proxy.destroy();
        a.free(self.text);
        a.destroy(self);
    }

    pub fn event(proxy: *wl.DataSource, ev: wl.DataSource.Event, self: *ClipboardSource) void {
        switch (ev) {
            .send => |s| {
                defer _ = c.api.close(s.fd);
                _ = c.api.write(s.fd, self.text.ptr, self.text.len);
            },
            .cancelled => {
                if (self.client.clipboard_source == self) {
                    self.client.clipboard_source = null;
                }
                self.destroy();
            },
            else => {},
        }
        _ = proxy;
    }
};

pub fn dataDeviceEvent(_: *wl.DataDevice, _: wl.DataDevice.Event, _: *Client) void {}

pub const Buffer = struct {
    client: *Client,
    wl_buffer: *wl.Buffer,
    image: *c.api.cairo_surface_t,
    memory: *anyopaque,
    len: usize,
    w: i32,
    h: i32,
    busy: bool = false,

    pub fn create(client: *Client, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.api.memfd_create("rediwm-pdf", c.api.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = c.api.close(fd);

        if (c.api.ftruncate(fd, @intCast(len)) != 0) return error.ShmFailed;
        const memory = c.api.mmap(null, len, c.api.PROT_READ | c.api.PROT_WRITE, c.api.MAP_SHARED, fd, 0);
        if (memory == c.api.MAP_FAILED) return error.ShmFailed;
        errdefer _ = c.api.munmap(memory, len);

        const pool = try client.shm.?.createPool(fd, @intCast(len));
        defer pool.destroy();

        const buffer = try pool.createBuffer(0, w, h, w * 4, .argb8888);
        errdefer buffer.destroy();

        const image = c.api.cairo_image_surface_create_for_data(
            @ptrCast(memory),
            c.api.CAIRO_FORMAT_ARGB32,
            w,
            h,
            w * 4,
        ) orelse return error.CairoFailed;
        errdefer c.api.cairo_surface_destroy(image);
        if (c.api.cairo_surface_status(image) != c.api.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

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
        c.api.cairo_surface_destroy(self.image);
        _ = c.api.munmap(self.memory, self.len);
        a.destroy(self);
    }
};

pub fn run(init: std.process.Init.Minimal) !void {
    _ = c.api.signal(c.api.SIGPIPE, c.api.SIG_IGN);
    const args = init.args.vector;

    if (args.len >= 2 and (std.mem.eql(u8, std.mem.span(args[1]), "--help") or std.mem.eql(u8, std.mem.span(args[1]), "-h"))) {
        std.debug.print(
            \\Usage: rediwm-pdf [--] FILE
            \\
            \\A sandboxed Wayland PDF viewer; one document per process.
            \\Open another document from Files to start a new viewer.
            \\
            \\Controls:
            \\  Wheel/Arrows: Scroll document
            \\  Ctrl+Wheel / +/-: Zoom in/out
            \\  0 / 9: Fit width / Fit page
            \\  R: Rotate 90° clockwise
            \\  Ctrl+L: Jump to page
            \\  Ctrl+P: Print
            \\  PageUp / PageDown / Space: Move viewport
            \\  Home / End: First / Last page
            \\  Ctrl+W / Esc: Close window / dialog
            \\
        , .{});
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, std.mem.span(args[1]), "--version")) {
        std.debug.print("rediwm-pdf 0.1.0\n", .{});
        return;
    }

    var i: usize = 1;
    if (args.len >= 2 and std.mem.eql(u8, std.mem.span(args[1]), "--")) i = 2;
    if (args.len != i + 1) {
        std.log.err("usage: rediwm-pdf [--] FILE; open another PDF from Files", .{});
        return error.ExpectedDocument;
    }
    const raw = std.mem.span(args[i]);
    const initial_path = try a.dupeSentinel(u8, raw, 0);
    defer a.free(initial_path);
    const document_fd = c.rediwm_pdf_open_document(initial_path.ptr);
    if (document_fd < 0) return error.CannotOpenRegularFile;
    defer _ = c.api.close(document_fd);
    // Printing needs the session bus, which the sandbox denies: fork the
    // helper now, while this process is unsandboxed and single-threaded.
    const print_fd = c.rediwm_pdf_print_start(document_fd, initial_path.ptr);
    if (print_fd < 0) std.log.warn("print helper unavailable; printing is disabled", .{});
    const force_csd = init.environ.getPosix("REDIWM_PDF_FORCE_CSD") != null;
    // Read before the sandbox closes the filesystem.
    @import("../files/settings.zig").loadTheme(a, std.Io.Threaded.global_single_threaded.io(), init.environ);
    defer @import("../files/settings.zig").deinitTheme();
    // Open the selected faces now: user-installed fonts can live outside
    // the system font directories the sandbox permits.
    for ([_]shell_text.Font{ .manrope, .manrope_bold }) |font| {
        shell_text.warmGlyphs(font, shell_ui.textSize(), 1, "") catch {};
    }

    // The Compose table for dead keys is a file read; the first dead key
    // would come after the sandbox closed the filesystem.
    const locale = @import("ui").compose.localeFromEnviron(init.environ);
    @import("ui").compose.preload(locale);

    const display = try @import("connection.zig").connect();
    defer display.disconnect();
    if (c.rediwm_pdf_sandbox_enter(document_fd, display.getFd(), print_fd) != 0) {
        std.log.err("required PDF sandbox could not be installed; refusing to parse the document", .{});
        return error.SandboxUnavailable;
    }

    var self = Client{
        .display = display,
        .print_fd = print_fd,
        .app = try app_mod.App.init(initial_path, document_fd),
        .locale = locale,
    };
    defer self.compose.deinit();
    defer self.closePrint();
    defer self.app.deinit();
    defer for (self.buffers) |slot| {
        if (slot) |buffer| buffer.destroy();
    };

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Client, Client.registryEvent, &self);

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

    self.xdg_toplevel.setAppId("rediwm-pdf");
    self.xdg_toplevel.setTitle(self.app.getTitle());
    self.xdg_toplevel.setMinSize(480, 320 + CSD_TITLEBAR_H);

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

    self.surface.commit();

    while (self.running) {
        self.app.sync();
        if (self.app.clipboard_request) {
            self.publishClipboard();
        }
        if (self.app.print_request) self.requestPrint();
        if (self.app.closed) {
            self.running = false;
            break;
        }

        if (self.app.title_changed) {
            self.xdg_toplevel.setTitle(self.app.getTitle());
            self.app.title_changed = false;
        }

        self.app.stepBar(key_repeat.nowMs());
        try self.render();

        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        }
        if (!self.running) {
            display.cancelRead();
            break;
        }

        const flushed = display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) {
            display.cancelRead();
            return error.DisplayFailed;
        }

        var fds = [_]c.api.struct_pollfd{
            .{ .fd = display.getFd(), .events = @intCast(c.api.POLLIN | @as(c_int, if (flushed == .AGAIN) c.api.POLLOUT else 0)), .revents = 0 },
            .{ .fd = self.app.worker.fds[0], .events = c.api.POLLIN, .revents = 0 },
            // poll ignores a negative fd.
            .{ .fd = self.print_fd, .events = c.api.POLLIN, .revents = 0 },
        };
        const now = key_repeat.nowMs();
        var timeout: c_int = if (self.key_repeat.timeoutMs(now)) |wait| @intCast(@min(wait, 60_000)) else -1;
        if (self.app.barTimeout(now)) |wait| timeout = if (timeout < 0) @intCast(wait) else @min(timeout, @as(c_int, @intCast(wait)));
        const result = c.api.poll(&fds, fds.len, timeout);
        if (result > 0 and (fds[0].revents & c.api.POLLIN != 0)) {
            if (display.readEvents() != .SUCCESS) return error.DisplayFailed;
        } else {
            display.cancelRead();
        }
        if ((fds[0].revents & (c.api.POLLERR | c.api.POLLHUP)) != 0) return error.DisplayFailed;
        if (fds[2].revents != 0) self.readPrintReplies();
        if (display.dispatchPending() != .SUCCESS) return error.DisplayFailed;
        self.repeatDue();
    }

    if (self.clipboard_source) |cs| cs.destroy();
    if (self.data_device) |dd| dd.release();

    for (self.outputs.items) |info| {
        if (info.logical) |logical| logical.destroy();
        info.proxy.destroy();
        a.destroy(info);
    }
    self.outputs.deinit(a);
    self.entered_outputs.deinit(a);
    if (self.xkb_state) |state| c.api.xkb_state_unref(state);
    if (self.xkb_context) |context| c.api.xkb_context_unref(context);
}

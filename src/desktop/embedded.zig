//! The desktop drawn by the compositor itself, enabled by `[desktop] enabled`
//! (plan-fold-desktop-into-compositor.md, Phase 2).
//!
//! `App` paints into one retained canvas. The canvas is published as fixed
//! tiles in `world_desktop_tree`: a change swaps and uploads only the tiles it
//! touches, and hands projection its exact damage. A single output-sized
//! buffer would re-upload the whole output on GLES2 for every hover frame and,
//! without damage, repaint the whole output as well.
//!
//! The canvas exists only while the desktop paints: it is allocated zeroed on
//! demand (untouched pages cost nothing), knows which tiles it holds, and is
//! freed `canvas_idle_ms` after the last paint; a tile it no longer holds is
//! repainted whole the next time damage reaches it. A tile with no visible
//! pixel is transparent, so it is neither uploaded nor drawn (2026-11-25: a
//! drag over the desktop drew 27 such tiles a frame, +27% instructions, and
//! the canvas kept 16 MB at 2560x1600).
//!
//! The filesystem worker stays a thread. The compositor thread only paints,
//! and wakes for worker results, deadlines and animation frames; an idle
//! desktop arms no timer.
const std = @import("std");
const platform = @import("platform");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const pixman = @import("pixman");

const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const host_mod = @import("host.zig");
const Worker = @import("watcher.zig").Worker;
const grid = @import("grid.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const geometry = @import("../geometry.zig");
const SceneData = @import("../scene_data.zig").SceneData;
const clipboard = @import("../clipboard.zig");
const DropTarget = @import("../desktop_drop.zig").Target;
const dnd = @import("dnd.zig");
const app_scope = @import("../session/app_scope.zig");
const embedded_tiles = @import("embedded_tiles.zig");

const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;

/// Logical tile edge. 240 × any scale in 1/120 steps (wp_fractional_scale's
/// unit) is a whole number of device pixels, so tiles meet without seams.
pub const tile_logical: i32 = 240;

pub const Desktop = struct {
    server: *Server,
    worker: *Worker,
    app: app_mod.App,
    tree: *sn.Tree,
    overlay: *sn.Buffer,
    overlay_rect: ?grid.Rect = null,
    output: ?*Output = null,
    /// Layout box and scale the canvas and tiles were built for.
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scale: f32 = 0,
    /// Zeroed by calloc, empty while the desktop is idle (see the file comment).
    canvas: []u32 = &.{},
    surface: ?*c.cairo_surface_t = null,
    canvas_width: i32 = 0,
    canvas_height: i32 = 0,
    /// When an idle canvas is freed; null without a canvas.
    canvas_release_at: ?i64 = null,
    /// The timer is armed for `canvas_release_at` alone, not for the App.
    timer_for_canvas: bool = false,
    tiles: std.ArrayList(Tile) = .empty,
    /// Every other available output shows only the desktop's own wallpaper.
    secondaries: std.ArrayList(Secondary) = .empty,
    wake: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    /// Something happened since the last tick: a worker result, a deadline,
    /// input, or a layout change. Otherwise only animation needs frames.
    pending: bool = true,
    animating: bool = false,
    /// Keys go to the desktop, as shell UI: compositor bindings still win,
    /// and no client (or input method) holds keyboard focus meanwhile.
    keyboard_focused: bool = false,
    focus_change: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(focusChanged),
    cursor: host_mod.Cursor = .normal,
    /// The pointer is over the desktop, so its cursor is the desktop's.
    hovered: bool = false,
    drop_target: DropTarget = .{},
    /// The worker is reading a drop or paste; one runs at a time.
    transfer: enum { none, drop, paste } = .none,
    /// Hit-test role shared by every tile.
    scene_data: SceneData = undefined,

    const DropAt = struct {
        destination: dnd.Destination,
        path: ?[]const u8 = null,
    };

    const Secondary = struct {
        output: *Output,
        node: *sn.Buffer,
        box: wlr.Box,
        scale: f32,
        /// The App wallpaper revision this view shows; null repaints it.
        revision: ?u64 = null,
    };

    pub const Tile = struct {
        node: *sn.Buffer,
        /// Device-pixel rectangle within the canvas.
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        /// Logical rectangle, for damage.
        logical: grid.Rect,
        /// The canvas holds this tile's current pixels.
        valid: bool = false,
        /// The tile has a visible pixel. An empty tile's node is transparent:
        /// never drawn, still the desktop for input, its texture kept.
        shown: bool = false,
        /// The node has a texture.
        textured: bool = false,
    };

    pub const canvas_idle_ms = 3000;

    pub fn create(server: *Server) !*Desktop {
        var child_env = try server.environ.createMap(a);
        const worker = blk: {
            errdefer child_env.deinit();
            try server.applyChildEnv(&child_env);
            break :blk try Worker.init(server.io, server.environ, child_env);
        };
        errdefer worker.deinit();
        const tree = try server.world_desktop_tree.createSceneTree();
        errdefer tree.node.destroy();
        const overlay = try server.overlay_tree.createSceneBuffer(null);
        errdefer overlay.node.destroy();
        overlay.node.setEnabled(false);
        overlay.point_accepts_input = overlayAcceptsInput;
        overlay.setFilterMode(.bilinear);
        const self = try a.create(Desktop);
        errdefer a.destroy(self);
        self.* = .{ .server = server, .worker = worker, .app = .{ .worker = worker, .separate_overlays = true }, .tree = tree, .overlay = overlay };
        self.app.host = .{ .ctx = self, .vtable = &vtable };
        self.scene_data = .{ .role = .{ .desktop = self } };
        self.scene_data.attach(&overlay.node);
        server.input.seat.keyboard_state.events.focus_change.add(&self.focus_change);
        errdefer self.focus_change.link.remove();
        const loop = server.wl_server.getEventLoop();
        self.wake = try loop.addFd(*Desktop, worker.wake_main, .{ .readable = true }, workerWake, self);
        errdefer self.wake.?.remove();
        self.timer = try loop.addTimer(*Desktop, deadline, self);
        self.syncLayout();
        return self;
    }

    pub fn destroy(self: *Desktop) void {
        if (self.wake) |source| source.remove();
        if (self.timer) |source| source.remove();
        self.focus_change.link.remove();
        if (self.drop_target.active) self.drop_target.finish(false);
        // Tile buffers still locked by the scene return to the pool when
        // wlroots releases them; none of them points back at this desktop.
        self.tree.node.destroy();
        self.overlay.node.destroy();
        self.freeCanvas();
        self.tiles.deinit(a);
        self.secondaries.deinit(a);
        self.app.deinit();
        self.worker.stopAndJoin();
        self.takeChildren();
        self.worker.deinit();
        a.destroy(self);
    }

    /// Follows the primary output's box and scale. A change rebuilds the
    /// canvas and tiles and repaints everything.
    pub fn syncLayout(self: *Desktop) void {
        self.syncPrimary();
        // Secondary views sit relative to the primary box.
        self.syncSecondaries();
    }

    fn syncPrimary(self: *Desktop) void {
        const output = self.server.effectivePrimaryOutput();
        self.output = output;
        const out = output orelse {
            self.tree.node.setEnabled(false);
            self.overlay.node.setEnabled(false);
            return;
        };
        var box: wlr.Box = undefined;
        self.server.output_layout.getBox(out.wlr_output, &box);
        if (box.width <= 0 or box.height <= 0) return;
        const scale = out.wlr_output.scale;
        self.tree.node.setEnabled(true);
        self.tree.node.setPosition(box.x, box.y);
        // The taskbar may have changed height without a box/scale change.
        self.app.geometry.top = out.usableBox().y - box.y;
        self.app.refreshBottom();
        if (box.width == self.box.width and box.height == self.box.height and scale == self.scale) {
            self.box = box;
            self.app.invalidate();
            self.schedule();
            return;
        }
        self.box = box;
        self.scale = scale;
        self.rebuild() catch |err| {
            log.err("desktop canvas {d}x{d}@{d}: {}", .{ box.width, box.height, scale, err });
            self.freeCanvas();
            self.clearTiles();
            return;
        };
        self.app.resize(box.width, box.height);
        // Icon rasters are loaded for the output's pixel density.
        const icon_size: i32 = @intFromFloat(@ceil(56 * scale));
        if (self.worker.icon_size.swap(icon_size, .acq_rel) != icon_size) self.worker.requestRefresh();
        self.schedule();
    }

    /// Forgets a dying output before it is freed; `syncLayout` follows.
    pub fn outputRemoved(self: *Desktop, output: *Output) void {
        if (self.output == output) self.output = null;
        var i: usize = 0;
        while (i < self.secondaries.items.len) {
            if (self.secondaries.items[i].output == output) {
                self.secondaries.items[i].node.node.destroy();
                _ = self.secondaries.swapRemove(i);
            } else i += 1;
        }
    }

    fn syncSecondaries(self: *Desktop) void {
        var i: usize = 0;
        while (i < self.secondaries.items.len) {
            const view = &self.secondaries.items[i];
            if (view.output == self.output or !view.output.isAvailable()) {
                view.node.node.destroy();
                _ = self.secondaries.swapRemove(i);
            } else i += 1;
        }
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |output| {
            if (output == self.output or !output.isAvailable()) continue;
            var box: wlr.Box = undefined;
            self.server.output_layout.getBox(output.wlr_output, &box);
            if (box.width <= 0 or box.height <= 0) continue;
            const view = for (self.secondaries.items) |*view| {
                if (view.output == output) break view;
            } else blk: {
                const node = self.tree.createSceneBuffer(null) catch continue;
                self.secondaries.append(a, .{ .output = output, .node = node, .box = box, .scale = 0 }) catch {
                    node.node.destroy();
                    continue;
                };
                break :blk &self.secondaries.items[self.secondaries.items.len - 1];
            };
            const scale = output.wlr_output.scale;
            if (view.box.width != box.width or view.box.height != box.height or view.scale != scale) view.revision = null;
            view.box = box;
            view.scale = scale;
            // Tiles sit relative to the primary box; views are placed in
            // world coordinates relative to the same tree.
            view.node.node.setPosition(box.x - self.box.x, box.y - self.box.y);
            view.node.setDestSize(box.width, box.height);
        }
        self.paintSecondaries();
    }

    /// Redraws a secondary view when its wallpaper or geometry changed.
    fn paintSecondaries(self: *Desktop) void {
        const projection = self.server.world.projection;
        for (self.secondaries.items) |*view| {
            if (view.revision == self.app.wallpaper_revision) continue;
            view.revision = self.app.wallpaper_revision;
            const image = self.app.wallpaper orelse {
                // No desktop wallpaper: the compositor's own shows through.
                view.node.setBuffer(null);
                projection.damageBuffer(view.node, null);
                continue;
            };
            const width = geometry.devicePixels(view.box.width, view.scale);
            const height = geometry.devicePixels(view.box.height, view.scale);
            if (width > 16384 or height > 16384) continue;
            // A static image the size of an output would only bloat the tile pool.
            const buffer = TileBuffer.create(width, height, false) catch |err| {
                log.warn("desktop wallpaper {d}x{d}: {}", .{ width, height, err });
                continue;
            };
            @memset(buffer.pixels, 0);
            const surface = c.cairo_image_surface_create_for_data(@ptrCast(buffer.pixels.ptr), c.CAIRO_FORMAT_ARGB32, width, height, width * 4);
            if (surface) |image_surface| {
                defer c.cairo_surface_destroy(image_surface);
                if (c.cairo_create(image_surface)) |cr| {
                    c.cairo_scale(cr, view.scale, view.scale);
                    @import("wallpaper.zig").render(image, cr, view.box.width, view.box.height);
                    c.cairo_destroy(cr);
                }
                c.cairo_surface_flush(image_surface);
            }
            _ = projection.presentOwned(view.node, self.server.renderer, &buffer.base, null);
            buffer.base.drop();
        }
    }

    const rebuild = embedded_tiles.rebuild;
    pub const ensureCanvas = embedded_tiles.ensureCanvas;
    pub const freeCanvas = embedded_tiles.freeCanvas;
    pub const clearTiles = embedded_tiles.clearTiles;
    pub const paint = embedded_tiles.paint;
    pub const publish = embedded_tiles.publish;
    pub const tileEmpty = embedded_tiles.tileEmpty;
    pub const deviceRect = embedded_tiles.deviceRect;
    pub const touches = embedded_tiles.touches;

    /// Asks the desktop's output for a frame, where `frame` does the work.
    pub fn schedule(self: *Desktop) void {
        self.pending = true;
        if (self.output) |output| output.wlr_output.scheduleFrame();
    }

    pub fn themeChanged(self: *Desktop) void {
        self.app.themeChanged();
        self.schedule();
    }

    /// Runs from the output's frame handler, before projection is synced.
    /// Returns whether the desktop is still animating.
    pub fn frame(self: *Desktop, output: *Output) bool {
        if (self.output != output or (!self.pending and !self.animating)) return false;
        self.pending = false;
        if (self.transfer != .none and self.worker.drop_done.load(.acquire)) {
            if (self.transfer == .drop) self.drop_target.finish(self.worker.drop_success.load(.acquire));
            self.transfer = .none;
        }
        self.app.sync();
        self.paintSecondaries();
        self.animating = self.app.tick();
        if (self.app.dirty) self.paint();
        self.armDeadline();
        return self.animating;
    }

    fn armDeadline(self: *Desktop) void {
        const timer = self.timer orelse return;
        const now = app_mod.nowMs();
        var next = self.app.nextDeadline(now);
        self.timer_for_canvas = false;
        if (self.canvas_release_at) |at| if (next == null or at < next.?) {
            next = at;
            self.timer_for_canvas = true;
        };
        const delay: c_int = if (self.animating) 0 else if (next) |at| @intCast(std.math.clamp(at - now, 1, 60_000)) else 0;
        timer.timerUpdate(delay) catch {};
    }

    pub fn paintOverlay(self: *Desktop) !void {
        const rect = self.app.overlayRect() orelse {
            self.overlay_rect = null;
            self.overlay.node.setEnabled(false);
            self.overlay.setBuffer(null);
            return;
        };
        const buffer = try @import("../panel_buffer.zig").PanelBuffer.create(rect.w, rect.h, self.scale);
        defer buffer.base.drop();
        const surface = c.cairo_image_surface_create_for_data(@ptrCast(buffer.pixels.ptr), c.CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.width * 4) orelse return error.CairoFailed;
        defer c.cairo_surface_destroy(surface);
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
        const cr = c.cairo_create(surface) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
        c.cairo_scale(cr, self.scale, self.scale);
        c.cairo_translate(cr, -@as(f64, @floatFromInt(rect.x)), -@as(f64, @floatFromInt(rect.y)));
        self.app.picker_theme = self.server.icon_theme_cfg;
        self.app.paintOverlay(cr, app_mod.nowMs());
        c.cairo_surface_flush(surface);
        const opening = self.overlay_rect == null;
        self.overlay_rect = rect;
        self.overlay.setBuffer(&buffer.base);
        if (opening) self.overlay.node.raiseToTop();
        self.syncOverlayPosition();
    }

    /// Follow the desktop's camera transform without rerasterizing its prompt.
    pub fn syncOverlayPosition(self: *Desktop) void {
        const rect = self.overlay_rect orelse return;
        if (self.output == null) return;
        const fixed = self.server.config.compositor.desktop_icons_fixed;
        const zoom = if (fixed) 1 else self.server.world.camera.zoom();
        const x: f64 = @floatFromInt(self.box.x + rect.x);
        const y: f64 = @floatFromInt(self.box.y + rect.y);
        const origin = if (fixed) geometry.Vec2{ .x = x, .y = y } else blk: {
            const point = self.server.world.toLayout(x, y);
            break :blk geometry.Vec2{ .x = point.x, .y = point.y };
        };
        const x0: i32 = @intFromFloat(@round(origin.x));
        const y0: i32 = @intFromFloat(@round(origin.y));
        self.overlay.node.setPosition(x0, y0);
        self.overlay.setDestSize(@max(1, @as(i32, @intFromFloat(@round(origin.x + @as(f64, @floatFromInt(rect.w)) * zoom))) - x0), @max(1, @as(i32, @intFromFloat(@round(origin.y + @as(f64, @floatFromInt(rect.h)) * zoom))) - y0));
        self.overlay.node.setEnabled(true);
    }

    fn overlayAcceptsInput(node: *sn.Buffer, sx: *f64, sy: *f64) callconv(.c) bool {
        const data = SceneData.fromNode(&node.node) orelse return false;
        const self = data.role.desktop;
        const rect = self.overlay_rect orelse return false;
        const prompt = self.app.promptRect() orelse return false;
        // Scene input coordinates use the destination size, not the raster.
        return prompt.contains(@as(f64, @floatFromInt(rect.x)) + sx.* * @as(f64, @floatFromInt(rect.w)) / @as(f64, @floatFromInt(node.dst_width)), @as(f64, @floatFromInt(rect.y)) + sy.* * @as(f64, @floatFromInt(rect.h)) / @as(f64, @floatFromInt(node.dst_height)));
    }

    /// Desktop-local logical coordinates for a layout point.
    pub fn localPoint(self: *const Desktop, lx: f64, ly: f64) struct { x: f64, y: f64 } {
        const world = if (self.server.config.compositor.desktop_icons_fixed)
            @import("../camera.zig").Vec{ .x = lx, .y = ly }
        else
            self.server.world.toWorld(lx, ly);
        return .{ .x = world.x - @as(f64, @floatFromInt(self.box.x)), .y = world.y - @as(f64, @floatFromInt(self.box.y)) };
    }

    /// With `icon_only_input`, empty desktop stays empty world unless a
    /// menu, dialog or edit is open.
    pub fn accepts(self: *Desktop, x: f64, y: f64) bool {
        if (!self.app.icon_only or self.app.menu or self.app.edit != .none or self.app.dragging) return true;
        return self.app.hit(x, y) != null;
    }

    pub fn pointerMotion(self: *Desktop, x: f64, y: f64) void {
        self.syncModifiers();
        if (!self.hovered) {
            self.hovered = true;
            self.applyCursor();
        }
        self.app.motion(x, y);
        if (self.app.dirty) self.schedule();
    }

    pub fn pointerLeave(self: *Desktop) void {
        if (!self.hovered) return;
        self.hovered = false;
        self.app.leave();
        if (self.app.dirty) self.schedule();
    }

    pub fn pointerButton(self: *Desktop, button: u32, pressed: bool) void {
        self.syncModifiers();
        self.app.button(button, pressed);
        self.schedule();
    }

    pub fn scroll(self: *Desktop, delta: f64) void {
        if (self.app.edit != .add_app) return;
        if (self.app.applications) |*picker| {
            picker.wheel(delta, self.app.geometry.w, self.app.geometry.h - self.app.geometry.bottom);
            self.app.invalidate();
            self.schedule();
        }
    }

    /// Whether `Keyboard` repeats a held key into the desktop.
    pub fn keyRepeats(self: *Desktop, sym: u32, utf8: []const u8) bool {
        self.syncModifiers();
        return self.app.keyRepeats(sym, utf8);
    }

    /// A key press while the desktop has keyboard focus.
    pub fn key(self: *Desktop, sym: u32, utf8: []const u8) void {
        self.syncModifiers();
        self.app.key(sym, utf8);
        self.schedule();
    }

    /// Ctrl-click selection and Shift-click in rename read these; the seat's
    /// keyboard holds them whether or not the desktop has keyboard focus.
    fn syncModifiers(self: *Desktop) void {
        const keyboard = self.server.input.seat.getKeyboard() orelse return;
        const mods = keyboard.getModifiers();
        self.app.ctrl = mods.ctrl;
        self.app.shift = mods.shift;
    }

    fn setKeyboardFocus(self: *Desktop, wanted: bool) void {
        if (wanted == self.keyboard_focused) return;
        self.keyboard_focused = wanted;
        if (!wanted) return;
        const seat = self.server.input.seat;
        if (seat.keyboard_state.focused_surface) |previous| {
            if (@import("../Toplevel.zig").fromSurface(self.server, previous)) |toplevel| toplevel.setActivated(false);
        }
        // A compositor-drawn window holds the keyboard without a surface.
        if (self.server.world.toplevels.first()) |toplevel| {
            if (toplevel.backend == .shell) toplevel.setActivated(false);
        }
        // Clients see a leave, and the text-input relay deactivates any IME.
        seat.keyboardClearFocus();
    }

    /// A window without a wl_surface (settings) took the keyboard; seat
    /// focus changes cover every other case (`focusChanged`).
    pub fn yieldKeyboard(self: *Desktop) void {
        if (!self.keyboard_focused) return;
        self.keyboard_focused = false;
        self.app.keyboardLeft(false);
        self.schedule();
    }

    fn focusChanged(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), event: *wlr.Seat.event.KeyboardFocusChange) void {
        const self: *Desktop = @fieldParentPtr("focus_change", listener);
        if (event.new_surface == null or !self.keyboard_focused) return;
        // A surface took the keyboard: menus, dialogs and edits close, as
        // they did when the desktop client's layer surface lost focus.
        self.keyboard_focused = false;
        self.app.keyboardLeft(false);
        self.schedule();
    }

    /// The desktop item under the pointer, classified independently of its folder flag.
    fn dropAt(self: *Desktop) DropAt {
        const index = self.app.hit(self.app.x, self.app.y) orelse return .{ .destination = .link };
        const item = self.app.icons.items[index].item;
        return .{
            .destination = dnd.destination(item.builtin == .trash, item.folder),
            .path = item.path,
        };
    }

    /// A client drag moved over the desktop. Trash and folders require move;
    /// only Trash forbids negotiation fallback to another action.
    pub fn dragHover(self: *Desktop) void {
        const target = self.dropAt();
        const preferred: @import("../desktop_drop.zig").Action = if (target.destination == .link) .copy else .move;
        self.drop_target.hover(self.server.input.seat, preferred, target.destination != .trash);
    }

    /// Receives a client drag released over the desktop. False leaves the
    /// drag to wlroots, which cancels it.
    pub fn drop(self: *Desktop, button: u32) bool {
        if (self.transfer != .none) return false;
        const target = self.dropAt();
        const is_trash = target.destination == .trash;
        const is_folder = target.destination == .folder;
        const preferred: @import("../desktop_drop.zig").Action = if (target.destination == .link) .copy else .move;
        const taken = self.drop_target.take(self.server.input.seat, button, preferred, !is_trash) orelse return false;
        self.worker.drop_done.store(false, .release);
        self.worker.enqueue(.{
            .kind = .drop,
            .path = if (is_folder) target.path.? else self.worker.dir,
            .folder = is_folder and taken.action == .move,
            .value = if (is_trash) "trash" else if (is_folder) "paste" else "",
            .fd = taken.fd,
        });
        self.transfer = .drop;
        self.app.leave();
        self.schedule();
        return true;
    }

    fn paste(self: *Desktop, dir: []const u8) host_mod.Paste {
        const source = self.server.input.seat.selection_source orelse return .local;
        if (clipboard.isOwnFileList(source)) return .local;
        const mime: [*:0]const u8 = if (clipboard.offers(source, "x-special/gnome-copied-files")) "x-special/gnome-copied-files" else if (clipboard.offers(source, "text/uri-list")) "text/uri-list" else return .ignored;
        if (self.transfer != .none) return .ignored;
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return .ignored;
        // wlr_data_source_send closes the write end itself.
        source.send(mime, fds[1]);
        self.worker.drop_done.store(false, .release);
        self.worker.enqueue(.{ .kind = .drop, .path = dir, .value = "paste", .fd = fds[0] });
        self.transfer = .paste;
        return .transfer;
    }

    fn applyCursor(self: *Desktop) void {
        if (!self.hovered) return;
        const input = &self.server.input;
        switch (self.cursor) {
            .normal => input.setDefaultCursor(),
            .busy => input.setNamedCursor("progress"),
            .text => input.setNamedCursor("text"),
            .grabbing => input.setNamedCursor("grabbing"),
        }
    }

    fn takeChildren(self: *Desktop) void {
        var started: [8]@import("watcher.zig").Launched = undefined;
        for (self.worker.takeStarted(&started)) |*launch| {
            app_scope.place(self.server, launch.pid, launch.app());
            _ = @import("../session/child.zig").watch(a, self.server.wl_server.getEventLoop(), launch.pid, null, null) catch {
                platform.child.killAndReap(launch.pid);
            };
        }
    }

    fn workerWake(fd: c_int, _: wl.EventMask, self: *Desktop) c_int {
        Worker.drain(fd);
        self.takeChildren();
        self.schedule();
        return 0;
    }

    fn deadline(self: *Desktop) c_int {
        // Freeing the idle canvas needs no frame; every App deadline does.
        if (!self.timer_for_canvas or self.animating or self.app.dirty) {
            self.schedule();
            return 0;
        }
        if (self.canvas_release_at) |at| if (at <= app_mod.nowMs()) self.freeCanvas();
        self.armDeadline();
        return 0;
    }

    fn bottomExclusion(self: *Desktop) ?i32 {
        const output = self.output orelse return null;
        var full: wlr.Box = undefined;
        self.server.output_layout.getBox(output.wlr_output, &full);
        return @max(0, full.y + full.height - (output.usableBox().y + output.usableBox().height));
    }

    fn from(ctx: ?*anyopaque) *Desktop {
        return @ptrCast(@alignCast(ctx.?));
    }

    const vtable: host_mod.Host.VTable = .{
        .keyboard = struct {
            fn f(ctx: ?*anyopaque, wanted: bool) void {
                from(ctx).setKeyboardFocus(wanted);
            }
        }.f,
        .cursor = struct {
            fn f(ctx: ?*anyopaque, cursor: host_mod.Cursor) void {
                const self = from(ctx);
                self.cursor = cursor;
                self.applyCursor();
            }
        }.f,
        .publishSelection = struct {
            fn f(ctx: ?*anyopaque, paths: []const []const u8, cut: bool) void {
                const uris = @import("dnd.zig").uriList(a, paths) catch |err| {
                    log.warn("desktop clipboard: {}", .{err});
                    return;
                };
                defer a.free(uris);
                clipboard.copyFiles(from(ctx).server, uris, cut) catch |err| log.warn("desktop clipboard: {}", .{err});
            }
        }.f,
        .paste = struct {
            fn f(ctx: ?*anyopaque, dir: []const u8) host_mod.Paste {
                return from(ctx).paste(dir);
            }
        }.f,
        .bottomExclusion = struct {
            fn f(ctx: ?*anyopaque) ?i32 {
                return from(ctx).bottomExclusion();
            }
        }.f,
        .newestWindow = struct {
            fn f(ctx: ?*anyopaque) u64 {
                var newest: u64 = 0;
                var it = from(ctx).server.world.toplevels.iterator(.forward);
                while (it.next()) |toplevel| newest = @max(newest, toplevel.id);
                return newest;
            }
        }.f,
        .windowAppeared = struct {
            fn f(ctx: ?*anyopaque, pid: i32, app_id: []const u8, after_id: u64) bool {
                var it = from(ctx).server.world.toplevels.iterator(.forward);
                while (it.next()) |toplevel| {
                    if (toplevel.id <= after_id) continue;
                    if (pid != 0 and toplevel.clientPid() == pid) return true;
                    if (app_id.len > 0 and std.ascii.eqlIgnoreCase(toplevel.appId(), app_id)) return true;
                }
                return false;
            }
        }.f,
        .openDesktopSettings = struct {
            fn f(ctx: ?*anyopaque) anyerror!void {
                const server = from(ctx).server;
                const output = server.getDefaultOutput() orelse return;
                output.toggleControlCenter();
                if (server.input.open_control_center) |cc| cc.selectPage(.desktop);
            }
        }.f,
        .openAppearance = struct {
            fn f(ctx: ?*anyopaque) anyerror!void {
                from(ctx).server.openAppearance();
            }
        }.f,
    };
};

/// One tile's pixels, owned by wlroots once published. Released buffers
/// return to a small pool of mostly equal-sized tiles.
const TileBuffer = @import("TileBuffer.zig");

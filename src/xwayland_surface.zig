// X11 window adapter for a managed Toplevel. Override-redirect windows are
// not created here; they get an unmanaged scene role in a later stage.
const std = @import("std");
const xscale = @import("xwayland_scale.zig");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Toplevel = @import("Toplevel.zig");
const resize = @import("resize.zig");

const Adapter = @This();
const log = std.log.scoped(.xwayland);

extern fn wlr_xwayland_surface_offer_focus(surface: *wlr.XwaylandSurface) void;
pub const offerFocus = wlr_xwayland_surface_offer_focus;

const config_x: u16 = 1;
const config_y: u16 = 2;
const config_width: u16 = 4;
const config_height: u16 = 8;

const hint_p_min_size: u32 = 1 << 4;
const hint_p_max_size: u32 = 1 << 5;
const hint_p_resize_inc: u32 = 1 << 6;
const hint_p_aspect: u32 = 1 << 7;
const hint_p_base_size: u32 = 1 << 8;

window: *Toplevel,
xsurface: *wlr.XwaylandSurface,
scene_attached: bool = false,
awaiting_commit: bool = false,

destroy: wl.Listener(void) = .init(handleDestroy),
associate: wl.Listener(void) = .init(handleAssociate),
dissociate: wl.Listener(void) = .init(handleDissociate),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleRequestConfigure),
request_move: wl.Listener(void) = .init(handleRequestMove),
request_resize: wl.Listener(*wlr.XwaylandSurface.event.Resize) = .init(handleRequestResize),
request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) = .init(handleRequestMinimize),
request_maximize: wl.Listener(void) = .init(handleRequestMaximize),
request_fullscreen: wl.Listener(void) = .init(handleRequestFullscreen),
request_demands_attention: wl.Listener(void) = .init(handleRequestDemandsAttention),
last_hint_urgent: bool = false,
request_activate: wl.Listener(void) = .init(handleRequestActivate),
request_close: wl.Listener(void) = .init(handleRequestClose),
set_title: wl.Listener(void) = .init(handleSetTitle),
set_class: wl.Listener(void) = .init(handleSetClass),
set_parent: wl.Listener(void) = .init(handleSetParent),
set_hints: wl.Listener(void) = .init(handleSetHints),
set_size_hints: wl.Listener(void) = .init(handleSetSizeHints),
set_decorations: wl.Listener(void) = .init(handleSetDecorations),
set_override_redirect: wl.Listener(void) = .init(handleSetOverrideRedirect),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
scene_destroy: wl.Listener(void) = .init(handleSceneDestroy),
surface_listeners: bool = false,

pub fn listen(self: *Adapter) void {
    self.xsurface.events.destroy.add(&self.destroy);
    self.xsurface.events.associate.add(&self.associate);
    self.xsurface.events.dissociate.add(&self.dissociate);
    self.xsurface.events.request_configure.add(&self.request_configure);
    self.xsurface.events.request_move.add(&self.request_move);
    self.xsurface.events.request_resize.add(&self.request_resize);
    self.xsurface.events.request_minimize.add(&self.request_minimize);
    self.xsurface.events.request_maximize.add(&self.request_maximize);
    self.xsurface.events.request_fullscreen.add(&self.request_fullscreen);
    self.xsurface.events.request_demands_attention.add(&self.request_demands_attention);
    self.xsurface.events.request_activate.add(&self.request_activate);
    self.xsurface.events.request_close.add(&self.request_close);
    self.xsurface.events.set_title.add(&self.set_title);
    self.xsurface.events.set_class.add(&self.set_class);
    self.xsurface.events.set_parent.add(&self.set_parent);
    self.xsurface.events.set_hints.add(&self.set_hints);
    self.xsurface.events.set_size_hints.add(&self.set_size_hints);
    self.xsurface.events.set_decorations.add(&self.set_decorations);
    self.xsurface.events.set_override_redirect.add(&self.set_override_redirect);
    if (self.xsurface.surface != null) self.attachSurface();
}

pub fn unlisten(self: *Adapter) void {
    self.detachSurface();
    self.destroy.link.remove();
    self.associate.link.remove();
    self.dissociate.link.remove();
    self.request_configure.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.request_minimize.link.remove();
    self.request_maximize.link.remove();
    self.request_fullscreen.link.remove();
    self.request_demands_attention.link.remove();
    self.request_activate.link.remove();
    self.request_close.link.remove();
    self.set_title.link.remove();
    self.set_class.link.remove();
    self.set_parent.link.remove();
    self.set_hints.link.remove();
    self.set_size_hints.link.remove();
    self.set_decorations.link.remove();
    self.set_override_redirect.link.remove();
}

pub fn attachSurface(self: *Adapter) void {
    const surface = self.xsurface.surface orelse return;
    if (!self.surface_listeners) {
        surface.events.commit.add(&self.commit);
        surface.events.map.add(&self.map);
        surface.events.unmap.add(&self.unmap);
        self.surface_listeners = true;
    }
    if (!self.scene_attached) {
        self.window.attachXwaylandScene(surface) catch |err| {
            log.err("could not attach X11 scene tree: {}", .{err});
            return;
        };
        self.scene_attached = true;
        self.window.scene_tree.node.events.destroy.add(&self.scene_destroy);
    }
    if (surface.mapped and !self.window.in_world) self.window.handleMapped();
}

pub fn detachSurface(self: *Adapter) void {
    if (self.surface_listeners) {
        self.commit.link.remove();
        self.map.link.remove();
        self.unmap.link.remove();
        self.surface_listeners = false;
    }
    if (self.scene_attached) {
        self.scene_destroy.link.remove();
        self.window.detachXwaylandScene();
        self.scene_attached = false;
    }
}

pub fn serverDecorations(self: *const Adapter) bool {
    if (self.window.live_rules.decorations) |dec| switch (dec) {
        .server => return true,
        .client => return false,
        .auto => {},
    };
    const d = self.xsurface.decorations;
    return !(d.no_title and d.no_border);
}

pub fn configure(self: *Adapter, x: i32, y: i32, width: i32, height: i32) void {
    const hints: ?*const SizeHints = if (self.xsurface.size_hints) |ptr| @ptrCast(@alignCast(ptr)) else null;
    const size = applySizeHints(width, height, hints);
    self.xsurface.configure(clampPos(x), clampPos(y), clampSize(size.width), clampSize(size.height));
    self.awaiting_commit = true;
}

pub fn clampPos(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

pub fn clampSize(v: i32) u16 {
    return @intCast(std.math.clamp(v, 1, @as(i32, std.math.maxInt(u16))));
}

pub const ClientSize = struct { width: i32, height: i32 };

pub fn applySizeHints(width: i32, height: i32, hints_ptr: ?*const SizeHints) ClientSize {
    const hints = hints_ptr orelse return .{ .width = @max(1, width), .height = @max(1, height) };
    return constrain(width, height, hints);
}

pub const SizeHints = extern struct {
    flags: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
    width_inc: i32,
    height_inc: i32,
    min_aspect_num: i32,
    min_aspect_den: i32,
    max_aspect_num: i32,
    max_aspect_den: i32,
    base_width: i32,
    base_height: i32,
    win_gravity: u32,
};

pub fn constrain(width: i32, height: i32, hints: *const SizeHints) ClientSize {
    // WM_NORMAL_HINTS contains client-supplied signed 32-bit values. Even an
    // ordinary window size times an unreduced aspect-ratio term can overflow
    // i32, before configure() gets a chance to clamp it to X11's size range.
    var w: i64 = @max(1, width);
    var h: i64 = @max(1, height);
    const base_w: i64 = if (hints.flags & hint_p_base_size != 0) @max(0, hints.base_width) else 0;
    const base_h: i64 = if (hints.flags & hint_p_base_size != 0) @max(0, hints.base_height) else 0;
    if (hints.flags & hint_p_min_size != 0) {
        w = @max(w, hints.min_width);
        h = @max(h, hints.min_height);
    } else if (hints.flags & hint_p_base_size != 0) {
        w = @max(w, hints.base_width);
        h = @max(h, hints.base_height);
    }
    if (hints.flags & hint_p_max_size != 0) {
        if (hints.max_width > 0) w = @min(w, hints.max_width);
        if (hints.max_height > 0) h = @min(h, hints.max_height);
    }
    if (hints.flags & hint_p_resize_inc != 0) {
        const inc_w = @max(1, hints.width_inc);
        const inc_h = @max(1, hints.height_inc);
        if (w > base_w) w = base_w + @divTrunc(w - base_w, inc_w) * inc_w;
        if (h > base_h) h = base_h + @divTrunc(h - base_h, inc_h) * inc_h;
    }
    if (hints.flags & hint_p_aspect != 0 and hints.min_aspect_den > 0 and hints.max_aspect_den > 0) {
        const min_n = hints.min_aspect_num;
        const min_d = hints.min_aspect_den;
        const max_n = hints.max_aspect_num;
        const max_d = hints.max_aspect_den;
        if (min_n > 0 and w * min_d < h * min_n) h = @divTrunc(w * min_d, min_n);
        if (max_n > 0 and w * max_d > h * max_n) w = @divTrunc(h * max_n, max_d);
    }
    // Min/max/base hints fit i32; increments and positive aspect ratios can
    // only reduce those positive dimensions.
    return .{ .width = @intCast(@max(1, w)), .height = @intCast(@max(1, h)) };
}

pub fn sizeConstraintsOf(hints_ptr: ?*const SizeHints) resize.SizeConstraints {
    const hints = hints_ptr orelse return .{ .control_min_width = 100 };
    var out = resize.SizeConstraints{ .control_min_width = 100 };
    if (hints.flags & hint_p_min_size != 0) {
        out.min_width = hints.min_width;
        out.min_height = hints.min_height;
    } else if (hints.flags & hint_p_base_size != 0) {
        out.min_width = hints.base_width;
        out.min_height = hints.base_height;
    }
    if (hints.flags & hint_p_max_size != 0) {
        out.max_width = hints.max_width;
        out.max_height = hints.max_height;
    }
    return out;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("destroy", listener);
    const toplevel = adapter.window;
    adapter.unlisten();
    toplevel.destroy();
}

fn handleAssociate(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("associate", listener);
    adapter.attachSurface();
}

fn handleDissociate(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("dissociate", listener);
    if (adapter.window.in_world) adapter.window.handleUnmapped();
    adapter.detachSurface();
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const adapter: *Adapter = @fieldParentPtr("commit", listener);
    adapter.awaiting_commit = false;
    adapter.window.handleSurfaceCommit();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("map", listener);
    adapter.window.handleMapped();
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("unmap", listener);
    adapter.window.handleUnmapped();
}

fn handleSceneDestroy(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("scene_destroy", listener);
    adapter.scene_destroy.link.remove();
    adapter.scene_attached = false;
    adapter.window.replaceDestroyedXwaylandScene();
}

fn handleRequestConfigure(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
    event: *wlr.XwaylandSurface.event.Configure,
) void {
    const adapter: *Adapter = @fieldParentPtr("request_configure", listener);
    const toplevel = adapter.window;
    if (!toplevel.rules_resolved) toplevel.resolveInitialRules();

    const n = toplevel.surfaceScale();
    var x: i32 = toplevel.x;
    var y: i32 = toplevel.y;
    var width_x: i32 = if (event.mask & config_width != 0)
        event.width
    else
        toplevel.clientSurfaceGeometry().width;
    var height_x: i32 = if (event.mask & config_height != 0)
        event.height
    else
        toplevel.clientSurfaceGeometry().height;

    if (!toplevel.in_world) {
        if (event.mask & config_x != 0) x = xscale.worldFloor(event.x, n);
        if (event.mask & config_y != 0) y = xscale.worldFloor(event.y, n);
    }
    if (toplevel.open_rules.width) |rw| width_x = xscale.surfaceLength(@as(i32, @intCast(rw)), n);
    if (toplevel.open_rules.height) |rh| height_x = xscale.surfaceLength(@as(i32, @intCast(rh)), n);
    if (toplevel.forcedGeometry()) |forced| {
        width_x = xscale.surfaceLength(forced.width, n);
        height_x = xscale.surfaceLength(forced.height, n);
    }
    if (width_x <= 0) width_x = 1;
    if (height_x <= 0) height_x = 1;

    // A client's own remembered geometry (e.g. a GTK dialog's last size and
    // position, saved on a different/larger display) is otherwise honored
    // as-is: nothing else clamps it to the current output. Left oversized or
    // off-screen, its buttons are visually and hit-test unreachable by mouse
    // while keyboard activation (Enter as the default action) still works,
    // since that never depends on screen position. Only the not-yet-placed
    // case is clamped, matching the position logic below - an already-mapped
    // window resizing itself is a separate concern this isn't policing.
    if (!toplevel.in_world) {
        if (toplevel.resolveTargetOutput()) |out| {
            const usable = out.usableBox();
            if (usable.width > 0 and usable.height > 0) {
                if (width_x > xscale.surfaceLength(usable.width, n)) width_x = xscale.surfaceLength(usable.width, n);
                if (height_x > xscale.surfaceLength(usable.height, n)) height_x = xscale.surfaceLength(usable.height, n);

                const world_w = xscale.worldLength(width_x, n);
                const world_h = xscale.worldLength(height_x, n);
                const max_x = usable.x + @max(0, usable.width - world_w);
                const max_y = usable.y + @max(0, usable.height - world_h);
                x = std.math.clamp(x, usable.x, max_x);
                y = std.math.clamp(y, usable.y, max_y);
            }
        }
    }

    const conf_x = xscale.surfacePosition((x + toplevel.borderWidth()), n);
    const conf_y = xscale.surfacePosition((y + toplevel.titlebarHeight()), n);
    adapter.configure(conf_x, conf_y, width_x, height_x);
    if (!toplevel.in_world and (x != 0 or y != 0)) {
        if (!toplevel.open_rules.hasPositionRule()) {
            toplevel.setPosition(x, y);
            toplevel.placed = true;
        }
    }
}

fn handleRequestMove(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_move", listener);
    adapter.window.beginMove();
}

fn handleRequestResize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize),
    event: *wlr.XwaylandSurface.event.Resize,
) void {
    const adapter: *Adapter = @fieldParentPtr("request_resize", listener);
    const edges: wlr.Edges = @bitCast(event.edges);
    adapter.window.server.input.startResize(adapter.window, edges, null, 0x110);
}

fn handleRequestMinimize(
    listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
    event: *wlr.XwaylandSurface.event.Minimize,
) void {
    const adapter: *Adapter = @fieldParentPtr("request_minimize", listener);
    if (event.minimize) {
        adapter.window.minimize();
    } else {
        adapter.window.restore();
    }
}

fn handleRequestMaximize(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_maximize", listener);
    const want = adapter.xsurface.maximized_horz or adapter.xsurface.maximized_vert;
    adapter.window.setMaximized(want);
}

fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_fullscreen", listener);
    adapter.window.setFullscreen(adapter.xsurface.fullscreen);
}

fn handleRequestActivate(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_activate", listener);
    // Unsolicited X11 activation requests attention instead of stealing focus.
    adapter.window.setUrgent(true);
}

fn handleRequestClose(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_close", listener);
    adapter.window.sendClose();
}

fn handleSetTitle(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_title", listener);
    adapter.window.handleIdentityChanged();
}

fn handleSetClass(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_class", listener);
    adapter.window.handleIdentityChanged();
}

fn handleSetParent(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_parent", listener);
    if (adapter.window.in_world and !adapter.window.minimized) adapter.window.raise();
    adapter.window.handleIdentityChanged();
}

fn handleSetHints(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_hints", listener);
    // ICCCM XUrgencyHint is separate from _NET_WM_STATE_DEMANDS_ATTENTION.
    const urgent = if (adapter.xsurface.hints) |hints| hints.flags & (1 << 8) != 0 else false;
    // Focus consumes urgency. Unrelated WM_HINTS changes must not resurrect
    // the same still-set hint after the user has acknowledged it.
    if (urgent == adapter.last_hint_urgent) return;
    adapter.last_hint_urgent = urgent;
    adapter.window.setUrgent(urgent);
}

extern fn wlr_xwayland_surface_set_demands_attention(surface: *wlr.XwaylandSurface, demands_attention: bool) void;

pub fn setDemandsAttention(adapter: *Adapter, urgent: bool) void {
    // Requests update wlroots' cached flag before emitting the signal. Also
    // compare compositor state so accepting a request publishes the X property.
    if (adapter.xsurface.demands_attention != urgent or adapter.window.needs_attention != urgent)
        wlr_xwayland_surface_set_demands_attention(adapter.xsurface, urgent);
}

fn handleRequestDemandsAttention(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("request_demands_attention", listener);
    adapter.window.setUrgent(adapter.xsurface.demands_attention);
}

fn handleSetSizeHints(listener: *wl.Listener(void)) void {
    _ = listener;
}

fn handleSetDecorations(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_decorations", listener);
    adapter.window.syncChrome(false, true, Toplevel.nowMs()) catch {};
}

fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
    const adapter: *Adapter = @fieldParentPtr("set_override_redirect", listener);
    if (!adapter.xsurface.override_redirect) return;

    const toplevel = adapter.window;
    const server = toplevel.server;
    const xsurface = adapter.xsurface;
    adapter.unlisten();
    toplevel.destroy();
    @import("xwayland_unmanaged.zig").create(server, xsurface) catch |err| {
        log.err("could not transition X11 window to override-redirect: {}", .{err});
    };
}

test "clamp X11 positions and sizes" {
    try std.testing.expectEqual(@as(i16, 32767), clampPos(40000));
    try std.testing.expectEqual(@as(i16, -32768), clampPos(-40000));
    try std.testing.expectEqual(@as(u16, 1), clampSize(0));
    try std.testing.expectEqual(@as(u16, 65535), clampSize(70000));
}

test "size hints apply min max and increments" {
    const hints = SizeHints{
        .flags = hint_p_min_size | hint_p_max_size | hint_p_base_size | hint_p_resize_inc,
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .min_width = 100,
        .min_height = 80,
        .max_width = 400,
        .max_height = 300,
        .width_inc = 10,
        .height_inc = 8,
        .min_aspect_num = 0,
        .min_aspect_den = 0,
        .max_aspect_num = 0,
        .max_aspect_den = 0,
        .base_width = 20,
        .base_height = 16,
        .win_gravity = 0,
    };
    const small = constrain(10, 10, &hints);
    try std.testing.expectEqual(@as(i32, 100), small.width);
    try std.testing.expectEqual(@as(i32, 80), small.height);
    const large = constrain(1000, 1000, &hints);
    try std.testing.expectEqual(@as(i32, 400), large.width);
    try std.testing.expectEqual(@as(i32, 296), large.height);
}

test "X11 aspect hints accept full signed 32-bit terms without overflow" {
    const maximum = std.math.maxInt(i32);
    var hints = std.mem.zeroes(SizeHints);
    hints.flags = hint_p_aspect;
    hints.min_aspect_num = maximum;
    hints.min_aspect_den = maximum;
    hints.max_aspect_num = maximum;
    hints.max_aspect_den = maximum;
    // Large unreduced terms still describe an ordinary square.
    try std.testing.expectEqual(ClientSize{ .width = 310, .height = 310 }, constrain(420, 310, &hints));
    try std.testing.expectEqual(ClientSize{ .width = 320, .height = 320 }, constrain(320, 440, &hints));
    try std.testing.expectEqual(ClientSize{ .width = maximum, .height = maximum }, constrain(maximum, maximum, &hints));
    hints.min_aspect_den = 1;
    hints.max_aspect_den = 1;
    try std.testing.expectEqual(ClientSize{ .width = 1, .height = 1 }, constrain(430, 330, &hints));
    hints.min_aspect_num = 1;
    hints.min_aspect_den = maximum;
    hints.max_aspect_num = 1;
    hints.max_aspect_den = maximum;
    try std.testing.expectEqual(ClientSize{ .width = 1, .height = 340 }, constrain(440, 340, &hints));
    try std.testing.expectEqual(ClientSize{ .width = 1, .height = 1 }, constrain(std.math.minInt(i32), std.math.minInt(i32), &hints));
}

test "X11 aspect hints ignore invalid terms and preserve ordinary ratios" {
    var hints = std.mem.zeroes(SizeHints);
    hints.flags = hint_p_aspect;
    hints.min_aspect_num = 1;
    hints.max_aspect_num = 1;
    try std.testing.expectEqual(ClientSize{ .width = 450, .height = 350 }, constrain(450, 350, &hints));
    hints.min_aspect_num = -1;
    hints.min_aspect_den = 1;
    hints.max_aspect_num = -1;
    hints.max_aspect_den = 1;
    try std.testing.expectEqual(ClientSize{ .width = 460, .height = 360 }, constrain(460, 360, &hints));
    hints.min_aspect_num = 4;
    hints.min_aspect_den = 3;
    hints.max_aspect_num = 4;
    hints.max_aspect_den = 3;
    try std.testing.expectEqual(ClientSize{ .width = 480, .height = 360 }, constrain(480, 400, &hints));
}

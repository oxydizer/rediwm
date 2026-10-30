// How a window frame looks, and the CPU rasterizer that draws it.
const std = @import("std");
const sdf = @import("ui").sdf;

const wlr = @import("wlroots");
const col = @import("color.zig");

const gpa = @import("main.zig").gpa;
const geometry = @import("geometry.zig");
const icon_service = @import("icon_service.zig");
const theme = @import("ui").theme;
const text = @import("ui").text;

const log = std.log.scoped(.chrome);

// App dialogs use these same decoration metrics and control hit targets.
const window_chrome = @import("ui").window_chrome;
pub const frame_border = window_chrome.frame_border;
pub const Metrics = window_chrome.Metrics;
pub const frameRadius = window_chrome.frameRadius;

/// At or above this effective titlebar alpha the blur behind it contributes
/// at most 2%, too little to repaint on every frame of an interactive move.
const glass_hold_min_alpha: f32 = 0.98;
pub fn titlebarGlassMayHold(opacity: f32) bool {
    return theme.global.window_bg[3] * opacity >= glass_hold_min_alpha;
}
const btn_radius = window_chrome.control_radius;
// Min/max/close glyphs are drawn 10% larger than the app icon scale.
const button_glyph_scale = window_chrome.button_glyph_scale;

// The app icon sits where the title text used to start; the title shifts
// right to make room for it when one is found.
const title_inset = window_chrome.title_inset;
pub const title_icon_size = window_chrome.title_icon_size;
const title_icon_gap = window_chrome.title_icon_gap;

/// Set once at startup, before any window exists, when the output pass built its
/// shaped programs (docs/plans/scene-graph-stage4.md). Then every decorated window
/// has a shape that clips the titlebar, the client and its subsurfaces together,
/// and the pass draws its corners, border ring and shadow. Without them (a driver
/// that cannot link the programs) windows are square, with no ring or shadow.
pub var shapes: bool = false;

/// Polygon outlines (`window_shape`, `taskbar_shape`) need two more GL programs,
/// built the first time a theme asks for one (`polygonsReady`), never for a theme
/// that keeps the rounded rectangle. `polygons` is true once they exist; code that
/// draws or captures reads it, and only layout code, never a render pass, calls
/// `polygonsReady`.
pub var polygons: bool = false;
var polygons_tried: bool = false;
pub var polygon_enabler: ?*const fn (*anyopaque) bool = null;
pub var polygon_context: ?*anyopaque = null;

pub fn polygonsReady() bool {
    if (polygons or polygons_tried or !shapes) return polygons;
    polygons_tried = true;
    const enable = polygon_enabler orelse return false;
    polygons = enable(polygon_context orelse return false);
    if (!polygons) std.log.scoped(.chrome).warn("polygon outlines are unavailable: the programs did not build", .{});
    return polygons;
}

pub const ControlKind = window_chrome.ControlKind;

const drm_format_argb8888: u32 = 0x34325241;

// Everything the rasterizer needs to reproduce a window's current appearance.
pub const ChromeState = struct {
    tabs: @import("chrome_tabs.zig").Strip = .{},
    active: bool = false,
    workspace_focus: bool = false,
    maximized: bool = false,
    density: f32 = 1,
    title: []const u8 = "",
    // Device pixels per logical pixel. Every metric here is logical; only the
    // sampling grid and the antialiasing ramp change with it.
    scale: f32 = 1,
    // 0 idle, 1 fully hovered; in-between is the border fade.
    hover: f32 = 0,
    // Window-button hover chip. `chip_pos` is a slot coordinate (0 minimize,
    // 1 maximize, 2 close, fractions in between) so it can glide between
    // buttons; `chip_alpha` fades it in and out independently.
    chip_pos: f32 = 0,
    chip_alpha: f32 = 0,
    // A real app icon found via icon_service.zig (see Toplevel.syncChrome),
    // drawn at the titlebar's top-left in place of nothing at all. Absent
    // clients just get the title text starting further left, same as today.
    icon: ?icon_service.Entry = null,
    // Logical px the icon and title keep in from the left, and the controls from the
    // right, so a polygon outline's slanted ends do not cut them (`Toplevel.controlInsets`).
    inset_left: i32 = 0,
    inset_right: i32 = 0,

    /// The frame's width as the controls see it: less the right inset.
    pub fn controlsWidth(self: ChromeState, logical_width: i32) i32 {
        return logical_width - self.inset_right;
    }

    fn titleFont(self: ChromeState) text.Font {
        return if (self.active) .manrope_bold else .manrope;
    }
};

// Inputs that produced the titlebar currently on screen. `rasterize` also reads
// `theme.global`; those are snapshotted here so a live reskin cannot be skipped.
pub const TitlebarMemo = struct {
    font_generation: u32 = 0,
    tabs_hash: u64 = 0,
    width: i32,
    height: i32,
    density: f32 = 1,
    active: bool = false,
    workspace_focus: bool = false,
    workspace_active_border: [4]f32 = @splat(0),
    // wlroots strdup's the title on set_title, so pointer equality implies
    // content equality without owning a copy of the string.
    title_ptr: ?[*:0]const u8,
    scale: f32,
    hover: f32,
    chip_pos: f32,
    chip_alpha: f32,
    maximized: bool,
    icon: ?icon_service.Entry,
    glass: [4]f32,
    border: [4]f32,
    border_soft: [4]f32,
    fg: [4]f32,
    dim: [4]f32,
    border_hover: [4]f32,
    surface_hover: [4]f32,
    danger: [4]f32,
    close_fg: [4]f32 = .{ 1, 1, 1, 1 },
    close_hover_alpha: f32 = 0.85,
    title_size: f32,
    chrome_height: f32 = 46,
    chrome_control_gap: f32 = 4,
    chrome_round_buttons: bool = false,
    top_band: [4]f32 = @splat(0),
    top_band_height: f32 = 0,
    inset_left: i32 = 0,
    inset_right: i32 = 0,

    pub fn capture(width: i32, height: i32, title_ptr: ?[*:0]const u8, state: ChromeState) TitlebarMemo {
        const t = theme.global;
        return .{
            .font_generation = text.font_generation,
            .width = width,
            .height = height,
            .density = state.density,
            .active = state.active,
            .workspace_focus = state.workspace_focus,
            .workspace_active_border = t.workspace_active_border,
            .title_ptr = title_ptr,
            .tabs_hash = @import("chrome_tabs.zig").hash(state.tabs),
            .scale = state.scale,
            .hover = state.hover,
            .chip_pos = state.chip_pos,
            .chip_alpha = state.chip_alpha,
            .maximized = state.maximized,
            .icon = state.icon,
            .glass = t.window_bg,
            .border = t.window_border,
            .border_soft = t.window_divider,
            .fg = t.window_fg,
            .dim = t.window_dim,
            .border_hover = t.window_border_hover,
            .surface_hover = t.surface_hover,
            .danger = t.window_close_hover,
            .close_fg = t.window_close_fg,
            .close_hover_alpha = t.window_close_hover_alpha,
            .title_size = t.title_size,
            .chrome_height = t.chrome_height,
            .chrome_control_gap = t.chrome_control_gap,
            .chrome_round_buttons = t.chrome_round_buttons,
            .top_band = t.window_top_band,
            .top_band_height = t.window_top_band_height,
            .inset_left = state.inset_left,
            .inset_right = state.inset_right,
        };
    }

    pub fn stableEql(a: TitlebarMemo, b: TitlebarMemo) bool {
        var normalized = a;
        normalized.hover = b.hover;
        normalized.chip_pos = b.chip_pos;
        normalized.chip_alpha = b.chip_alpha;
        return normalized.eql(b);
    }

    /// Whether `ChromeBuffer.createUpdated` can derive `b` from the buffer
    /// painted for `a`: only hover, focus, the hovered control, title or weight differ.
    pub fn reusableFor(a: TitlebarMemo, b: TitlebarMemo) bool {
        var normalized = a;
        normalized.title_ptr = b.title_ptr;
        normalized.tabs_hash = b.tabs_hash;
        normalized.active = b.active;
        normalized.workspace_focus = b.workspace_focus;
        return normalized.stableEql(b);
    }

    pub fn eql(a: TitlebarMemo, b: TitlebarMemo) bool {
        if (a.font_generation != b.font_generation) return false;
        if (a.width != b.width) return false;
        if (a.height != b.height) return false;
        if (a.density != b.density) return false;
        if (a.active != b.active) return false;
        if (a.workspace_focus != b.workspace_focus) return false;
        if (a.title_ptr != b.title_ptr or a.tabs_hash != b.tabs_hash) return false;
        if (a.scale != b.scale) return false;
        if (a.hover != b.hover) return false;
        if (a.chip_pos != b.chip_pos or a.chip_alpha != b.chip_alpha) return false;
        if (a.maximized != b.maximized) return false;
        if (!iconEql(a.icon, b.icon)) return false;
        inline for (.{ "glass", "border", "border_soft", "fg", "dim", "border_hover", "surface_hover", "danger", "close_fg", "workspace_active_border" }) |field| {
            if (!rgbaEql(@field(a, field), @field(b, field))) return false;
        }
        return a.close_hover_alpha == b.close_hover_alpha and a.title_size == b.title_size and a.chrome_height == b.chrome_height and a.chrome_control_gap == b.chrome_control_gap and a.chrome_round_buttons == b.chrome_round_buttons and
            rgbaEql(a.top_band, b.top_band) and a.top_band_height == b.top_band_height and a.inset_left == b.inset_left and a.inset_right == b.inset_right;
    }
};

fn rgbaEql(a: [4]f32, b: [4]f32) bool {
    return std.mem.eql(f32, &a, &b);
}

fn iconEql(a: ?icon_service.Entry, b: ?icon_service.Entry) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    // Compare the service's stable handle id, not `pixels.ptr`: once
    // eviction lands, a freed buffer's address could be reused for a
    // different icon, which a raw pointer comparison would miss.
    return left.id == right.id;
}

pub const Rect = window_chrome.Rect;

/// Where a control sits on the hover chip's glide axis.
pub fn controlSlot(kind: ControlKind) f32 {
    return switch (kind) {
        .minimize => 0,
        .maximize => 1,
        .close => 2,
    };
}

pub inline fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub const controlRect = window_chrome.controlRect;
pub const controlRectScaled = window_chrome.controlRectScaled;

// The titlebar: a plain band. The window's shape gives it its corners and the
// output pass draws the border ring over it, so no pixel here is shaped.
pub const ChromeBuffer = struct {
    // wlroots imports this data-pointer buffer as a texture for the scene.
    base: wlr.Buffer,
    // The buffer is device pixels; the frame it draws is logical ones.
    width: i32,
    height: i32,
    logical_width: i32,
    state: ChromeState,
    pixels: []u32,
    // Logical width from the title rect's left edge that the drawn title can
    // cover, so a title change repaints only the old and new text.
    title_extent: i32 = 0,
    tabs_layout_hash: u64 = 0,
    tabs_titles: [128]u64 = @splat(0),

    fn rememberTabs(frame: *ChromeBuffer) void {
        frame.tabs_layout_hash = @import("chrome_tabs.zig").layoutHash(frame.state.tabs);
        for (frame.state.tabs.tabs, 0..) |tab, i| frame.tabs_titles[i] = std.hash.Wyhash.hash(0, tab.title);
    }

    const impl = wlr.Buffer.Impl{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(logical_width: i32, state: ChromeState) !*ChromeBuffer {
        const frame = try gpa.create(ChromeBuffer);
        errdefer gpa.destroy(frame);

        const width = devicePixels(logical_width, state.scale);
        const height = devicePixels((Metrics{ .density = state.density }).titlebarHeight(), state.scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        frame.* = .{
            .base = undefined,
            .width = width,
            .height = height,
            .logical_width = logical_width,
            .state = state,
            .pixels = pixels,
        };
        frame.base.init(&impl, width, height);
        try frame.rasterize(null);
        frame.title_extent = frame.titleExtent();
        frame.rememberTabs();
        // The title belongs to wlroots and can change while this buffer lives.
        frame.state.title = "";
        frame.state.tabs.tabs = &.{};
        return frame;
    }

    /// Reuse stable fill, title and icon pixels. The old buffer remains
    /// immutable while wlroots may still be sampling it. `title_changed`
    /// repaints the span covering the old and new title (terminals animate
    /// their titles several times a second; a full raster evaluates every
    /// control and corner SDF again for pixels that cannot change).
    pub fn createUpdated(previous: *const ChromeBuffer, state: ChromeState, title_changed: bool) !*ChromeBuffer {
        const frame = try gpa.create(ChromeBuffer);
        errdefer gpa.destroy(frame);
        const pixels = try gpa.dupe(u32, previous.pixels);
        errdefer gpa.free(pixels);
        frame.* = previous.*;
        frame.pixels = pixels;
        frame.state = state;
        frame.base.init(&impl, frame.width, frame.height);
        if (state.tabs.tabs.len > 0) {
            const tabs = @import("chrome_tabs.zig");
            if (previous.tabs_layout_hash == tabs.layoutHash(state.tabs) and
                previous.state.hover == state.hover and previous.state.chip_pos == state.chip_pos and previous.state.chip_alpha == state.chip_alpha and previous.state.maximized == state.maximized)
            {
                const geom = tabs.geometry(state.controlsWidth(frame.logical_width), state.density, state.tabs);
                for (state.tabs.tabs[geom.first..][0..geom.count], 0..) |tab, i| {
                    if (previous.tabs_titles[geom.first + i] == std.hash.Wyhash.hash(0, tab.title)) continue;
                    const rect = geom.tab(i);
                    const left: i32 = @intFromFloat(@floor(rect.x));
                    const right: i32 = @intFromFloat(@ceil(rect.x + rect.w));
                    try frame.rasterize(.{ .x = left, .y = 0, .w = right - left, .h = frame.height });
                }
            } else try frame.rasterize(null);
            frame.rememberTabs();
            frame.state.tabs.tabs = &.{};
            frame.state.title = "";
            return frame;
        }
        const controls_changed = previous.state.chip_pos != state.chip_pos or previous.state.chip_alpha != state.chip_alpha or previous.state.maximized != state.maximized;
        const Span = struct { x0: i32, x1: i32 };
        var spans: [2]Span = undefined;
        var count: usize = 0;
        if (title_changed or previous.state.active != state.active) {
            frame.title_extent = frame.titleExtent();
            const rect = titleRect(frame.logical_width, state);
            const extent = @max(previous.title_extent, frame.title_extent);
            if (extent > 0) {
                spans[count] = .{ .x0 = rect.x, .x1 = rect.x + extent };
                count += 1;
            }
        }
        var right = frame.logical_width;
        if (controls_changed) right = @min(right, @max(0, controlRectScaled(frame.state.controlsWidth(frame.logical_width), .minimize, frame.state.density).x - 1));
        if (right < frame.logical_width) {
            spans[count] = .{ .x0 = right, .x1 = frame.logical_width };
            count += 1;
        }
        std.mem.sort(Span, spans[0..count], {}, struct {
            fn less(_: void, a: Span, b: Span) bool {
                return a.x0 < b.x0;
            }
        }.less);
        // A narrow frame can make the regions overlap. Rasterize their union
        // once, so text coverage is never composited twice.
        const band_h = (Metrics{ .density = state.density }).titlebarHeight();
        var i: usize = 0;
        while (i < count) {
            var span = spans[i];
            i += 1;
            while (i < count and spans[i].x0 <= span.x1) : (i += 1) span.x1 = @max(span.x1, spans[i].x1);
            try frame.rasterize(.{ .x = span.x0, .y = 0, .w = span.x1 - span.x0, .h = band_h });
        }
        frame.state.title = "";
        frame.state.tabs.tabs = &.{};
        return frame;
    }

    /// The span the title can occupy: after the app icon, before the controls.
    fn titleRect(logical_width: i32, state: ChromeState) text.Rect {
        const m: Metrics = .{ .density = state.density };
        const title_left: i32 = state.inset_left + if (state.icon != null) m.length(title_inset) + m.iconSize() + m.length(title_icon_gap) else m.length(title_inset);
        const controls_left = controlRectScaled(state.controlsWidth(logical_width), .minimize, state.density).x;
        return .{ .x = title_left, .y = 0, .w = @max(0, controls_left - title_left), .h = m.titlebarHeight() - frame_border };
    }

    /// Logical width the current title can ink, measured from the title
    /// rect's left edge: its advance plus a margin for glyph overhang and
    /// antialiasing, capped by the rect (long titles are ellipsized to it).
    fn titleExtent(frame: *const ChromeBuffer) i32 {
        if (frame.state.title.len == 0) return 0;
        const rect = titleRect(frame.logical_width, frame.state);
        const m: Metrics = .{ .density = frame.state.density };
        const width = text.measureWidth(frame.state.title, frame.state.titleFont(), theme.global.title_size * m.density, frame.state.scale) catch return rect.w;
        return @min(rect.w, width + 2);
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
        base.finish();
        const frame: *ChromeBuffer = @fieldParentPtr("base", base);
        gpa.free(frame.pixels);
        gpa.destroy(frame);
    }

    fn beginDataPtrAccess(
        base: *wlr.Buffer,
        _: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        const frame: *ChromeBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(frame.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(frame.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}

    fn rasterize(frame: *ChromeBuffer, clip: ?Rect) !void {
        const scale = frame.state.scale;
        const m: Metrics = .{ .density = frame.state.density };
        const controls_width = frame.state.controlsWidth(frame.logical_width);
        const min_btn = controlRectScaled(controls_width, .minimize, frame.state.density);
        const max_btn = controlRectScaled(controls_width, .maximize, frame.state.density);
        const close_btn = controlRectScaled(controls_width, .close, frame.state.density);
        // All glyphs fit inside their buttons. Include a full device pixel
        // around the group for antialiasing, including fractional scales.
        const control_left = @as(f32, @floatFromInt(min_btn.x)) - 1 / scale;
        const control_right = @as(f32, @floatFromInt(close_btn.x + close_btn.w)) + 1 / scale;
        const control_top = @as(f32, @floatFromInt(min_btn.y)) - 1 / scale;
        const control_bottom = @as(f32, @floatFromInt(min_btn.y + min_btn.h)) + 1 / scale;
        const diag = std.math.sqrt1_2;
        const icon_left: f32 = @floatFromInt(frame.state.inset_left + m.length(title_inset));
        const icon_top: f32 = @floatFromInt(@divTrunc(m.titlebarHeight() - m.iconSize(), 2));
        const base = Color.chrome();
        // Away from the controls and the icon every pixel in a row has the same
        // fill. Pack that colour once instead of repeating four rounded float
        // conversions across the bar.
        const stride: usize = @intCast(frame.width);

        const x0: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x)) * scale)))))) else 0;
        const x1: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x + box.w)) * scale)))))) else stride;
        const controls = Controls.init(min_btn, max_btn, close_btn, frame.state.chip_pos, frame.state.chip_alpha, diag, scale, m.contentScale(), frame.state.maximized);
        const icon_right = icon_left + @as(f32, @floatFromInt(m.iconSize()));
        // The columns of the control group and of the icon. A column's centre
        // grows with x, so each is one run; the rest of a row is the flat fill.
        var control_run: ColumnRun = .{ .start = x1, .end = x1 };
        var icon_run: ColumnRun = .{ .start = x1, .end = x1 };
        for (x0..x1) |x| {
            const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
            if (px >= control_left and px <= control_right) control_run.add(x);
            if (px >= icon_left and px < icon_right) icon_run.add(x);
        }
        for (0..@intCast(frame.height)) |device_y| {
            const py = (@as(f32, @floatFromInt(device_y)) + 0.5) / scale;
            const yi: i32 = @intFromFloat(@floor(py));
            const row = frame.pixels[device_y * stride ..][0..stride];
            var row_color = base;
            // The strip along the top edge; the row it ends in is covered in part.
            const band = bandCoverage(py, scale, m.density);
            if (band > 0) row_color = Color.fromRgba(theme.global.window_top_band).scaled(band).over(row_color);
            if (yi == m.titlebarHeight() - 1) row_color = Color.divider().over(row_color);
            const flat_color = row_color.argb();
            const control_row = py >= control_top and py <= control_bottom;
            const icon_row = frame.state.tabs.tabs.len == 0 and frame.state.icon != null and
                py >= icon_top and py < icon_top + @as(f32, @floatFromInt(m.iconSize()));
            // The icon is left of the controls, but a narrow frame can make
            // the two overlap.
            var runs: [2]ColumnRun = undefined;
            var count: usize = 0;
            if (icon_row and icon_run.start < icon_run.end) {
                runs[count] = icon_run;
                count += 1;
            }
            if (control_row and control_run.start < control_run.end) {
                if (count > 0 and control_run.start <= runs[0].end) {
                    runs[0] = .{ .start = @min(runs[0].start, control_run.start), .end = @max(runs[0].end, control_run.end) };
                } else {
                    runs[count] = control_run;
                    count += 1;
                }
            }
            var x = x0;
            for (runs[0..count]) |run| {
                @memset(row[x..run.start], flat_color);
                for (run.start..run.end) |shaded| {
                    const px = (@as(f32, @floatFromInt(shaded)) + 0.5) / scale;
                    const in_controls = control_row and px >= control_left and px <= control_right;
                    const in_icon = icon_row and px >= icon_left and px < icon_right;
                    if (!in_controls and !in_icon) {
                        row[shaded] = flat_color;
                        continue;
                    }

                    var color = row_color;
                    if (in_controls) color = controls.paint(color, px, py);

                    if (if (frame.state.tabs.tabs.len == 0) frame.state.icon else null) |icon| {
                        if (px >= icon_left and px < icon_right and
                            py >= icon_top and py < icon_top + @as(f32, @floatFromInt(m.iconSize())))
                        {
                            const ix: i32 = @intFromFloat(@floor((px - icon_left) * scale));
                            const iy: i32 = @intFromFloat(@floor((py - icon_top) * scale));
                            if (ix >= 0 and ix < icon.size and iy >= 0 and iy < icon.size) {
                                const sample = icon.pixels[@intCast(iy * icon.size + ix)];
                                color = Color.fromPremultiplied(sample).over(color);
                            }
                        }
                    }

                    row[shaded] = color.argb();
                }
                x = run.end;
            }
            @memset(row[x..x1], flat_color);
        }

        if (frame.state.tabs.tabs.len > 0) {
            @import("chrome_tabs.zig").paint(Color, frame.pixels, frame.width, frame.height, frame.state.controlsWidth(frame.logical_width), frame.state.density, scale, frame.state.tabs, frame.state.icon, clip);
            return;
        }
        const text_rect = titleRect(frame.logical_width, frame.state);
        var text_clip = text_rect;
        if (clip) |box| {
            const left = @max(text_rect.x, box.x);
            const right = @min(text_rect.x + text_rect.w, box.x + box.w);
            if (right <= left) return;
            text_clip.x = left;
            text_clip.w = right - left;
        }
        try text.drawOpts(
            frame.pixels,
            frame.width,
            frame.height,
            frame.state.title,
            .{ .r = Color.text().r, .g = Color.text().g, .b = Color.text().b, .a = Color.text().a },
            scale,
            frame.state.titleFont(),
            theme.global.title_size * m.density,
            .{ .rect = text_rect, .clip = text_clip },
        );
    }
};

/// How much of the pixel row centred at logical `py` the theme's top band covers.
fn bandCoverage(py: f32, scale: f32, density: f32) f32 {
    const height = @min(theme.global.window_top_band_height * density, theme.global.chrome_height * density);
    if (height <= 0 or theme.global.window_top_band[3] <= 0) return 0;
    return std.math.clamp((height - (py - 0.5 / scale)) * scale, 0, 1);
}

// What the window's analytic shadow was last set from (Toplevel.syncShadow).
pub const ShadowMemo = struct {
    width: i32,
    height: i32,
    radius: f32,
    color: [4]f32,
    softness: f32,
    offset_y: f32,
    scale: f32,
    disabled: bool,
    /// Which polygon outline the shadow follows (`Toplevel.shapeKey`).
    shape: u64,

    pub fn capture(width: i32, height: i32, radius: f32, scale: f32, disabled: bool, shape: u64) ShadowMemo {
        const t = theme.global;
        return .{
            .width = width,
            .height = height,
            .radius = radius,
            .color = t.shadow,
            .softness = t.shadow_size,
            .offset_y = t.shadow_offset_y,
            .scale = scale,
            .disabled = disabled,
            .shape = shape,
        };
    }

    pub fn eql(a: ShadowMemo, b: ShadowMemo) bool {
        if (a.disabled != b.disabled) return false;
        if (a.disabled) return true;
        return a.width == b.width and
            a.height == b.height and
            a.radius == b.radius and
            rgbaEql(a.color, b.color) and
            a.softness == b.softness and
            a.offset_y == b.offset_y and
            a.scale == b.scale and
            a.shape == b.shape;
    }
};

test {
    _ = @import("chrome_tests.zig");
}

const chrome_paint = @import("chrome_paint.zig");
pub const borderColor = chrome_paint.borderColor;
pub const windowBorderColor = chrome_paint.windowBorderColor;
pub const fillColor = chrome_paint.fillColor;
const Color = chrome_paint.Color;
const Controls = chrome_paint.Controls;

/// Device columns `start..end` of a raster; empty while `start == end`.
const ColumnRun = struct {
    start: usize,
    end: usize,

    fn add(run: *ColumnRun, x: usize) void {
        if (run.start == run.end) run.start = x;
        run.end = x + 1;
    }
};
pub const sdQuad = chrome_paint.sdQuad;
pub const sdRoundedBox = chrome_paint.sdRoundedBox;
pub const coverage = chrome_paint.coverage;
pub const devicePixels = chrome_paint.devicePixels;

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

// The client's surface has square corners of its own, so the frame reserves a
// band of chrome below it deep enough to hold the bottom corner arcs.
pub fn footerHeight(radius: f32) i32 {
    return @max(frame_border, @as(i32, @intFromFloat(@ceil(radius))));
}

pub const ControlKind = window_chrome.ControlKind;

// The two horizontal bands of chrome the compositor draws. The client surface
// fills the gap between them.
pub const Band = enum { titlebar, footer };

fn bandHeight(band: Band, radius: f32, density: f32) i32 {
    return switch (band) {
        .titlebar => (Metrics{ .density = density }).titlebarHeight(),
        .footer => footerHeight(radius),
    };
}

// Little-endian packed 32-bit DRM formats. Byte 0 holds the low-order channel,
// so `index` gives the byte offset of red, green, blue and alpha in that order.
const drm_format_argb8888: u32 = 0x34325241;
const drm_format_xrgb8888: u32 = 0x34325258;
const drm_format_abgr8888: u32 = 0x34324241;
const drm_format_xbgr8888: u32 = 0x34324258;

const PixelLayout = struct { index: [4]usize, has_alpha: bool };

fn pixelLayout(format: u32) ?PixelLayout {
    return switch (format) {
        drm_format_argb8888 => .{ .index = .{ 2, 1, 0, 3 }, .has_alpha = true },
        drm_format_xrgb8888 => .{ .index = .{ 2, 1, 0, 3 }, .has_alpha = false },
        drm_format_abgr8888 => .{ .index = .{ 0, 1, 2, 3 }, .has_alpha = true },
        drm_format_xbgr8888 => .{ .index = .{ 0, 1, 2, 3 }, .has_alpha = false },
        else => null,
    };
}

/// Cached result of sampling a client's bottom edge. `fallback` is a known
/// glass fill; it is not the same as never having sampled.
pub const EdgeSampleKind = enum { uninitialized, color, fallback };

/// Buffer-space mapping used to decide whether a cached edge sample is still
/// valid. Pointers to buffers or textures are intentionally absent: reuse
/// does not prove the pixels are unchanged, and a new swapchain buffer does
/// not by itself prove they are.
pub const EdgeMapping = struct {
    source_x: f64 = 0,
    source_y: f64 = 0,
    source_w: f64 = 0,
    source_h: f64 = 0,
    scale: i32 = 1,
    transform_normal: bool = true,
    buffer_width: i32 = 0,
    buffer_height: i32 = 0,
    format: u32 = 0,
    surface_width: i32 = 0,
    surface_height: i32 = 0,
    geom_x: i32 = 0,
    geom_y: i32 = 0,
    geom_w: i32 = 0,
    geom_h: i32 = 0,
    has_texture: bool = false,
    row_x: i32 = 0,
    row_y: i32 = 0,
    row_w: i32 = 0,
    row_h: i32 = 0,
    row_valid: bool = false,

    pub fn canSample(self: EdgeMapping) bool {
        return self.transform_normal and self.has_texture and self.row_valid;
    }

    pub fn eql(a: EdgeMapping, b: EdgeMapping) bool {
        return a.source_x == b.source_x and a.source_y == b.source_y and
            a.source_w == b.source_w and a.source_h == b.source_h and
            a.scale == b.scale and a.transform_normal == b.transform_normal and
            a.buffer_width == b.buffer_width and a.buffer_height == b.buffer_height and
            a.format == b.format and
            a.surface_width == b.surface_width and a.surface_height == b.surface_height and
            a.geom_x == b.geom_x and a.geom_y == b.geom_y and
            a.geom_w == b.geom_w and a.geom_h == b.geom_h and
            a.has_texture == b.has_texture and
            a.row_x == b.row_x and a.row_y == b.row_y and
            a.row_w == b.row_w and a.row_h == b.row_h and
            a.row_valid == b.row_valid;
    }
};

/// Effective committed damage in the same buffer coordinates as `EdgeMapping.row_*`.
pub const EdgeDamage = enum {
    /// No damage reported for this commit.
    none,
    /// Damage exists and intersects the sampled row.
    intersects_row,
    /// Damage exists but misses the sampled row.
    misses_row,
    /// Damage or its mapping cannot be trusted; resample.
    unknown,
};

pub const SampleAction = enum {
    /// Read the client's bottom row.
    sample,
    /// Keep the cached colour or fallback; do not read.
    skip,
    /// Use the glass fill without reading. Must replace a previously sampled colour.
    fallback,
};

pub fn rectsOverlap(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    if (aw <= 0 or ah <= 0 or bw <= 0 or bh <= 0) return false;
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by;
}

/// Decide whether this commit needs a texture read, a glass fallback, or nothing.
/// `force` covers first sample after map, re-enabling SSD, and a pending sample
/// remembered across resize-skipped commits.
pub fn decideEdgeSample(
    cached: EdgeSampleKind,
    last: ?EdgeMapping,
    current: EdgeMapping,
    damage: EdgeDamage,
    force: bool,
) SampleAction {
    if (!current.canSample()) {
        if (!force and cached == .fallback) {
            if (last) |prev| {
                if (prev.eql(current)) return .skip;
            }
        }
        return .fallback;
    }

    if (force or cached == .uninitialized) return .sample;

    const mapping_changed = if (last) |prev| !prev.eql(current) else true;
    if (mapping_changed) return .sample;

    return switch (damage) {
        .intersects_row, .unknown => .sample,
        .none, .misses_row => .skip,
    };
}

fn growScratch(scratch: *[]u32, count: usize) ?[]u32 {
    if (scratch.len >= count) return scratch.*[0..count];
    if (scratch.len == 0) {
        scratch.* = gpa.alloc(u32, count) catch return null;
    } else {
        scratch.* = gpa.realloc(scratch.*, count) catch return null;
    }
    return scratch.*[0..count];
}

// The skirt butts straight against the client's last row of pixels, so a glass
// fill leaves a visible seam against any window that is not glass-coloured.
// Reading that row and filling the band with it makes the skirt read as part of
// the window. `row` is in buffer pixels. Returns straight-alpha RGBA, or null
// when the row cannot be read and the caller should keep the glass.
// `scratch` is grown to the row width and owned by the caller.
pub fn sampleEdge(texture: *wlr.Texture, row: wlr.Box, scratch: *[]u32) ?[4]f32 {
    if (row.width <= 0 or row.height <= 0) return null;
    const format = texture.preferredReadFormat();
    const layout = pixelLayout(format) orelse return null;

    const count: usize = @intCast(row.width);
    const pixels = growScratch(scratch, count) orelse {
        log.err("sampleEdge: could not allocate {d} pixels", .{count});
        return null;
    };

    if (!texture.readPixels(&.{
        .data = @ptrCast(pixels.ptr),
        .format = format,
        .stride = @intCast(count * @sizeOf(u32)),
        .dst_x = 0,
        .dst_y = 0,
        .src_box = row,
    })) return null;

    // Per-channel median: exact for the uniform background that dominates a
    // window's bottom row, and unmoved by a cursor or scrollbar sitting in it.
    var histogram = [_][256]u32{[_]u32{0} ** 256} ** 4;
    for (pixels) |pixel| {
        const bytes: [4]u8 = @bitCast(pixel);
        for (&histogram, layout.index) |*channel, index| channel[bytes[index]] += 1;
    }

    var median: [4]f32 = .{ 0, 0, 0, 0 };
    for (&median, &histogram) |*value, *channel| {
        var seen: usize = 0;
        for (channel, 0..) |bucket, level| {
            seen += bucket;
            if (seen * 2 >= count) {
                value.* = @as(f32, @floatFromInt(level)) / 255.0;
                break;
            }
        }
    }

    // wl_shm's 8888 formats carry premultiplied alpha; Color wants straight.
    const alpha: f32 = if (layout.has_alpha) median[3] else 1;
    if (alpha == 0) return null;
    return .{
        @min(1, median[0] / alpha),
        @min(1, median[1] / alpha),
        @min(1, median[2] / alpha),
        alpha,
    };
}

// Everything the rasterizer needs to reproduce a window's current appearance.
pub const ChromeState = struct {
    tabs: @import("chrome_tabs.zig").Strip = .{},
    radius: f32,
    active: bool = false,
    maximized: bool = false,
    density: f32 = 1,
    title: []const u8 = "",
    // Fill for the skirt, sampled from the client's own bottom row. Straight
    // alpha; null keeps the same glass the titlebar uses.
    skirt_fill: ?[4]f32 = null,
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

    fn titleFont(self: ChromeState) text.Font {
        return if (self.active) .manrope_bold else .manrope;
    }
};

// Inputs that produced the titlebar currently on screen. Skirt colour is
// intentionally absent so a changed edge sample can repaint only the footer.
// `rasterize` also reads `theme.global`; those are snapshotted here so a live
// reskin cannot be skipped. Width/height/radius stay full-frame because the
// SDF is evaluated against the whole rounded rectangle.
pub const TitlebarMemo = struct {
    font_generation: u32 = 0,
    tabs_hash: u64 = 0,
    width: i32,
    height: i32,
    radius: f32,
    density: f32 = 1,
    active: bool = false,
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

    pub fn capture(width: i32, height: i32, title_ptr: ?[*:0]const u8, state: ChromeState) TitlebarMemo {
        const t = theme.global;
        return .{
            .font_generation = text.font_generation,
            .width = width,
            .height = height,
            .radius = state.radius,
            .density = state.density,
            .active = state.active,
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
    /// painted for `a`: only hover, the hovered control, title or weight differ.
    pub fn reusableFor(a: TitlebarMemo, b: TitlebarMemo) bool {
        var normalized = a;
        normalized.title_ptr = b.title_ptr;
        normalized.tabs_hash = b.tabs_hash;
        normalized.active = b.active;
        return normalized.stableEql(b);
    }

    pub fn eql(a: TitlebarMemo, b: TitlebarMemo) bool {
        if (a.font_generation != b.font_generation) return false;
        if (a.width != b.width) return false;
        if (a.height != b.height) return false;
        if (a.radius != b.radius or a.density != b.density) return false;
        if (a.active != b.active) return false;
        if (a.title_ptr != b.title_ptr or a.tabs_hash != b.tabs_hash) return false;
        if (a.scale != b.scale) return false;
        if (a.hover != b.hover) return false;
        if (a.chip_pos != b.chip_pos or a.chip_alpha != b.chip_alpha) return false;
        if (a.maximized != b.maximized) return false;
        if (!iconEql(a.icon, b.icon)) return false;
        inline for (.{ "glass", "border", "border_soft", "fg", "dim", "border_hover", "surface_hover", "danger", "close_fg" }) |field| {
            if (!rgbaEql(@field(a, field), @field(b, field))) return false;
        }
        return a.close_hover_alpha == b.close_hover_alpha and a.title_size == b.title_size and a.chrome_height == b.chrome_height and a.chrome_control_gap == b.chrome_control_gap;
    }
};

// Footer raster inputs. Title, icon, and control hover do not appear in the
// skirt; the rounded-rectangle SDF still needs the full frame size.
pub const FooterMemo = struct {
    width: i32,
    height: i32,
    radius: f32,
    density: f32 = 1,
    skirt_fill: ?[4]f32,
    scale: f32,
    hover: f32,
    glass: [4]f32,
    border: [4]f32,
    border_hover: [4]f32,

    pub fn capture(width: i32, height: i32, state: ChromeState) FooterMemo {
        const t = theme.global;
        return .{
            .width = width,
            .height = height,
            .radius = state.radius,
            .density = state.density,
            .skirt_fill = state.skirt_fill,
            .scale = state.scale,
            .hover = state.hover,
            .glass = t.window_bg,
            .border = t.window_border,
            .border_hover = t.window_border_hover,
        };
    }

    pub fn stableEql(a: FooterMemo, b: FooterMemo) bool {
        var normalized = a;
        normalized.hover = b.hover;
        return normalized.eql(b);
    }

    pub fn eql(a: FooterMemo, b: FooterMemo) bool {
        if (a.width != b.width) return false;
        if (a.height != b.height) return false;
        if (a.radius != b.radius or a.density != b.density) return false;
        if (!optionalRgbaEql(a.skirt_fill, b.skirt_fill)) return false;
        if (a.scale != b.scale) return false;
        if (a.hover != b.hover) return false;
        inline for (.{ "glass", "border", "border_hover" }) |field| {
            if (!rgbaEql(@field(a, field), @field(b, field))) return false;
        }
        return true;
    }
};

fn rgbaEql(a: [4]f32, b: [4]f32) bool {
    return std.mem.eql(f32, &a, &b);
}

fn optionalRgbaEql(a: ?[4]f32, b: ?[4]f32) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return rgbaEql(left, right);
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

inline fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub const controlRect = window_chrome.controlRect;
pub const controlRectScaled = window_chrome.controlRectScaled;

pub const ChromeBuffer = struct {
    // wlroots imports this data-pointer buffer as a texture for the scene.
    // The pixel coverage is the CPU equivalent of shaders/rounded_frame.frag;
    // it avoids a separate render pass while preserving the SDF edge quality.
    base: wlr.Buffer,
    // The buffer is device pixels; the frame it draws is logical ones.
    width: i32,
    height: i32,
    logical_width: i32,
    logical_height: i32,
    // Which band of the frame this buffer holds, and where that band starts in
    // frame coordinates. The rasterizer measures everything against the whole
    // frame, so both bands are cut from one rounded rectangle.
    band: Band,
    band_y: i32,
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

    pub fn create(
        logical_width: i32,
        logical_height: i32,
        band: Band,
        state: ChromeState,
    ) !*ChromeBuffer {
        const frame = try gpa.create(ChromeBuffer);
        errdefer gpa.destroy(frame);

        const band_h = bandHeight(band, state.radius, state.density);
        const width = devicePixels(logical_width, state.scale);
        const height = devicePixels(band_h, state.scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        frame.* = .{
            .base = undefined,
            .width = width,
            .height = height,
            .logical_width = logical_width,
            .logical_height = logical_height,
            .band = band,
            .band_y = switch (band) {
                .titlebar => 0,
                .footer => logical_height - band_h,
            },
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
        const corners: i32 = @min(frame.logical_width, @as(i32, @intFromFloat(@ceil(state.radius))) + 1);
        const border_changed = previous.state.hover != state.hover;
        if (state.tabs.tabs.len > 0 and frame.band == .titlebar) {
            const tabs = @import("chrome_tabs.zig");
            if (previous.tabs_layout_hash == tabs.layoutHash(state.tabs) and
                previous.state.hover == state.hover and previous.state.chip_pos == state.chip_pos and previous.state.chip_alpha == state.chip_alpha and previous.state.maximized == state.maximized)
            {
                const geom = tabs.geometry(frame.logical_width, state.density, state.tabs);
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
        const controls_changed = frame.band == .titlebar and (previous.state.chip_pos != state.chip_pos or previous.state.chip_alpha != state.chip_alpha or previous.state.maximized != state.maximized);
        const Span = struct { x0: i32, x1: i32 };
        var spans: [3]Span = undefined;
        var count: usize = 0;
        if (border_changed) {
            spans[count] = .{ .x0 = 0, .x1 = corners };
            count += 1;
        }
        if ((title_changed or previous.state.active != state.active) and frame.band == .titlebar) {
            frame.title_extent = frame.titleExtent();
            const rect = titleRect(frame.logical_width, state);
            const extent = @max(previous.title_extent, frame.title_extent);
            if (extent > 0) {
                spans[count] = .{ .x0 = rect.x, .x1 = rect.x + extent };
                count += 1;
            }
        }
        var right = if (border_changed) frame.logical_width - corners else frame.logical_width;
        if (controls_changed) right = @min(right, @max(0, controlRectScaled(frame.logical_width, .minimize, frame.state.density).x - 1));
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
        const band_h = bandHeight(frame.band, state.radius, state.density);
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
        const title_left: i32 = if (state.icon != null) m.length(title_inset) + m.iconSize() + m.length(title_icon_gap) else m.length(title_inset);
        const controls_left = controlRectScaled(logical_width, .minimize, state.density).x;
        return .{ .x = title_left, .y = 0, .w = @max(0, controls_left - title_left), .h = m.titlebarHeight() - frame_border };
    }

    /// Logical width the current title can ink, measured from the title
    /// rect's left edge: its advance plus a margin for glyph overhang and
    /// antialiasing, capped by the rect (long titles are ellipsized to it).
    fn titleExtent(frame: *const ChromeBuffer) i32 {
        if (frame.band != .titlebar or frame.state.title.len == 0) return 0;
        const rect = titleRect(frame.logical_width, frame.state);
        const m: Metrics = .{ .density = frame.state.density };
        const width = text.measureWidth(frame.state.title, frame.state.titleFont(), theme.global.title_size * m.density, frame.state.scale) catch return rect.w;
        return @min(rect.w, width + 2);
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
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
        const fw: f32 = @floatFromInt(frame.logical_width);
        const fh: f32 = @floatFromInt(frame.logical_height);
        const band_top: f32 = @floatFromInt(frame.band_y);
        const radius = frame.state.radius;
        const border: f32 = @floatFromInt(frame_border);
        const inner_r = @max(radius - border, 0);
        const min_btn = controlRectScaled(frame.logical_width, .minimize, frame.state.density);
        const max_btn = controlRectScaled(frame.logical_width, .maximize, frame.state.density);
        const close_btn = controlRectScaled(frame.logical_width, .close, frame.state.density);
        // All glyphs fit inside their buttons. Include a full device pixel
        // around the group for antialiasing, including fractional scales.
        const control_left = @as(f32, @floatFromInt(min_btn.x)) - 1 / scale;
        const control_right = @as(f32, @floatFromInt(close_btn.x + close_btn.w)) + 1 / scale;
        const control_top = @as(f32, @floatFromInt(min_btn.y)) - 1 / scale;
        const control_bottom = @as(f32, @floatFromInt(min_btn.y + min_btn.h)) + 1 / scale;
        const diag = std.math.sqrt1_2;
        const icon_left: f32 = @floatFromInt(m.length(title_inset));
        const icon_top: f32 = @floatFromInt(@divTrunc(m.titlebarHeight() - m.iconSize(), 2));
        // Hover gently brightens the same border used by the straight edges.
        const edge_color = borderFill(frame.state.hover);
        // The titlebar uses the window tint. The
        // skirt continues the client, so it takes the client's own edge colour.
        const base = switch (frame.band) {
            .titlebar => Color.chrome(),
            .footer => if (frame.state.skirt_fill) |fill| Color.fromRgba(fill) else Color.chrome(),
        };
        // Away from the corners and the side antialiasing ramp, every pixel
        // in a row has the same fill and outer coverage. Pack that colour once
        // instead of repeating four rounded float conversions across the bar.
        const flat_inset = @max(radius, 1 / scale);
        const stride: usize = @intCast(frame.width);

        const x0: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x)) * scale)))))) else 0;
        const x1: usize = if (clip) |box| @intCast(@min(frame.width, @max(0, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(box.x + box.w)) * scale)))))) else stride;
        for (0..@intCast(frame.height)) |device_y| {
            // Rows are band-local device pixels; py is a frame-local logical
            // coordinate, so the shape below is the whole frame's.
            const py = band_top + (@as(f32, @floatFromInt(device_y)) + 0.5) / scale;
            const yi: i32 = @intFromFloat(@floor(py));
            const row = device_y * stride;
            var row_color = base;
            if (frame.band == .titlebar and yi == m.titlebarHeight() - 1) row_color = Color.divider().over(row_color);
            const flat_color = row_color.scaled(edgeCoverage(sdRoundedBox(fw / 2, py, 0, 0, fw, fh, radius), scale)).argb();
            const control_row = frame.band == .titlebar and py >= control_top and py <= control_bottom;
            const icon_row = frame.band == .titlebar and frame.state.tabs.tabs.len == 0 and frame.state.icon != null and
                py >= icon_top and py < icon_top + @as(f32, @floatFromInt(m.iconSize()));
            for (x0..x1) |x| {
                const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
                const in_controls = control_row and px >= control_left and px <= control_right;
                const in_icon = icon_row and px >= icon_left and px < icon_left + @as(f32, @floatFromInt(m.iconSize()));
                if (px >= flat_inset and px < fw - flat_inset and !in_controls and !in_icon) {
                    frame.pixels[row + x] = flat_color;
                    continue;
                }

                const outer_cov = edgeCoverage(sdRoundedBox(px, py, 0, 0, fw, fh, radius), scale);
                if (outer_cov == 0) {
                    frame.pixels[row + x] = 0;
                    continue;
                }

                var color = row_color;

                if (frame.band == .titlebar) {
                    if (in_controls) {
                        color = paintControls(
                            color,
                            px,
                            py,
                            min_btn,
                            max_btn,
                            close_btn,
                            frame.state.chip_pos,
                            frame.state.chip_alpha,
                            diag,
                            scale,
                            m.contentScale(),
                            frame.state.maximized,
                        );
                    }

                    if (if (frame.state.tabs.tabs.len == 0) frame.state.icon else null) |icon| {
                        if (px >= icon_left and px < icon_left + @as(f32, @floatFromInt(m.iconSize())) and
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
                }

                // Scene rects draw the straight frame edges. Retain only the
                // curved border, of which each band holds two corners.
                const in_corner = (px < radius or px >= fw - radius) and
                    (py < radius or py >= fh - radius);
                if (in_corner) {
                    const inner_cov = edgeCoverage(
                        sdRoundedBox(px, py, border, border, fw - 2 * border, fh - 2 * border, inner_r),
                        scale,
                    );
                    // Match the straight scene rects: border over the fill.
                    // Interpolating straight RGB and alpha independently
                    // produces a bright fringe and removes the fill under
                    // the border. Normalize the stroke coverage because the
                    // outer coverage is applied to the whole pixel below.
                    const stroke_cov = clamp01(1 - inner_cov / outer_cov);
                    color = edge_color.scaled(stroke_cov).over(color);
                }
                color.a *= outer_cov;
                frame.pixels[row + x] = color.argb();
            }
        }

        if (frame.band != .titlebar) return;

        if (frame.state.tabs.tabs.len > 0) {
            @import("chrome_tabs.zig").paint(Color, frame.pixels, frame.width, frame.height, frame.logical_width, frame.state.density, scale, frame.state.tabs, frame.state.icon, clip);
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

// The node is offset by the caller. The cutout must compensate for that
// offset so the outer shadow never darkens the translucent frame interior.
pub const ShadowState = struct {
    radius: f32,
    scale: f32 = 1,
    color: [4]f32,
    softness: f32,
    offset_y: f32 = 0,
};

pub const ShadowMemo = struct {
    width: i32,
    height: i32,
    radius: f32,
    color: [4]f32,
    softness: f32,
    offset_y: f32,
    scale: f32,
    disabled: bool,

    pub fn capture(width: i32, height: i32, radius: f32, scale: f32, disabled: bool) ShadowMemo {
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
            a.scale == b.scale;
    }
};

// A soft drop shadow behind the frame, cut from the same sdRoundedBox shape
// as ChromeBuffer so it always matches the window's actual corner radius.
// There's no blur primitive in this rasterizer (see shadowCoverage below);
// this is a single full-canvas raster, unlike ChromeBuffer's thin bands, so
// its cost scales with window area rather than titlebar/footer height — see
// the plan doc's note on a possible future 9-slice if that shows up as
// resize stutter on large windows.
pub const ShadowBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    frame_w: i32,
    frame_h: i32,
    margin: i32,
    state: ShadowState,
    pixels: []u32,

    const impl = wlr.Buffer.Impl{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(frame_w: i32, frame_h: i32, state: ShadowState) !*ShadowBuffer {
        const shadow = try gpa.create(ShadowBuffer);
        errdefer gpa.destroy(shadow);

        const margin: i32 = @intFromFloat(@ceil(state.softness));
        const width = devicePixels(frame_w + 2 * margin, state.scale);
        const height = devicePixels(frame_h + 2 * margin, state.scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        shadow.* = .{
            .base = undefined,
            .width = width,
            .height = height,
            .frame_w = frame_w,
            .frame_h = frame_h,
            .margin = margin,
            .state = state,
            .pixels = pixels,
        };
        shadow.base.init(&impl, width, height);
        shadow.rasterize();
        return shadow;
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
        const shadow: *ShadowBuffer = @fieldParentPtr("base", base);
        gpa.free(shadow.pixels);
        gpa.destroy(shadow);
    }

    fn beginDataPtrAccess(
        base: *wlr.Buffer,
        _: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        const shadow: *ShadowBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(shadow.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(shadow.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}

    fn rasterize(shadow: *ShadowBuffer) void {
        const scale = shadow.state.scale;
        const margin_f: f32 = @floatFromInt(shadow.margin);
        const fw: f32 = @floatFromInt(shadow.frame_w);
        const fh: f32 = @floatFromInt(shadow.frame_h);
        const softness = shadow.state.softness;
        const color = Color.fromRgba(shadow.state.color);
        const stride: usize = @intCast(shadow.width);

        for (0..@intCast(shadow.height)) |device_y| {
            const py = (@as(f32, @floatFromInt(device_y)) + 0.5) / scale;
            const row = device_y * stride;
            for (0..stride) |x| {
                const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
                const d = sdRoundedBox(px, py, margin_f, margin_f, fw, fh, shadow.state.radius);
                const frame_d = sdRoundedBox(px, py, margin_f, margin_f - shadow.state.offset_y, fw, fh, shadow.state.radius);
                const cov = shadowCoverage(d, softness) * (1 - edgeCoverage(frame_d, scale));
                if (cov <= 0) {
                    shadow.pixels[row + x] = 0;
                    continue;
                }
                var c = color;
                c.a *= cov;
                shadow.pixels[row + x] = c.argb();
            }
        }
    }
};

pub const ShadowPatchKind = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    top_edge,
    bottom_edge,
    left_edge,
    right_edge,
};

pub const ShadowPatchBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    pixels: []u32,

    const impl = wlr.Buffer.Impl{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(kind: ShadowPatchKind, state: ShadowState) !*ShadowPatchBuffer {
        const patch = try gpa.create(ShadowPatchBuffer);
        errdefer gpa.destroy(patch);

        const margin: i32 = @intFromFloat(@ceil(state.softness));
        const c_size: i32 = @intFromFloat(@ceil(state.radius + state.softness));
        const scale = state.scale;

        var logical_w: i32 = c_size;
        var logical_h: i32 = c_size;

        switch (kind) {
            .top_left, .top_right, .bottom_left, .bottom_right => {
                logical_w = c_size;
                logical_h = c_size;
            },
            .top_edge, .bottom_edge => {
                logical_w = 1;
                logical_h = c_size;
            },
            .left_edge, .right_edge => {
                logical_w = c_size;
                logical_h = 1;
            },
        }

        const dev_w = devicePixels(logical_w, scale);
        const dev_h = devicePixels(logical_h, scale);
        const length: usize = @intCast(dev_w * dev_h);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        patch.* = .{
            .base = undefined,
            .width = dev_w,
            .height = dev_h,
            .pixels = pixels,
        };
        patch.base.init(&impl, dev_w, dev_h);
        patch.rasterize(kind, state, c_size, margin);
        return patch;
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
        const patch: *ShadowPatchBuffer = @fieldParentPtr("base", base);
        gpa.free(patch.pixels);
        gpa.destroy(patch);
    }

    fn beginDataPtrAccess(
        base: *wlr.Buffer,
        _: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        const patch: *ShadowPatchBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(patch.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(patch.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}

    fn rasterize(patch: *ShadowPatchBuffer, kind: ShadowPatchKind, state: ShadowState, c_size: i32, margin: i32) void {
        const scale = state.scale;
        const margin_f: f32 = @floatFromInt(margin);
        const ref_fw: f32 = @floatFromInt(2 * c_size);
        const ref_fh: f32 = @floatFromInt(2 * c_size);
        const softness = state.softness;
        const color = Color.fromRgba(state.color);
        const stride: usize = @intCast(patch.width);

        for (0..@intCast(patch.height)) |dev_y| {
            const row = dev_y * stride;
            for (0..stride) |dev_x| {
                var px: f32 = undefined;
                var py: f32 = undefined;

                const lx = (@as(f32, @floatFromInt(dev_x)) + 0.5) / scale;
                const ly = (@as(f32, @floatFromInt(dev_y)) + 0.5) / scale;

                switch (kind) {
                    .top_left => {
                        px = lx;
                        py = ly;
                    },
                    .top_right => {
                        px = (ref_fw + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.width)) / scale) + lx;
                        py = ly;
                    },
                    .bottom_left => {
                        px = lx;
                        py = (ref_fh + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.height)) / scale) + ly;
                    },
                    .bottom_right => {
                        px = (ref_fw + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.width)) / scale) + lx;
                        py = (ref_fh + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.height)) / scale) + ly;
                    },
                    .top_edge => {
                        px = margin_f + @as(f32, @floatFromInt(c_size));
                        py = ly;
                    },
                    .bottom_edge => {
                        px = margin_f + @as(f32, @floatFromInt(c_size));
                        py = (ref_fh + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.height)) / scale) + ly;
                    },
                    .left_edge => {
                        px = lx;
                        py = margin_f + @as(f32, @floatFromInt(c_size));
                    },
                    .right_edge => {
                        px = (ref_fw + 2.0 * margin_f) - (@as(f32, @floatFromInt(patch.width)) / scale) + lx;
                        py = margin_f + @as(f32, @floatFromInt(c_size));
                    },
                }

                const d = sdRoundedBox(px, py, margin_f, margin_f, ref_fw, ref_fh, state.radius);
                const frame_d = sdRoundedBox(px, py, margin_f, margin_f - state.offset_y, ref_fw, ref_fh, state.radius);
                const cov = shadowCoverage(d, softness) * (1 - edgeCoverage(frame_d, scale));
                if (cov <= 0) {
                    patch.pixels[row + dev_x] = 0;
                    continue;
                }
                var c = color;
                c.a *= cov;
                patch.pixels[row + dev_x] = c.argb();
            }
        }
    }
};

pub const ShadowPatchSet = struct {
    corners: [4]*ShadowPatchBuffer,
    edges: [4]*ShadowPatchBuffer,
    state: ShadowState,

    pub fn create(state: ShadowState) !*ShadowPatchSet {
        const set = try gpa.create(ShadowPatchSet);
        errdefer gpa.destroy(set);

        set.state = state;
        set.corners[0] = try ShadowPatchBuffer.create(.top_left, state);
        errdefer set.corners[0].base.drop();
        set.corners[1] = try ShadowPatchBuffer.create(.top_right, state);
        errdefer set.corners[1].base.drop();
        set.corners[2] = try ShadowPatchBuffer.create(.bottom_left, state);
        errdefer set.corners[2].base.drop();
        set.corners[3] = try ShadowPatchBuffer.create(.bottom_right, state);
        errdefer set.corners[3].base.drop();

        set.edges[0] = try ShadowPatchBuffer.create(.top_edge, state);
        errdefer set.edges[0].base.drop();
        set.edges[1] = try ShadowPatchBuffer.create(.bottom_edge, state);
        errdefer set.edges[1].base.drop();
        set.edges[2] = try ShadowPatchBuffer.create(.left_edge, state);
        errdefer set.edges[2].base.drop();
        set.edges[3] = try ShadowPatchBuffer.create(.right_edge, state);
        errdefer set.edges[3].base.drop();

        return set;
    }

    pub fn destroy(set: *ShadowPatchSet) void {
        for (set.corners) |b| b.base.drop();
        for (set.edges) |b| b.base.drop();
        gpa.destroy(set);
    }
};

var global_shadow_patch_set: ?*ShadowPatchSet = null;

pub fn getOrMakeShadowPatchSet(state: ShadowState) !*ShadowPatchSet {
    if (global_shadow_patch_set) |set| {
        if (set.state.radius == state.radius and
            set.state.scale == state.scale and
            rgbaEql(set.state.color, state.color) and
            set.state.softness == state.softness and
            set.state.offset_y == state.offset_y)
        {
            return set;
        }
        set.destroy();
        global_shadow_patch_set = null;
    }
    const new_set = try ShadowPatchSet.create(state);
    global_shadow_patch_set = new_set;
    return new_set;
}

pub fn clearShadowPatchCache() void {
    if (global_shadow_patch_set) |set| {
        set.destroy();
        global_shadow_patch_set = null;
    }
}

// Unlike edgeCoverage's fixed one-device-pixel-wide AA ramp, this fades over
// `softness` logical pixels — an analytic stand-in for a real Gaussian blur,
// which this CPU rasterizer has no primitive for.
fn shadowCoverage(distance: f32, softness: f32) f32 {
    if (softness <= 0) return if (distance <= 0) 1 else 0;
    const t = clamp01(1 - distance / softness);
    return t * t * (3 - 2 * t); // smoothstep
}

test "shadowCoverage fades from opaque to transparent over softness" {
    try std.testing.expectEqual(@as(f32, 1), shadowCoverage(-5, 24));
    try std.testing.expectEqual(@as(f32, 1), shadowCoverage(0, 24));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), shadowCoverage(12, 24), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), shadowCoverage(24, 24));
    try std.testing.expectEqual(@as(f32, 0), shadowCoverage(30, 24));
    try std.testing.expectEqual(@as(f32, 1), shadowCoverage(-5, 0));
    try std.testing.expectEqual(@as(f32, 0), shadowCoverage(5, 0));
}

test "titlebar glass holds only while the titlebar is at least 98% opaque" {
    const saved = theme.global.window_bg;
    defer theme.global.window_bg = saved;
    theme.global.window_bg[3] = 0.98;
    try std.testing.expect(titlebarGlassMayHold(1));
    try std.testing.expect(!titlebarGlassMayHold(0.9));
    theme.global.window_bg[3] = 250.0 / 255.0; // #rrggbbfa
    try std.testing.expect(titlebarGlassMayHold(1));
    theme.global.window_bg[3] = 0.97;
    try std.testing.expect(!titlebarGlassMayHold(1));
}

test "outer shadow leaves the unshifted glass frame transparent" {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const shadow = try ShadowBuffer.create(120, 100, .{
            .radius = 10,
            .scale = scale,
            .color = .{ 0, 0, 0, 0.35 },
            .softness = 24,
            .offset_y = 8,
        });
        defer shadow.base.drop();
        // Node origin is (-24, -16): these points are well inside the
        // actual frame, including the strip above the shifted shadow.
        for ([_]i32{ 2, 20, 60, 98 }) |y| {
            const ix: usize = @intFromFloat(84 * scale);
            const iy: usize = @intFromFloat(@as(f32, @floatFromInt(y + 16)) * scale);
            try std.testing.expectEqual(@as(u32, 0), shadow.pixels[iy * @as(usize, @intCast(shadow.width)) + ix]);
        }
        const outside_x: usize = @intFromFloat(20 * scale);
        const outside_y: usize = @intFromFloat(60 * scale);
        try std.testing.expect(shadow.pixels[outside_y * @as(usize, @intCast(shadow.width)) + outside_x] >> 24 > 0);
    }
}

test "ShadowBuffer rasterizes a soft rounded shadow behind the frame" {
    const shadow = try ShadowBuffer.create(200, 120, .{ .radius = 10, .scale = 1, .color = .{ 0, 0, 0, 0.35 }, .softness = 24 });
    defer shadow.base.drop();

    try std.testing.expectEqual(@as(i32, 200 + 48), shadow.width);
    try std.testing.expectEqual(@as(i32, 120 + 48), shadow.height);

    // CSS outer shadows are clipped out under the frame, including glass.
    const stride: usize = @intCast(shadow.width);
    const center_x: usize = @intCast(@divTrunc(shadow.width, 2));
    const center_y: usize = @intCast(@divTrunc(shadow.height, 2));
    try std.testing.expectEqual(@as(u32, 0), shadow.pixels[center_y * stride + center_x]);

    // The canvas corner sits diagonally past the falloff radius: fully
    // transparent.
    try std.testing.expectEqual(@as(u32, 0), shadow.pixels[0]);
}

fn borderFill(hover: f32) Color {
    const t = clamp01(hover);
    if (t <= 0) return Color.border();
    if (t >= 1) return Color.border_hover();
    return Color.lerp(Color.border(), Color.border_hover(), t);
}

/// Straight border edges, matching the rasterized corner arcs.
pub fn borderColor(hover: f32) col.Premul {
    return borderFill(hover).straight().premultiply();
}

/// Chrome backing beneath the border, shared by the header and client sides.
pub fn fillColor() col.Premul {
    return Color.chrome().straight().premultiply();
}

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Decoration-specific colors leave the rest of the shell independent.
    fn chrome() Color {
        return fromRgba(theme.global.window_bg);
    }
    fn border() Color {
        return fromRgba(theme.global.window_border);
    }
    fn divider() Color {
        return fromRgba(theme.global.window_divider);
    }
    fn text_dim() Color {
        return fromRgba(theme.global.window_dim);
    }

    // .window:hover border, .win-btn:hover, .win-btn.close:hover and --text.
    fn border_hover() Color {
        return fromRgba(theme.global.window_border_hover);
    }
    fn control_hover() Color {
        return fromRgba(theme.global.surface_hover);
    }
    fn close_hover() Color {
        var c = fromRgba(theme.global.window_close_hover);
        c.a *= theme.global.window_close_hover_alpha;
        return c;
    }
    fn text() Color {
        return fromRgba(theme.global.window_fg);
    }
    fn textOnClose() Color {
        return Color.fromRgba(theme.global.window_close_fg);
    }

    pub fn fromRgba(rgba: [4]f32) Color {
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha. Mirrors
    // Taskbar.Color.fromPremultiplied; the two Color types are private to
    // each file, so this is a small, deliberate duplicate rather than a
    // shared one.
    pub fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    pub fn over(source: Color, destination: Color) Color {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        return .{
            .r = from.r + (to.r - from.r) * t,
            .g = from.g + (to.g - from.g) * t,
            .b = from.b + (to.b - from.b) * t,
            .a = from.a + (to.a - from.a) * t,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * alpha };
    }

    fn straight(color: Color) col.Straight {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    }

    pub fn argb(color: Color) u32 {
        return color.straight().argb();
    }
};

fn paintControls(
    base: Color,
    px: f32,
    py: f32,
    min_btn: Rect,
    max_btn: Rect,
    close_btn: Rect,
    chip_pos: f32,
    chip_alpha: f32,
    diag: f32,
    scale: f32,
    density: f32,
    maximized: bool,
) Color {
    var color = base;

    // .win-btn:hover chip, 4px radius, drawn under the glyph. One chip
    // slides between the buttons; its rect and red-ness are interpolated
    // from the slot coordinate.
    if (chip_alpha > 0) {
        const pos = std.math.clamp(chip_pos, 0, 2);
        const from_max = pos >= 1;
        const a_btn = if (from_max) max_btn else min_btn;
        const b_btn = if (from_max) close_btn else max_btn;
        const t = if (from_max) pos - 1 else pos;
        const fill = Color.lerp(Color.control_hover(), Color.close_hover(), clamp01(pos - 1));
        const chip = edgeCoverage(sdRoundedBox(
            px,
            py,
            mix(@floatFromInt(a_btn.x), @floatFromInt(b_btn.x), t),
            mix(@floatFromInt(a_btn.y), @floatFromInt(b_btn.y), t),
            mix(@floatFromInt(a_btn.w), @floatFromInt(b_btn.w), t),
            mix(@floatFromInt(a_btn.h), @floatFromInt(b_btn.h), t),
            btn_radius * density,
        ), scale);
        if (chip > 0) color = fill.scaled(chip * clamp01(chip_alpha)).over(color);
    }

    // Enlarge glyphs within the existing hover chips and hit targets.
    const glyph_scale = density * button_glyph_scale;
    const min_cov = minimizeIconCoverage(min_btn.centerX() + (px - min_btn.centerX()) / glyph_scale, min_btn.centerY() + (py - min_btn.centerY()) / glyph_scale, min_btn, scale * glyph_scale);
    if (min_cov > 0) color = iconColor(chip_pos, chip_alpha, .minimize).scaled(min_cov).over(color);
    const max_cov = maximizeIconCoverage(max_btn.centerX() + (px - max_btn.centerX()) / glyph_scale, max_btn.centerY() + (py - max_btn.centerY()) / glyph_scale, max_btn, scale * glyph_scale, maximized);
    if (max_cov > 0) color = iconColor(chip_pos, chip_alpha, .maximize).scaled(max_cov).over(color);
    const close_cov = closeIconCoverage(close_btn.centerX() + (px - close_btn.centerX()) / glyph_scale, close_btn.centerY() + (py - close_btn.centerY()) / glyph_scale, close_btn, diag, scale * glyph_scale);
    if (close_cov > 0) color = iconColor(chip_pos, chip_alpha, .close).scaled(close_cov).over(color);
    return color;
}

// Resting glyphs use neutral dim ink, --text on hover, #fff over close red.
fn iconColor(chip_pos: f32, chip_alpha: f32, kind: ControlKind) Color {
    // Keep the theme's dim brightness without its blue tint on the controls.
    const dim = Color.text_dim();
    const luminance = dim.r * 0.2126 + dim.g * 0.7152 + dim.b * 0.0722;
    const resting = Color{ .r = luminance, .g = luminance, .b = luminance, .a = dim.a };
    const weight = clamp01(1 - @abs(chip_pos - controlSlot(kind))) * clamp01(chip_alpha);
    return Color.lerp(resting, if (kind == .close) Color.textOnClose() else Color.text(), weight);
}

fn minimizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32) f32 {
    // A 12px dash at the lower edge of the glyph area.
    const cx = btn.centerX();
    const cy = btn.centerY() + 5;
    return edgeCoverage(sdRoundedBox(px, py, cx - 6, cy - 0.85, 12, 1.7, 0.85), scale);
}

fn maximizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32, maximized: bool) f32 {
    // A 10px outlined square, balanced against the dash and close glyph.
    const cx = btn.centerX();
    const cy = btn.centerY();
    if (!maximized) return outlineSquare(px, py, cx, cy, scale);
    // The lower-left window shows only its left and bottom edges, leaving
    // a clear gap around the complete upper-right window.
    const lower = edgeCoverage(@min(
        sdRoundedBox(px, py, cx - 7, cy - 3, 1.5, 10, 0.5),
        sdRoundedBox(px, py, cx - 7, cy + 5.5, 10, 1.5, 0.5),
    ), scale);
    return @max(lower, outlineSquare(px - 2, py + 2, cx, cy, scale));
}

fn outlineSquare(px: f32, py: f32, cx: f32, cy: f32, scale: f32) f32 {
    const outer = edgeCoverage(sdRoundedBox(px, py, cx - 5, cy - 5, 10, 10, 1), scale);
    const inner = edgeCoverage(sdRoundedBox(px, py, cx - 3.5, cy - 3.5, 7, 7, 0.5), scale);
    return clamp01(outer - inner);
}

const closeIconCoverage = window_chrome.closeIconCoverage;

// Shared with ui/paint.zig, which must not depend on the compositor.
pub const sdQuad = sdf.sdQuad;
pub const sdRoundedBox = sdf.sdRoundedBox;
pub const coverage = sdf.coverage;

// Same ramp, but for a distance measured in logical pixels while sampling on a
// denser grid: the edge stays one device pixel wide however far it is scaled.
inline fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

pub fn devicePixels(logical: i32, scale: f32) i32 {
    return geometry.devicePixels(logical, scale);
}

inline fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}

fn sampleTitlebarMemo() TitlebarMemo {
    return .{
        .width = 200,
        .height = 100,
        .radius = 10,
        .title_ptr = null,
        .scale = 1,
        .hover = 0,
        .chip_pos = 0,
        .chip_alpha = 0,
        .maximized = false,
        .icon = null,
        .glass = .{ 0, 0, 0, 1 },
        .border = .{ 1, 1, 1, 0.09 },
        .border_soft = .{ 1, 1, 1, 0.06 },
        .fg = .{ 1, 1, 1, 1 },
        .dim = .{ 0.5, 0.5, 0.5, 1 },
        .border_hover = .{ 1, 1, 1, 0.22 },
        .surface_hover = .{ 1, 1, 1, 0.08 },
        .danger = .{ 1, 0, 0, 1 },
        .title_size = 13.5,
    };
}

fn sampleFooterMemo() FooterMemo {
    return .{
        .width = 200,
        .height = 100,
        .radius = 10,
        .skirt_fill = null,
        .scale = 1,
        .hover = 0,
        .glass = .{ 0, 0, 0, 1 },
        .border = .{ 1, 1, 1, 0.09 },
        .border_hover = .{ 1, 1, 1, 0.22 },
    };
}

fn sampleMapping() EdgeMapping {
    return .{
        .source_x = 0,
        .source_y = 0,
        .source_w = 400,
        .source_h = 260,
        .scale = 1,
        .transform_normal = true,
        .buffer_width = 400,
        .buffer_height = 260,
        .format = drm_format_argb8888,
        .surface_width = 400,
        .surface_height = 260,
        .geom_x = 0,
        .geom_y = 0,
        .geom_w = 400,
        .geom_h = 260,
        .has_texture = true,
        .row_x = 0,
        .row_y = 259,
        .row_w = 400,
        .row_h = 1,
        .row_valid = true,
    };
}

test "TitlebarMemo.eql is true for identical inputs" {
    try std.testing.expect(sampleTitlebarMemo().eql(sampleTitlebarMemo()));
    const inactive = sampleTitlebarMemo();
    var active = inactive;
    active.active = true;
    try std.testing.expect(!inactive.eql(active));
    try std.testing.expect(inactive.reusableFor(active));
}

test "TitlebarMemo.eql compares the title pointer, not the string contents" {
    var a_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var b_buf = [_:0]u8{ 'h', 'e', 'l', 'l', 'o' };
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    left.title_ptr = &a_buf;
    right.title_ptr = &b_buf;
    try std.testing.expect(!left.eql(right));
    right.title_ptr = &a_buf;
    try std.testing.expect(left.eql(right));
}

test "TitlebarMemo.eql compares icon identity by id, not pixel pointer" {
    var pixels_a = [_]u32{0xFF000000};
    var pixels_b = [_]u32{0xFF000000};
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();

    // Same id, different backing pixel buffers: still the same icon.
    left.icon = .{ .id = 1, .pixels = &pixels_a, .size = 1 };
    right.icon = .{ .id = 1, .pixels = &pixels_b, .size = 1 };
    try std.testing.expect(left.eql(right));

    // Different id, even sharing a pixel buffer: a different icon. A raw
    // pointer comparison would get this wrong once eviction can free and
    // reuse a buffer's address for a different icon.
    right.icon = .{ .id = 2, .pixels = &pixels_a, .size = 1 };
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.eql ignores sampled skirt colour" {
    const title = sampleTitlebarMemo();
    try std.testing.expect(title.eql(sampleTitlebarMemo()));
}

test "FooterMemo.eql is false when the sampled skirt colour changes" {
    var left = sampleFooterMemo();
    var right = sampleFooterMemo();
    left.skirt_fill = .{ 0.1, 0.2, 0.3, 1 };
    right.skirt_fill = .{ 0.1, 0.2, 0.3, 1 };
    try std.testing.expect(left.eql(right));
    right.skirt_fill = .{ 0.1, 0.2, 0.4, 1 };
    try std.testing.expect(!left.eql(right));
    right.skirt_fill = null;
    try std.testing.expect(!left.eql(right));
}

test "FooterMemo.eql ignores title and control hover" {
    const footer = sampleFooterMemo();
    try std.testing.expect(footer.eql(sampleFooterMemo()));
}

test "TitlebarMemo.eql detects font, title size and close control appearance" {
    var left = sampleTitlebarMemo();
    var right = sampleTitlebarMemo();
    right.font_generation +%= 1;
    try std.testing.expect(!left.eql(right));
    try std.testing.expect(!left.reusableFor(right));
    right = left;
    right.title_size = 14;
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_fg = .{ 0, 1, 0, 1 };
    try std.testing.expect(!left.eql(right));
    right = left;
    right.close_hover_alpha = 0.4;
    try std.testing.expect(!left.eql(right));
}

test "TitlebarMemo.capture reads title_size from theme.global" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global.title_size = 19.25;
    const memo = TitlebarMemo.capture(10, 10, null, .{ .radius = 0, .scale = 1 });
    try std.testing.expectEqual(@as(f32, 19.25), memo.title_size);
}

test "chrome geometry changes invalidate retained titlebar pixels" {
    const saved = theme.global;
    defer theme.global = saved;
    const before = TitlebarMemo.capture(400, 320, null, .{ .radius = 10 });
    theme.global.chrome_control_gap += 1;
    const spaced = TitlebarMemo.capture(400, 320, null, .{ .radius = 10 });
    try std.testing.expect(!before.eql(spaced));
    try std.testing.expect(!before.reusableFor(spaced));
    theme.global.chrome_control_gap = saved.chrome_control_gap;
    theme.global.chrome_height += 1;
    const taller = TitlebarMemo.capture(400, 320, null, .{ .radius = 10 });
    try std.testing.expect(!before.reusableFor(taller));
}

test "chrome controls fit and stay centered at every supported height and density" {
    const saved = theme.global;
    defer theme.global = saved;
    for ([_]f32{ 28, 55, 84 }) |height| {
        theme.global.chrome_height = height;
        for ([_]f32{ 1, 0.75 }) |density| {
            const m: Metrics = .{ .density = density };
            for ([_]f32{ 0, 4, 24 }) |gap| {
                theme.global.chrome_control_gap = gap;
                const min = controlRectScaled(400, .minimize, density);
                const max = controlRectScaled(400, .maximize, density);
                const close = controlRectScaled(400, .close, density);
                try std.testing.expectEqual(m.controlGap(), max.x - (min.x + min.w));
                try std.testing.expectEqual(m.controlGap(), close.x - (max.x + max.w));
                try std.testing.expect(min.y >= 0 and min.y + min.h < m.titlebarHeight());
                try std.testing.expect(@abs(2 * min.y + min.h - m.titlebarHeight()) <= 1);
                try std.testing.expect(m.iconSize() < min.h);
                try std.testing.expect(min.x > m.length(title_inset) + m.iconSize() + m.length(title_icon_gap));
            }
        }
    }
}

test "rectsOverlap treats touching edges as disjoint" {
    try std.testing.expect(!rectsOverlap(0, 0, 10, 10, 10, 0, 10, 10));
    try std.testing.expect(rectsOverlap(0, 259, 400, 1, 0, 259, 400, 1));
    try std.testing.expect(!rectsOverlap(0, 0, 400, 259, 0, 259, 400, 1));
    try std.testing.expect(rectsOverlap(0, 0, 400, 260, 0, 259, 400, 1));
}

test "decideEdgeSample samples the first commit and skips later misses" {
    const mapping = sampleMapping();
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.uninitialized, null, mapping, .none, false));
    try std.testing.expectEqual(SampleAction.skip, decideEdgeSample(.color, mapping, mapping, .misses_row, false));
    try std.testing.expectEqual(SampleAction.skip, decideEdgeSample(.color, mapping, mapping, .none, false));
}

test "decideEdgeSample resamples one-pixel edge damage and full damage" {
    const mapping = sampleMapping();
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, mapping, .intersects_row, false));
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, mapping, .unknown, false));
}

test "decideEdgeSample ignores buffer pointer rotation when damage misses the row" {
    const mapping = sampleMapping();
    try std.testing.expectEqual(SampleAction.skip, decideEdgeSample(.color, mapping, mapping, .misses_row, false));
}

test "decideEdgeSample resamples when the source viewport or scale changes" {
    const mapping = sampleMapping();
    var cropped = mapping;
    cropped.source_y = 10;
    cropped.source_h = 240;
    cropped.row_y = 249;
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, cropped, .none, false));

    var scaled = mapping;
    scaled.scale = 2;
    scaled.buffer_width = 800;
    scaled.buffer_height = 520;
    scaled.row_y = 519;
    scaled.row_w = 800;
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, scaled, .misses_row, false));
}

test "decideEdgeSample resamples when xdg geometry offsets the row" {
    const mapping = sampleMapping();
    var inset = mapping;
    inset.geom_y = 10;
    inset.geom_h = 240;
    inset.row_y = 249;
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, inset, .none, false));
}

test "decideEdgeSample falls back on unsupported transforms and does not keep a colour" {
    const mapping = sampleMapping();
    var rotated = mapping;
    rotated.transform_normal = false;
    rotated.row_valid = false;
    try std.testing.expectEqual(SampleAction.fallback, decideEdgeSample(.color, mapping, rotated, .none, false));
    try std.testing.expectEqual(SampleAction.skip, decideEdgeSample(.fallback, rotated, rotated, .none, false));
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.fallback, rotated, mapping, .none, false));
}

test "decideEdgeSample falls back when the texture is missing" {
    const mapping = sampleMapping();
    var empty = mapping;
    empty.has_texture = false;
    empty.row_valid = false;
    try std.testing.expectEqual(SampleAction.fallback, decideEdgeSample(.uninitialized, null, empty, .unknown, false));
    try std.testing.expectEqual(SampleAction.skip, decideEdgeSample(.fallback, empty, empty, .none, false));
}

test "decideEdgeSample force overrides a valid cache" {
    const mapping = sampleMapping();
    try std.testing.expectEqual(SampleAction.sample, decideEdgeSample(.color, mapping, mapping, .misses_row, true));
    var empty = mapping;
    empty.has_texture = false;
    empty.row_valid = false;
    try std.testing.expectEqual(SampleAction.fallback, decideEdgeSample(.fallback, empty, empty, .none, true));
}

test "ShadowMemo.eql ignores geometry while the shadow is disabled" {
    const a = ShadowMemo{
        .width = 10,
        .height = 10,
        .radius = 0,
        .color = .{ 0, 0, 0, 0 },
        .softness = 0,
        .offset_y = 0,
        .scale = 1,
        .disabled = true,
    };
    var b = a;
    b.width = 999;
    try std.testing.expect(a.eql(b));
    b.disabled = false;
    try std.testing.expect(!a.eql(b));
}

test "ShadowMemo.eql is false when softness changes" {
    const a = ShadowMemo{
        .width = 200,
        .height = 100,
        .radius = 10,
        .color = .{ 0, 0, 0, 0.35 },
        .softness = 24,
        .offset_y = 8,
        .scale = 1,
        .disabled = false,
    };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.softness = 32;
    try std.testing.expect(!a.eql(b));
}

test "corner antialiasing stays between the fill and the composited straight border" {
    const saved_theme = theme.global;
    defer theme.global = saved_theme;
    for ([_]f32{ 0.4, 0.98, 1 }) |alpha| {
        theme.global.window_bg = .{ 16.0 / 255.0, 18.0 / 255.0, 21.0 / 255.0, alpha };
        for ([_]f32{ 0, 0.35, 1 }) |hover| {
            for ([_]f32{ 0.75, 1, 1.25, 1.5, 2 }) |scale| {
                for ([_]f32{ 7.5, 10 }) |radius| {
                    for ([_]Band{ .titlebar, .footer }) |band| {
                        const skirt: [4]f32 = .{ 0.2, 0.3, 0.4, alpha };
                        const frame = try ChromeBuffer.create(400, 300, band, .{
                            .radius = radius,
                            .scale = scale,
                            .hover = hover,
                            .skirt_fill = skirt,
                        });
                        defer frame.base.drop();
                        const fill = if (band == .titlebar) Color.chrome() else Color.fromRgba(skirt);
                        const bordered = borderFill(hover).over(fill);
                        const stride: usize = @intCast(frame.width);
                        var samples: usize = 0;
                        for (frame.pixels, 0..) |pixel, i| {
                            const px = (@as(f32, @floatFromInt(i % stride)) + 0.5) / scale;
                            const py = @as(f32, @floatFromInt(frame.band_y)) + (@as(f32, @floatFromInt(i / stride)) + 0.5) / scale;
                            if (!(px < radius or px >= 400 - radius) or !(py < radius or py >= 300 - radius)) continue;
                            const outer = edgeCoverage(sdRoundedBox(px, py, 0, 0, 400, 300, radius), scale);
                            // Coverage may blend the fill towards the same
                            // border-over-fill as the scene rects, never make
                            // it brighter or punch a transparent hole in it.
                            const a = fill.scaled(outer).argb();
                            const b = bordered.scaled(outer).argb();
                            inline for (.{ 0, 8, 16, 24 }) |shift| {
                                const channel = (pixel >> shift) & 0xff;
                                const lo = @min((a >> shift) & 0xff, (b >> shift) & 0xff);
                                const hi = @max((a >> shift) & 0xff, (b >> shift) & 0xff);
                                try std.testing.expect(channel + 1 >= lo and channel <= hi + 1);
                            }
                            if (outer > 0 and outer < 1) samples += 1;
                        }
                        try std.testing.expect(samples > 0);
                    }
                }
            }
        }
    }
}

test "cached chrome updates exactly match complete rasters across hover controls and scales" {
    for ([_]i32{ 20, 200, 640 }) |width| {
        for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
            for ([_]f32{ 1, 0.75, 1.0 / 1.7 }) |density| {
                for ([_]f32{ 0, 12 }) |radius| {
                    for ([_]Band{ .titlebar, .footer }) |band| {
                        var state: ChromeState = .{ .radius = radius * density, .density = density, .scale = scale, .title = "Cached window title", .skirt_fill = .{ 0.2, 0.3, 0.4, 0.7 } };
                        var previous = try ChromeBuffer.create(width, 350, band, state);
                        defer previous.base.drop();
                        // Titles change alone and together with hover and
                        // controls: growing, shrinking, ellipsized, fallback
                        // glyphs (a terminal spinner) and empty.
                        const titles = [_][]const u8{
                            "Cached window title",
                            "\u{280b} Working on a task that is long enough to be ellipsized before the controls",
                            "Short",
                            "Short",
                            "",
                            "\u{2819} Working \u{2014} claude",
                        };
                        var step: usize = 0;
                        for ([_]f32{ 0.35, 1, 0 }) |hover| {
                            for ([_]?ControlKind{ .minimize, .maximize, .close, null }) |control| {
                                const previous_title = state.title;
                                state.hover = hover;
                                state.chip_pos = if (control) |kind| controlSlot(kind) else 0.5;
                                state.chip_alpha = if (control == null) 0.35 else 1;
                                state.title = titles[step % titles.len];
                                state.active = step % 2 == 0;
                                step += 1;
                                const expected = try ChromeBuffer.create(width, 350, band, state);
                                defer expected.base.drop();
                                const updated = try ChromeBuffer.createUpdated(previous, state, !std.mem.eql(u8, previous_title, state.title));
                                errdefer updated.base.drop();
                                try std.testing.expectEqualSlices(u32, expected.pixels, updated.pixels);
                                previous.base.drop();
                                previous = updated;
                            }
                        }
                    }
                }
            }
        }
    }
}

test "tab title updates preserve neighbouring pixels and match a full raster" {
    const Tab = @import("chrome_tabs.zig").Tab;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const before = [_]Tab{ .{ .id = 1, .title = "A longer title", .active = true, .attention = false }, .{ .id = 2, .title = "Untouched", .active = false, .attention = false } };
        var state: ChromeState = .{ .radius = 10, .scale = scale, .tabs = .{ .tabs = &before } };
        const old = try ChromeBuffer.create(600, 300, .titlebar, state);
        defer old.base.drop();
        var after = before;
        after[0].title = "Short";
        state.tabs.tabs = &after;
        const updated = try ChromeBuffer.createUpdated(old, state, true);
        defer updated.base.drop();
        const full = try ChromeBuffer.create(600, 300, .titlebar, state);
        defer full.base.drop();
        try std.testing.expectEqualSlices(u32, full.pixels, updated.pixels);
        const geom = @import("chrome_tabs.zig").geometry(600, 1, state.tabs);
        const untouched = geom.tab(1);
        for (0..@intCast(old.height)) |y| {
            const start: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@ceil(untouched.x * scale)));
            const end: usize = y * @as(usize, @intCast(old.width)) + @as(usize, @intFromFloat(@floor((untouched.x + untouched.w) * scale)));
            try std.testing.expectEqualSlices(u32, old.pixels[start..end], updated.pixels[start..end]);
        }
    }
}

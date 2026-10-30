//! Taskbar value types: chip state, memos and raster keys, tray state, colours and fills, the bar buffer and chip paint records.

const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("../geometry.zig");
const icon_service = @import("../icon_service.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const Toplevel = @import("../Toplevel.zig");
const taskbar_metrics = @import("metrics.zig");
const taskbar_classify = @import("classify.zig");
const taskbar_paint_util = @import("paint_util.zig");
const Anim = anim.Anim;
const chipSize = taskbar_metrics.chipSize;
const tileSize = taskbar_metrics.tileSize;
const chipPad = taskbar_metrics.chipPad;
const chipTitle = taskbar_classify.chipTitle;
const monogramOf = taskbar_classify.monogramOf;
const textColor = taskbar_paint_util.textColor;
const clamp01 = taskbar_paint_util.clamp01;
const Taskbar = @import("../Taskbar.zig");
const bar_height = Taskbar.bar_height;
const base_chip_size = Taskbar.base_chip_size;
const press_scale = Taskbar.press_scale;
const TrayKind = Taskbar.TrayKind;
const AppKind = Taskbar.AppKind;
const create = Taskbar.create;

pub const MeasuredWidth = struct {
    width: f32 = 0,
    scale: f32 = 0,
    font_generation: u32 = 0,
    valid: bool = false,

    pub fn get(self: *const MeasuredWidth, scale: f32) ?f32 {
        if (!self.valid or self.scale != scale or self.font_generation != text.font_generation) return null;
        return self.width;
    }

    pub fn put(self: *MeasuredWidth, scale: f32, width: f32) f32 {
        self.* = .{ .width = width, .scale = scale, .font_generation = text.font_generation, .valid = true };
        return width;
    }
};

pub const ChipState = struct {
    toplevel: *Toplevel,
    buffer_node: ?*sn.Buffer = null,
    dirty: bool = true,
    kind: AppKind = .other,
    // A real icon found via the XDG icon theme, when one exists; falls back
    // to the hand-drawn `tileStyle`/`glyphSd` tile below when null.
    icon: ?icon_service.Entry = null,
    target_x: f32 = 0,
    // Struct field defaults must be comptime; the anchor size is fine here
    // since `reconcile` always overwrites this with the live `chipSize()`
    // (via `sharedChipWidth`) right after construction.
    width: f32 = @floatFromInt(base_chip_size),
    flip: Anim = .{},
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
    // What the raster on screen was painted from; see `ChipMemo`.
    painted: ?ChipMemo = null,
    // That raster, still referenced here, and the sampled paint and placement
    // it used: a change of title alone copies it and repaints only the title.
    raster: ?*BarBuffer = null,
    raster_key: ?ChipRasterKey = null,

    pub fn renderX(self: ChipState, now_ms: i64) f32 {
        return self.target_x + self.flip.value(now_ms);
    }
};

// Inputs to a chip raster that `reconcile` can change, so a title change
// (terminal spinners, tab counters) repaints only its own chip. Hover and
// press curves mark chips dirty from `tick`, and `relayout` repaints
// everything. The theme fields are snapshotted because colour-only reskins
// arrive through here, like chrome.TitlebarMemo.
pub const ChipMemo = struct {
    x: f32,
    width: f32,
    active: bool,
    needs_attention: bool,
    kind: AppKind,
    icon: ?u64,
    title_hash: u64,
    scale: f32,
    bar_height: i32,
    chip_size: i32,
    tile_size: i32,
    chip_pad: i32,
    radius: f32,
    title_size: f32,
    font: []const u8,
    colors: [6][4]f32,

    pub fn capture(bar: *Taskbar, chip: *const ChipState, now_ms: i64) ChipMemo {
        const t = ui_theme.global;
        return .{
            .x = chip.renderX(now_ms),
            .width = chip.width,
            .active = chip.toplevel == bar.server.world.toplevels.first(),
            .needs_attention = chip.toplevel.needs_attention,
            .kind = chip.kind,
            .icon = if (chip.icon) |icon| icon.id else null,
            // Covers the monogram too: both fall back from title to app_id.
            .title_hash = std.hash.Wyhash.hash(0, chipTitle(chip.toplevel)),
            .scale = bar.wlr_output.scale,
            .bar_height = bar.box.height,
            .chip_size = chipSize(),
            .tile_size = tileSize(),
            .chip_pad = chipPad(),
            .radius = t.radius,
            .title_size = t.taskbar_title_size,
            .font = t.font,
            .colors = .{ ui_theme.taskbar(.taskbar_surface), ui_theme.taskbar(.taskbar_hover), ui_theme.taskbar(.surface_hover), ui_theme.taskbar(.taskbar_border), ui_theme.taskbar(.border_soft), ui_theme.taskbar(.window_fg) },
        };
    }
};

// Chip raster inputs that `ChipMemo` leaves to the hover/press curves and
// FLIP offset, sampled as `ChipPaint` does, plus the buffer placement. Chips
// without an icon draw a monogram taken from the title into their tile.
pub const ChipRasterKey = struct {
    left: i32,
    width: i32,
    scale: f32,
    x: f32,
    fill: Color,
    border: Color,
    monogram: [4]u8 = @splat(0),
    monogram_len: usize = 0,

    pub fn capture(bar: *Taskbar, now_ms: i64, chip: *const ChipState, left: i32, width: i32) ChipRasterKey {
        const paint = ChipPaint.init(bar, now_ms, chip);
        var key: ChipRasterKey = .{
            .left = left,
            .width = width,
            .scale = bar.wlr_output.scale,
            .x = paint.x,
            .fill = paint.fill,
            .border = paint.border,
        };
        if (chip.icon == null and chip.kind == .other) {
            var storage: [4]u8 = undefined;
            const label = monogramOf(chip.toplevel, &storage);
            @memcpy(key.monogram[0..label.len], label);
            key.monogram_len = label.len;
        }
        return key;
    }
};

pub const TrayState = struct {
    kind: TrayKind,
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
};

// ---- Colors (design-system tokens shared with chrome.zig where noted) ----
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Exact CSS tints; glass.c supplies the filtered backdrop underneath.
    pub fn bar_fill() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_bg));
    }
    pub fn hairline() Color {
        return fromRgba(ui_theme.taskbar(.border_soft));
    }
    // The bar's own outline; unset it is the hairline `border_soft` always drew.
    pub fn outline() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_outline) orelse ui_theme.taskbar(.border_soft));
    }
    pub fn chip_idle() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_surface));
    }
    pub fn hover_fill() Color {
        return fromRgba(ui_theme.taskbar(.surface_hover));
    }
    pub fn active_fill() Color {
        return fromRgba(ui_theme.taskbar(.taskbar_hover)).scaled(2.8);
    }
    pub fn fromRgba(c: [4]f32) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }
    pub fn chip_title_idle() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_fg)));
    }
    pub fn tray_icon() Color {
        return fromRgba(ui_theme.taskbar(.window_fg));
    }
    pub fn tray_icon_hover() Color {
        return fromRgba(ui_theme.taskbar(.window_fg));
    }
    pub const glyph = Color{ .r = 1, .g = 1, .b = 1, .a = 0.96 };
    pub fn clock_time() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_fg)));
    }
    pub fn clock_date() text.Color {
        return textColor(fromRgba(ui_theme.taskbar(.window_dim)));
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
        const ct = clamp01(t);
        return .{
            .r = from.r + (to.r - from.r) * ct,
            .g = from.g + (to.g - from.g) * ct,
            .b = from.b + (to.b - from.b) * ct,
            .a = from.a + (to.a - from.a) * ct,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = clamp01(color.a * alpha) };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha, so it can go through the
    // existing `.over()` blend unchanged.
    pub fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    pub fn argb(color: Color) u32 {
        return (col.Straight{ .r = color.r, .g = color.g, .b = color.b, .a = color.a }).argb();
    }
};

// ---- Tile fills, straight from the App Fills table (135deg gradients) ----
pub const Fill = union(enum) { solid: Color, gradient: struct { a: Color, b: Color } };

pub const TileStyle = struct { fill: Fill, hairline: bool };

// ---- The buffer itself: same data-pointer wlr.Buffer technique as
// chrome.ChromeBuffer, recreated wholesale on every repaint. ----
pub const BarBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    logical_width: i32,
    scale: f32,
    pixels: []u32,

    pub const drm_format_argb8888: u32 = 0x34325241;

    pub const impl = wlr.Buffer.Impl{
        .destroy = destroyBuffer,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    pub fn create(logical_width: i32, logical_height: i32, scale: f32) !*BarBuffer {
        const buf = try gpa.create(BarBuffer);
        errdefer gpa.destroy(buf);

        const width = geometry.devicePixels(logical_width, scale);
        const height = geometry.devicePixels(logical_height, scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        buf.* = .{ .base = undefined, .width = width, .height = height, .logical_width = logical_width, .scale = scale, .pixels = pixels };
        buf.base.init(&impl, width, height);
        return buf;
    }

    pub fn destroyBuffer(base: *wlr.Buffer) callconv(.c) void {
        base.finish();
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        gpa.free(buf.pixels);
        gpa.destroy(buf);
    }

    pub fn beginDataPtrAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(buf.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
        return true;
    }

    pub fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
};

pub const ChipPaint = struct {
    chip: *const ChipState,
    x: f32,
    fill: Color,
    border: Color,
    bar_height: i32,
    flat: ChipFlat = .{},

    pub fn init(bar: *Taskbar, now_ms: i64, chip: *const ChipState) ChipPaint {
        const active = chip.toplevel == bar.server.world.toplevels.first();
        const hover = chip.hover.value(now_ms);
        const press_strength = std.math.clamp((1 - chip.press.value(now_ms)) / (1 - press_scale), 0, 1);
        const style = @import("chip_style.zig").lookFrom(Color, .taskbar, active, chip.toplevel.needs_attention, hover, press_strength);
        var paint: ChipPaint = .{
            .chip = chip,
            .x = chip.renderX(now_ms),
            .fill = style.fill,
            .border = style.border,
            .bar_height = bar.box.height,
        };
        paint.flat = .init(&paint, bar.wlr_output.scale);
        return paint;
    }
};

// Most of a chip is empty or flat fill. Pixels at least one logical pixel
// from every edge and from the icon tile get exactly what `paintChipPixel`
// computes there, without its three SDFs, which were most of the raster
// time. One pixel of distance saturates coverage only from scale 0.75 up.
pub const ChipFlat = struct {
    enabled: bool = false,
    outer: Rect = undefined,
    // The inner rounded box, shrunk by the margin, minus its corners.
    band_h: Rect = undefined,
    band_v: Rect = undefined,
    tile: Rect = undefined,
    fill: u32 = 0,

    pub const Rect = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,

        pub fn contains(r: Rect, x: f32, y: f32) bool {
            return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1;
        }
    };

    pub fn init(paint: *const ChipPaint, scale: f32) ChipFlat {
        const x = paint.x;
        const y: f32 = @floatFromInt(@divTrunc(paint.bar_height - chipSize(), 2));
        const w = paint.chip.width;
        const h: f32 = @floatFromInt(chipSize());
        // `paintChipPixel`'s inner box, with sdRoundedBox's radius clamp.
        const iw = w - 2;
        const ih = h - 2;
        const corner = @max(1, @min(@max(0, ui_theme.global.radius - 1), @min(iw, ih) / 2));
        const tile_x = x + @as(f32, @floatFromInt(chipPad()));
        const tile_y = y + @as(f32, @floatFromInt(chipPad()));
        const tile: f32 = @floatFromInt(tileSize());
        const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .enabled = scale >= 0.75,
            .outer = .{ .x0 = x - 1, .y0 = y - 1, .x1 = x + w + 1, .y1 = y + h + 1 },
            .band_h = .{ .x0 = x + 1 + corner, .y0 = y + 2, .x1 = x + 1 + iw - corner, .y1 = y + ih },
            .band_v = .{ .x0 = x + 2, .y0 = y + 1 + corner, .x1 = x + iw, .y1 = y + 1 + ih - corner },
            .tile = .{ .x0 = tile_x - 1, .y0 = tile_y - 1, .x1 = tile_x + tile + 1, .y1 = tile_y + tile + 1 },
            // The same expression `paintChipPixel` evaluates at full coverage.
            .fill = Color.lerp(paint.border, paint.fill, 1).scaled(1).over(clear).argb(),
        };
    }
};

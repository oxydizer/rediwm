//! Build-time tool: turns the phinger-cursors SVG sources (Figma exports plus
//! `cursor-theme.json`) into installable Xcursor themes.
//!
//!   rediwm-cursorgen <source dir> <output dir>
//!
//! Each variant becomes `<output>/phinger-cursors-<variant>/` with an
//! `index.theme` and a `cursors/` directory; aliases are symlinks. Every SVG
//! carries its hotspot as a 1px `#hotspot` rect, removed before rendering.
//! Cursors with `animations` rotate their `#spinner` group, eased
//! in-out-cubic, and are written as multi-frame Xcursor images that wlroots
//! and libXcursor animate.
const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("cairo.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const Handle = opaque {};
const GError = opaque {};
const Rectangle = extern struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64 };
extern fn rsvg_handle_new_from_data([*]const u8, usize, *?*GError) ?*Handle;
extern fn rsvg_handle_render_document(*Handle, *c.cairo_t, *const Rectangle, *?*GError) c_int;
extern fn rsvg_handle_get_geometry_for_layer(*Handle, [*:0]const u8, *const Rectangle, *Rectangle, *Rectangle, *?*GError) c_int;
extern fn g_object_unref(*anyopaque) void;
extern fn g_error_free(*GError) void;

/// Nominal sizes written into every cursor file, each rendered from the SVG
/// drawn for the nearest design size (the 24px and 32px artwork differ).
/// Xcursor loaders pick the nearest size, so these cover the usual cursor
/// sizes at scales 1 through 3.
const Size = struct { nominal: u32, design: u32 };
const sizes = [_]Size{
    .{ .nominal = 24, .design = 24 },
    .{ .nominal = 32, .design = 32 },
    .{ .nominal = 40, .design = 32 },
    .{ .nominal = 48, .design = 24 },
    .{ .nominal = 64, .design = 32 },
    .{ .nominal = 96, .design = 32 },
};
/// The spinner animation: 720° over 1.5 s, split into this many frames.
const spin_frames = 36;
const spin_degrees = 720.0;
const spin_ms = 1500;

/// Extra names the source JSON leaves out. `all-resize` is a cursor-shape-v1
/// name; the hashes are the legacy names Qt/X11 toolkits still request.
const extra_aliases = [_][2][]const u8{
    .{ "move", "all-resize" },
    .{ "pointer", "e29285e634086352946a0e7090d73106" },
    .{ "pointer", "9d800788f1b08800ae810202380a0822" },
    .{ "copy", "1081e37283d90000800003c07f3ef6bf" },
    .{ "copy", "6407b0e94181790501fd1e167b474872" },
    .{ "alias", "640fb0e74195791501fd1ed57b41487f" },
    .{ "alias", "3085a0e285430894940527032f8b26df" },
    .{ "grabbing", "fcf21c00b30f7e3f83fe0dfd12e71cff" },
    .{ "help", "5c6cd98b3f3ebcb1f9c7f1c204630408" },
    .{ "help", "d9ce0ab605698f320427677b458ad60b" },
    .{ "not-allowed", "03b6e0fcb3499374a867c041f52298f0" },
    .{ "ew-resize", "028006030e0e7ebffc7f7070c0600140" },
    .{ "ns-resize", "00008160000006810000408080010102" },
    .{ "nesw-resize", "fcf1c3c7cd4491d801f1e1c78f100000" },
    .{ "nwse-resize", "c7088f0f3e6c8088236ef8e1e3e70000" },
    .{ "col-resize", "14fef782d02440884392942c11205230" },
    .{ "row-resize", "2870a09082c103050810ffdffffe0204" },
};

const Theme = struct {
    name: []const u8,
    variants: []const Variant,
};
const Variant = struct {
    name: []const u8,
    cursors: []const Cursor,
};
const Cursor = struct {
    name: []const u8,
    sprites: []const Sprite,
    aliases: ?[]const []const u8 = null,
};
const Sprite = struct {
    file: []const u8,
    animations: ?[]const std.json.Value = null,
};

const Image = struct {
    nominal: u32,
    width: u32,
    height: u32,
    xhot: u32,
    yhot: u32,
    delay: u32,
    pixels: []u32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: {s} <source dir> <output dir>\n", .{args[0]});
        std.process.exit(2);
    }
    const src_dir = args[1];
    const out_dir = args[2];
    const io = init.io;

    const json_path = try std.fs.path.join(allocator, &.{ src_dir, "cursor-theme.json" });
    const json = try Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(4 << 20));
    const parsed = try std.json.parseFromSlice(Theme, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try mkdirs(allocator, out_dir);
    for (parsed.value.variants) |variant| {
        const theme_dir = try std.fmt.allocPrint(allocator, "{s}/phinger-cursors-{s}", .{ out_dir, variant.name });
        const cursors_dir = try std.fmt.allocPrint(allocator, "{s}/cursors", .{theme_dir});
        try mkdirs(allocator, cursors_dir);
        const index = try std.fmt.allocPrint(allocator,
            \\[Icon Theme]
            \\Name={c}{s}
            \\Comment=Phinger Cursors by Philipp Schaffrath, CC BY-SA 4.0; built for RediWM
            \\
        , .{ std.ascii.toUpper(variant.name[0]), variant.name[1..] });
        try writeFile(allocator, theme_dir, "index.theme", index);

        for (variant.cursors) |cursor| {
            var images: std.ArrayList(Image) = .empty;
            for (sizes) |size| {
                const sprite = findSprite(cursor, size.design) orelse return error.MissingSprite;
                const path = try std.fs.path.join(allocator, &.{ src_dir, sprite.file });
                const svg = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
                const animated = sprite.animations != null and sprite.animations.?.len > 0;
                const frames: u32 = if (animated) spin_frames else 1;
                for (0..frames) |frame| {
                    try images.append(allocator, try renderFrame(allocator, svg, size, frame, frames));
                }
            }
            try writeCursor(allocator, cursors_dir, cursor.name, images.items);
            if (cursor.aliases) |aliases| for (aliases) |alias| try link(allocator, cursors_dir, cursor.name, alias);
            for (extra_aliases) |extra| {
                if (std.mem.eql(u8, extra[0], cursor.name)) try link(allocator, cursors_dir, cursor.name, extra[1]);
            }
        }
    }
}

fn findSprite(cursor: Cursor, design: u32) ?Sprite {
    var buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, "_{d}.svg", .{design}) catch return null;
    for (cursor.sprites) |sprite| {
        if (std.mem.endsWith(u8, sprite.file, suffix)) return sprite;
    }
    return null;
}

/// Hotspot of the source artwork, in design pixels: the `x`/`y` of the first
/// rect inside `<g id="hotspot">` (absent attributes mean 0).
fn hotspot(svg: []const u8) !struct { x: f64, y: f64 } {
    const group = std.mem.indexOf(u8, svg, "<g id=\"hotspot\"") orelse return error.MissingHotspot;
    const rect_start = std.mem.indexOfPos(u8, svg, group, "<rect") orelse return error.MissingHotspot;
    const rect_end = std.mem.indexOfPos(u8, svg, rect_start, ">") orelse return error.MissingHotspot;
    const rect = svg[rect_start..rect_end];
    return .{ .x = attr(rect, " x=\"") orelse 0, .y = attr(rect, " y=\"") orelse 0 };
}

fn attr(tag: []const u8, key: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, tag, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return std.fmt.parseFloat(f64, tag[start..end]) catch null;
}

/// The source with its hotspot marker removed and, for animated cursors,
/// the spinner rotated to `degrees` about its own centre.
fn prepare(allocator: std.mem.Allocator, svg: []const u8, spin: ?struct { degrees: f64, cx: f64, cy: f64 }) ![]u8 {
    const group = std.mem.indexOf(u8, svg, "<g id=\"hotspot\"") orelse return error.MissingHotspot;
    const close = std.mem.indexOfPos(u8, svg, group, "</g>") orelse return error.MissingHotspot;
    const without = try std.mem.concat(allocator, u8, &.{ svg[0..group], svg[close + "</g>".len ..] });
    const s = spin orelse return without;
    const tag = "<g id=\"spinner\">";
    const at = std.mem.indexOf(u8, without, tag) orelse return error.MissingSpinner;
    const rotated = try std.fmt.allocPrint(allocator, "<g id=\"spinner\" transform=\"rotate({d:.4} {d:.4} {d:.4})\">", .{ s.degrees, s.cx, s.cy });
    return std.mem.concat(allocator, u8, &.{ without[0..at], rotated, without[at + tag.len ..] });
}

fn easeInOutCubic(t: f64) f64 {
    return if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2;
}

fn renderFrame(allocator: std.mem.Allocator, svg: []const u8, size: Size, frame: usize, frames: u32) !Image {
    const design: f64 = @floatFromInt(size.design);
    const factor = @as(f64, @floatFromInt(size.nominal)) / design;
    const hot = try hotspot(svg);

    const source = if (frames == 1) try prepare(allocator, svg, null) else blk: {
        const centre = try spinnerCentre(svg, design);
        const t = @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(frames));
        break :blk try prepare(allocator, svg, .{ .degrees = spin_degrees * easeInOutCubic(t), .cx = centre.x, .cy = centre.y });
    };

    const px: i32 = @intCast(size.nominal);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, px, px) orelse return error.CairoFailed;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.CairoFailed;
    defer c.cairo_destroy(cr);

    var err: ?*GError = null;
    const handle = rsvg_handle_new_from_data(source.ptr, source.len, &err) orelse return error.SvgParseFailed;
    defer g_object_unref(handle);
    const viewport = Rectangle{ .width = @floatFromInt(px), .height = @floatFromInt(px) };
    if (rsvg_handle_render_document(handle, cr, &viewport, &err) == 0) return error.SvgRenderFailed;
    c.cairo_surface_flush(surface);

    // Cairo ARGB32 is premultiplied native-endian 0xAARRGGBB: exactly the
    // Xcursor pixel format on little-endian machines.
    const data = c.cairo_image_surface_get_data(surface) orelse return error.CairoFailed;
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const n: usize = size.nominal;
    const pixels = try allocator.alloc(u32, n * n);
    for (0..n) |y| {
        const row: [*]align(4) const u32 = @ptrCast(@alignCast(data + y * stride));
        @memcpy(pixels[y * n ..][0..n], row[0..n]);
    }

    // Spread 1500 ms across the frames without rounding drift.
    const delay: u32 = if (frames == 1) 0 else @intCast((spin_ms * (frame + 1)) / frames - (spin_ms * frame) / frames);
    return .{
        .nominal = size.nominal,
        .width = size.nominal,
        .height = size.nominal,
        .xhot = @min(size.nominal - 1, @as(u32, @intFromFloat(@floor(hot.x * factor)))),
        .yhot = @min(size.nominal - 1, @as(u32, @intFromFloat(@floor(hot.y * factor)))),
        .delay = delay,
        .pixels = pixels,
    };
}

fn spinnerCentre(svg: []const u8, design: f64) !struct { x: f64, y: f64 } {
    var err: ?*GError = null;
    const handle = rsvg_handle_new_from_data(svg.ptr, svg.len, &err) orelse return error.SvgParseFailed;
    defer g_object_unref(handle);
    const viewport = Rectangle{ .width = design, .height = design };
    var ink: Rectangle = .{ .width = 0, .height = 0 };
    var logical: Rectangle = .{ .width = 0, .height = 0 };
    if (rsvg_handle_get_geometry_for_layer(handle, "#spinner", &viewport, &ink, &logical, &err) == 0) return error.MissingSpinner;
    return .{ .x = logical.x + logical.width / 2, .y = logical.y + logical.height / 2 };
}

fn writeCursor(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, images: []const Image) !void {
    var out: std.ArrayList(u8) = .empty;
    const header_len = 16;
    const toc_len = 12 * images.len;
    try putAll(&out, allocator, &.{ 0x72756358, header_len, 0x10000, @intCast(images.len) }); // "Xcur"
    var position: usize = header_len + toc_len;
    for (images) |image| {
        try putAll(&out, allocator, &.{ 0xfffd0002, image.nominal, @intCast(position) });
        position += 36 + image.pixels.len * 4;
    }
    for (images) |image| {
        try putAll(&out, allocator, &.{ 36, 0xfffd0002, image.nominal, 1, image.width, image.height, image.xhot, image.yhot, image.delay });
        for (image.pixels) |pixel| try putAll(&out, allocator, &.{pixel});
    }
    try writeFile(allocator, dir, name, out.items);
}

fn putAll(out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const u32) !void {
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try out.appendSlice(allocator, &bytes);
    }
}

fn writeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    const file = c.fopen(path.ptr, "wb") orelse return error.WriteFailed;
    defer _ = c.fclose(file);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.WriteFailed;
}

fn link(allocator: std.mem.Allocator, dir: []const u8, target: []const u8, alias: []const u8) !void {
    if (std.mem.eql(u8, target, alias)) return;
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, alias }, 0);
    const to = try allocator.dupeZ(u8, target);
    _ = c.unlink(path.ptr);
    if (c.symlink(to.ptr, path.ptr) != 0) return error.LinkFailed;
}

fn mkdirs(allocator: std.mem.Allocator, path: []const u8) !void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const part = try allocator.dupeZ(u8, path[0..i]);
        if (c.mkdir(part.ptr, 0o755) != 0 and std.c._errno().* != @intFromEnum(std.posix.E.EXIST)) return error.MkdirFailed;
    }
}

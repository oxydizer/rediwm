//! Straight and premultiplied colour, kept apart by type (AGENTS.md, "Rendering").
//!
//! Themes and config describe straight RGBA. wlroots scene/render colours and
//! RediWM's 0xAARRGGBB buffers are premultiplied: GLES2 blends with
//! `GL_ONE, GL_ONE_MINUS_SRC_ALPHA`, so straight alpha turns a 9% white edge
//! nearly solid white. Scene rect colours go through `createRect`/`setRect`,
//! which accept only `Premul`; the only way to get one from a theme colour is
//! `Straight.premultiply`.
const std = @import("std");
const wlr = @import("wlroots");

pub const Straight = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn fromRgba(rgba: [4]f32) Straight {
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    /// Parses `#rrggbb` or `#rrggbbaa` at compile time.
    pub fn hex(comptime text: []const u8) Straight {
        comptime {
            if ((text.len != 7 and text.len != 9) or text[0] != '#')
                @compileError("expected #rrggbb or #rrggbbaa, got '" ++ text ++ "'");
            return .{
                .r = hexChannel(text[1..3]),
                .g = hexChannel(text[3..5]),
                .b = hexChannel(text[5..7]),
                .a = if (text.len == 9) hexChannel(text[7..9]) else 1,
            };
        }
    }

    /// For APIs that take straight RGBA, such as the UI renderer.
    pub fn toRgba(c: Straight) [4]f32 {
        return .{ c.r, c.g, c.b, c.a };
    }

    pub fn premultiply(c: Straight) Premul {
        return .{ .rgba = .{ c.r * c.a, c.g * c.a, c.b * c.a, c.a } };
    }

    /// Packs into a premultiplied 0xAARRGGBB pixel, clamping alpha before
    /// it scales the colour channels.
    pub fn argb(c: Straight) u32 {
        const a = clamp01(c.a);
        return pack(a, c.r * a, c.g * a, c.b * a);
    }
};

pub const Premul = struct {
    rgba: [4]f32,

    pub const transparent: Premul = .{ .rgba = @splat(0) };

    /// Black at `alpha`, whose straight and premultiplied forms coincide.
    pub fn black(alpha: f32) Premul {
        return .{ .rgba = .{ 0, 0, 0, alpha } };
    }

    /// Fades every channel, as scene-buffer opacity does.
    pub fn scale(c: Premul, opacity: f32) Premul {
        var out = c;
        for (&out.rgba) |*channel| channel.* *= opacity;
        return out;
    }

    pub fn argb(c: Premul) u32 {
        return pack(c.rgba[3], c.rgba[0], c.rgba[1], c.rgba[2]);
    }

    pub fn renderColor(c: Premul) wlr.RenderPass.Color {
        return .{ .r = c.rgba[0], .g = c.rgba[1], .b = c.rgba[2], .a = c.rgba[3] };
    }
};

pub fn createRect(tree: *wlr.SceneTree, width: c_int, height: c_int, c: Premul) !*wlr.SceneRect {
    return tree.createSceneRect(width, height, &c.rgba);
}

pub fn setRect(rect: *wlr.SceneRect, c: Premul) void {
    rect.setColor(&c.rgba);
}

// Rounds rather than truncates: `lerp` at t == 1 returns its endpoint only to
// within a ULP, and truncating turned interpolated fills one level darker
// than their endpoints (visible in chrome corner arcs).
fn pack(a: f32, r: f32, g: f32, b: f32) u32 {
    return (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

fn byte(v: f32) u32 {
    return @intFromFloat(@round(clamp01(v) * 255.0));
}

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn hexChannel(comptime digits: []const u8) f32 {
    const value = std.fmt.parseInt(u8, digits, 16) catch @compileError("invalid hex digits '" ++ digits ++ "'");
    return @as(f32, @floatFromInt(value)) / 255.0;
}

test "premultiplied packing rounds and clamps" {
    const edge: Straight = .{ .r = 1, .g = 1, .b = 1, .a = 0.09 };
    try std.testing.expectEqual(@as(u32, 0x17171717), edge.argb());
    try std.testing.expectEqual(edge.argb(), edge.premultiply().argb());
    try std.testing.expectEqual(@as(u32, 0xff00ff00), (Straight{ .r = -1, .g = 2, .b = 0, .a = 3 }).argb());
    try std.testing.expectEqual(@as(u32, 0x80000000), Premul.black(0.5).argb());
    try std.testing.expectEqual(@as(u32, 0x40404040), (Straight{ .r = 1, .g = 1, .b = 1, .a = 0.5 }).premultiply().scale(0.5).argb());
}

test "hex colours are parsed at compile time" {
    const c = comptime Straight.hex("#ff0617");
    try std.testing.expectEqual(@as(u32, 0xffff0617), c.argb());
    try std.testing.expectEqual(@as(u32, 0x80800000), (comptime Straight.hex("#ff000080")).argb());
}

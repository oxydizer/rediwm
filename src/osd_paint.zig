const i18n = @import("i18n");
const std = @import("std");
const ui = @import("ui");
const Profile = @import("power_profiles.zig").Profile;

pub const Kind = enum { volume, microphone, brightness, keyboard_backlight, caps_lock, power_profile, zoom, window_zoom };
const KeyboardLevel = struct {
    current: u32 = 0,
    maximum: u32 = 3,

    fn label(self: KeyboardLevel) []const u8 {
        if (self.current == 0) return i18n.tr("Off");
        if (self.maximum == 1) return i18n.tr("On");
        if (self.maximum > 3) return i18n.tr("Keyboard backlight");
        if (self.current == self.maximum) return i18n.tr("High");
        return if (self.current == 1) i18n.tr("Low") else i18n.tr("Medium");
    }
};
pub const State = struct {
    kind: Kind,
    level: f32 = 0,
    active: bool = false, // muted for audio, enabled for Caps Lock
    profile: Profile = .balanced,
    keyboard: KeyboardLevel = .{},
    window_id: ?u64 = null,
};

pub fn width(kind: Kind) i32 {
    return switch (kind) {
        .volume, .brightness => 304,
        .zoom => 320,
        .window_zoom => 72,
        .power_profile, .keyboard_backlight => 212,
        .microphone, .caps_lock => 76,
    };
}
pub fn hasLevel(kind: Kind) bool {
    return kind == .volume or kind == .brightness or kind == .zoom;
}
pub fn height(kind: Kind) i32 {
    return if (kind == .window_zoom) 32 else 60;
}
const icon_size = 26;
pub const slider_width = 182;
const slider_height = 11;
pub fn paint(r: *ui.paint.Renderer, state: State) void {
    const t = ui.theme.shellPalette();
    const white = t.window_fg;
    const red = t.accent;
    const track = t.app_divider;
    const wide = hasLevel(state.kind);
    const w: f32 = @floatFromInt(width(state.kind));
    const h: f32 = @floatFromInt(height(state.kind));
    const inset: f32 = if (state.kind == .window_zoom) 0 else 4;
    // Border uses the same premultiplied painter as the shell.
    r.fillRect(inset, inset, w - 2 * inset, h - 2 * inset, .{ .color = .{ t.window_bg[0], t.window_bg[1], t.window_bg[2], t.osd_opacity }, .radius = t.osd_radius, .border_width = 1, .border_color = t.osd_border });
    if (state.kind == .window_zoom) {
        var buf: [16]u8 = undefined;
        const percent: u32 = @intFromFloat(@round(state.level * 100));
        const label = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch unreachable;
        r.drawTextCentered(4, 0, w - 8, h, .{ .content = label, .font_size = 16, .weight = 600, .color = white });
        return;
    }
    const icon: ui.layout.IconId = switch (state.kind) {
        .volume => if (state.active) .volume_muted else if (state.level < 0.4) .volume_low else .volume,
        .microphone => if (state.active) .mic_muted else .mic_outline,
        .brightness => .brightness,
        .keyboard_backlight => .keyboard,
        .zoom => .zoom_out,
        .window_zoom => unreachable,
        .caps_lock => .caps_lock,
        .power_profile => switch (state.profile) {
            .power_saver => .power_saver,
            .balanced => .power_balanced,
            .performance => .power_performance,
        },
    };
    if (state.kind == .power_profile or state.kind == .keyboard_backlight) {
        r.drawIcon(16, 17, icon_size, icon_size, .{ .id = icon, .color = white, .stroke_width = 2.5 });
        const label = if (state.kind == .power_profile) state.profile.label() else state.keyboard.label();
        r.drawText(54, 10, w - 70, 22, .{ .content = label, .font_size = 15, .color = white });
        if (state.kind == .power_profile) {
            paintSegments(r, w - 70, @backingInt(state.profile) + 1, 3, red, track);
        } else if (state.keyboard.maximum <= 3) {
            paintSegments(r, w - 70, state.keyboard.current, state.keyboard.maximum, red, track);
        } else {
            const fraction = @as(f32, @floatFromInt(state.keyboard.current)) / @as(f32, @floatFromInt(state.keyboard.maximum));
            r.fillRect(54, 37, w - 70, 6, .{ .color = track, .radius = 3 });
            r.fillRect(54, 37, (w - 70) * fraction, 6, .{ .color = red, .radius = 3 });
        }
        return;
    }
    r.drawIcon(if (wide) 16 else 25, if (wide) 17 else 8, icon_size, icon_size, .{ .id = icon, .color = white, .stroke_width = 2.5 });
    if (wide) {
        r.fillRect(54, 24.5, slider_width, slider_height, .{ .color = track, .radius = 5.5 });
        const level = if (state.kind == .volume and state.active) 0 else std.math.clamp(state.level, 0, 1);
        r.fillRect(54, 24.5, slider_width * level, slider_height, .{ .color = red, .radius = 5.5 });
        var buf: [16]u8 = undefined;
        const percent: u32 = @intFromFloat(@round(std.math.clamp(state.level, 0, if (state.kind == .zoom) @as(f32, 100) else 10) * 100));
        const label = if (state.kind == .zoom)
            std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch ""
        else
            std.fmt.bufPrint(&buf, "{d}", .{percent}) catch "";
        r.drawText(248, 14, w - 260, 32, .{ .content = label, .font_size = 18, .color = white });
    } else {
        if (state.active) r.fillRect(47, 27, 6, 6, .{ .color = if (state.kind == .microphone) red else white, .radius = 3 });
        r.drawText(if (state.kind == .microphone) 17 else 30, 34, 52, 20, .{ .content = if (state.kind == .microphone) (if (state.active) i18n.tr("Muted") else i18n.tr("Mic on")) else (if (state.active) i18n.tr("On") else i18n.tr("Off")), .font_size = 12, .color = white });
    }
}

fn paintSegments(r: *ui.paint.Renderer, bar_width: f32, filled: u32, count: u32, accent: [4]f32, track: [4]f32) void {
    const gap = 4;
    const segment = (bar_width - gap * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count));
    for (0..count) |i| {
        const x = 54 + @as(f32, @floatFromInt(i)) * (segment + gap);
        r.fillRect(x, 37, segment, 6, .{ .color = if (i < filled) accent else track, .radius = 3 });
    }
}

test "OSD pixels are premultiplied at integer and fractional scales" {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        inline for (std.meta.tags(Kind)) |kind| {
            const w: i32 = @intFromFloat(@as(f32, @floatFromInt(width(kind))) * scale);
            const h: i32 = @intFromFloat(@as(f32, @floatFromInt(height(kind))) * scale);
            const pixels = try std.testing.allocator.alloc(u32, @intCast(w * h));
            defer std.testing.allocator.free(pixels);
            @memset(pixels, 0);
            var renderer = ui.paint.Renderer.init(pixels, w, h, scale);
            paint(&renderer, .{ .kind = kind, .level = 0.7, .active = true });
            for (pixels) |pixel| {
                const a = pixel >> 24;
                try std.testing.expect((pixel & 255) <= a and ((pixel >> 8) & 255) <= a and ((pixel >> 16) & 255) <= a);
            }
        }
    }
}

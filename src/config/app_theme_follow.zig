//! Reloadable GTK themes. Two bounded slots give GtkSettings a new name when
//! colors change; GTK caches user gtk.css for the lifetime of an application.
const std = @import("std");
const app = @import("app_theme.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const names = [_][]const u8{ "RediWM-a", "RediWM-b" };

pub fn name(slot: u1) []const u8 {
    return names[slot];
}

pub fn dataHome(a: Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_DATA_HOME")) |path| if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    const home = env.getPosix("HOME") orelse return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) return error.NoHome;
    return std.fs.path.join(a, &.{ home, ".local/share" });
}

pub fn current(a: Allocator, io: Io, home: []const u8) !?u1 {
    const path = try std.fs.path.join(a, &.{ home, "gtk-3.0/settings.ini" });
    defer a.free(path);
    const bytes = try app.readOptional(a, io, path) orelse return null;
    defer a.free(bytes);
    const selected = app.iniValue(bytes, "Settings", "gtk-theme-name") orelse return null;
    for (names, 0..) |value, slot| if (std.mem.eql(u8, selected, value)) return @intCast(slot);
    return null;
}

pub fn css(a: Allocator, p: app.Palette, gtk4: bool) ![]u8 {
    const colors = try app.gtkColors(a, p, gtk4);
    defer a.free(colors);
    const private = if (gtk4) try a.dupe(u8, "") else try privateColors(a, colors);
    defer a.free(private);
    // The base follows the palette, not dark_mode: a dark palette over light
    // Adwaita leaves every widget the overrides miss light.
    const dark = app.isDark(p);
    const base = if (gtk4)
        (if (dark) "Default/Default-dark.css" else "Default/Default-light.css")
    else
        (if (dark) "Adwaita/gtk-contained-dark.css" else "Adwaita/gtk-contained.css");
    return std.fmt.allocPrint(a, "@import url(\"resource:///org/gtk/libgtk/theme/{s}\");\n{s}{s}\n" ++
        // Chromium samples the window as its toolbar and a headerbar as
        // its frame. Keep the address field separate from that toolbar.
        "window.background.chromium {{ background-color: @headerbar_bg_color; color: @window_fg_color; }}\n" ++
        "window.background.chromium label {{ color: @window_fg_color; }}\n" ++
        "window.background.chromium entry {{ background-color: @view_bg_color; color: @view_fg_color; }}\n", .{ base, colors, private });
}

const define = "@define-color ";

/// Each named color again as `rediwm_<name>`, which only the slots define.
fn privateColors(a: Allocator, colors: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, colors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, define)) continue;
        try out.appendSlice(a, define ++ "rediwm_");
        try out.appendSlice(a, line[define.len..]);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// GTK3 user CSS outranks every theme, and generators (matugen/DMS, KDE's
/// colors.css) define the standard names there. Aliases appended last win
/// over those, and GTK resolves them at style time against the loaded slot,
/// so running apps still follow a slot switch although user CSS is cached.
/// GTK4 gets none: libadwaita loads no slot, leaving the aliases unresolved.
pub fn userAliases(a: Allocator, p: app.Palette) ![]u8 {
    const colors = try app.gtkColors(a, p, false);
    defer a.free(colors);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, colors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, define)) continue;
        const color = line[define.len..][0 .. std.mem.indexOfScalar(u8, line[define.len..], ' ') orelse continue];
        try out.appendSlice(a, define);
        try out.appendSlice(a, color);
        try out.appendSlice(a, " @rediwm_");
        try out.appendSlice(a, color);
        try out.appendSlice(a, ";\n");
    }
    return out.toOwnedSlice(a);
}

/// Writes all files before any settings-change notification may be sent. User
/// CSS and settings are retained; RediWM's snapshot import is removed, and
/// GTK3's gtk.css gains `userAliases` in its place.
pub fn apply(a: Allocator, io: Io, home: []const u8, data: []const u8, p: app.Palette) !u1 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const styles = [_][]const u8{ try css(mem, p, false), try css(mem, p, true) };
    const aliases = try userAliases(mem, p);
    const previous = try current(mem, io, home);
    var slot: u1 = if (previous) |old| old ^ 1 else 0;
    if (previous) |old| {
        var same = true;
        for ([_][]const u8{ "gtk-3.0", "gtk-4.0" }, styles) |version, style| {
            const path = try std.fs.path.join(mem, &.{ data, "themes", name(old), version, "gtk.css" });
            const saved = try app.readOptional(mem, io, path) orelse "";
            same = same and std.mem.eql(u8, saved, style);
        }
        if (same) slot = old;
    }
    var tx = app.Transaction{ .a = mem, .io = io };
    for ([_][]const u8{ "gtk-3.0", "gtk-4.0" }, styles) |version, style| {
        const path = try std.fs.path.join(mem, &.{ data, "themes", name(slot), version, "gtk.css" });
        try tx.add(path, style, false);
        // Supply either requested variant from the same resolved palette.
        const dark_path = try std.fs.path.join(mem, &.{ data, "themes", name(slot), version, "gtk-dark.css" });
        try tx.add(dark_path, style, false);
        const settings_path = try std.fs.path.join(mem, &.{ home, version, "settings.ini" });
        const settings = try app.readOptional(mem, io, settings_path) orelse "";
        try tx.add(settings_path, try app.patchIni(mem, settings, "Settings", "gtk-theme-name", name(slot)), true);
        const user_path = try std.fs.path.join(mem, &.{ home, version, "gtk.css" });
        if (try app.readOptional(mem, io, user_path)) |user| {
            const patched = if (std.mem.eql(u8, version, "gtk-3.0"))
                try app.replaceManagedCss(mem, user, aliases)
            else
                try app.removeManagedCss(mem, user);
            try tx.add(user_path, patched, true);
        }
    }
    try tx.commit();
    return slot;
}

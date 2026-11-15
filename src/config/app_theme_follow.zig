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

/// One slot stylesheet. GTK loads gtk-dark.css instead of gtk.css when an
/// application prefers a dark theme, which Chromium browsers set from the
/// light/dark preference: `dark` picks the Chromium colours for that file
/// (`app.browserPalette`). Everything else follows the palette in both.
pub fn css(a: Allocator, p: app.Palette, gtk4: bool, dark: bool) ![]u8 {
    const colors = try app.gtkColors(a, p, gtk4);
    defer a.free(colors);
    const private = if (gtk4) try a.dupe(u8, "") else try privateColors(a, colors);
    defer a.free(private);
    const chromium = try chromiumCss(a, app.browserPalette(p, dark));
    defer a.free(chromium);
    // The base follows the palette, not dark_mode: a dark palette over light
    // Adwaita leaves every widget the overrides miss light.
    const base = if (gtk4)
        (if (app.isDark(p)) "Default/Default-dark.css" else "Default/Default-light.css")
    else
        (if (app.isDark(p)) "Adwaita/gtk-contained-dark.css" else "Adwaita/gtk-contained.css");
    return std.fmt.allocPrint(a, "@import url(\"resource:///org/gtk/libgtk/theme/{s}\");\n{s}{s}\n{s}", .{ base, colors, private, chromium });
}

/// Chromium's GTK mode renders these nodes (ui/gtk/gtk_color_mixers.cc), each
/// under a `window.background` root, with a `chromium` class on every node.
/// Colours are literal: the browser palette may differ from the named colours
/// and from the Adwaita base, which would otherwise show through.
fn chromiumCss(a: Allocator, b: app.Palette) ![]u8 {
    const w = "window.background.chromium";
    const toolbar = app.hex(b.toolbar);
    const fg = app.hex(b.fg);
    const dim = app.hex(b.dim);
    const border = app.hex(b.border);
    const accent = app.hex(b.accent);
    const on_accent = app.hex(b.on_accent);
    const view = app.hex(b.bg);
    return std.fmt.allocPrint(a,
        // The window is the toolbar and the active tab; a headerbar the frame,
        // the tab strip. The address field stays apart from that toolbar.
        w ++ ", " ++ w ++ " window.background {{ background-color: {[toolbar]s}; color: {[fg]s}; }}\n" ++
        w ++ " headerbar, " ++ w ++ " headerbar:backdrop {{ background-color: {[frame]s}; background-image: none; color: {[fg]s}; border-color: {[border]s}; }}\n" ++
        w ++ " headerbar label.title, " ++ w ++ " headerbar:backdrop label.title {{ color: {[fg]s}; }}\n" ++
        // Direct labels only: a menu item's label inherits its disabled colour.
        w ++ " > label, " ++ w ++ " spinner, " ++ w ++ " button.image-button, " ++ w ++ " button.flat.scale image {{ color: {[fg]s}; }}\n" ++
        w ++ " label:disabled, " ++ w ++ " spinner:disabled {{ color: {[dim]s}; }}\n" ++
        w ++ " label.link:link {{ color: {[accent]s}; }}\n" ++
        w ++ " entry, " ++ w ++ " textview.view, " ++ w ++ " textview.view text, " ++ w ++ " treeview.view {{ background-color: {[view]s}; color: {[fg]s}; border-color: {[border]s}; }}\n" ++
        w ++ " entry:focus {{ border-color: {[accent]s}; }}\n" ++
        w ++ " textview.view:disabled text {{ color: {[dim]s}; }}\n" ++
        w ++ " textview.view text selection, " ++ w ++ " treeview.view:selected, " ++ w ++ " treeview.view:selected label {{ background-color: {[accent]s}; color: {[on_accent]s}; }}\n" ++
        w ++ " button, " ++ w ++ " button:backdrop {{ background-color: {[item]s}; background-image: none; box-shadow: none; color: {[fg]s}; border-color: {[border]s}; }}\n" ++
        w ++ " button label {{ color: {[fg]s}; }}\n" ++
        w ++ " button:disabled label {{ color: {[dim]s}; }}\n" ++
        w ++ " button.toggle:checked {{ background-color: {[accent]s}; color: {[on_accent]s}; }}\n" ++
        w ++ " menu {{ background-color: {[toolbar]s}; color: {[fg]s}; border-color: {[border]s}; }}\n" ++
        w ++ " menu menuitem, " ++ w ++ " menu menuitem label, " ++ w ++ " menu menuitem radio, " ++ w ++ " menu menuitem cellview {{ color: {[fg]s}; }}\n" ++
        w ++ " menu menuitem:hover {{ background-color: {[accent]s}; color: {[on_accent]s}; }}\n" ++
        w ++ " menu menuitem:hover label, " ++ w ++ " menu menuitem:hover cellview {{ color: {[on_accent]s}; }}\n" ++
        w ++ " menu menuitem:disabled label {{ color: {[dim]s}; }}\n" ++
        // Shortcuts: a little quieter than the item, still readable.
        w ++ " menu menuitem accelerator {{ color: alpha(currentColor, 0.8); }}\n" ++
        w ++ " separator {{ background-color: {[border]s}; color: {[border]s}; }}\n" ++
        w ++ " frame border, " ++ w ++ " box.frame {{ border-color: {[border]s}; }}\n" ++
        w ++ " scrollbar trough, " ++ w ++ " statusbar {{ background-color: {[view]s}; }}\n" ++
        w ++ " scrollbar slider {{ background-color: {[dim]s}; }}\n" ++
        w ++ " scale trough {{ background-color: {[border]s}; }}\n" ++
        w ++ " scale highlight {{ background-color: {[accent]s}; }}\n" ++
        w ++ " notebook tab:checked {{ background-color: {[toolbar]s}; }}\n", .{
        .toolbar = &toolbar,
        .frame = &app.hex(app.frame(b.bg, b.toolbar)),
        .fg = &fg,
        .dim = &dim,
        .border = &border,
        .accent = &accent,
        .on_accent = &on_accent,
        .view = &view,
        .item = &app.hex(b.item),
    });
}

test "Chromium's GTK colours follow the requested darkness, the frame stands apart, and menu labels keep their state" {
    const a = std.testing.allocator;
    const p = app.Palette.fromTheme(.{});
    for ([_]bool{ false, true }) |gtk4| for ([_]bool{ false, true }) |dark| {
        const style = try css(a, p, gtk4, dark);
        defer a.free(style);
        const b = app.browserPalette(p, dark);
        const frame = app.hex(app.frame(b.bg, b.toolbar));
        try std.testing.expect(!std.mem.eql(u8, &frame, &app.hex(b.toolbar)));
        var buf: [96]u8 = undefined;
        const rule = try std.fmt.bufPrint(&buf, "headerbar:backdrop {{ background-color: {s};", .{&frame});
        try std.testing.expect(std.mem.indexOf(u8, style, rule) != null);
        const window = try std.fmt.bufPrint(&buf, "window.background.chromium window.background {{ background-color: {s}; color: {s}; }}", .{ &app.hex(b.toolbar), &app.hex(b.fg) });
        try std.testing.expect(std.mem.indexOf(u8, style, window) != null);
        try std.testing.expect(std.mem.indexOf(u8, style, "window.background.chromium label {") == null);
        try std.testing.expect(std.mem.indexOf(u8, style, "window.background.chromium > label") != null);
        // The rest of the slot follows the palette in both files.
        try std.testing.expect(std.mem.indexOf(u8, style, "gtk-contained-dark.css") != null or std.mem.indexOf(u8, style, "Default-dark.css") != null);
    };
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
    // Per GTK version: gtk.css, then gtk-dark.css.
    const styles = [_][2][]const u8{
        .{ try css(mem, p, false, false), try css(mem, p, false, true) },
        .{ try css(mem, p, true, false), try css(mem, p, true, true) },
    };
    const aliases = try userAliases(mem, p);
    const previous = try current(mem, io, home);
    var slot: u1 = if (previous) |old| old ^ 1 else 0;
    if (previous) |old| {
        var same = true;
        for ([_][]const u8{ "gtk-3.0", "gtk-4.0" }, styles) |version, pair| {
            for ([_][]const u8{ "gtk.css", "gtk-dark.css" }, pair) |file, style| {
                const path = try std.fs.path.join(mem, &.{ data, "themes", name(old), version, file });
                const saved = try app.readOptional(mem, io, path) orelse "";
                same = same and std.mem.eql(u8, saved, style);
            }
        }
        if (same) slot = old;
    }
    var tx = app.Transaction{ .a = mem, .io = io };
    for ([_][]const u8{ "gtk-3.0", "gtk-4.0" }, styles) |version, pair| {
        for ([_][]const u8{ "gtk.css", "gtk-dark.css" }, pair) |file, style| {
            const path = try std.fs.path.join(mem, &.{ data, "themes", name(slot), version, file });
            try tx.add(path, style, false);
        }
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

//! Explicit palette exports. User styles and toolkit preferences are merged;
//! the first originals are kept beside them as .rediwm-backup files. A file
//! that is a symlink (another tool's generated output) is replaced by a regular
//! file holding its current contents; a rollback puts the link back.
const std = @import("std");
const theme = @import("ui").theme;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Toolkit = enum { gtk, qt };
/// `style5`/`style6`: the RediWM Qt style plugin is installed for that major.
pub const QtSupport = struct { qt5: bool, qt6: bool, style5: bool = false, style6: bool = false };
pub const qt_platform = "qt5ct"; // qt6ct also advertises this plugin key.
/// Fusion with neutral title bars (src/qt_style/); Fusion where it is missing.
pub const qt_style = "RediWM";
pub const follow = @import("app_theme_follow.zig");

pub fn configHome(a: Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_CONFIG_HOME")) |path| if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    const home = env.getPosix("HOME") orelse return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) return error.NoHome;
    return std.fs.path.join(a, &.{ home, ".config" });
}

pub fn executable(a: Allocator, io: Io, env: std.process.Environ, name: []const u8) !?[]u8 {
    var dirs = std.mem.splitScalar(u8, env.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const path = try std.fs.path.join(a, &.{ dir, name });
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
            a.free(path);
            continue;
        };
        if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) return path;
        a.free(path);
    }
    return null;
}

pub fn qtEnabled(a: Allocator, io: Io, home: []const u8) !bool {
    const path = try std.fs.path.join(a, &.{ home, "rediwm/app-colors.conf" });
    defer a.free(path);
    const content = try readOptional(a, io, path) orelse return false;
    defer a.free(content);
    return std.mem.eql(u8, iniValue(content, "Applications", "qt") orelse "false", "true");
}

const Color = [3]u8;
pub const Palette = struct {
    bg: Color,
    fg: Color,
    toolbar: Color,
    sidebar: Color,
    sidebar_fg: Color,
    item: Color,
    hover: Color,
    border: Color,
    accent: Color,
    on_accent: Color,
    danger: Color,
    dim: Color,

    pub fn fromTheme(source: theme.Theme) Palette {
        const t = source.forApp();
        const bg = composite(t.app_bg, .{ 255, 255, 255 });
        const fg = composite(t.window_fg, bg);
        const accent = composite(t.shell_accent orelse t.start_menu_selected_marker, bg);
        return .{
            .bg = bg,
            .fg = fg,
            .toolbar = composite(t.app_toolbar, bg),
            .sidebar = composite(t.app_sidebar, bg),
            .sidebar_fg = composite(t.sidebarForeground(), composite(t.app_sidebar, bg)),
            .item = composite(t.app_item, bg),
            .hover = composite(t.app_item_hover, bg),
            .border = composite(t.app_item_border, bg),
            .accent = accent,
            .on_accent = if (t.shell_on_accent) |c| composite(c, accent) else contrast(accent),
            .danger = composite(t.danger, bg),
            .dim = blend(fg, bg, 0.5),
        };
    }
};

fn composite(c: [4]f32, bg: Color) Color {
    var out: Color = undefined;
    const alpha = std.math.clamp(c[3], 0, 1);
    for (&out, bg, c[0..3]) |*v, base, channel| v.* = @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255 * alpha + @as(f32, @floatFromInt(base)) * (1 - alpha)));
    return out;
}

fn blend(fg: Color, bg: Color, alpha: f32) Color {
    var result: Color = undefined;
    for (&result, fg, bg) |*v, f, b| v.* = @intFromFloat(@round(@as(f32, @floatFromInt(f)) * alpha + @as(f32, @floatFromInt(b)) * (1 - alpha)));
    return result;
}

/// Whether the palette needs a dark base stylesheet beneath it.
pub fn isDark(p: Palette) bool {
    return contrast(p.bg)[0] == 255;
}

fn contrast(c: Color) Color {
    var luminance: f32 = 0;
    for (c, [_]f32{ 0.2126, 0.7152, 0.0722 }) |byte, weight| {
        const v = @as(f32, @floatFromInt(byte)) / 255;
        luminance += weight * (if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4));
    }
    return if (luminance > 0.179) .{ 0, 0, 0 } else .{ 255, 255, 255 };
}

fn hex(c: Color) [7]u8 {
    const digits = "0123456789abcdef";
    var result: [7]u8 = undefined;
    result[0] = '#';
    for (c, 0..) |v, i| {
        result[1 + 2 * i] = digits[v >> 4];
        result[2 + 2 * i] = digits[v & 15];
    }
    return result;
}

fn appendFmt(list: *std.ArrayList(u8), a: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(text);
    try list.appendSlice(a, text);
}

pub fn gtkColors(a: Allocator, p: Palette, gtk4: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "/* Generated by RediWM. Apply GTK colors again after changing the theme. */\n");
    const names = [_][]const u8{
        "window_bg_color",                   "window_fg_color",                   "view_bg_color",              "view_fg_color",
        "headerbar_bg_color",                "headerbar_fg_color",                "headerbar_backdrop_color",   "sidebar_bg_color",
        "sidebar_fg_color",                  "sidebar_backdrop_color",            "secondary_sidebar_bg_color", "secondary_sidebar_fg_color",
        "card_bg_color",                     "card_fg_color",                     "dialog_bg_color",            "dialog_fg_color",
        "popover_bg_color",                  "popover_fg_color",                  "accent_bg_color",            "accent_fg_color",
        "accent_color",                      "borders",                           "theme_bg_color",             "theme_fg_color",
        "theme_base_color",                  "theme_text_color",                  "theme_selected_bg_color",    "theme_selected_fg_color",
        "theme_unfocused_bg_color",          "theme_unfocused_fg_color",          "theme_unfocused_base_color", "theme_unfocused_text_color",
        "theme_unfocused_selected_bg_color", "theme_unfocused_selected_fg_color", "insensitive_fg_color",
    };
    const colors = [_]Color{
        p.bg,      p.fg,         p.bg,      p.fg,      p.toolbar,    p.fg,        p.toolbar,
        p.sidebar, p.sidebar_fg, p.sidebar, p.sidebar, p.sidebar_fg, p.item,      p.fg,
        p.bg,      p.fg,         p.toolbar, p.fg,      p.accent,     p.on_accent, p.accent,
        p.border,  p.bg,         p.fg,      p.bg,      p.fg,         p.accent,    p.on_accent,
        p.bg,      p.fg,         p.bg,      p.fg,      p.accent,     p.on_accent, p.dim,
    };
    for (names, colors) |name, color| try appendFmt(&out, a, "@define-color {s} {s};\n", .{ name, hex(color) });
    try appendFmt(&out, a, "@define-color destructive_bg_color {s};\n@define-color destructive_fg_color {s};\n", .{ hex(p.danger), hex(contrast(p.danger)) });
    try appendFmt(&out, a, "@define-color button_hover_color {s};\n", .{hex(p.hover)});
    if (gtk4) {
        try out.appendSlice(a, ":root {\n");
        for (names[0..21], colors[0..21]) |name, color| {
            const variable = try a.dupe(u8, name);
            defer a.free(variable);
            std.mem.replaceScalar(u8, variable, '_', '-');
            try appendFmt(&out, a, "  --{s}: {s};\n", .{ variable, hex(color) });
        }
        try appendFmt(&out, a, "  --destructive-bg-color: {s};\n  --destructive-fg-color: {s};\n}}\n", .{ hex(p.danger), hex(contrast(p.danger)) });
    }
    // GTK3's built-in Adwaita uses literal colors. Named colors alone cannot
    // recolor it; override common surfaces without replacing widget geometry.
    try out.appendSlice(a,
        \\window.background, messagedialog.background { color: @window_fg_color; background-color: @window_bg_color; }
        \\headerbar, headerbar:backdrop { color: @headerbar_fg_color; background-color: @headerbar_bg_color; background-image: none; }
        \\.sidebar, .sidebar:backdrop { color: @sidebar_fg_color; background-color: @sidebar_bg_color; }
        \\.view, .view:backdrop, textview text, textview text:backdrop, treeview, treeview:backdrop { color: @view_fg_color; background-color: @view_bg_color; }
        \\entry, entry:backdrop, spinbutton:not(.vertical) { color: @view_fg_color; background-color: @view_bg_color; border-color: @borders; }
        \\button, button:backdrop { color: @window_fg_color; background-color: @card_bg_color; background-image: none; border-color: @borders; }
        \\button:hover { background-color: @button_hover_color; }
        \\button.suggested-action, button.suggested-action:backdrop, selection, :selected { color: @accent_fg_color; background-color: @accent_bg_color; }
        \\button.destructive-action { color: @destructive_fg_color; background-color: @destructive_bg_color; }
        \\menu, popover > contents { color: @popover_fg_color; background-color: @popover_bg_color; }
        \\*:disabled { color: @insensitive_fg_color; }
        \\
    );
    return out.toOwnedSlice(a);
}

pub fn qtColors(a: Allocator, p: Palette) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "[ColorScheme]\n");
    // QPalette::ColorRole order, including NoRole, PlaceholderText and Qt6's
    // Accent. Extra roles are ignored by Qt5 and older Qt6.
    // QPalette has no separate foreground for AlternateBase. A contrasting
    // sidebar cannot also be used for alternating rows with the content text.
    const alternate = if (std.meta.eql(p.sidebar_fg, p.fg)) p.sidebar else p.item;
    const active = [_]Color{ p.fg, p.item, blend(p.item, .{ 255, 255, 255 }, 0.7), p.hover, p.border, p.border, p.fg, p.fg, p.fg, p.bg, p.bg, p.border, p.accent, p.on_accent, p.accent, p.accent, alternate, p.bg, p.toolbar, p.fg, p.dim, p.accent };
    for ([_][]const u8{ "active_colors", "inactive_colors", "disabled_colors" }, 0..) |name, group| {
        try appendFmt(&out, a, "{s}=", .{name});
        for (active, 0..) |color, role| {
            const dimmed = group == 2 and switch (role) {
                0, 6, 7, 8, 13, 14, 15, 19, 20 => true,
                else => false,
            };
            try appendFmt(&out, a, "{s}{s}", .{ if (role == 0) "" else ", ", hex(if (dimmed) blend(color, p.bg, 0.5) else color) });
        }
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// KDE Frameworks apps (Dolphin, Kate) read their colors from kdeglobals, not
/// from the qt6ct palette. Only the color roles RediWM has a source for are
/// written; neutral/positive and the disabled/inactive effects stay as found.
pub fn kdeGlobals(a: Allocator, content: []const u8, p: Palette) ![]u8 {
    const Role = struct { key: []const u8, color: Color };
    const Group = struct { section: []const u8, roles: []const Role };
    const groups = [_]Group{
        .{ .section = "Colors:Window", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.bg }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.fg } } },
        .{ .section = "Colors:View", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.bg }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.fg } } },
        .{ .section = "Colors:Button", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.item }, .{ .key = "BackgroundAlternate", .color = p.hover }, .{ .key = "ForegroundNormal", .color = p.fg } } },
        .{ .section = "Colors:Selection", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.accent }, .{ .key = "BackgroundAlternate", .color = p.accent }, .{ .key = "ForegroundNormal", .color = p.on_accent } } },
        .{ .section = "Colors:Tooltip", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.toolbar }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.fg } } },
        .{ .section = "Colors:Complementary", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.sidebar }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.sidebar_fg } } },
        .{ .section = "Colors:Header", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.toolbar }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.fg } } },
        .{ .section = "Colors:Header][Inactive", .roles = &.{ .{ .key = "BackgroundNormal", .color = p.toolbar }, .{ .key = "BackgroundAlternate", .color = p.item }, .{ .key = "ForegroundNormal", .color = p.fg } } },
    };
    // Every group shares the accent, link and dim roles.
    const shared = [_]Role{
        .{ .key = "DecorationFocus", .color = p.accent },
        .{ .key = "DecorationHover", .color = p.accent },
        .{ .key = "ForegroundActive", .color = p.accent },
        .{ .key = "ForegroundLink", .color = p.accent },
        .{ .key = "ForegroundVisited", .color = p.dim },
        .{ .key = "ForegroundInactive", .color = p.dim },
        .{ .key = "ForegroundNegative", .color = p.danger },
    };
    var current = try a.dupe(u8, content);
    errdefer a.free(current);
    for (groups) |group| for ([_][]const Role{ group.roles, &shared }) |roles| for (roles) |role| {
        var buf: [11]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "{d},{d},{d}", .{ role.color[0], role.color[1], role.color[2] }) catch unreachable;
        const next = try patchIni(a, current, group.section, role.key, value);
        a.free(current);
        current = next;
    };
    return current;
}

pub fn iniValue(content: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var inside = false;
    var result: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            inside = std.mem.eql(u8, std.mem.trim(u8, line, "[]"), section);
            continue;
        }
        if (!inside) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) result = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
    }
    return result;
}

pub fn patchIni(a: Allocator, content: []const u8, section: []const u8, key: []const u8, value: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, value, "\n\r\x00") != null) return error.InvalidValue;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var inside = false;
    var inserted = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            inside = std.mem.eql(u8, std.mem.trim(u8, line, "[]"), section);
            try appendFmt(&out, a, "{s}\n", .{raw});
            if (inside and !inserted) {
                try appendFmt(&out, a, "{s}={s}\n", .{ key, value });
                inserted = true;
            }
            continue;
        }
        if (inside) if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        };
        if (raw.len == 0 and lines.index == null) break;
        try appendFmt(&out, a, "{s}\n", .{raw});
    }
    if (!inserted) try appendFmt(&out, a, "[{s}]\n{s}={s}\n", .{ section, key, value });
    return out.toOwnedSlice(a);
}

const css_begin = "/* BEGIN REDIWM APP COLORS */";
const css_end = "/* END REDIWM APP COLORS */";
pub fn patchCss(a: Allocator, content: []const u8) ![]u8 {
    return replaceManagedCss(a, content, "@import url(\"rediwm-colors.css\");\n");
}

/// Later rules and named colors win over other palette generators, so the
/// block goes last.
pub fn replaceManagedCss(a: Allocator, content: []const u8, body: []const u8) ![]u8 {
    const original = try removeManagedCss(a, content);
    defer a.free(original);
    return std.fmt.allocPrint(a, "{s}" ++ css_begin ++ "\n{s}" ++ css_end ++ "\n", .{ original, body });
}

/// Named themes must not compete with a stale, higher-priority snapshot.
pub fn removeManagedCss(a: Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var rest = content;
    while (std.mem.indexOf(u8, rest, css_begin)) |begin| {
        try out.appendSlice(a, rest[0..begin]);
        const end = std.mem.indexOf(u8, rest[begin + css_begin.len ..], css_end) orelse return error.InvalidManagedCss;
        rest = rest[begin + css_begin.len + end + css_end.len ..];
        if (std.mem.startsWith(u8, rest, "\n")) rest = rest[1..];
    }
    if (std.mem.indexOf(u8, rest, css_end) != null) return error.InvalidManagedCss;
    try out.appendSlice(a, rest);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

pub fn readOptional(a: Allocator, io: Io, path: []const u8) !?[]u8 {
    // Follows a file symlink: the link target's content is what gets merged.
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidFile;
    return try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

const Change = struct { path: []const u8, data: []const u8, original: ?[]const u8, link: ?[]const u8, temp: []const u8, permissions: Io.File.Permissions };
pub const Transaction = struct {
    a: Allocator,
    io: Io,
    changes: std.ArrayList(Change) = .empty,

    pub fn add(self: *Transaction, path: []const u8, data: []const u8, backup: bool) !void {
        var parent = std.fs.path.dirname(path);
        while (parent) |dir| : (parent = std.fs.path.dirname(dir)) {
            if (dir.len <= 1) break;
            const stat = Io.Dir.cwd().statFile(self.io, dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (stat.kind == .sym_link) return error.ManagedSymlink;
        }
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link: ?[]const u8 = if (Io.Dir.cwd().readLink(self.io, path, &link_buf)) |n| try self.a.dupe(u8, link_buf[0..n]) else |err| switch (err) {
            error.NotLink, error.FileNotFound => null,
            else => return err,
        };
        const original = try readOptional(self.a, self.io, path);
        if (original) |old| {
            if (link == null and std.mem.eql(u8, old, data)) return;
            if (backup) {
                const saved = try std.fmt.allocPrint(self.a, "{s}.rediwm-backup", .{path});
                if (try readOptional(self.a, self.io, saved) == null) try self.add(saved, old, false);
            }
        }
        const permissions = if (original != null) (try Io.Dir.cwd().statFile(self.io, path, .{})).permissions else Io.File.Permissions.fromMode(0o600);
        try self.changes.append(self.a, .{ .path = path, .data = data, .original = original, .link = link, .temp = try std.fmt.allocPrint(self.a, "{s}.rediwm-tmp", .{path}), .permissions = permissions });
    }

    pub fn commit(self: *Transaction) !void {
        var staged: usize = 0;
        defer for (self.changes.items[0..staged]) |change| Io.Dir.cwd().deleteFile(self.io, change.temp) catch {};
        // Stage every file before publishing any; failure on a later target
        // must not leave GTK3 updated while GTK4 still has the old palette.
        for (self.changes.items) |change| {
            try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(change.path).?);
            const file = try Io.Dir.cwd().createFile(self.io, change.temp, .{ .exclusive = true, .permissions = change.permissions });
            staged += 1;
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, change.data);
            try file.sync(self.io);
        }
        var published: usize = 0;
        errdefer {
            var rollback_failed = false;
            for (self.changes.items[0..published]) |change| {
                if (change.link) |target| {
                    Io.Dir.cwd().symLink(self.io, target, change.temp, .{}) catch {
                        rollback_failed = true;
                        continue;
                    };
                    Io.Dir.rename(.cwd(), change.temp, .cwd(), change.path, self.io) catch {
                        rollback_failed = true;
                    };
                } else if (change.original) |original| {
                    const file = Io.Dir.cwd().createFile(self.io, change.temp, .{ .exclusive = true, .permissions = change.permissions }) catch {
                        rollback_failed = true;
                        continue;
                    };
                    defer file.close(self.io);
                    file.writeStreamingAll(self.io, original) catch {
                        rollback_failed = true;
                        continue;
                    };
                    Io.Dir.rename(.cwd(), change.temp, .cwd(), change.path, self.io) catch {
                        rollback_failed = true;
                    };
                } else Io.Dir.cwd().deleteFile(self.io, change.path) catch {
                    rollback_failed = true;
                };
            }
            if (rollback_failed) std.log.err("app colors rollback failed; restore the .rediwm-backup files", .{});
        }
        for (self.changes.items) |change| {
            try Io.Dir.rename(.cwd(), change.temp, .cwd(), change.path, self.io);
            published += 1;
        }
    }
};

pub fn apply(a: Allocator, io: Io, home: []const u8, toolkit: Toolkit, p: Palette, support: QtSupport) !void {
    return applyRevision(a, io, home, toolkit, p, support, null);
}

/// A palette revision in the watched config directory wakes qt5ct/qt6ct even
/// when only the palette in its colors/ subdirectory changed.
pub fn applyRevision(a: Allocator, io: Io, home: []const u8, toolkit: Toolkit, p: Palette, support: QtSupport, revision: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tx = Transaction{ .a = alloc, .io = io };
    switch (toolkit) {
        .gtk => for ([_][]const u8{ "gtk-3.0", "gtk-4.0" }, 0..) |version, i| {
            const css = try std.fs.path.join(alloc, &.{ home, version, "gtk.css" });
            const colors = try std.fs.path.join(alloc, &.{ home, version, "rediwm-colors.css" });
            try tx.add(colors, try gtkColors(alloc, p, i == 1), false);
            try tx.add(css, try patchCss(alloc, try readOptional(alloc, io, css) orelse ""), true);
        },
        .qt => {
            if (!support.qt5 and !support.qt6) return error.QtToolsMissing;
            const colors = try qtColors(alloc, p);
            for ([_][]const u8{ "qt5ct", "qt6ct" }, [_]bool{ support.qt5, support.qt6 }, [_]bool{ support.style5, support.style6 }) |version, installed, styled| {
                if (!installed) continue;
                const scheme = try std.fs.path.join(alloc, &.{ home, version, "colors/rediwm.conf" });
                const config = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}.conf", .{ home, version, version });
                var content: []const u8 = try readOptional(alloc, io, config) orelse "";
                content = try patchIni(alloc, content, "Appearance", "custom_palette", "true");
                content = try patchIni(alloc, content, "Appearance", "color_scheme_path", try quotedPath(alloc, scheme));
                content = try patchIni(alloc, content, "Appearance", "style", if (styled) qt_style else "Fusion");
                if (revision) |value| content = try patchIni(alloc, content, "RediWM", "palette_revision", value);
                try tx.add(scheme, colors, false);
                try tx.add(config, content, true);
            }
            const kdeglobals = try std.fs.path.join(alloc, &.{ home, "kdeglobals" });
            try tx.add(kdeglobals, try kdeGlobals(alloc, try readOptional(alloc, io, kdeglobals) orelse "", p), true);
            const state = try std.fs.path.join(alloc, &.{ home, "rediwm/app-colors.conf" });
            try tx.add(state, try patchIni(alloc, try readOptional(alloc, io, state) orelse "", "Applications", "qt", "true"), true);
        },
    }
    try tx.commit();
}

fn quotedPath(a: Allocator, path: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, path, "\n\r\x00") != null) return error.InvalidValue;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '"');
    for (path) |c| {
        if (c == '\\' or c == '"') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

test "app palettes composite straight alpha and choose readable accent text" {
    var t = theme.Theme{};
    t.app_bg = .{ 0, 0, 0, 1 };
    t.app_toolbar = .{ 1, 0, 0, 0.5 };
    t.shell_accent = .{ 1, 1, 1, 1 };
    var p = Palette.fromTheme(t);
    try std.testing.expectEqual(Color{ 128, 0, 0 }, p.toolbar);
    try std.testing.expectEqual(Color{ 0, 0, 0 }, p.on_accent);
    t.shell_accent = .{ 0, 0, 0, 1 };
    p = Palette.fromTheme(t);
    try std.testing.expectEqual(Color{ 255, 255, 255 }, p.on_accent);
    t.app_bg = .{ 1, 1, 1, 1 };
    t.app_fg = .{ 0.2, 0.1, 0, 1 };
    t.app_sidebar = .{ 0, 0, 0, 1 };
    t.app_sidebar_fg = .{ 1, 1, 1, 1 };
    p = Palette.fromTheme(t);
    try std.testing.expectEqual(Color{ 51, 26, 0 }, p.fg);
    try std.testing.expectEqual(Color{ 255, 255, 255 }, p.sidebar_fg);
    try std.testing.expectEqual(t.app_fg.?, t.forApp().window_fg);
    try std.testing.expectEqual((theme.Theme{}).window_fg, t.window_fg);
}

test "app colors edits are idempotent and scoped to their INI section" {
    const a = std.testing.allocator;
    const original = "# keep\n[Other]\ncustom_palette=false\n[Appearance]\nstyle=Old\ncustom_palette=false\n[Fonts]\ngeneral=Example\n";
    const first = try patchIni(a, original, "Appearance", "custom_palette", "true");
    defer a.free(first);
    const second = try patchIni(a, first, "Appearance", "custom_palette", "true");
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqualStrings("false", iniValue(second, "Other", "custom_palette").?);
    try std.testing.expectEqualStrings("Example", iniValue(second, "Fonts", "general").?);
    const css = try patchCss(a, "/* user */\nbutton { color: red; }\n");
    defer a.free(css);
    const again = try patchCss(a, css);
    defer a.free(again);
    try std.testing.expectEqualStrings(css, again);
    try std.testing.expect(std.mem.startsWith(u8, again, "/* user */\nbutton { color: red; }\n"));
    try std.testing.expect(std.mem.endsWith(u8, again, css_end ++ "\n"));
    try std.testing.expectError(error.InvalidManagedCss, patchCss(a, css_begin));
}

test "app colors publishes both GTK versions and keeps the first backup" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    try tmp.dir.createDirPath(io, "gtk-3.0");
    try tmp.dir.writeFile(io, .{ .sub_path = "gtk-3.0/gtk.css", .data = "/* user */\n" });
    const p = Palette.fromTheme(.{});
    try apply(a, io, home, .gtk, p, .{ .qt5 = false, .qt6 = false });
    try apply(a, io, home, .gtk, p, .{ .qt5 = false, .qt6 = false });
    const backup = try tmp.dir.readFileAlloc(io, "gtk-3.0/gtk.css.rediwm-backup", a, .limited(1024));
    defer a.free(backup);
    try std.testing.expectEqualStrings("/* user */\n", backup);
    const gtk4 = try tmp.dir.readFileAlloc(io, "gtk-4.0/rediwm-colors.css", a, .limited(16384));
    defer a.free(gtk4);
    try std.testing.expect(std.mem.indexOf(u8, gtk4, "--window-bg-color: #181c22;") != null);
    try tmp.dir.createDirPath(io, "qt6ct/qt6ct.conf");
    try std.testing.expectError(error.InvalidFile, apply(a, io, home, .qt, p, .{ .qt5 = true, .qt6 = true }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "qt5ct/qt5ct.conf", .{}));
}

test "app colors replaces a file symlink, and rejects linked directories and staging failures" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    try tmp.dir.createDirPath(io, "gtk-4.0");
    try tmp.dir.writeFile(io, .{ .sub_path = "user.css", .data = "/* owned elsewhere */\n" });
    try tmp.dir.symLink(io, "../user.css", "gtk-4.0/gtk.css", .{});
    const p = Palette.fromTheme(.{});
    try apply(a, io, home, .gtk, p, .{ .qt5 = false, .qt6 = false });
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotLink, tmp.dir.readLink(io, "gtk-4.0/gtk.css", &buf));
    const merged = try tmp.dir.readFileAlloc(io, "gtk-4.0/gtk.css", a, .limited(4096));
    defer a.free(merged);
    try std.testing.expect(std.mem.startsWith(u8, merged, "/* owned elsewhere */\n"));
    try std.testing.expect(std.mem.endsWith(u8, merged, css_end ++ "\n"));
    const target = try tmp.dir.readFileAlloc(io, "user.css", a, .limited(64));
    defer a.free(target);
    try std.testing.expectEqualStrings("/* owned elsewhere */\n", target);
    const saved = try tmp.dir.readFileAlloc(io, "gtk-4.0/gtk.css.rediwm-backup", a, .limited(64));
    defer a.free(saved);
    try std.testing.expectEqualStrings("/* owned elsewhere */\n", saved);
    try tmp.dir.deleteTree(io, "gtk-3.0");
    try tmp.dir.deleteFile(io, "gtk-4.0/gtk.css");
    try tmp.dir.writeFile(io, .{ .sub_path = "gtk-4.0/gtk.css.rediwm-tmp", .data = "busy" });
    try std.testing.expectError(error.PathAlreadyExists, apply(a, io, home, .gtk, p, .{ .qt5 = false, .qt6 = false }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "gtk-3.0/gtk.css", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "gtk-3.0/rediwm-colors.css.rediwm-tmp", .{}));
    try tmp.dir.deleteTree(io, "gtk-4.0");
    try tmp.dir.createDirPath(io, "external4");
    try tmp.dir.symLink(io, "external4", "gtk-4.0", .{});
    try std.testing.expectError(error.ManagedSymlink, apply(a, io, home, .gtk, p, .{ .qt5 = false, .qt6 = false }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "external4/rediwm-colors.css", .{}));
}

test "kdeglobals export replaces stale roles in place and is idempotent" {
    const a = std.testing.allocator;
    var t = theme.Theme{};
    t.app_bg = .{ 0.2, 0.1, 0, 1 };
    const p = Palette.fromTheme(t);
    const old = "[Colors:Window]\nBackgroundNormal=54,29,25\nForegroundNeutral=1,2,3\n[General]\nColorScheme=Old\n";
    const first = try kdeGlobals(a, old, p);
    defer a.free(first);
    const second = try kdeGlobals(a, first, p);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqualStrings("51,26,0", iniValue(first, "Colors:Window", "BackgroundNormal").?);
    try std.testing.expectEqualStrings("1,2,3", iniValue(first, "Colors:Window", "ForegroundNeutral").?);
    try std.testing.expectEqualStrings("Old", iniValue(first, "General", "ColorScheme").?);
    try std.testing.expect(iniValue(first, "Colors:Header][Inactive", "BackgroundNormal") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "[Colors:Header][Inactive]\n") != null);
}

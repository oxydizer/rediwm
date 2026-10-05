// Pure matching and deterministic ranking for the start menu.
//
// Matches search queries against application entries and built-in Settings,
// ranking exact matches, name prefixes, word prefixes, keywords, and descriptions.
const std = @import("std");
const Allocator = std.mem.Allocator;

const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;

pub const Category = enum {
    all,
    apps,
};

pub const SearchResult = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    icon: ?[]const u8 = null,
    is_settings: bool = false,
    is_loading: bool = false,
    app_entry: ?*const AppEntry = null,
    score: i32 = 0,
};

pub const settings_id = "rediwm.settings";
pub const settings_name = "Settings";
pub const settings_description = "System preferences, display, appearance and input";
pub const loading_id = "rediwm.loading";
pub const loading_name = "Loading applications…";
pub const loading_description = "Scanning installed apps";
const settings_keywords = "settings;control;panel;preferences;display;appearance;mouse;keyboard";

pub fn search(
    allocator: Allocator,
    catalog: []const AppEntry,
    query: []const u8,
    category: Category,
    loading: bool,
) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer results.deinit(allocator);

    const trimmed = std.mem.trim(u8, query, " \t\r\n");

    if (trimmed.len == 0) {
        // Empty query: alphabetical applications plus Settings if in .all
        for (catalog) |*app| {
            const desc = app.generic_name orelse app.comment orelse "";
            try results.append(allocator, .{
                .id = app.id,
                .name = app.name,
                .description = desc,
                .icon = app.icon,
                .is_settings = false,
                .app_entry = app,
                .score = 100,
            });
        }

        // Sort applications alphabetically
        std.mem.sort(SearchResult, results.items, {}, sortAlphabetical);

        if (loading) {
            try results.append(allocator, .{
                .id = loading_id,
                .name = loading_name,
                .description = loading_description,
                .is_loading = true,
                .score = 0,
            });
        }

        if (category == .all) {
            try results.append(allocator, .{
                .id = settings_id,
                .name = settings_name,
                .description = settings_description,
                .icon = "preferences-system",
                .is_settings = true,
                .app_entry = null,
                .score = 50,
            });
        }
        return results.toOwnedSlice(allocator);
    }

    var q_buf: [256]u8 = undefined;
    const q_lower = if (trimmed.len <= q_buf.len)
        std.ascii.lowerString(&q_buf, trimmed)
    else
        try std.ascii.allocLowerString(allocator, trimmed);
    defer if (trimmed.len > q_buf.len) allocator.free(q_lower);

    // Score applications
    for (catalog) |*app| {
        const desc = app.generic_name orelse app.comment orelse "";
        if (scoreItem(app.name, app.generic_name, app.keywords, app.comment, q_lower)) |sc| {
            try results.append(allocator, .{
                .id = app.id,
                .name = app.name,
                .description = desc,
                .icon = app.icon,
                .is_settings = false,
                .app_entry = app,
                .score = sc,
            });
        }
    }

    // Score Settings if in .all
    if (category == .all) {
        if (scoreItem(settings_name, null, settings_keywords, settings_description, q_lower)) |sc| {
            try results.append(allocator, .{
                .id = settings_id,
                .name = settings_name,
                .description = settings_description,
                .icon = "preferences-system",
                .is_settings = true,
                .app_entry = null,
                .score = sc,
            });
        }
    }

    // Sort by ranking criteria
    std.mem.sort(SearchResult, results.items, {}, sortRanked);

    return results.toOwnedSlice(allocator);
}

fn scoreItem(
    name: []const u8,
    generic_name: ?[]const u8,
    keywords: []const u8,
    comment: ?[]const u8,
    q_lower: []const u8,
) ?i32 {
    var name_buf: [256]u8 = undefined;
    const name_len = name.len;
    const n_lower = if (name.len <= name_buf.len)
        std.ascii.lowerString(&name_buf, name)
    else
        return null;

    const len_penalty: i32 = @intCast(@min(name_len, 50));

    // Tier 1: Exact match
    if (std.mem.eql(u8, n_lower, q_lower)) {
        return 1000;
    }

    // Tier 2: Prefix match
    if (std.mem.startsWith(u8, n_lower, q_lower)) {
        return 800 - len_penalty;
    }

    // Tier 3: Word prefix in name
    if (matchesWordPrefix(n_lower, q_lower)) {
        return 600 - len_penalty;
    }

    // Tier 4: Substring in name
    if (std.mem.indexOf(u8, n_lower, q_lower) != null) {
        return 400 - len_penalty;
    }

    // Tier 5: Generic name / keywords match
    if (generic_name) |gn| {
        var gn_buf: [256]u8 = undefined;
        if (gn.len <= gn_buf.len) {
            const gn_lower = std.ascii.lowerString(&gn_buf, gn);
            if (std.mem.startsWith(u8, gn_lower, q_lower) or matchesWordPrefix(gn_lower, q_lower)) {
                return 300;
            }
        }
    }

    if (keywords.len > 0) {
        var it = std.mem.splitScalar(u8, keywords, ';');
        while (it.next()) |kw| {
            const kw_trim = std.mem.trim(u8, kw, " \t");
            if (kw_trim.len == 0) continue;
            var kw_buf: [128]u8 = undefined;
            if (kw_trim.len <= kw_buf.len) {
                const kw_lower = std.ascii.lowerString(&kw_buf, kw_trim);
                if (std.mem.startsWith(u8, kw_lower, q_lower)) {
                    return 280;
                }
            }
        }
    }

    // Tier 6: Description/comment match
    if (comment) |c| {
        var c_buf: [512]u8 = undefined;
        if (c.len <= c_buf.len) {
            const c_lower = std.ascii.lowerString(&c_buf, c);
            if (std.mem.indexOf(u8, c_lower, q_lower) != null) {
                return 200;
            }
        }
    }

    return null;
}

fn matchesWordPrefix(text: []const u8, prefix: []const u8) bool {
    var it = std.mem.splitAny(u8, text, " \t-_/");
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (std.mem.startsWith(u8, word, prefix)) return true;
    }
    return false;
}

fn sortAlphabetical(_: void, a: SearchResult, b: SearchResult) bool {
    const ord = std.ascii.orderIgnoreCase(a.name, b.name);
    if (ord != .eq) return ord == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortRanked(_: void, a: SearchResult, b: SearchResult) bool {
    // Higher score first
    if (a.score != b.score) return a.score > b.score;
    // Shorter name preferred
    if (a.name.len != b.name.len) return a.name.len < b.name.len;
    // Alphabetical tie-breaking
    const ord = std.ascii.orderIgnoreCase(a.name, b.name);
    if (ord != .eq) return ord == .lt;
    // Stable ID tie-breaking
    return std.mem.order(u8, a.id, b.id) == .lt;
}

test "search exact match vs prefix rank" {
    const apps = [_]AppEntry{
        .{
            .id = "term.desktop",
            .desktop_file_path = "",
            .name = "Terminal",
            .exec = "term",
        },
        .{
            .id = "term-emu.desktop",
            .desktop_file_path = "",
            .name = "Terminal Emulator",
            .exec = "term",
        },
    };
    const res = try search(std.testing.allocator, &apps, "Terminal", .all, false);
    defer std.testing.allocator.free(res);

    try std.testing.expect(res.len >= 2);
    try std.testing.expectEqualStrings("Terminal", res[0].name);
    try std.testing.expectEqualStrings("Terminal Emulator", res[1].name);
}

test "search word prefix in name" {
    const apps = [_]AppEntry{
        .{
            .id = "foot-server.desktop",
            .desktop_file_path = "",
            .name = "Foot Server",
            .exec = "foot --server",
        },
    };
    const res = try search(std.testing.allocator, &apps, "serv", .all, false);
    defer std.testing.allocator.free(res);

    try std.testing.expectEqual(@as(usize, 1), res.len);
    try std.testing.expectEqualStrings("Foot Server", res[0].name);
}

test "search empty query and category filtering" {
    const apps = [_]AppEntry{
        .{
            .id = "z.desktop",
            .desktop_file_path = "",
            .name = "Zebra",
            .exec = "zebra",
        },
        .{
            .id = "a.desktop",
            .desktop_file_path = "",
            .name = "Ant",
            .exec = "ant",
        },
    };

    // Category .all contains alphabetical apps + Settings action
    const all_res = try search(std.testing.allocator, &apps, "", .all, false);
    defer std.testing.allocator.free(all_res);
    try std.testing.expectEqual(@as(usize, 3), all_res.len);
    try std.testing.expectEqualStrings("Ant", all_res[0].name);
    try std.testing.expectEqualStrings("Zebra", all_res[1].name);
    try std.testing.expect(all_res[2].is_settings);

    const loading_res = try search(std.testing.allocator, &.{}, "", .all, true);
    defer std.testing.allocator.free(loading_res);
    try std.testing.expectEqual(@as(usize, 2), loading_res.len);
    try std.testing.expect(loading_res[0].is_loading);
    try std.testing.expect(loading_res[1].is_settings);

    // Category .apps filters out Settings action
    const apps_res = try search(std.testing.allocator, &apps, "", .apps, false);
    defer std.testing.allocator.free(apps_res);
    try std.testing.expectEqual(@as(usize, 2), apps_res.len);
    try std.testing.expectEqualStrings("Ant", apps_res[0].name);
    try std.testing.expectEqualStrings("Zebra", apps_res[1].name);
}

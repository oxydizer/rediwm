//! Read-only session locale information and personal shell clock preferences.
const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const config = @import("config");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("locale.h");
    @cInclude("langinfo.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("monetary.h");
});

const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    message: []const u8 = "",
};

fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}

fn container(a: std.mem.Allocator, direction: ui.layout.Direction, items: []const W) !W {
    return .{ .kind = .container, .direction = direction, .gap = 12, .@"align" = .stretch, .width = .{ .flex = 1 }, .children = try a.dupe(W, items) };
}

fn card(a: std.mem.Allocator, items: []const W) !W {
    var result = try container(a, .column, items);
    const t = panel.palette();
    result.kind = .{ .rect = .{ .color = t.settings_card_bg, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.border_soft } };
    result.padding = ui.layout.Edges.all(16);
    return result;
}

fn info(a: std.mem.Allocator, name: []const u8, value: []const u8) !W {
    return container(a, .column, &.{ text(name, 12, true), text(value, 14, false) });
}

fn localeName(cc: *panel.ControlCenter, category: []const u8) []const u8 {
    for ([_][]const u8{ "LC_ALL", category, "LANG" }) |key| {
        if (cc.server.environ.getPosix(key)) |value| if (value.len != 0) return value;
    }
    return "C";
}

fn localeLabel(a: std.mem.Allocator, name: []const u8, item: c.nl_item) ![]const u8 {
    const name_z = try a.dupeZ(u8, name);
    const locale = c.newlocale(c.LC_ALL_MASK, name_z, null) orelse return name;
    defer c.freelocale(locale);
    const value = std.mem.span(c.nl_langinfo_l(item, locale));
    if (value.len == 0) return name;
    return std.fmt.allocPrint(a, "{s} ({s})", .{ value, name });
}

fn timezone(a: std.mem.Allocator, cc: *panel.ControlCenter) ![]const u8 {
    if (cc.server.environ.getPosix("TZ")) |value| return if (value.len == 0) "UTC" else value;
    var path: [4096]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(cc.server.io, "/etc/localtime", &path) catch 0;
    if (std.mem.indexOf(u8, path[0..len], "zoneinfo/")) |start| return a.dupe(u8, path[start + "zoneinfo/".len .. len]);
    var raw = c.time(null);
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (c.localtime_r(&raw, &tm) == null) return "Unavailable";
    var buffer: [96]u8 = undefined;
    const count = c.strftime(&buffer, buffer.len, "%Z (UTC%z)", &tm);
    return a.dupe(u8, buffer[0..count]);
}

fn previews(a: std.mem.Allocator, prefs: config.loader.RegionConfig) !W {
    const locale = c.newlocale(c.LC_ALL_MASK, "", null) orelse return text("Regional formats are unavailable for this session.", 12, true);
    defer c.freelocale(locale);
    // Fixed examples make format changes easy to compare, with no preview timer.
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = 124;
    tm.tm_mon = 2;
    tm.tm_mday = 14;
    tm.tm_hour = 15;
    tm.tm_min = 24;
    var date: [128]u8 = @splat(0);
    var time: [64]u8 = @splat(0);
    var number: [128]u8 = @splat(0);
    var currency: [128]u8 = @splat(0);
    _ = c.strftime_l(&date, date.len, "%x", &tm, locale);
    // Match the shell's clock, which currently uses English AM/PM labels.
    _ = c.strftime(&time, time.len, prefs.timeFormat(), &tm);
    // Only this thread, and only for the numeric conversion. Never setlocale:
    // the compositor has workers and they must retain their own locale state.
    const previous = c.uselocale(locale);
    const number_len = c.snprintf(&number, number.len, "%'.2f", @as(f64, 1234.56));
    _ = c.uselocale(previous);
    const currency_len = c.strfmon_l(&currency, currency.len, locale, "%n", @as(f64, 1234.56));
    return container(a, .column, &.{
        try info(a, "Date", try a.dupe(u8, std.mem.sliceTo(&date, 0))),
        try info(a, "Time", try a.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(&time, 0), " "))),
        try info(a, "Number", if (number_len > 0 and number_len < number.len) try a.dupe(u8, std.mem.sliceTo(&number, 0)) else "Unavailable"),
        try info(a, "Currency", if (std.mem.span(c.nl_langinfo_l(c.INT_CURR_SYMBOL, locale)).len == 0) "Not specified" else if (currency_len > 0) try a.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(&currency, 0), " ")) else "Unavailable"),
    });
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const prefs = cc.server.config.region;
    const language = try card(a, &.{
        text("Language", 17, false),
        try info(a, "Session language", try localeLabel(a, localeName(cc, "LC_MESSAGES"), c._NL_IDENTIFICATION_LANGUAGE)),
        text("RediWM currently uses English.", 12, true),
    });
    const region = try card(a, &.{
        text("Region", 17, false),
        try info(a, "Regional formats", try localeLabel(a, localeName(cc, "LC_TIME"), c._NL_ADDRESS_COUNTRY_NAME)),
        text("Inherited from your login session.", 12, true),
    });
    var toggle = try container(a, .row, &.{
        text("Use 24-hour time", 13, false),
        .{ .name = "clock_24h", .kind = .{ .toggle = .{ .on = prefs.clock_24h, .style = .settings, .owner = cc, .on_change = clockChanged } } },
    });
    toggle.justify = .space_between;
    toggle.@"align" = .center;
    const timing = try card(a, &.{
        text("Time & Date", 17, false),
        try info(a, "Time zone", try timezone(a, cc)),
        toggle,
        text("Taskbar, calendar, lock screen and Files.", 12, true),
        text("First day of the week", 13, false),
        .{ .name = "first_day_of_week", .kind = .{ .select = .{ .labels = &days, .selected = @intFromEnum(prefs.first_day_of_week), .owner = cc, .on_change = firstDayChanged } }, .width = .{ .percent = 1 } },
        text("Changes the taskbar calendar.", 12, true),
    });
    const preview = try card(a, &.{ text("Formats Preview", 17, false), try previews(a, prefs) });
    var body = try container(a, if (cc.panel_box.width < 900) .column else .row, &.{
        try container(a, .column, &.{ language, timing }),
        try container(a, .column, &.{ region, preview }),
    });
    body.width = .{ .percent = 1 };
    var root = try container(a, .column, &.{ body, text(s.message, 12, true) });
    if (s.message.len == 0) root.children = root.children[0..1];
    root.width = .{ .percent = 1 };
    return root;
}

fn save(owner: ?*anyopaque, comptime key: []const u8, value: @FieldType(config.loader.RegionConfig, key)) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    config.setting_save.saveRegion(gpa, cc.server.io, cc.server.config.path, key, value) catch {
        cc.region.message = "Could not save. Check the configuration file and try again.";
        cc.refresh();
        return;
    };
    @field(cc.server.config.region, key) = value;
    cc.region.message = "";
    @import("../../config_runtime/apply.zig").applyRegion(cc.server);
}

fn clockChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    save(owner, "clock_24h", on);
}
fn firstDayChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < days.len) save(owner, "first_day_of_week", @enumFromInt(index));
}

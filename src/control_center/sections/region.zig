//! Personal session locale, timezone and shell clock preferences.
const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const config = @import("config");
const wl = @import("wayland").server.wl;
const Child = @import("../../session/child.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("locale.h");
    @cInclude("langinfo.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("monetary.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    message: []const u8 = "",
    options: std.heap.ArenaAllocator = .init(gpa),
    locales: std.ArrayList([]const u8) = .empty,
    zones: std.ArrayList([]const u8) = .empty,
    values: [3][]const []const u8 = .{ &.{}, &.{}, &.{} },
    loaded: bool = false,
    locale_child: ?*Child = null,
    locale_source: ?*wl.EventSource = null,
    locale_fd: i32 = -1,
    locale_output: std.ArrayList(u8) = .empty,

    pub fn deinit(s: *Section) void {
        if (s.locale_source) |source| source.remove();
        if (s.locale_fd >= 0) _ = c.close(s.locale_fd);
        if (s.locale_child) |child| {
            child.detach();
            child.signal(.KILL);
        }
        s.options.deinit();
        s.arena.deinit();
    }
};

fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn loadOptions(s: *Section, cc: *panel.ControlCenter) !void {
    s.loaded = true;
    const a = s.options.allocator();
    try s.zones.append(a, "UTC");
    const table = std.Io.Dir.readFileAlloc(.cwd(), cc.server.io, "/usr/share/zoneinfo/zone.tab", a, .limited(1 << 20)) catch "";
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var columns = std.mem.splitScalar(u8, line, '\t');
        _ = columns.next();
        _ = columns.next();
        if (columns.next()) |zone| try s.zones.append(a, zone);
    }
    std.mem.sort([]const u8, s.zones.items, {}, less);
    var child = try std.process.spawn(cc.server.io, .{ .argv = &.{ "/usr/bin/locale", "-a" }, .stdout = .pipe, .stderr = .ignore });
    errdefer {
        child.kill(cc.server.io);
    }
    s.locale_fd = child.stdout.?.handle;
    errdefer {
        _ = c.close(s.locale_fd);
        s.locale_fd = -1;
    }
    _ = c.fcntl(s.locale_fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK));
    const loop = cc.server.wl_server.getEventLoop();
    s.locale_source = try loop.addFd(*panel.ControlCenter, s.locale_fd, .{ .readable = true }, localeReady, cc);
    errdefer {
        s.locale_source.?.remove();
        s.locale_source = null;
    }
    s.locale_child = try Child.watch(gpa, loop, child.id.?, cc, localeExited);
}

fn localeExited(owner: ?*anyopaque, _: *Child, _: ?u32) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.region.locale_child = null;
}

fn localeReady(_: c_int, _: wl.EventMask, cc: *panel.ControlCenter) c_int {
    const s = &cc.region;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = c.read(s.locale_fd, &buffer, buffer.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            if (std.posix.errno(n) == .AGAIN) return 0;
            break;
        }
        if (n == 0) break;
        if (s.locale_output.items.len + @as(usize, @intCast(n)) > 64 * 1024) break;
        s.locale_output.appendSlice(s.options.allocator(), buffer[0..@intCast(n)]) catch break;
    }
    s.locale_source.?.remove();
    s.locale_source = null;
    _ = c.close(s.locale_fd);
    s.locale_fd = -1;
    const a = s.options.allocator();
    var lines = std.mem.splitScalar(u8, s.locale_output.items, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0 or std.mem.eql(u8, name, "POSIX")) continue;
        const z = a.dupeZ(u8, name) catch continue;
        const locale = c.newlocale(c.LC_ALL_MASK, z, null) orelse continue;
        c.freelocale(locale);
        s.locales.append(a, z) catch break;
    }
    std.mem.sort([]const u8, s.locales.items, {}, less);
    cc.refresh();
    return 0;
}

fn choice(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, comptime key: []const u8, index: usize, choices: []const []const u8, inherited: []const u8, item: ?c.nl_item) !W {
    var labels: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    try labels.append(a, try std.fmt.allocPrint(a, "Inherited from login ({s})", .{inherited}));
    try values.append(a, "");
    const selected = @field(cc.server.config.region, key);
    var selected_index: usize = 0;
    for (choices) |value| {
        try labels.append(a, if (item) |what| try localeLabel(a, value, what) else value);
        try values.append(a, value);
        if (std.mem.eql(u8, value, selected)) selected_index = values.items.len - 1;
    }
    if (selected.len != 0 and selected_index == 0) {
        try labels.append(a, try std.fmt.allocPrint(a, "Current: {s}", .{selected}));
        try values.append(a, selected);
        selected_index = values.items.len - 1;
    }
    s.values[index] = values.items;
    return .{ .name = key, .kind = .{ .select = .{ .labels = labels.items, .selected = selected_index, .disabled = index != 0 and s.locale_source != null, .owner = cc, .id = index, .on_change = preferenceChanged } }, .width = .{ .percent = 1 } };
}

fn preferenceChanged(owner: ?*anyopaque, id: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (id >= cc.region.values.len or index >= cc.region.values[id].len) return;
    const value = cc.region.values[id][index];
    const owned = cc.server.config.arena.allocator().dupe(u8, value) catch return;
    switch (id) {
        0 => save(owner, "timezone", owned),
        1 => save(owner, "language", owned),
        2 => save(owner, "formats", owned),
        else => {},
    }
}

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
    const name = try a.dupeZ(u8, prefs.formats);
    const locale = c.newlocale(c.LC_ALL_MASK, name, null) orelse return text("Regional formats are unavailable for this session.", 12, true);
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
    _ = c.strftime(&time, time.len, prefs.taskbarTimeFormat(), &tm);
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
    if (!s.loaded and !cc.server.greeter_mode) loadOptions(s, cc) catch {};
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const prefs = cc.server.config.region;
    const language = try card(a, &.{
        text("Language", 17, false),
        text("Application language", 13, false),
        try choice(s, cc, a, "language", 1, s.locales.items, localeName(cc, "LC_MESSAGES"), c._NL_IDENTIFICATION_LANGUAGE),
        text("RediWM currently uses English. Only installed locales are listed.", 12, true),
    });
    const region = try card(a, &.{
        text("Region", 17, false),
        text("Regional formats", 13, false),
        try choice(s, cc, a, "formats", 2, s.locales.items, localeName(cc, "LC_TIME"), c._NL_ADDRESS_COUNTRY_NAME),
        text("Date format for the taskbar; date, number and currency formats for new apps.", 12, true),
    });
    var toggle = try container(a, .row, &.{
        text("Use 24-hour time", 13, false),
        .{ .name = "clock_24h", .kind = .{ .toggle = .{ .on = prefs.clock_24h, .style = .settings, .owner = cc, .on_change = clockChanged } } },
    });
    toggle.justify = .space_between;
    toggle.@"align" = .center;
    var seconds_toggle = try container(a, .row, &.{
        text("Show seconds", 13, false),
        .{ .name = "clock_show_seconds", .kind = .{ .toggle = .{ .on = prefs.clock_show_seconds, .style = .settings, .owner = cc, .on_change = secondsChanged } } },
    });
    seconds_toggle.justify = .space_between;
    seconds_toggle.@"align" = .center;
    var day_toggle = try container(a, .row, &.{
        text("Show day", 13, false),
        .{ .name = "clock_show_day", .kind = .{ .toggle = .{ .on = prefs.clock_show_day, .style = .settings, .owner = cc, .on_change = dayChanged } } },
    });
    day_toggle.justify = .space_between;
    day_toggle.@"align" = .center;
    const timing = try card(a, &.{
        text("Time & Date", 17, false),
        text("Time zone", 13, false),
        try choice(s, cc, a, "timezone", 0, s.zones.items, try timezone(a, cc), null),
        toggle,
        text("Taskbar, calendar, lock screen and new apps.", 12, true),
        seconds_toggle,
        day_toggle,
        text("Taskbar clock. The date uses your regional format.", 12, true),
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
    var root = try container(a, .column, &.{
        text("Saved for your user’s RediWM session only; system defaults are unchanged.", 12, true),
        text("Language and region apply to new apps launched by RediWM. Reopen apps to use them.", 12, true),
        body,
        text(s.message, 12, true),
    });
    if (s.message.len == 0) root.children = root.children[0..3];
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
fn secondsChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    save(owner, "clock_show_seconds", on);
}
fn dayChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    save(owner, "clock_show_day", on);
}
fn firstDayChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < days.len) save(owner, "first_day_of_week", @enumFromInt(index));
}

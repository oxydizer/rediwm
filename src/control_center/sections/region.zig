//! Personal session locale, timezone and shell clock preferences.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const config = @import("config");
const wl = @import("wayland").server.wl;
const Child = @import("../../session/child.zig");
const c = @import("c");

const days = [_]i18n.Message{ i18n.msg("Sunday"), i18n.msg("Monday"), i18n.msg("Tuesday"), i18n.msg("Wednesday"), i18n.msg("Thursday"), i18n.msg("Friday"), i18n.msg("Saturday") };

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
    var child = try std.process.spawn(cc.server.io, .{ .argv = &.{ "locale", "-a" }, .stdout = .pipe, .stderr = .ignore });
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
        if (name.len == 0 or std.mem.eql(u8, name, "POSIX") or std.mem.eql(u8, name, "C") or std.mem.startsWith(u8, name, "C.")) continue;
        const z = a.dupeSentinel(u8, name, 0) catch continue;
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
    try labels.append(a, try i18n.allocPrint(a, tr("Inherited from login ({locale})"), .{ .locale = if (std.mem.eql(u8, inherited, "C") or std.mem.eql(u8, inherited, "POSIX")) tr("English") else inherited }));
    try values.append(a, "");
    const selected = @field(cc.server.config.region, key);
    var selected_index: usize = 0;
    if (index == 1) {
        // Catalogs do not require glibc locale generation. Always offer them;
        // generated locales below remain available for other applications.
        for (i18n.languages) |language| {
            const label = try i18n.allocPrint(a, tr("{name} ({locale})"), .{
                .name = language.native_name,
                .locale = language.locale,
            });
            try labels.append(a, label);
            try values.append(a, language.locale);
            if (sameLocale(selected, language.locale) or std.mem.eql(u8, selected, language.tag)) selected_index = values.items.len - 1;
        }
    }
    for (choices) |value| {
        if (index == 1) {
            var duplicate = false;
            for (values.items) |existing| if (sameLocale(existing, value)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
        }
        const display = if (item) |what| try localeLabel(a, value, what) else value;
        const available = index != 1 or catalogForLocale(value) != null or std.mem.startsWith(u8, value, "en") or std.mem.startsWith(u8, value, "C");
        try labels.append(a, if (available) display else try i18n.allocPrint(a, tr("{locale} · RediWM stays in English"), .{ .locale = display }));
        try values.append(a, value);
        if (std.mem.eql(u8, value, selected)) selected_index = values.items.len - 1;
    }
    if (selected.len != 0 and selected_index == 0) {
        try labels.append(a, try i18n.allocPrint(a, tr("Current: {locale}"), .{ .locale = selected }));
        try values.append(a, selected);
        selected_index = values.items.len - 1;
    }
    s.values[index] = values.items;
    return .{ .name = key, .kind = .{ .select = .{ .labels = labels.items, .selected = selected_index, .disabled = index == 2 and s.locale_source != null, .owner = cc, .id = index, .on_change = preferenceChanged } }, .width = .{ .percent = 1 } };
}

fn sameLocale(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len == 0 or rhs.len == 0) return std.mem.eql(u8, lhs, rhs);
    var left: [128]u8 = undefined;
    var right: [128]u8 = undefined;
    return std.mem.eql(u8, i18n.normalize(&left, lhs), i18n.normalize(&right, rhs));
}
fn catalogForLocale(value: []const u8) ?[]const u8 {
    var buffer: [128]u8 = undefined;
    const tag = i18n.normalize(&buffer, value);
    const base = tag[0 .. std.mem.indexOfScalar(u8, tag, '_') orelse tag.len];
    for (i18n.languages) |language| if (std.mem.eql(u8, tag, language.tag) or std.mem.eql(u8, base, language.tag) or (std.mem.eql(u8, base, "pt") and std.mem.eql(u8, language.tag, "pt_BR"))) return language.locale;
    return null;
}
fn localeHint(a: std.mem.Allocator, cc: *panel.ControlCenter) ![]const u8 {
    const selected = i18n.resolve(cc.server.config.region.language, cc.server.environ);
    const canonical = catalogForLocale(selected) orelse return tr("Reopen running apps to use the selected language.");
    const name = try a.dupeSentinel(u8, if (std.mem.indexOfScalar(u8, selected, '_') != null) selected else canonical, 0);
    if (c.newlocale(c.LC_MESSAGES_MASK, name, null)) |locale| {
        c.freelocale(locale);
        return tr("Reopen running apps to use the selected language.");
    }
    return i18n.allocPrint(a, tr("Enable {locale} in your system’s locale settings to use it in other apps and regional formats."), .{ .locale = canonical });
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

fn paragraph(a: std.mem.Allocator, value: []const u8, width: f32) !W {
    return panel.paragraph(a, value, width - 28, 12, true);
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
    const name_z = try a.dupeSentinel(u8, name, 0);
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
    if (c.localtime_r(&raw, &tm) == null) return tr("Unavailable");
    var buffer: [96]u8 = undefined;
    const count = c.strftime(&buffer, buffer.len, "%Z (UTC%z)", &tm);
    return a.dupe(u8, buffer[0..count]);
}

fn previews(a: std.mem.Allocator, prefs: config.loader.RegionConfig) !W {
    const name = try a.dupeSentinel(u8, prefs.formats, 0);
    const locale = c.newlocale(c.LC_ALL_MASK, name, null) orelse return text(tr("Regional formats are unavailable for this session."), 12, true);
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
        try info(a, tr("Date"), try a.dupe(u8, std.mem.sliceTo(&date, 0))),
        try info(a, tr("Time"), try a.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(&time, 0), " "))),
        try info(a, tr("Number"), if (number_len > 0 and number_len < number.len) try a.dupe(u8, std.mem.sliceTo(&number, 0)) else tr("Unavailable")),
        try info(a, tr("Currency"), if (std.mem.span(c.nl_langinfo_l(c.INT_CURR_SYMBOL, locale)).len == 0) tr("Not specified") else if (currency_len > 0) try a.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(&currency, 0), " ")) else tr("Unavailable")),
    });
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    if (!s.loaded and !cc.server.greeter_mode) loadOptions(s, cc) catch {};
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const prefs = cc.server.config.region;
    const stacked = cc.panel_box.width < 1100;
    const content_width = @as(f32, @floatFromInt(cc.panel_box.width)) - panel.sidebarWidth(cc) - 100;
    const paragraph_width = if (stacked) content_width else (content_width - 12) / 2;
    const language = try card(a, &.{
        panel.sectionTitle(tr("Language")),
        text(tr("Application language"), 13, false),
        try choice(s, cc, a, "language", 1, s.locales.items, localeName(cc, "LC_MESSAGES"), c._NL_IDENTIFICATION_LANGUAGE),
    });
    const region = try card(a, &.{
        panel.sectionTitle(tr("Region")),
        text(tr("Regional formats"), 13, false),
        try choice(s, cc, a, "formats", 2, s.locales.items, localeName(cc, "LC_TIME"), c._NL_ADDRESS_COUNTRY_NAME),
        try paragraph(a, tr("Date format for the taskbar; date, number and currency formats for new apps."), paragraph_width),
    });
    var toggle = try container(a, .row, &.{
        text(tr("Use 24-hour time"), 13, false),
        .{ .name = "clock_24h", .kind = .{ .toggle = .{ .on = prefs.clock_24h, .style = .settings, .owner = cc, .on_change = clockChanged } } },
    });
    toggle.justify = .space_between;
    toggle.@"align" = .center;
    var seconds_toggle = try container(a, .row, &.{
        text(tr("Show seconds"), 13, false),
        .{ .name = "clock_show_seconds", .kind = .{ .toggle = .{ .on = prefs.clock_show_seconds, .style = .settings, .owner = cc, .on_change = secondsChanged } } },
    });
    seconds_toggle.justify = .space_between;
    seconds_toggle.@"align" = .center;
    var day_toggle = try container(a, .row, &.{
        text(tr("Show day"), 13, false),
        .{ .name = "clock_show_day", .kind = .{ .toggle = .{ .on = prefs.clock_show_day, .style = .settings, .owner = cc, .on_change = dayChanged } } },
    });
    day_toggle.justify = .space_between;
    day_toggle.@"align" = .center;
    const timing = try card(a, &.{
        panel.sectionTitle(tr("Time & Date")),
        text(tr("Time zone"), 13, false),
        try choice(s, cc, a, "timezone", 0, s.zones.items, try timezone(a, cc), null),
        toggle,
        try paragraph(a, tr("Taskbar, calendar, lock screen and new apps."), paragraph_width),
        seconds_toggle,
        day_toggle,
        try paragraph(a, tr("Taskbar clock. The date uses your regional format."), paragraph_width),
        text(tr("First day of the week"), 13, false),
        .{ .name = "first_day_of_week", .kind = .{ .select = .{ .labels = panel.translatedLabels(&days), .selected = @intFromEnum(prefs.first_day_of_week), .owner = cc, .on_change = firstDayChanged } }, .width = .{ .percent = 1 } },
        try paragraph(a, tr("Changes the taskbar calendar."), paragraph_width),
    });
    const preview = try card(a, &.{ panel.sectionTitle(tr("Formats Preview")), try previews(a, prefs) });
    var body = try container(a, if (stacked) .column else .row, &.{
        try container(a, .column, &.{ language, timing }),
        try container(a, .column, &.{ region, preview }),
    });
    body.width = .{ .percent = 1 };
    var root = try container(a, .column, &.{
        try paragraph(a, tr("Saved for your user’s RediWM session only; system defaults are unchanged."), paragraph_width),
        try paragraph(a, try localeHint(a, cc), content_width),
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
        cc.region.message = tr("Could not save. Check the configuration file and try again.");
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

//! Settings → Input → Input Sources: the keyboard layouts (add, remove,
//! reorder; at most four, XKB's group limit), Fcitx's input methods read-only,
//! how to switch and whether the taskbar shows the indicator. Layouts are
//! written to `xkb_layout`/`xkb_variant`/`xkb_labels` in one save and applied
//! by the config reload (`input_sources.zig`).
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const ui = @import("ui");
const W = ui.layout.Widget;
const config = @import("config");
const config_sources = config.input_sources;
const taskbar_items = config.taskbar_items;
const fold = ui.fold;
const panel = @import("../panel.zig");
const gpa = @import("../../main.zig").gpa;

const max_results = 40;

/// When the XKB registry is missing: common layouts, named in their own language.
const fallback = [_]struct { layout: []const u8, variant: []const u8 = "", name: []const u8 }{
    .{ .layout = "us", .name = "English (US)" }, // i18n: raw
    .{ .layout = "gb", .name = "English (UK)" }, // i18n: raw
    .{ .layout = "us", .variant = "dvorak", .name = "English (Dvorak)" }, // i18n: raw
    .{ .layout = "de", .name = "Deutsch" }, // i18n: raw
    .{ .layout = "fr", .name = "Français (AZERTY)" }, // i18n: raw
    .{ .layout = "fr", .variant = "bepo", .name = "Français (BÉPO)" }, // i18n: raw
    .{ .layout = "be", .name = "Belge" }, // i18n: raw
    .{ .layout = "ch", .variant = "fr", .name = "Suisse romand" }, // i18n: raw
    .{ .layout = "ca", .variant = "multix", .name = "Canadien multilingue" }, // i18n: raw
    .{ .layout = "es", .name = "Español" }, // i18n: raw
    .{ .layout = "it", .name = "Italiano" }, // i18n: raw
    .{ .layout = "pt", .name = "Português" }, // i18n: raw
    .{ .layout = "br", .name = "Português (Brasil)" }, // i18n: raw
    .{ .layout = "ru", .name = "Русский" }, // i18n: raw
    .{ .layout = "ua", .name = "Українська" }, // i18n: raw
    .{ .layout = "jp", .name = "日本語" }, // i18n: raw
    .{ .layout = "kr", .name = "한국어" }, // i18n: raw
    .{ .layout = "cn", .name = "中文" }, // i18n: raw
};

/// XKB's own layout switch keys, kept in `xkb_options`.
const switch_options = [_]struct { option: []const u8, label: i18n.Message }{
    .{ .option = "", .label = i18n.msg("Only the shortcut (Super+Shift+Space)") },
    .{ .option = "grp:alt_shift_toggle", .label = i18n.msg("Alt+Shift") },
    .{ .option = "grp:ctrl_shift_toggle", .label = i18n.msg("Ctrl+Shift") },
    .{ .option = "grp:caps_toggle", .label = i18n.msg("Caps Lock") },
    .{ .option = "grp:shifts_toggle", .label = i18n.msg("Both Shift keys") },
};

const show_labels = [_]i18n.Message{ i18n.msg("Automatic"), i18n.msg("Always"), i18n.msg("Never") };

const Result = struct { layout: []const u8, variant: []const u8 };
const LanguageGroup = struct { key: []const u8, label: []const u8 };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    picker_open: bool = false,
    search: ?*W = null,
    search_focus: bool = false,
    results: []Result = &.{},
    language_keys: []const []const u8 = &.{},
    selected_language: [128]u8 = @splat(0),
    selected_language_len: usize = 0,
    message: []const u8 = "",

    /// Before a rebuild. A picker that just opened has no field yet and keeps
    /// its request for focus.
    pub fn capture(s: *Section) void {
        if (s.search) |field| s.search_focus = ui.input.current.focused == field;
    }

    pub fn deinit(s: *Section) void {
        if (s.search) |w| gpa.free(w.kind.text_input.value);
        s.search = null;
        s.arena.deinit();
    }
};

fn owner(ctx: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(ctx.?));
}

fn text(value: []const u8, size: f32, dim: bool) W {
    return panel.label(value, size, dim);
}

fn row(a: std.mem.Allocator, items: []const W) !W {
    return .{ .kind = .container, .direction = .row, .gap = 10, .@"align" = .center, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}

fn column(a: std.mem.Allocator, items: []const W, gap: f32) !W {
    return .{ .kind = .container, .direction = .column, .gap = gap, .@"align" = .stretch, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}

fn card(a: std.mem.Allocator, items: []const W) !W {
    var result = try column(a, items, 12);
    result.name = "input_sources";
    const t = ui.theme.global;
    result.kind = .{ .rect = .{ .color = t.app_item, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.app_item_border, .relief = t.settings_card_relief } };
    result.padding = ui.layout.Edges.all(16);
    return result;
}

fn badge(a: std.mem.Allocator, value: []const u8) !W {
    const t = panel.palette();
    var label = text(value, 12, false);
    label.kind.text.weight = 700;
    const width: f32 = 44;
    const ink = ui.measure.textNatural(value, .sans, 700, 12).w;
    return .{
        .kind = .{ .rect = .{ .color = t.surface_hover, .radius = 6 } },
        .direction = .row,
        .@"align" = .center,
        .width = .{ .fixed = width },
        .height = .{ .fixed = 26 },
        .padding = .{ .left = @max(0, @floor((width - ink) / 2)) },
        .children = try a.dupe(W, &.{label}),
    };
}

fn iconButton(cc: *panel.ControlCenter, name: []const u8, label: []const u8, icon: ui.layout.IconId, id: usize, enabled: bool, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = label, .icon = icon, .owner = cc, .id = id, .on_click = callback, .state = if (enabled) .idle else .disabled } }, .width = .{ .fixed = 32 }, .height = .{ .fixed = 32 } };
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    const saved = if (s.search) |w| w.kind.text_input else null;
    _ = s.arena.reset(.retain_capacity);
    s.search = null;
    s.results = &.{};
    const manager = cc.server.input_sources orelse {
        if (saved) |field| gpa.free(field.value);
        s.root = text(tr("Input sources are unavailable."), 13, true);
        return;
    };
    if (s.picker_open) manager.wantCatalog();
    s.root = tree(s, cc, manager, s.arena.allocator(), saved) catch blk: {
        s.search_focus = false;
        break :blk panel.outOfMemory();
    };
    // A field that took the text over owns it; otherwise it is dropped here.
    if (s.search == null) if (saved) |field| gpa.free(field.value);
}

fn tree(s: *Section, cc: *panel.ControlCenter, manager: anytype, a: std.mem.Allocator, saved: ?ui.layout.TextInputData) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, panel.sectionTitle(tr("Input Sources")));
    try items.append(a, try panel.paragraph(a, tr("The taskbar shows the active source. Click it, or press Super+Shift+Space, to switch."), contentWidth(cc), 12, true));

    const layouts = manager.configuredLayouts();
    const sources = manager.sources();
    const active = manager.activeIndex();
    for (layouts, 0..) |layout, i| {
        const label = if (i < sources.len) sources[i].label else layout.layout;
        const name = if (i < sources.len) sources[i].name else layout.layout;
        var id_buf: [160]u8 = undefined;
        var info = try column(a, &.{ text(name, 13, false), idText(try a.dupe(u8, layout.format(&id_buf))) }, 2);
        info.width = .{ .flex = 1 };
        var line = try row(a, &.{
            try badge(a, label),
            info,
            iconButton(cc, try std.fmt.allocPrint(a, "input_source_up_{d}", .{i}), tr("Move up"), .chevron_up, i, i > 0, moveUp),
            iconButton(cc, try std.fmt.allocPrint(a, "input_source_down_{d}", .{i}), tr("Move down"), .chevron_down, i, i + 1 < layouts.len, moveDown),
            iconButton(cc, try std.fmt.allocPrint(a, "input_source_remove_{d}", .{i}), tr("Remove"), .close, i, layouts.len > 1, remove),
        });
        line.name = try std.fmt.allocPrint(a, "input_source_{d}", .{i});
        if (active == i) line.children[0].kind.rect.color = panel.palette().accent;
        if (active == i) line.children[0].children[0].kind.text.color = panel.palette().on_accent;
        try items.append(a, line);
    }

    if (layouts.len < config_sources.max_layouts) {
        const add: W = .{ .name = "input_source_add", .kind = .{ .button = .{ .label = if (s.picker_open) tr("Close") else tr("Add layout…"), .leading_icon = if (s.picker_open) null else .plus, .owner = cc, .on_click = togglePicker } }, .height = .{ .fixed = 34 } };
        try items.append(a, try row(a, &.{add}));
        if (s.picker_open) try items.append(a, try picker(s, cc, manager, a, saved, layouts));
    } else {
        try items.append(a, text(tr("Four keyboard layouts is the most XKB allows."), 12, true));
    }
    if (s.message.len > 0) try items.append(a, text(s.message, 12, true));

    if (cc.server.config.input_method.env == .fcitx or manager.fcitxRunning()) try items.append(a, try fcitxBlock(cc, manager, a, sources));
    try items.append(a, try options(cc, a));
    return card(a, items.items);
}

fn contentWidth(cc: *panel.ControlCenter) f32 {
    return @as(f32, @floatFromInt(cc.panel_box.width)) - panel.sidebarWidth(cc) - 100;
}

fn picker(s: *Section, cc: *panel.ControlCenter, manager: anytype, a: std.mem.Allocator, saved: ?ui.layout.TextInputData, layouts: []const config_sources.Layout) !W {
    const field: W = .{
        .name = "input_source_search",
        .kind = .{ .text_input = saved orelse .{ .field = .{ .leading_icon = .search }, .placeholder = tr("Search layouts or languages…"), .value = try gpa.dupe(u8, ""), .owner = cc, .on_change = searchChanged } },
        .height = .{ .fixed = 36 },
        .width = .{ .percent = 1 },
    };
    const query = std.mem.trim(u8, field.kind.text_input.value, " ");
    var children: std.ArrayList(W) = .empty;
    try children.append(a, field);
    var groups: std.ArrayList(LanguageGroup) = .empty;
    var results: std.ArrayList(Result) = .empty;
    var rows: std.ArrayList(W) = .empty;
    var total: usize = 0;
    switch (manager.catalogState()) {
        .loading => try children.append(a, text(tr("Loading layouts…"), 12, true)),
        .ready => for (manager.catalog.?.entries) |entry| {
            if (configured(layouts, entry.layout, entry.variant)) continue;
            var id_buf: [160]u8 = undefined;
            const spelled = (config_sources.Layout{ .layout = entry.layout, .variant = entry.variant }).format(&id_buf);
            if (!matches(query, &.{ entry.description, entry.layout, entry.variant, entry.brief, entry.languages, spelled })) continue;
            try appendLanguageGroup(a, &groups, languageName(entry.description), languageName(entry.description));
        },
        .unavailable => for (fallback) |entry| {
            if (configured(layouts, entry.layout, entry.variant)) continue;
            if (!matches(query, &.{ entry.name, entry.layout, entry.variant })) continue;
            try appendLanguageGroup(a, &groups, languageName(entry.name), languageName(entry.name));
        },
    }
    const keys = try a.alloc([]const u8, groups.items.len);
    var labels = try a.alloc([]const u8, groups.items.len);
    var selected: ?usize = null;
    for (groups.items, 0..) |group, i| {
        keys[i] = group.key;
        labels[i] = group.label;
        if (s.selected_language_len > 0 and fold.eql(group.key, s.selected_language[0..s.selected_language_len], .{})) selected = i;
    }
    if (selected == null and groups.items.len > 0) selected = 0;
    s.language_keys = keys;
    if (selected) |i| {
        const key = keys[i];
        s.selected_language_len = @min(key.len, s.selected_language.len);
        @memcpy(s.selected_language[0..s.selected_language_len], key[0..s.selected_language_len]);
    } else {
        s.selected_language_len = 0;
    }
    if (groups.items.len > 0) {
        try children.append(a, text(tr("Language"), 13, false));
        try children.append(a, .{
            .name = "input_source_language",
            .kind = .{ .select = .{
                .labels = labels,
                .selected = selected,
                .owner = cc,
                .on_change = languageChanged,
            } },
            .width = .{ .percent = 1 },
        });
    }
    switch (manager.catalogState()) {
        .loading => {},
        .ready => for (manager.catalog.?.entries) |entry| {
            if (configured(layouts, entry.layout, entry.variant)) continue;
            const key = languageName(entry.description);
            if (!fold.eql(key, s.selected_language[0..s.selected_language_len], .{})) continue;
            var id_buf: [160]u8 = undefined;
            const spelled = (config_sources.Layout{ .layout = entry.layout, .variant = entry.variant }).format(&id_buf);
            if (!matches(query, &.{ entry.description, entry.layout, entry.variant, entry.brief, entry.languages, spelled })) continue;
            total += 1;
            if (results.items.len >= max_results) continue;
            try rows.append(a, try resultRow(cc, a, results.items.len, entry.description, try a.dupe(u8, spelled)));
            try results.append(a, .{ .layout = entry.layout, .variant = entry.variant });
        },
        .unavailable => for (fallback) |entry| {
            if (configured(layouts, entry.layout, entry.variant)) continue;
            if (!fold.eql(languageName(entry.name), s.selected_language[0..s.selected_language_len], .{})) continue;
            if (!matches(query, &.{ entry.name, entry.layout, entry.variant })) continue;
            total += 1;
            var id_buf: [160]u8 = undefined;
            const spelled = (config_sources.Layout{ .layout = entry.layout, .variant = entry.variant }).format(&id_buf);
            try rows.append(a, try resultRow(cc, a, results.items.len, entry.name, try a.dupe(u8, spelled)));
            try results.append(a, .{ .layout = entry.layout, .variant = entry.variant });
        },
    }
    s.results = results.items;
    if (manager.catalogState() != .loading) {
        if (groups.items.len == 0) {
            try children.append(a, text(tr("No layouts match."), 12, true));
        } else if (rows.items.len == 0) {
            try children.append(a, text(tr("No layouts match this search."), 12, true));
        }
        try children.append(a, try column(a, rows.items, 2));
        if (total > rows.items.len) try children.append(a, text(try i18n.allocPrint(a, tr("{shown} of {total} layouts; type to narrow the list."), .{ .shown = rows.items.len, .total = total }), 11, true));
    }
    var result = try column(a, children.items, 8);
    s.search = &result.children[0];
    return result;
}

fn appendLanguageGroup(a: std.mem.Allocator, groups: *std.ArrayList(LanguageGroup), key: []const u8, label: []const u8) !void {
    for (groups.items) |group| {
        if (fold.eql(group.key, key, .{})) return;
    }
    try groups.append(a, .{ .key = key, .label = label });
}

fn languageName(description: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, description, '(') orelse description.len;
    return std.mem.trim(u8, description[0..end], " ");
}

fn languageChanged(ctx: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(ctx);
    const s = &cc.input_sources;
    if (index >= s.language_keys.len) return;
    const key = s.language_keys[index];
    if (key.len > s.selected_language.len) return;
    s.selected_language_len = key.len;
    @memcpy(s.selected_language[0..key.len], key);
    cc.refresh();
}

fn resultRow(cc: *panel.ControlCenter, a: std.mem.Allocator, index: usize, name: []const u8, spelled: []const u8) !W {
    var label = text(name, 13, false);
    label.width = .{ .flex = 1 };
    return .{
        .name = try std.fmt.allocPrint(a, "input_source_result_{d}", .{index}),
        .kind = .{ .row = .{ .owner = cc, .id = index, .on_click = addResult } },
        .direction = .row,
        .@"align" = .center,
        .gap = 10,
        .width = .{ .percent = 1 },
        .height = .{ .fixed = 34 },
        .padding = ui.layout.Edges.xy(10, 0),
        .children = try a.dupe(W, &.{ label, idText(spelled) }),
    };
}

/// A layout's XKB spelling at its own measured width, so a fractional scale
/// never ellipsizes it.
fn idText(spelled: []const u8) W {
    var id = text(spelled, 11, true);
    id.width = .{ .fixed = @ceil(ui.measure.textNatural(spelled, .sans, 400, 11).w) + 8 };
    return id;
}

fn configured(layouts: []const config_sources.Layout, layout: []const u8, variant: []const u8) bool {
    for (layouts) |l| if (l.eql(.{ .layout = layout, .variant = variant })) return true;
    return false;
}

/// Every word of the query appears in one of the fields (case-insensitive).
fn matches(query: []const u8, fields: []const []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        var found = false;
        for (fields) |field| if (containsIgnoreCase(field, word)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

test "language groups merge identical visible language names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var groups: std.ArrayList(LanguageGroup) = .empty;
    try appendLanguageGroup(arena.allocator(), &groups, "English", "English");
    try appendLanguageGroup(arena.allocator(), &groups, "english", "english");
    try appendLanguageGroup(arena.allocator(), &groups, "Croatian", "Croatian");
    try std.testing.expectEqual(@as(usize, 2), groups.items.len);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn fcitxBlock(cc: *panel.ControlCenter, manager: anytype, a: std.mem.Allocator, sources: anytype) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(tr("Input methods (Fcitx 5)"), 13, false));
    if (!manager.fcitxRunning()) {
        try items.append(a, text(tr("Fcitx 5 is not running. Its input methods appear here while it runs."), 12, true));
    } else {
        var any = false;
        for (sources, 0..) |source, i| {
            if (source.kind != .fcitx) continue;
            any = true;
            var name = text(source.name, 13, false);
            name.width = .{ .flex = 1 };
            var line = try row(a, &.{ try badge(a, source.label), name });
            line.name = try std.fmt.allocPrint(a, "input_method_{d}", .{i});
            try items.append(a, line);
        }
        if (!any) try items.append(a, text(tr("Fcitx's current group has no input methods besides keyboards."), 12, true));
    }
    try items.append(a, text(tr("Fcitx manages its own list; RediWM only switches between its methods."), 11, true));
    const tool = config.app_theme.executable(a, cc.server.io, cc.server.environ, "fcitx5-configtool") catch null;
    if (tool != null) try items.append(a, try row(a, &.{.{ .name = "fcitx_configure", .kind = .{ .button = .{ .label = tr("Configure in Fcitx…"), .owner = cc, .on_click = configureFcitx } }, .height = .{ .fixed = 34 } }}));
    return column(a, items.items, 8);
}

fn options(cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const group = groupOption(cc.server.config.input.xkb_options);
    var labels: std.ArrayList([]const u8) = .empty;
    var selected: ?usize = null;
    for (switch_options, 0..) |choice, i| {
        try labels.append(a, choice.label.get());
        if (std.mem.eql(u8, choice.option, group)) selected = i;
    }
    if (selected == null) {
        try labels.append(a, try i18n.allocPrint(a, tr("Custom ({option})"), .{ .option = group }));
        selected = labels.items.len - 1;
    }
    var switch_label = text(tr("Also switch with"), 13, false);
    switch_label.width = .{ .flex = 1 };
    const switch_row = try row(a, &.{
        switch_label,
        .{ .name = "input_source_switch_with", .kind = .{ .select = .{ .labels = labels.items, .selected = selected, .owner = cc, .on_change = switchWithChanged } }, .width = .{ .fixed = 260 } },
    });
    const items = cc.server.config.compositor.taskbar_items;
    const id = @backingInt(taskbar_items.Item.input_source);
    const show: usize = if (items.auto[id]) 0 else if (items.visible[id]) 1 else 2;
    var show_label = text(tr("Show in taskbar"), 13, false);
    show_label.width = .{ .flex = 1 };
    const show_row = try row(a, &.{
        show_label,
        .{ .name = "input_source_show", .kind = .{ .select = .{ .labels = panel.translatedLabels(&show_labels), .selected = show, .owner = cc, .on_change = showChanged } }, .width = .{ .fixed = 260 } },
    });
    return column(a, &.{ switch_row, text(tr("XKB switch keys change keyboard layouts only."), 11, true), show_row, text(tr("Automatic shows it while there is more than one source."), 11, true) }, 8);
}

/// The first `grp:` entry of an `xkb_options` list, or "".
fn groupOption(xkb_options: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, xkb_options, ',');
    while (it.next()) |raw| {
        const option = std.mem.trim(u8, raw, " ");
        if (std.mem.startsWith(u8, option, "grp:")) return option;
    }
    return "";
}

/// `xkb_options` with its `grp:` entries replaced by `option` (or dropped).
fn withGroupOption(a: std.mem.Allocator, xkb_options: []const u8, option: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, xkb_options, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " ");
        if (entry.len == 0 or std.mem.startsWith(u8, entry, "grp:")) continue;
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, entry);
    }
    if (option.len > 0) {
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, option);
    }
    return out.items;
}

// ---- actions ------------------------------------------------------------

fn save(cc: *panel.ControlCenter, layouts: []const config_sources.Layout) void {
    const joined = config_sources.join(gpa, layouts) catch return;
    defer joined.deinit(gpa);
    config.setting_save.saveInputSources(gpa, cc.server.io, cc.server.config.path, joined.layout, joined.variant, joined.labels) catch |err| {
        std.log.warn("could not save keyboard layouts: {}", .{err});
        cc.input_sources.message = tr("Could not save. Check the configuration file and try again.");
        cc.refresh();
        return;
    };
    cc.input_sources.message = "";
    @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
    cc.refresh();
}

/// A copy of the layouts, so a reload during the save can't pull them away.
fn current(cc: *panel.ControlCenter, buf: *[config_sources.max_layouts + 1]config_sources.Layout, storage: *[config_sources.max_layouts + 1][3][64]u8) []config_sources.Layout {
    const manager = cc.server.input_sources orelse return buf[0..0];
    const layouts = manager.configuredLayouts();
    for (layouts, 0..) |layout, i| {
        buf[i] = .{ .layout = copy(&storage[i][0], layout.layout), .variant = copy(&storage[i][1], layout.variant), .label = copy(&storage[i][2], layout.label) };
    }
    return buf[0..layouts.len];
}

fn copy(dest: *[64]u8, value: []const u8) []const u8 {
    const n = @min(value.len, dest.len);
    @memcpy(dest[0..n], value[0..n]);
    return dest[0..n];
}

fn moveUp(ctx: ?*anyopaque, index: usize) void {
    move(owner(ctx), index, false);
}

fn moveDown(ctx: ?*anyopaque, index: usize) void {
    move(owner(ctx), index, true);
}

fn move(cc: *panel.ControlCenter, index: usize, down: bool) void {
    var buf: [config_sources.max_layouts + 1]config_sources.Layout = undefined;
    var storage: [config_sources.max_layouts + 1][3][64]u8 = undefined;
    const layouts = current(cc, &buf, &storage);
    const other = if (down) index + 1 else index -% 1;
    if (index >= layouts.len or other >= layouts.len) return;
    std.mem.swap(config_sources.Layout, &layouts[index], &layouts[other]);
    save(cc, layouts);
}

fn remove(ctx: ?*anyopaque, index: usize) void {
    const cc = owner(ctx);
    var buf: [config_sources.max_layouts + 1]config_sources.Layout = undefined;
    var storage: [config_sources.max_layouts + 1][3][64]u8 = undefined;
    const layouts = current(cc, &buf, &storage);
    if (index >= layouts.len or layouts.len < 2) return;
    var kept: [config_sources.max_layouts]config_sources.Layout = undefined;
    var n: usize = 0;
    for (layouts, 0..) |layout, i| if (i != index) {
        kept[n] = layout;
        n += 1;
    };
    save(cc, kept[0..n]);
}

fn addResult(ctx: ?*anyopaque, index: usize) void {
    const cc = owner(ctx);
    const s = &cc.input_sources;
    if (index >= s.results.len) return;
    var result_storage: [2][64]u8 = undefined;
    const chosen: config_sources.Layout = .{ .layout = copy(&result_storage[0], s.results[index].layout), .variant = copy(&result_storage[1], s.results[index].variant) };
    if (!config_sources.validName(chosen.layout) or (chosen.variant.len > 0 and !config_sources.validName(chosen.variant))) return;
    var buf: [config_sources.max_layouts + 1]config_sources.Layout = undefined;
    var storage: [config_sources.max_layouts + 1][3][64]u8 = undefined;
    const layouts = current(cc, &buf, &storage);
    if (layouts.len >= config_sources.max_layouts) return;
    buf[layouts.len] = chosen;
    // The rebuild frees the search text; this tree still shows it.
    s.picker_open = false;
    save(cc, buf[0 .. layouts.len + 1]);
}

fn togglePicker(ctx: ?*anyopaque, _: usize) void {
    const cc = owner(ctx);
    const s = &cc.input_sources;
    s.picker_open = !s.picker_open;
    s.search_focus = s.picker_open;
    cc.refresh();
}

fn searchChanged(ctx: ?*anyopaque, _: usize, _: []const u8) void {
    owner(ctx).refresh();
}

fn configureFcitx(ctx: ?*anyopaque, _: usize) void {
    const cc = owner(ctx);
    @import("../../config_runtime/actions.zig").executeAction(cc.server, .{ .spawn = "fcitx5-configtool" });
}

fn switchWithChanged(ctx: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(ctx);
    if (index >= switch_options.len) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const value = withGroupOption(arena.allocator(), cc.server.config.input.xkb_options, switch_options[index].option) catch return;
    config.setting_save.saveInput(gpa, cc.server.io, cc.server.config.path, "xkb_options", value) catch |err| {
        std.log.warn("could not save the layout switch keys: {}", .{err});
        return;
    };
    @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
    cc.refresh();
}

fn showChanged(ctx: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(ctx);
    var items = cc.server.config.compositor.taskbar_items;
    const id = @backingInt(taskbar_items.Item.input_source);
    switch (index) {
        0 => {
            items.visible[id] = true;
            items.auto[id] = true;
        },
        1 => items.setVisible(.input_source, true),
        2 => items.setVisible(.input_source, false),
        else => return,
    }
    config.setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "taskbar_items", items) catch |err| {
        std.log.warn("could not save taskbar items: {}", .{err});
        return;
    };
    cc.server.config.compositor.taskbar_items = items;
    cc.server.refreshTaskbarsGeometry();
    cc.refresh();
}

test "group options are replaced without touching other XKB options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("grp:caps_toggle", groupOption("ctrl:nocaps, grp:caps_toggle"));
    try std.testing.expectEqualStrings("", groupOption("ctrl:nocaps"));
    try std.testing.expectEqualStrings("ctrl:nocaps,grp:alt_shift_toggle", try withGroupOption(a, "ctrl:nocaps,grp:caps_toggle", "grp:alt_shift_toggle"));
    try std.testing.expectEqualStrings("ctrl:nocaps", try withGroupOption(a, "grp:caps_toggle,ctrl:nocaps", ""));
    try std.testing.expectEqualStrings("grp:shifts_toggle", try withGroupOption(a, "", "grp:shifts_toggle"));
    try std.testing.expect(matches("ger nodead", &.{ "German (no dead keys)", "de", "nodeadkeys" }));
    try std.testing.expect(matches("jpn", &.{ "Japanese", "jp", "", "ja", "jpn" }));
    try std.testing.expect(!matches("french", &.{ "German", "de" }));
}

//! Systemd Settings page. Data and requests outlive widget-tree rebuilds.
const std = @import("std");
const ui = @import("ui");
const cairo = @import("ui").cairo;
const panel = @import("../panel.zig");
const systemd = @import("../../systemd.zig");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;

const Filter = enum { all, enabled, slow, disabled, failed };
const Sort = enum { service, status, startup, notify, time };
const Row = struct { name: []const u8, select: *W, initial: ?usize, notify: *W, notify_initial: ?usize };
const column_widths = [_]f32{ 0, 88, 120, 132, 104 };
pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    search: ?*W = null,
    search_focus: bool = false,
    table: ?*W = null,
    table_scroll: ui.layout.ScrollState = .{},
    filter: Filter = .all,
    sort: Sort = .service,
    descending: bool = false,
    selected: ?[]u8 = null,
    rows: []Row = &.{},

    pub fn capture(s: *Section) void {
        s.search_focus = s.search != null and ui.input.current.focused == s.search;
    }
    pub fn deinit(s: *Section) void {
        if (s.search) |w| gpa.free(w.kind.text_input.value);
        if (s.selected) |v| gpa.free(v);
        s.arena.deinit();
    }
};

fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = 13, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
fn group(a: std.mem.Allocator, children: []const W, column: bool) !W {
    return .{ .kind = .container, .direction = if (column) .column else .row, .gap = 8, .@"align" = if (column) .stretch else .center, .width = .{ .percent = 1 }, .children = try a.dupe(W, children) };
}
fn button(cc: *panel.ControlCenter, label: []const u8, id: usize, cb: *const fn (?*anyopaque, usize) void, disabled: bool) W {
    return .{ .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = cb, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
fn named(w: W, name: []const u8) W {
    var result = w;
    result.name = name;
    return result;
}
fn tableText(value: []const u8, secondary: bool) W {
    return .{ .kind = .{ .text = .{
        .content = value,
        .font_size = @floatCast(if (secondary) cairo.statusSize() else cairo.textSize()),
        .color = ui.theme.global.window_fg,
    } } };
}
/// Empty-table message, painted like a row so the table keeps its shape.
fn placeholder(a: std.mem.Allocator, value: []const u8) !W {
    var label = tableText(value, false);
    label.kind.text.color[3] *= 0.5;
    var row = try group(a, &.{label}, false);
    row.name = "services_placeholder";
    row.height = .{ .fixed = 54 };
    row.padding = ui.layout.Edges.xy(8, 0);
    return row;
}
fn cell(a: std.mem.Allocator, content: W, index: usize) !W {
    var result = try group(a, &.{content}, false);
    result.width = if (index == 0) .{ .flex = 1 } else .{ .fixed = column_widths[index] };
    result.height = .{ .percent = 1 };
    result.padding = ui.layout.Edges.xy(4, 0);
    result.gap = 0;
    result.children[0].width = .{ .percent = 1 };
    return result;
}
fn columnHeader(a: std.mem.Allocator, cc: *panel.ControlCenter, s: *Section, label: []const u8, index: usize) !W {
    const sorted = @intFromEnum(s.sort) == index;
    var caption = tableText(label, false);
    caption.kind.text.font_size = @floatCast(cairo.headingSize());
    caption.kind.text.weight = 600;
    caption.width = .{ .flex = 1 };
    var children: std.ArrayList(W) = .empty;
    try tryAppend(&children, a, caption);
    if (sorted) try tryAppend(&children, a, .{ .kind = .{ .icon = .{ .id = if (s.descending) .chevron_down else .chevron_up, .color = ui.theme.global.window_fg } }, .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 } });
    if (index < column_widths.len - 1) {
        var divider = ui.theme.global.window_fg;
        divider[3] *= 0.2;
        try tryAppend(&children, a, .{ .kind = .{ .rect = .{ .color = divider } }, .width = .{ .fixed = 1 }, .height = .{ .fixed = 18 } });
    }
    var header = try group(a, children.items, false);
    header.name = label;
    header.kind = .{ .row = .{
        .owner = cc,
        .id = index,
        .on_click = sortClicked,
        .background = .{ .color = if (sorted) ui.theme.global.surface else .{ 0, 0, 0, 0 } },
        .hover_background = .{ .color = ui.theme.global.surface_hover },
    } };
    header.width = if (index == 0) .{ .flex = 1 } else .{ .fixed = column_widths[index] };
    header.height = .{ .fixed = 30 };
    header.padding = ui.layout.Edges.xy(4, 0);
    header.gap = 4;
    return header;
}
fn duration(a: std.mem.Allocator, us: ?u64) []const u8 {
    const value = us orelse return "—";
    return if (value < 1_000_000) std.fmt.allocPrint(a, "{d} ms", .{@divTrunc(value, 1000)}) catch "—" else std.fmt.allocPrint(a, "{d:.2} s", .{@as(f64, @floatFromInt(value)) / 1_000_000}) catch "—";
}
pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    if (s.table) |table| s.table_scroll = table.kind.scroll_container;
    s.table = null;
    // The field allocator is the input dispatcher's allocator, not the arena.
    const saved = if (s.search) |w| w.kind.text_input else null;
    _ = s.arena.reset(.retain_capacity);
    s.search = null;
    s.rows = &.{};
    const client = cc.systemd_client orelse {
        if (saved) |field| gpa.free(field.value);
        s.root = text("Systemd is unavailable.", true);
        return;
    };
    s.root = tree(s, cc, client, s.arena.allocator(), saved) catch blk: {
        // The search text is kept only once the new field holds it; that
        // field is not on screen, so it must not take focus.
        if (s.search == null) if (saved) |field| gpa.free(field.value);
        s.search_focus = false;
        s.rows = &.{};
        break :blk panel.outOfMemory();
    };
}
fn tree(s: *Section, cc: *panel.ControlCenter, client: *systemd.Client, a: std.mem.Allocator, saved: ?ui.layout.TextInputData) !W {
    client.open();
    const units = client.snapshot.units.items;
    const narrow = cc.panel_box.width < 1040;
    const gutter = ui.widgets.scrollbar.gutter(ui.theme.global.scrollbar_width);
    // Match the actual content width after Settings' navigation and padding.
    const table_width: f32 = @floatFromInt(cc.panel_box.width - @as(i32, if (cc.panel_box.width < 660) 140 else 308));
    const stacked = table_width < 620;
    const compact = table_width < 444;
    var content: std.ArrayList(W) = .empty;
    const locked = !client.unlocked;
    var hint = text(if (client.unlocking) "Waiting for authentication…" else if (locked) "Unlock to make service changes." else "Service changes are unlocked for this session.", true);
    hint.width = if (compact) .{ .percent = 1 } else .{ .flex = 1 };
    var lock_button = named(button(cc, if (client.unlocked) "Lock" else "Unlock", 0, lockClicked, client.unlocking), "services_unlock");
    lock_button.kind.button.leading_icon = if (client.unlocked) .checkmark else .lock;
    lock_button.width = if (compact) .{ .percent = 1 } else .auto;
    try tryAppend(&content, a, try group(a, &.{ hint, lock_button }, compact));
    var enabled: usize = 0;
    for (units) |unit| if (unit.enabled()) {
        enabled += 1;
    };
    var summary = try group(a, &.{
        text(try std.fmt.allocPrint(a, "Boot time: {s}", .{duration(a, client.boot_us)}), false),
        text(try std.fmt.allocPrint(a, "{d} services, {d} enabled", .{ units.len, enabled }), true),
    }, true);
    summary.width = .{ .flex = 1 };
    var analyze_button = named(button(cc, if (client.analyzing) "Analyzing…" else "Analyze", 0, analyze, client.busy()), "services_analyze");
    analyze_button.kind.button.variant = .primary;
    var actions = try group(a, &.{
        analyze_button,
        named(button(cc, "Optimize", 0, noop, true), "services_optimize"),
        named(button(cc, "Refresh", 0, refresh, client.busy()), "services_refresh"),
    }, false);
    actions.width = .auto;
    var banner = try group(a, &.{ summary, actions }, narrow);
    banner.kind = .{ .rect = .{ .color = ui.theme.global.app_item, .radius = 8, .border_width = 1, .border_color = ui.theme.global.app_item_border } };
    banner.padding = ui.layout.Edges.all(12);
    try tryAppend(&content, a, banner);
    const field = try a.create(W);
    field.* = .{ .name = "services_search", .kind = .{ .text_input = saved orelse .{ .field = .{ .leading_icon = .search }, .placeholder = "Search services…", .value = try gpa.dupe(u8, ""), .owner = cc, .on_change = searchChanged } }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } };
    s.search = field;
    var filters: [5]W = undefined;
    inline for (.{ "All", "Enabled", "Slow", "Disabled", "Failed" }, 0..) |label, i| {
        filters[i] = named(button(cc, label, i, filterClicked, i == 2 and !client.analyzed), label);
        if (@intFromEnum(s.filter) == i) filters[i].kind.button.variant = .primary;
    }
    const search_column: W = .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .children = field[0..1] };
    var filter_row = try group(a, &filters, false);
    filter_row.name = "services_filters";
    filter_row.height = .{ .fixed = 36 };
    filter_row.width = .auto;
    const toolbar = named(try group(a, &.{ search_column, filter_row }, false), "services_toolbar");

    if (client.status().len > 0) try tryAppend(&content, a, text(try a.dupe(u8, client.status()), false));
    if (s.filter == .slow) try tryAppend(&content, a, text("Services taking at least 1 second to activate.", true));
    if (s.selected) |selected| {
        if (client.snapshot.index.get(selected)) |i| {
            const unit = units[i];
            try tryAppend(&content, a, text(try a.dupe(u8, selected), false));
            try tryAppend(&content, a, try group(a, &.{
                named(button(cc, "Start", @intFromEnum(systemd.Action.start), actionClicked, locked or client.busy() or std.mem.eql(u8, unit.active, "active") or std.mem.startsWith(u8, unit.startup, "masked")), "services_start"),
                named(button(cc, "Stop", @intFromEnum(systemd.Action.stop), actionClicked, locked or client.busy() or std.mem.eql(u8, unit.active, "inactive")), "services_stop"),
                named(button(cc, "Restart", @intFromEnum(systemd.Action.restart), actionClicked, locked or client.busy() or std.mem.startsWith(u8, unit.startup, "masked")), "services_restart"),
            }, false));
            if (unit.trigger.len > 0) try tryAppend(&content, a, text(try std.fmt.allocPrint(a, "Activated by: {s}", .{unit.trigger}), true));
        }
    }
    try tryAppend(&content, a, text("Startup settings apply at boot. Deferred is coming later.", true));
    try tryAppend(&content, a, text("Notify sets the service type and applies on its next start. Saving requires administrator authentication.", true));
    if (client.analyzed) try tryAppend(&content, a, text("Boot: from kernel start. Activation times overlap; — means unavailable.", true));

    try tryAppend(&content, a, toolbar);

    const sorted = try a.alloc(usize, units.len);
    var count: usize = 0;
    for (units, 0..) |unit, i| {
        if (!matches(unit, field.kind.text_input.value, s.filter)) continue;
        sorted[count] = i;
        count += 1;
    }
    std.mem.sort(usize, sorted[0..count], SortContext{ .section = s, .units = units }, less);
    var table: std.ArrayList(W) = .empty;
    var headers: [5]W = undefined;
    inline for (.{ "Service", "Status", "Start mode", "Notify", "Startup time" }, 0..) |label, i| {
        headers[i] = try columnHeader(a, cc, s, label, i);
    }
    var header = try group(a, &headers, false);
    header.name = "services_columns";
    header.kind = .{ .rect = .{ .color = ui.theme.global.app_bar } };
    header.gap = 0;
    if (stacked) {
        // The same column widths are used by the wrapped header and rows.
        var details = try group(a, headers[1..], false);
        details.gap = 0;
        if (compact) {
            details = try group(a, &.{ try group(a, headers[1..3], false), try group(a, headers[3..], false) }, true);
            details.gap = 0;
            for (details.children) |*line| line.gap = 0;
        }
        header.children = try a.dupe(W, &.{ headers[0], details });
        header.direction = .column;
        header.@"align" = .stretch;
        header.children[0].width = .{ .percent = 1 };
    }
    try tryAppend(&table, a, header);
    var rows: std.ArrayList(W) = .empty;
    s.rows = try a.alloc(Row, count);
    for (sorted[0..count], 0..) |i, row_index| {
        const unit = units[i];
        const unit_name = try a.dupe(u8, unit.name);
        var title = try group(a, &.{ tableText(unit_name, false), tableText(try a.dupe(u8, unit.description), true) }, true);
        title.gap = 2;
        title.width = .{ .flex = 1 };
        var status_widget = try group(a, &.{ tableText(try a.dupe(u8, unit.active), false), tableText(try a.dupe(u8, unit.sub), true) }, true);
        status_widget.gap = 2;
        if (std.mem.eql(u8, unit.active, "failed")) status_widget.children[0].kind.text.color = ui.theme.global.danger;
        const active = std.mem.eql(u8, unit.active, "active");
        const failed = std.mem.eql(u8, unit.active, "failed");
        status_widget.children[0] = try group(a, &.{
            .{ .kind = .{ .rect = .{ .color = if (failed) ui.theme.global.danger else if (active) ui.theme.global.accent else panel.palette().dim, .radius = 4 } }, .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 } },
            status_widget.children[0],
        }, false);
        status_widget.children[0].gap = 6;
        status_widget.children[0].children[1].width = .{ .flex = 1 };
        const choices: []const []const u8 = if (unit.editable()) &.{ "Enabled", "Disabled", "Deferred" } else try a.dupe([]const u8, &.{try a.dupe(u8, unit.startup)});
        const initial: usize = if (unit.editable() and !unit.enabled()) 1 else 0;
        const type_index = systemd.typeIndex(unit.service_type);
        const notify_labels = if (type_index != null) systemd.service_types else blk: {
            const labels = try a.alloc([]const u8, systemd.service_types.len + 1);
            @memcpy(labels[0..systemd.service_types.len], systemd.service_types);
            labels[systemd.service_types.len] = if (unit.service_type.len > 0) try a.dupe(u8, unit.service_type) else "Unavailable";
            break :blk labels;
        };
        const notify_initial = type_index orelse systemd.service_types.len;
        const selected = if (s.selected) |v| std.mem.eql(u8, v, unit_name) else false;
        var cells: [5]W = undefined;
        cells[0] = try cell(a, title, 0);
        cells[1] = try cell(a, status_widget, 1);
        cells[2] = try cell(a, .{ .name = try std.fmt.allocPrint(a, "startup:{s}", .{unit_name}), .kind = .{ .select = .{ .labels = choices, .disabled_options = if (unit.editable()) &.{2} else &.{}, .selected = initial, .disabled = locked or client.busy() or !unit.editable() } }, .height = .{ .fixed = 34 } }, 2);
        cells[3] = try cell(a, .{ .name = try std.fmt.allocPrint(a, "notify:{s}", .{unit_name}), .kind = .{ .select = .{ .labels = notify_labels, .disabled_options = if (type_index == null) &.{systemd.service_types.len} else &.{}, .selected = notify_initial, .disabled = locked or client.busy() or !unit.typeEditable() } }, .height = .{ .fixed = 34 } }, 3);
        cells[4] = try cell(a, tableText(duration(a, unit.time_us), false), 4);
        s.rows[row_index] = .{ .name = unit_name, .select = &cells[2].children[0], .initial = initial, .notify = &cells[3].children[0], .notify_initial = notify_initial };
        var row = try group(a, &cells, false);
        row.gap = 0;
        if (stacked) {
            var details = try group(a, cells[1..], false);
            details.gap = 0;
            details.height = .{ .fixed = 40 };
            if (compact) {
                details = try group(a, &.{ try group(a, cells[1..3], false), try group(a, cells[3..], false) }, true);
                details.gap = 2;
                for (details.children) |*line| {
                    line.gap = 0;
                    line.height = .{ .fixed = 40 };
                }
            }
            cells[0].width = .{ .percent = 1 };
            cells[0].height = .{ .fixed = 36 };
            row.children = try a.dupe(W, &.{ cells[0], details });
            row.direction = .column;
            row.@"align" = .stretch;
            row.gap = 2;
        }
        row.name = unit_name;
        row.kind = .{ .row = .{ .owner = cc, .id = row_index, .on_click = rowClicked, .selected = selected } };
        const highlight: ui.layout.RectStyle = .{ .color = if (selected) ui.theme.global.app_item_selected else ui.theme.global.app_item_hover, .radius = 6, .border_width = 1, .border_color = if (selected) ui.theme.shellPalette().accent else ui.theme.global.app_item_border };
        row.kind.row.background = if (selected) highlight else .{ .color = .{ 0, 0, 0, 0 } };
        row.kind.row.hover_background = highlight;
        row.padding = ui.layout.Edges.xy(0, 4);
        row.height = .{ .fixed = if (!stacked) 54 else if (compact) 130 else 88 };
        try tryAppend(&rows, a, row);
    }
    if (count == 0) try tryAppend(&rows, a, try placeholder(a, if (client.awaitingList()) "Loading services…" else "No matching services."));
    var body = try group(a, rows.items, true);
    body.gap = 2;
    body.padding = ui.layout.Edges.xy(0, 8);
    try tryAppend(&table, a, body);
    const viewport = try a.create(W);
    viewport.* = try group(a, table.items, true);
    viewport.name = "services_table_scroll";
    viewport.kind = .{ .scroll_container = s.table_scroll };
    viewport.height = .{ .flex = 1 };
    viewport.gap = 0;
    viewport.padding.right = gutter;
    s.table = viewport;
    var table_widget: W = .{ .kind = .container, .direction = .column, .width = .{ .percent = 1 }, .children = viewport[0..1] };
    table_widget.name = "services_table";
    table_widget.kind = .{ .rect = .{ .color = ui.theme.global.app_bg } };
    table_widget.gap = 0;
    table_widget.height = .{ .flex = 1 };
    try tryAppend(&content, a, table_widget);
    var root = try group(a, content.items, true);
    root.height = .{ .flex = 1 };
    return root;
}
fn tryAppend(list: *std.ArrayList(W), a: std.mem.Allocator, widget: W) !void {
    try list.append(a, widget);
}
fn matches(unit: systemd.Unit, query: []const u8, filter: Filter) bool {
    if (std.ascii.indexOfIgnoreCase(unit.name, query) == null and std.ascii.indexOfIgnoreCase(unit.description, query) == null) return false;
    return switch (filter) {
        .all => true,
        .enabled => unit.enabled(),
        .disabled => std.mem.eql(u8, unit.startup, "disabled"),
        .slow => (unit.time_us orelse 0) >= 1_000_000,
        .failed => std.mem.eql(u8, unit.active, "failed"),
    };
}
const SortContext = struct { section: *Section, units: []const systemd.Unit };
fn less(ctx: SortContext, left: usize, right: usize) bool {
    const a = ctx.units[left];
    const b = ctx.units[right];
    var order: std.math.Order = switch (ctx.section.sort) {
        .service => std.mem.order(u8, a.name, b.name),
        .status => std.mem.order(u8, a.active, b.active),
        .startup => std.mem.order(u8, a.startup, b.startup),
        .notify => std.mem.order(u8, a.service_type, b.service_type),
        .time => std.math.order(a.time_us orelse 0, b.time_us orelse 0),
    };
    if (order == .eq) order = std.mem.order(u8, a.name, b.name);
    return if (ctx.section.descending) order == .gt else order == .lt;
}
pub fn apply(s: *Section, cc: *panel.ControlCenter) void {
    const client = cc.systemd_client orelse return;
    for (s.rows) |*row| {
        const notify = row.notify.kind.select.selected;
        if (notify != row.notify_initial) {
            row.notify.kind.select.selected = row.notify_initial;
            if (notify) |index| client.setType(row.name, index);
            return;
        }
        const selected = row.select.kind.select.selected;
        if (selected == row.initial) continue;
        row.select.kind.select.selected = row.initial;
        if (selected) |index| {
            if (index < 2) client.act(row.name, if (index == 0) .enable else .disable);
        }
        return;
    }
}
fn owner(ctx: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(ctx.?));
}
fn noop(_: ?*anyopaque, _: usize) void {}
fn lockClicked(ctx: ?*anyopaque, _: usize) void {
    const client = owner(ctx).systemd_client orelse return;
    if (client.unlocked) client.lock() else client.unlock();
}
fn analyze(ctx: ?*anyopaque, _: usize) void {
    if (owner(ctx).systemd_client) |client| client.analyze();
}
fn refresh(ctx: ?*anyopaque, _: usize) void {
    if (owner(ctx).systemd_client) |client| client.refresh();
}
fn filterClicked(ctx: ?*anyopaque, id: usize) void {
    const cc = owner(ctx);
    cc.services.filter = @enumFromInt(id);
    cc.refresh();
}
fn sortClicked(ctx: ?*anyopaque, id: usize) void {
    const cc = owner(ctx);
    const sort: Sort = @enumFromInt(id);
    cc.services.descending = if (cc.services.sort == sort) !cc.services.descending else sort == .time;
    cc.services.sort = sort;
    cc.refresh();
}
fn rowClicked(ctx: ?*anyopaque, id: usize) void {
    const cc = owner(ctx);
    if (id >= cc.services.rows.len) return;
    const selected = gpa.dupe(u8, cc.services.rows[id].name) catch return;
    if (cc.services.selected) |old| gpa.free(old);
    cc.services.selected = selected;
    cc.refresh();
}
fn actionClicked(ctx: ?*anyopaque, id: usize) void {
    const cc = owner(ctx);
    const client = cc.systemd_client orelse return;
    client.act(cc.services.selected orelse return, @enumFromInt(id));
}
fn searchChanged(ctx: ?*anyopaque, _: usize, _: []const u8) void {
    owner(ctx).refresh();
}

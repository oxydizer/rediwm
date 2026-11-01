//! Printer setup, queue settings and explicit diagnostic print workflows.
const i18n = @import("i18n");
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const printing = @import("../../printing/client.zig");
const cups = @import("../../printing/cups.zig");
const ladder = @import("../../printing/ladder.zig");
const usb = @import("../../printing/usb_sysfs.zig");
const admin = @import("../../printing/admin.zig");
const setup = @import("../../printing/setup.zig");
const tools = @import("../../printing/tools.zig");
const preferences = @import("../../printing/preferences.zig");
const known = @import("../../printing/known_devices.zig");
const notifier = @import("../../printing/notifier.zig");
const driver_options = @import("../../printing/options.zig");
const secure = @import("../../network/secure_allocator.zig").allocator;
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const Form = enum { none, add, connection, remove, test_confirm, test_result, queue_rename };
pub const Disclosure = enum { history, more_options, manage, troubleshooting, label_tools, devices };
pub const Field = enum { address, name, rename, loaded_width, loaded_height, measured_width, measured_height, raw_dpi, queue_name, auth_user };
const field_names = [_][]const u8{ "printers_address", "printers_name", "printers_rename", "printers_loaded_width", "printers_loaded_height", "printers_measured_width", "printers_measured_height", "printers_raw_dpi", "printers_queue_name", "printers_auth_user" };
const Input = struct { widget: ?*W = null, data: ?ui.layout.TextInputData = null };
const RangeDraft = struct { name: [128]u8 = undefined, len: usize = 0, range: cups.ipp.Range = .{ .lower = 0, .upper = 0 }, value: f32 = 0 };
pub const PendingAdd = struct {
    arena: std.heap.ArenaAllocator,
    arguments: admin.Add,
    pub fn destroy(self: *PendingAdd) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};
pub const PendingRename = struct { old: [128]u8 = undefined, old_len: usize = 0, new: [128]u8 = undefined, new_len: usize = 0, after_admin: bool = false };
pub const PendingOption = struct { queue: [128]u8 = undefined, queue_len: usize = 0, key: [128]u8 = undefined, key_len: usize = 0, value: [1024]u8 = undefined, value_len: usize = 0, ppd: bool = false, after_admin: bool = false };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    client: ?*printing.Client = null,
    administration: ?*admin.Manager = null,
    password: ui.widgets.secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    password_focus: bool = false,
    listener: ?*notifier.Listener = null,
    listener_attempted: bool = false,
    admin_generation: u64 = 0,
    form: Form = .none,
    fields: [field_names.len]Input = @splat(.{}),
    focused_field: ?Field = null,
    message: []const u8 = "",
    driver_index: usize = 0,
    driver_name: [1024]u8 = undefined,
    driver_name_len: usize = 0,
    pending_add: ?*PendingAdd = null,
    pending_rename: ?PendingRename = null,
    pending_option: ?PendingOption = null,
    migration_pending: bool = false,
    queue_refs: []const []const u8 = &.{},
    driver_refs: []const []const u8 = &.{},
    device_refs: []const admin.Device = &.{},
    ranges: [16]RangeDraft = @splat(.{}),
    range_count: usize = 0,
    add_discovered: bool = false,
    add_device_id: [8192]u8 = undefined,
    add_device_len: usize = 0,
    language: ?tools.Language = null,
    test_kind: printing.TestKind = .driver,
    inches: bool = false,
    suggested: ?cups.ipp.Resolution = null,
    expanded: [@typeInfo(Disclosure).@"enum".field_names.len]bool = @splat(false),
    history_limit: usize = 5,
    expanded_job: ?i32 = null,
    reveal_target: ?[]const u8 = null,
    fields_for: [512]u8 = undefined,
    fields_for_len: usize = 0,
    probe_address: [8192]u8 = undefined,
    probe_address_len: usize = 0,
    option_refs: []const @import("../../printing/options.zig").Option = &.{},
    selected: [512]u8 = undefined,
    selected_len: usize = 0,
    copied: bool = false,
    pub fn capture(self: *Section) void {
        self.focused_field = null;
        self.password_focus = false;
        if (ui.input.current.focused) |focused| {
            if (focused.name) |name| self.password_focus = std.mem.eql(u8, name, "printers_auth_password");
            for (self.fields, 0..) |field, i| if (field.widget == focused) {
                self.focused_field = @enumFromInt(i);
            };
        }
    }
    fn saveFields(self: *Section) void {
        for (&self.fields) |*field| {
            if (field.widget) |widget| field.data = widget.kind.text_input;
            field.widget = null;
        }
    }
    pub fn restoreFocus(self: *Section, cc: *panel.ControlCenter) void {
        if (self.password_focus) if (findNamed(&self.root, "printers_auth_password")) |widget| ui.input.current.focus(&cc.root, widget);
        if (self.focused_field) |id| if (self.fields[@intFromEnum(id)].widget) |widget| ui.input.current.focus(&cc.root, widget);
        if (self.reveal_target) |name| {
            if (findNamed(&self.root, name)) |widget| ui.widgets.scroll_container.ensureVisibleChild(&cc.body_children[1], widget);
            self.reveal_target = null;
        }
    }
    pub fn hide(self: *Section) void {
        self.password.clear();
        self.password_focus = false;
        self.saveFields();
        if (self.pending_add) |pending| pending.destroy();
        self.pending_add = null;
        self.pending_rename = null;
        self.pending_option = null;
        self.migration_pending = false;
        if (self.administration) |manager| manager.destroy();
        self.administration = null;
        if (self.client) |client| client.destroy();
        self.client = null;
        if (self.listener) |listener| listener.destroy();
        self.listener = null;
        self.listener_attempted = false;
        self.form = .none;
        self.focused_field = null;
        self.copied = false;
        self.reveal_target = null;
    }
    pub fn deinit(self: *Section) void {
        self.hide();
        for (self.fields) |field| if (field.data) |data| gpa.free(data.value);
        if (self.password.storage.len != 0) secure.free(self.password.storage);
        self.arena.deinit();
    }
};

pub fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = t.app_text_size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } }, .width = .{ .percent = 1 } };
}
fn findNamed(root: *W, name: []const u8) ?*W {
    if (root.name) |value| if (std.mem.eql(u8, value, name)) return root;
    for (root.children) |*child| if (findNamed(child, name)) |found| return found;
    return null;
}
pub fn named(value: W, name: []const u8) W {
    var result = value;
    result.name = name;
    return result;
}
pub fn group(a: A, items: []const W) !W {
    return .{ .kind = .container, .direction = .column, .gap = 10, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
pub fn card(a: A, items: []const W) !W {
    var result = try group(a, items);
    const t = panel.palette();
    result.kind = .{ .rect = .{ .color = t.app_item, .radius = t.settings_card_radius, .border_width = 1, .border_color = t.app_item_border, .relief = t.settings_card_relief } };
    result.padding = ui.layout.Edges.all(14);
    return result;
}
pub fn button(cc: *panel.ControlCenter, name: []const u8, label: []const u8, id: usize, disabled: bool, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = callback, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
pub fn isOpen(self: *const Section, which: Disclosure) bool {
    return self.expanded[@intFromEnum(which)];
}
pub fn disclosure(self: *Section, cc: *panel.ControlCenter, name: []const u8, label: []const u8, which: Disclosure) W {
    var result = button(cc, name, label, @intFromEnum(which), false, disclosureClicked);
    result.width = .{ .percent = 1 };
    result.kind.button.variant = .ghost;
    result.kind.button.trailing_icon = if (isOpen(self, which)) .chevron_down else .chevron_right;
    return result;
}
fn disclosureClicked(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    cc.printers.expanded[id] = !cc.printers.expanded[id];
    cc.refresh();
}
pub fn actionRow(a: A, cc: *panel.ControlCenter, items: []const W) !W {
    var result = try group(a, items);
    if (cc.panel_box.width >= 760) {
        result.direction = .row;
        result.@"align" = .center;
        for (result.children) |*child| child.width = .{ .flex = 1 };
    }
    return result;
}
fn changed(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    cc.printers.copied = false;
    if (cc.printers.pending_add != null and !cc.printers.client.?.busy) finishCreate(cc);
    if (cc.printers.pending_rename) |pending| if (!cc.printers.client.?.busy) {
        if (pending.after_admin) finishRename(cc) else submitRename(cc);
    };
    if (cc.printers.migration_pending and !cc.printers.client.?.busy) {
        cc.printers.fields_for_len = 0;
        cc.printers.migration_pending = false;
    }
    if (cc.printers.pending_option) |pending| if (pending.after_admin and !cc.printers.client.?.busy) verifyOption(cc);
    cc.refresh();
}
fn adminChanged(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    if (cc.printers.administration) |manager| if (manager.generation != cc.printers.admin_generation) {
        cc.printers.admin_generation = manager.generation;
        cc.printers.form = .none;
        if (cc.printers.pending_rename) |*pending| pending.after_admin = true;
        if (cc.printers.pending_option) |*pending| pending.after_admin = true;
        if (cc.printers.client) |client| client.act(.refresh) catch client.invalidate();
    };
    if (cc.printers.administration) |manager| if (!manager.authentication) {
        cc.printers.password.clear();
    };
    cc.refresh();
}
fn authenticateClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const self = &cc.printers;
    const manager = self.administration orelse return;
    manager.authenticate(fieldValue(self, .auth_user), self.password.value()) catch {
        self.message = i18n.tr("Enter a valid CUPS administrator username and password.");
        self.password.clear();
        cc.refresh();
        return;
    };
    self.password.clear();
    self.message = "";
    cc.refresh();
}
fn cancelAuthenticationClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.printers.password.clear();
    if (cc.printers.administration) |manager| manager.cancelAuthentication();
    cc.refresh();
}
fn cupsChanged(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    if (cc.printers.client) |client| client.invalidate();
}
pub fn build(self: *Section, cc: *panel.ControlCenter) void {
    self.saveFields();
    self.option_refs = &.{};
    self.queue_refs = &.{};
    self.driver_refs = &.{};
    self.device_refs = &.{};
    _ = self.arena.reset(.retain_capacity);
    self.root = tree(self, cc, self.arena.allocator()) catch panel.outOfMemory();
    const width: f32 = @floatFromInt(cc.panel_box.width - @as(i32, if (cc.panel_box.width < 660) 140 else 308));
    wrapLabels(self.arena.allocator(), &self.root, @max(width, 80)) catch {};
}
/// Widget text is single-line. Explanatory paragraphs become ordinary shared
/// text widgets so long diagnostic reasons remain readable at narrow widths.
fn wrapLabels(a: A, widget: *W, available: f32) !void {
    const width = switch (widget.width) {
        .fixed => |v| v,
        .percent => |v| available * v,
        else => available,
    };
    const inner = @max(40, width - widget.padding.left - widget.padding.right);
    if (widget.kind == .text and widget.name == null) {
        const style = widget.kind.text;
        const font: ui.text.Font = if (style.family == .mono) .mono else if (style.weight >= 700) .manrope_heavy else if (style.weight >= 600) .manrope_bold else .manrope;
        if ((ui.text.measureWidthF(style.content, font, style.font_size, 1) catch 0) <= inner) return;
        var lines: std.ArrayList(W) = .empty;
        var start: usize = 0;
        var last_space: ?usize = null;
        for (style.content, 0..) |ch, i| {
            if (ch != ' ') continue;
            if ((ui.text.measureWidthF(style.content[start..i], font, style.font_size, 1) catch 0) > inner) {
                const end = last_space orelse i;
                var line = style;
                line.content = style.content[start..end];
                try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
                start = end + 1;
                last_space = null;
            }
            last_space = i;
        }
        if (start < style.content.len) {
            if ((ui.text.measureWidthF(style.content[start..], font, style.font_size, 1) catch 0) > inner) if (last_space) |end| {
                if (end > start) {
                    var line = style;
                    line.content = style.content[start..end];
                    try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
                    start = end + 1;
                }
            };
            var line = style;
            line.content = style.content[start..];
            try lines.append(a, .{ .kind = .{ .text = line }, .width = .{ .percent = 1 } });
        }
        widget.kind = .container;
        widget.direction = .column;
        widget.gap = 2;
        widget.children = try lines.toOwnedSlice(a);
        return;
    }
    var fixed: f32 = 0;
    var flex: usize = 0;
    if (widget.direction == .row) for (widget.children) |child| {
        switch (child.width) {
            .fixed => |v| fixed += v,
            else => flex += 1,
        }
    };
    const share = if (flex > 0) @max(40, (inner - fixed - widget.gap * @as(f32, @floatFromInt(widget.children.len -| 1))) / @as(f32, @floatFromInt(flex))) else inner;
    for (widget.children) |*child| try wrapLabels(a, child, if (widget.direction == .row and child.width != .fixed) share else inner);
}
fn tree(self: *Section, cc: *panel.ControlCenter, a: A) !W {
    if (cc.server.greeter_mode) return text(i18n.tr("Printers are unavailable in the greeter."), true);
    if (self.client == null) self.client = printing.Client.create(cc.server.io, cc.server.environ, cc.server.wl_server.getEventLoop(), cc, changed) catch return text(i18n.tr("Could not start printer diagnostics."), true);
    const client = self.client.?;
    var content: std.ArrayList(W) = .empty;
    const state = client.current;
    if (state) |snapshot| if (snapshot.admin_local) {
        if (self.administration == null) self.administration = admin.Manager.create(cc.server.wl_server.getEventLoop(), cc.server.environ, cc, adminChanged) catch null;
        if (!self.listener_attempted) {
            self.listener_attempted = true;
            self.listener = notifier.Listener.create(gpa, cc.server.io, cc.server.environ, cc.server.wl_server.getEventLoop(), cc, cupsChanged) catch null;
        }
        if (self.listener) |listener| if (listener.ready) client.enableSubscriptions();
    };
    if (state) |snapshot| if (!snapshot.admin_local) {
        if (self.administration) |manager| manager.destroy();
        self.administration = null;
        if (self.listener) |listener| listener.destroy();
        self.listener = null;
        self.listener_attempted = false;
    };
    const failure: ?anyerror = if (client.failure) |err| err else if (state) |snapshot| if (snapshot.failure) |err| err else snapshot.action_error else null;
    const status = if (client.busy) i18n.tr("Loading printers…") else if (failure) |err| cups.failure(err) else i18n.tr("Connected to CUPS.");
    if (client.busy or failure != null) try content.append(a, named(text(status, true), "printers_status"));
    try content.append(a, try actionRow(a, cc, &.{
        button(cc, "printers_add", i18n.tr("Add a printer"), 0, !canAdmin(self) or busy(self), addClicked),
        button(cc, "printers_refresh", i18n.tr("Refresh"), 0, client.busy, refresh),
    }));
    if (self.message.len > 0) try content.append(a, text(self.message, false));
    if (self.administration) |manager| {
        if (manager.status.len != 0) try content.append(a, text(manager.status, true));
        if (manager.authentication) {
            if (self.password.storage.len == 0) {
                self.password.storage = try secure.alloc(u8, 4095);
                @memset(self.password.storage, 0);
            }
            const username = try cups.user(a);
            try content.append(a, try card(a, &.{
                text(i18n.tr("Authorize printer administration"), false),
                text(i18n.tr("Enter an account permitted to administer the local CUPS server."), true),
                try entry(self, cc, a, .auth_user, i18n.tr("Username"), username),
                .{ .name = "printers_auth_password", .kind = .{ .secret_input = .{ .placeholder = i18n.tr("Password"), .input = &self.password } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } },
                try actionRow(a, cc, &.{
                    button(cc, "printers_auth_submit", i18n.tr("Authenticate"), 0, false, authenticateClicked),
                    button(cc, "printers_auth_cancel", i18n.tr("Cancel"), 0, false, cancelAuthenticationClicked),
                }),
            }));
        }
    } else try content.append(a, text(i18n.tr("Printer setup requires the local default CUPS server."), true));
    if (state) |snapshot| {
        if (snapshot.action_error) |err| try content.append(a, text(cups.failure(err), false));
        if (snapshot.failure != null) {
            try content.append(a, text(snapshot.platform.missing_cups, true));
            try content.append(a, button(cc, "printers_start", i18n.tr("Start CUPS"), 0, !snapshot.admin_local or busy(self) or self.administration == null, startClicked));
        }

        if (self.form == .add or self.form == .connection) try content.append(a, try addForm(self, cc, a, snapshot));
        if (snapshot.cups) |data| {
            if (data.printers.len == 0) {
                try content.append(a, text(i18n.tr("No printers configured."), false));
            } else {
                const selected = selectIndex(self, data.printers);
                const labels = try a.alloc([]const u8, data.printers.len);
                const queue_refs = try a.alloc([]const u8, data.printers.len);
                for (data.printers, 0..) |printer, i| {
                    queue_refs[i] = try a.dupe(u8, printer.name);
                    labels[i] = try std.fmt.allocPrint(a, "{s} · {s}{s}", .{ printer.name, cups.printerState(printer.state), if (std.mem.eql(u8, printer.name, data.user_default)) i18n.tr(" · Default") else if (printer.is_default) i18n.tr(" · System default") else "" });
                }
                self.queue_refs = queue_refs;
                try content.append(a, try group(a, &.{
                    text(i18n.tr("Printer"), false),
                    .{ .name = "printers_printer", .kind = .{ .select = .{ .labels = labels, .selected = selected, .disabled = busy(self), .owner = cc, .on_change = select } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } },
                }));
                try details(self, cc, a, &content, snapshot, data, data.printers[selected]);
            }
        }
        // Attached printers can still be inspected if CUPS is missing or empty.
        if (snapshot.usb) |inventory| if (inventory.devices.len > 0) {
            var devices: std.ArrayList(W) = .empty;
            try devices.append(a, disclosure(self, cc, "printers_devices", i18n.tr("Attached USB printers"), .devices));
            if (isOpen(self, .devices)) for (inventory.devices) |device| {
                try devices.append(a, text(try std.fmt.allocPrint(a, "{s} {s} ({x:0>4}:{x:0>4})", .{ device.manufacturer, device.product, device.vid, device.pid }), true));
                if (known.lookup(device.vid, device.pid)) |hint| {
                    try devices.append(a, text(hint.note, true));
                    try devices.append(a, text(hint.driver_project, true));
                }
                if (device.nodes.len == 0) try devices.append(a, text(i18n.tr("No usblp node was found; CUPS may still use libusb or ipp-usb."), true));
            };
            try content.append(a, try card(a, devices.items));
        };
    }
    return group(a, content.items);
}
fn selectIndex(self: *Section, printers: []const cups.Printer) usize {
    for (printers, 0..) |printer, i| if (std.mem.eql(u8, printer.name, self.selected[0..self.selected_len])) return i;
    self.form = .none;
    self.expanded[@intFromEnum(Disclosure.history)] = false;
    self.history_limit = 5;
    self.expanded_job = null;
    self.selected_len = @min(printers[0].name.len, self.selected.len);
    @memcpy(self.selected[0..self.selected_len], printers[0].name[0..self.selected_len]);
    return 0;
}

const printers_details = @import("printers_details.zig");
pub const resolution = printers_details.resolution;
pub const diagnostic = printers_details.diagnostic;
const details = printers_details.details;
pub fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}

const printers_actions = @import("printers_actions.zig");
const refresh = printers_actions.refresh;
const select = printers_actions.select;
pub const cancel = printers_actions.cancel;
pub const copy = printers_actions.copy;
const startClicked = printers_actions.startClicked;
pub const resumeClicked = printers_actions.resumeClicked;
pub const disableClicked = printers_actions.disableClicked;
pub const acceptingClicked = printers_actions.acceptingClicked;
pub const defaultClicked = printers_actions.defaultClicked;
pub const systemDefaultClicked = printers_actions.systemDefaultClicked;
pub const renameClicked = printers_actions.renameClicked;
pub const removeClicked = printers_actions.removeClicked;
pub const removeConfirm = printers_actions.removeConfirm;
pub const optionChanged = printers_actions.optionChanged;
pub const changeOption = printers_actions.changeOption;
const verifyOption = printers_actions.verifyOption;
pub const rangeChanged = printers_actions.rangeChanged;
pub const rangeApply = printers_actions.rangeApply;
pub fn busy(self: *Section) bool {
    return (if (self.client) |client| client.busy else true) or (if (self.administration) |manager| manager.busy else false);
}
pub fn canAdmin(self: *Section) bool {
    const client = self.client orelse return false;
    const state = client.current orelse return false;
    const manager = self.administration orelse return false;
    return state.admin_local and client.failure == null and state.failure == null and state.cups != null and manager.availability == .available;
}
pub fn chosen(cc: *panel.ControlCenter) ?cups.Printer {
    if (!std.mem.eql(u8, cc.printers.selected[0..cc.printers.selected_len], cc.printers.fields_for[0..cc.printers.fields_for_len])) return null;
    const client = cc.printers.client orelse return null;
    const state = client.current orelse return null;
    const data = state.cups orelse return null;
    for (data.printers) |printer| if (std.mem.eql(u8, printer.name, cc.printers.selected[0..cc.printers.selected_len])) return printer;
    return null;
}
pub fn fieldValue(self: *Section, id: Field) []const u8 {
    const input = self.fields[@intFromEnum(id)];
    return if (input.widget) |widget| widget.kind.text_input.value else if (input.data) |data| data.value else "";
}
pub fn setField(self: *Section, id: Field, text_value: []const u8) !void {
    const input = &self.fields[@intFromEnum(id)];
    const copy_value = try gpa.dupe(u8, text_value);
    if (input.widget) |widget| input.data = widget.kind.text_input;
    if (input.data) |*data| {
        gpa.free(data.value);
        data.value = copy_value;
        data.cursor_pos = copy_value.len;
        data.selection_anchor = null;
        if (input.widget) |widget| widget.kind.text_input = data.*;
    } else input.data = .{ .owner = null, .id = @intFromEnum(id), .placeholder = "", .value = copy_value, .cursor_pos = copy_value.len, .on_change = fieldChanged };
}
pub fn entry(self: *Section, cc: *panel.ControlCenter, a: A, id: Field, label: []const u8, initial: []const u8) !W {
    const input = &self.fields[@intFromEnum(id)];
    if (input.data == null) try setField(self, id, initial);
    var data = input.data.?;
    data.owner = cc;
    data.id = @intFromEnum(id);
    data.placeholder = label;
    data.on_change = fieldChanged;
    const widget: W = .{ .name = field_names[@intFromEnum(id)], .kind = .{ .text_input = data }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
    const container = try group(a, &.{ text(label, true), widget });
    input.widget = &container.children[1];
    return container;
}
fn fieldChanged(raw: ?*anyopaque, id: usize, _: []const u8) void {
    const cc = owner(raw);
    if (id == @intFromEnum(Field.address)) {
        cc.printers.add_discovered = false;
        cc.printers.probe_address_len = 0;
        cc.printers.add_device_len = 0;
        cc.printers.driver_name_len = 0;
        cc.printers.driver_index = 0;
    }
    cc.printers.suggested = null;
    cc.refresh();
}
pub fn queueNames(a: A, data: cups.Snapshot) ![]const []const u8 {
    const names = try a.alloc([]const u8, data.printers.len);
    for (data.printers, 0..) |printer, i| names[i] = printer.name;
    return names;
}
pub fn runAdmin(cc: *panel.ControlCenter, action: admin.Action) void {
    if (busy(&cc.printers) or (action != .start_service and !canAdmin(&cc.printers))) return;
    if (action == .start_service) {
        const client = cc.printers.client orelse return;
        const state = client.current orelse return;
        if (!state.admin_local) return;
    }
    const manager = cc.printers.administration orelse return;
    manager.request(action) catch |err| {
        cc.printers.message = switch (err) {
            error.QueueExists => i18n.tr("A printer with this queue name already exists. Choose another name."),
            error.InvalidName => i18n.tr("Use letters, numbers, dots, hyphens or underscores for the queue name."),
            error.InvalidUri, error.UnsupportedScheme => i18n.tr("Enter a supported printer address without credentials."),
            error.UntrustedDevice => i18n.tr("Find available printers again and choose the current discovered device."),
            else => i18n.tr("The printer change could not be requested."),
        };
    };
    cc.refresh();
}
pub fn runClient(cc: *panel.ControlCenter, action: printing.Action) void {
    const client = cc.printers.client orelse return;
    client.act(action) catch {
        cc.printers.message = i18n.tr("Wait for the current printer operation to finish.");
    };
    cc.refresh();
}
pub fn dismiss(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.printers.form = .none;
    cc.refresh();
}

const printers_add = @import("printers_add.zig");
const addClicked = printers_add.addClicked;
const addForm = printers_add.addForm;
pub const connectionClicked = printers_add.connectionClicked;
const finishCreate = printers_add.finishCreate;
pub const queueRenameClicked = printers_add.queueRenameClicked;
pub const queueRenameConfirm = printers_add.queueRenameConfirm;
const submitRename = printers_add.submitRename;
const finishRename = printers_add.finishRename;

const printers_tools = @import("printers_tools.zig");
pub const mediaFor = printers_tools.mediaFor;
pub const toolsForm = printers_tools.toolsForm;
pub const testClicked = printers_tools.testClicked;

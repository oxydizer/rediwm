//! SSH view state. File contents never enter the compositor: the helper
//! publishes public identities, paths and health metadata only.
const std = @import("std");
const i18n = @import("i18n");
const ui = @import("ui");
const panel = @import("../panel.zig");
const client = @import("../../keys/client.zig");
const model = @import("keys").model;
const secure = @import("../../network/secure_allocator.zig").allocator;
const gpa = @import("../../main.zig").gpa;
pub const W = ui.layout.Widget;
pub const A = std.mem.Allocator;
pub const Form = enum { none, generate, passphrase, comment, label, trash };
pub const Field = enum { name, comment, label };
pub const field_names = [_][]const u8{ "keys_name", "keys_comment", "keys_label" };
const Input = struct { widget: ?*W = null, data: ?ui.layout.TextInputData = null };
pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    client: ?*client.Client = null,
    items: []const model.Item = &.{},
    selected: [64]u8 = undefined,
    selected_len: usize = 0,
    location: usize = 0,
    form: Form = .none,
    message: []const u8 = "",
    fields: [field_names.len]Input = @splat(.{}),
    old: ui.widgets.secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    password: ui.widgets.secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    confirm: ui.widgets.secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    focused: [64]u8 = undefined,
    focused_len: usize = 0,
    pub fn clearSecrets(self: *Section) void {
        self.old.clear();
        self.password.clear();
        self.confirm.clear();
    }
    fn saveFields(self: *Section) void {
        for (&self.fields) |*field| {
            if (field.widget) |widget| field.data = widget.kind.text_input;
            field.widget = null;
        }
    }
    pub fn capture(self: *Section) void {
        self.focused_len = 0;
        if (ui.input.current.focused) |widget| if (widget.name) |name| {
            if (std.mem.startsWith(u8, name, "keys_") and name.len <= self.focused.len) {
                @memcpy(self.focused[0..name.len], name);
                self.focused_len = name.len;
            }
        };
    }
    pub fn restoreFocus(self: *Section, cc: *panel.ControlCenter) void {
        if (self.focused_len > 0) if (find(&self.root, self.focused[0..self.focused_len])) |widget| ui.input.current.focus(&cc.root, widget);
    }
    pub fn hide(self: *Section) void {
        self.clearSecrets();
        self.saveFields();
        if (self.client) |worker| worker.destroy();
        self.client = null;
        self.form = .none;
        self.focused_len = 0;
        self.items = &.{};
        self.message = "";
    }
    pub fn deinit(self: *Section) void {
        self.hide();
        for (self.fields) |field| if (field.data) |data| gpa.free(data.value);
        for ([_]*ui.widgets.secret_input.Input{ &self.old, &self.password, &self.confirm }) |input| if (input.storage.len > 0) secure.free(input.storage);
        self.arena.deinit();
    }
};
fn find(root: *W, name: []const u8) ?*W {
    if (root.name) |value| if (std.mem.eql(u8, name, value)) return root;
    for (root.children) |*child| if (find(child, name)) |found| return found;
    return null;
}
pub fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}
pub fn text(value: []const u8, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = t.app_text_size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } }, .width = .{ .percent = 1 } };
}
pub fn group(a: A, items: []const W) !W {
    return .{ .kind = .container, .direction = .column, .gap = 10, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
pub fn card(a: A, items: []const W) !W {
    return panel.card(try a.dupe(W, items));
}
pub fn actions(a: A, items: []const W) !W {
    var row = try group(a, items);
    row.direction = .row;
    for (row.children) |*child| child.width = .{ .flex = 1 };
    return row;
}
pub fn button(cc: *panel.ControlCenter, name: []const u8, label: []const u8, id: usize, disabled: bool, callback: *const fn (?*anyopaque, usize) void) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = callback, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } };
}
pub fn chosen(self: *const Section) ?model.Item {
    for (self.items) |item| if (std.mem.eql(u8, item.fingerprint, self.selected[0..self.selected_len])) return item;
    return null;
}
pub fn location(self: *const Section, item: model.Item) model.Location {
    return item.locations[@min(self.location, item.locations.len - 1)];
}
pub fn busy(self: *const Section) bool {
    return if (self.client) |worker| worker.busy else false;
}
fn changed(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    cc.key_settings.clearSecrets();
    cc.refresh();
}
pub fn build(self: *Section, cc: *panel.ControlCenter) void {
    self.saveFields();
    _ = self.arena.reset(.retain_capacity);
    self.items = &.{};
    self.root = @import("keys_ssh.zig").tree(self, cc, self.arena.allocator()) catch panel.outOfMemory();
    const width = @max(80, @as(f32, @floatFromInt(cc.panel_box.width)) - panel.sidebarWidth(cc) - 80);
    wrap(self.arena.allocator(), &self.root, width) catch {};
}
fn wrap(a: A, widget: *W, width: f32) !void {
    const inner = @max(40, width - widget.padding.left - widget.padding.right);
    if (widget.kind == .text and ui.measure.textNatural(widget.kind.text.content, .sans, widget.kind.text.weight, widget.kind.text.font_size).w > inner) {
        const style = widget.kind.text;
        const name = widget.name;
        widget.* = try panel.paragraph(a, style.content, inner, style.font_size, style.weight < 600);
        widget.name = name;
        for (widget.children) |*child| child.kind.text.color = style.color;
        return;
    }
    const share = if (widget.direction == .row and widget.children.len > 0) (inner - widget.gap * @as(f32, @floatFromInt(widget.children.len - 1))) / @as(f32, @floatFromInt(widget.children.len)) else inner;
    for (widget.children) |*child| try wrap(a, child, share);
}
pub fn start(self: *Section, cc: *panel.ControlCenter) !void {
    if (cc.server.greeter_mode) return error.Greeter;
    if (self.client == null) self.client = try client.Client.create(cc.server.io, cc.server.wl_server.getEventLoop(), cc, changed);
}
pub fn copyInventory(self: *Section, a: A, inventory: model.Inventory) !void {
    const items = try a.dupe(model.Item, inventory.items);
    for (items) |*item| {
        inline for (.{ "fingerprint", "algorithm", "public_key", "comment", "label" }) |field| @field(item, field) = try a.dupe(u8, @field(item, field));
        const locations = try a.dupe(model.Location, item.locations);
        for (locations) |*place| place.path = try a.dupe(u8, place.path);
        item.locations = locations;
    }
    self.items = items;
}
pub fn failure(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "KeygenFailed")) return i18n.tr("The key could not be changed. Check the current passphrase.");
    if (std.mem.eql(u8, value, "PathAlreadyExists")) return i18n.tr("A file already exists at that location. Choose another name.");
    if (std.mem.eql(u8, value, "FileChanged")) return i18n.tr("The key changed since it was selected. Refresh and try again.");
    if (std.mem.eql(u8, value, "InvalidPath")) return i18n.tr("Enter a filename without slashes or a leading dot.");
    if (std.mem.eql(u8, value, "MissingKeygen")) return i18n.tr("Install OpenSSH to generate or change keys.");
    if (std.mem.eql(u8, value, "InvalidText") or std.mem.eql(u8, value, "InvalidPassphrase")) return i18n.tr("Use at most 512 bytes without line breaks or control characters.");
    if (std.mem.eql(u8, value, "MissingTrashTool")) return i18n.tr("Install gio to move keys to Trash.");
    return i18n.tr("The key operation could not be completed. Refresh and try again.");
}
pub const cancel = @import("keys_forms.zig").cancel;

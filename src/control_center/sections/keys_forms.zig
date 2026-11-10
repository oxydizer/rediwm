//! Shared text/secret widgets over persistent drafts and locked secret storage.
const std = @import("std");
const i18n = @import("i18n");
const ui = @import("ui");
const panel = @import("../panel.zig");
const protocol = @import("keys").protocol;
const s = @import("keys.zig");
const gpa = @import("../../main.zig").gpa;
const secure = @import("../../network/secure_allocator.zig").allocator;

pub fn open(raw: ?*anyopaque, id: usize) void {
    const cc = s.owner(raw);
    const self = &cc.key_settings;
    if (s.busy(self)) return;
    const form: s.Form = @fromBackingInt(@intCast(id));
    const item = s.chosen(self);
    if (form != .generate and item == null) return;
    self.clearSecrets();
    self.message = "";
    switch (form) {
        .generate => {
            setField(self, .name, "id_ed25519") catch return;
            setField(self, .comment, "") catch return;
        },
        .comment => setField(self, .comment, item.?.comment) catch return,
        .label => setField(self, .label, item.?.label) catch return,
        else => {},
    }
    self.form = form;
    cc.refresh();
}
pub fn cancel(raw: ?*anyopaque, _: usize) void {
    const cc = s.owner(raw);
    cc.key_settings.clearSecrets();
    cc.key_settings.form = .none;
    cc.key_settings.message = "";
    cc.refresh();
}
fn secret(input: *ui.widgets.secret_input.Input, name: []const u8, placeholder: []const u8) !s.W {
    if (input.storage.len == 0) {
        input.storage = try secure.alloc(u8, 1024);
        @memset(input.storage, 0);
    }
    return .{ .name = name, .kind = .{ .secret_input = .{ .placeholder = placeholder, .input = input } }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } };
}
pub fn build(self: *s.Section, cc: *panel.ControlCenter, a: s.A) !s.W {
    var widgets: std.ArrayList(s.W) = .empty;
    const item = s.chosen(self);
    const encrypted = if (item) |key| s.location(self, key).encrypted else false;
    switch (self.form) {
        .generate => {
            try widgets.append(a, panel.sectionTitle(i18n.tr("New Ed25519 key")));
            try widgets.append(a, try entry(self, cc, a, .name, i18n.tr("Filename in ~/.ssh")));
            try widgets.append(a, try entry(self, cc, a, .comment, i18n.tr("Comment")));
        },
        .passphrase => try widgets.append(a, panel.sectionTitle(i18n.tr("Change passphrase"))),
        .comment => try widgets.append(a, try entry(self, cc, a, .comment, i18n.tr("Comment"))),
        .label => {
            try widgets.append(a, try entry(self, cc, a, .label, i18n.tr("Label")));
            try widgets.append(a, s.text(i18n.tr("Labels apply to every copy of this public fingerprint."), true));
        },
        .trash => {
            try widgets.append(a, panel.sectionTitle(i18n.tr("Move this key to Trash?")));
            try widgets.append(a, s.text(item.?.fingerprint, false));
            try widgets.append(a, try panel.paragraph(a, s.location(self, item.?).path, 420, panel.palette().app_text_size, true));
            try widgets.append(a, try panel.paragraph(a, i18n.tr("This location and its matching .pub file will move to Trash. Other copies stay where they are. References in SSH configuration and servers may still need this key."), 420, panel.palette().app_text_size, true));
        },
        .none => {},
    }
    if ((self.form == .passphrase or self.form == .comment) and encrypted) {
        try widgets.append(a, s.text(i18n.tr("Current passphrase"), true));
        try widgets.append(a, try secret(&self.old, "keys_old_passphrase", i18n.tr("Current passphrase")));
    }
    if (self.form == .generate or self.form == .passphrase) {
        try widgets.append(a, s.text(i18n.tr("New passphrase (optional)"), true));
        try widgets.append(a, try secret(&self.password, "keys_new_passphrase", i18n.tr("New passphrase")));
        try widgets.append(a, s.text(i18n.tr("Confirm passphrase"), true));
        try widgets.append(a, try secret(&self.confirm, "keys_confirm_passphrase", i18n.tr("Confirm passphrase")));
        try widgets.append(a, s.text(i18n.tr("An empty passphrase leaves the private key unencrypted."), true));
    }
    try widgets.append(a, try s.actions(a, &.{
        s.button(cc, "keys_submit", if (self.form == .generate) i18n.tr("Generate key") else if (self.form == .trash) i18n.tr("Move to Trash") else i18n.tr("Save"), 0, s.busy(self), submit),
        s.button(cc, "keys_cancel", i18n.tr("Cancel"), 0, false, cancel),
    }));
    return s.card(a, widgets.items);
}
fn submit(raw: ?*anyopaque, _: usize) void {
    const cc = s.owner(raw);
    const self = &cc.key_settings;
    if (s.busy(self)) return;
    defer self.clearSecrets();
    if ((self.form == .generate or self.form == .passphrase) and !std.mem.eql(u8, self.password.value(), self.confirm.value())) {
        self.message = i18n.tr("The passphrases do not match. Enter them again.");
        cc.refresh();
        return;
    }
    var req: protocol.Request = .{ .old_passphrase = self.old.value(), .new_passphrase = self.password.value() };
    if (self.form != .generate) {
        const item = s.chosen(self) orelse return;
        req.path = s.location(self, item).path;
        req.fingerprint = item.fingerprint;
    }
    switch (self.form) {
        .generate => {
            req.action = .generate;
            req.path = value(self, .name);
            req.text = value(self, .comment);
        },
        .comment => {
            req.action = .comment;
            req.text = value(self, .comment);
        },
        .label => {
            req.action = .label;
            req.text = value(self, .label);
        },
        .passphrase => req.action = .passphrase,
        .trash => req.action = .trash,
        .none => return,
    }
    submitRequest(cc, req);
}
pub fn submitRequest(cc: *panel.ControlCenter, req: protocol.Request) void {
    const self = &cc.key_settings;
    const client = self.client orelse return;
    client.act(req) catch {
        self.message = i18n.tr("Could not start the key operation.");
        cc.refresh();
        return;
    };
    self.form = .none;
    self.message = "";
    cc.refresh();
}
fn value(self: *const s.Section, id: s.Field) []const u8 {
    const field = self.fields[@backingInt(id)];
    return if (field.widget) |widget| widget.kind.text_input.value else if (field.data) |data| data.value else "";
}
fn setField(self: *s.Section, id: s.Field, content: []const u8) !void {
    const field = &self.fields[@backingInt(id)];
    const bytes = try gpa.dupe(u8, content);
    if (field.widget) |widget| field.data = widget.kind.text_input;
    if (field.data) |*data| {
        gpa.free(data.value);
        data.value = bytes;
        data.cursor_pos = bytes.len;
        data.selection_anchor = null;
        if (field.widget) |widget| widget.kind.text_input = data.*;
    } else field.data = .{ .owner = null, .id = @backingInt(id), .placeholder = "", .value = bytes, .cursor_pos = bytes.len, .on_change = edited };
}
fn entry(self: *s.Section, cc: *panel.ControlCenter, a: s.A, id: s.Field, label: []const u8) !s.W {
    const field = &self.fields[@backingInt(id)];
    if (field.data == null) try setField(self, id, "");
    var data = field.data.?;
    data.owner = cc;
    data.placeholder = label;
    const widget: s.W = .{ .name = s.field_names[@backingInt(id)], .kind = .{ .text_input = data }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } };
    const row = try s.group(a, &.{ s.text(label, true), widget });
    field.widget = &row.children[1];
    return row;
}
fn edited(_: ?*anyopaque, _: usize, _: []const u8) void {}

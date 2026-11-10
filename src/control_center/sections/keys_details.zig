const std = @import("std");
const i18n = @import("i18n");
const panel = @import("../panel.zig");
const model = @import("keys").model;
const s = @import("keys.zig");
const forms = @import("keys_forms.zig");

pub fn build(self: *s.Section, cc: *panel.ControlCenter, a: s.A, widgets: *std.ArrayList(s.W), item: model.Item) !void {
    const place = s.location(self, item);
    const busy = s.busy(self);
    const keygen = self.client.?.current.?.value.inventory.keygen;
    const trash = self.client.?.current.?.value.inventory.trash;
    try widgets.append(a, s.button(cc, "keys_back", i18n.tr("Back to SSH keys"), 0, busy, back));
    try widgets.append(a, panel.sectionTitle(if (item.label.len > 0) item.label else if (item.comment.len > 0) item.comment else std.fs.path.basename(place.path)));
    try widgets.append(a, @import("keys_ssh.zig").named(s.text(item.fingerprint, false), "keys_fingerprint"));
    try widgets.append(a, s.text(try std.fmt.allocPrint(a, "{s} · {d}", .{ item.algorithm, item.bits }), true));
    try widgets.append(a, s.text(try @import("keys_ssh.zig").health(a, item), false));
    const paths = try a.alloc([]const u8, item.locations.len);
    for (item.locations, paths) |location, *path| path.* = location.path;
    try widgets.append(a, s.text(i18n.tr("Location"), true));
    try widgets.append(a, .{ .name = "keys_location", .kind = .{ .select = .{ .labels = paths, .selected = @min(self.location, paths.len - 1), .disabled = busy or self.form != .none, .owner = cc, .on_change = selectLocation } }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } });
    try widgets.append(a, s.button(cc, "keys_copy", i18n.tr("Copy public key"), 0, busy, copy));
    if (self.form != .none) {
        try widgets.append(a, try forms.build(self, cc, a));
        return;
    }
    try widgets.append(a, try s.group(a, &.{
        s.button(cc, "keys_edit_label", i18n.tr("Edit label…"), @backingInt(s.Form.label), busy, forms.open),
        s.button(cc, "keys_passphrase", i18n.tr("Change passphrase…"), @backingInt(s.Form.passphrase), busy or !place.private or !keygen, forms.open),
        s.button(cc, "keys_edit_comment", i18n.tr("Edit comment…"), @backingInt(s.Form.comment), busy or !place.private or !keygen, forms.open),
        s.button(cc, "keys_recreate", i18n.tr("Recreate missing .pub file"), @backingInt(@import("keys").protocol.Action.recreate_public), busy or !place.private or !place.missing_public, act),
        s.button(cc, "keys_permissions", i18n.tr("Fix permissions"), @backingInt(@import("keys").protocol.Action.permissions), busy, act),
        s.button(cc, "keys_delete", i18n.tr("Move to Trash…"), @backingInt(s.Form.trash), busy or !trash, forms.open),
    }));
    if (!trash) try widgets.append(a, s.text(i18n.tr("Install gio to move keys to Trash."), true));
}
fn selectLocation(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = s.owner(raw);
    if (s.busy(&cc.key_settings) or cc.key_settings.form != .none) return;
    cc.key_settings.location = index;
    cc.key_settings.message = "";
    cc.refresh();
}
fn copy(raw: ?*anyopaque, _: usize) void {
    const cc = s.owner(raw);
    const item = s.chosen(&cc.key_settings) orelse return;
    @import("../../clipboard.zig").copyText(cc.server, item.public_key);
    cc.key_settings.message = i18n.tr("Public key copied.");
    cc.refresh();
}
fn back(raw: ?*anyopaque, _: usize) void {
    const cc = s.owner(raw);
    if (s.busy(&cc.key_settings)) return;
    cc.key_settings.clearSecrets();
    cc.key_settings.selected_len = 0;
    cc.key_settings.form = .none;
    cc.key_settings.message = "";
    cc.refresh();
}
fn act(raw: ?*anyopaque, id: usize) void {
    const cc = s.owner(raw);
    const self = &cc.key_settings;
    const item = s.chosen(self) orelse return;
    forms.submitRequest(cc, .{ .action = @fromBackingInt(@intCast(id)), .path = s.location(self, item).path, .fingerprint = item.fingerprint });
}

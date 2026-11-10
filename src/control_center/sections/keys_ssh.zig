//! SSH inventory and selection. Later certificate/agent phases add views here.
const std = @import("std");
const i18n = @import("i18n");
const panel = @import("../panel.zig");
const s = @import("keys.zig");
const forms = @import("keys_forms.zig");
const details = @import("keys_details.zig");
pub fn tree(self: *s.Section, cc: *panel.ControlCenter, a: s.A) !s.W {
    s.start(self, cc) catch return s.text(i18n.tr("Could not load SSH keys."), true);
    const client = self.client.?;
    var widgets: std.ArrayList(s.W) = .empty;
    try widgets.append(a, panel.sectionTitle(i18n.tr("SSH keys")));
    try widgets.append(a, s.text(i18n.tr("Manage the current user's keys in ~/.ssh."), true));
    const keygen = if (client.current) |current| current.value.inventory.keygen else false;
    try widgets.append(a, try s.actions(a, &.{
        s.button(cc, "keys_new", i18n.tr("New key…"), @backingInt(s.Form.generate), client.busy or !keygen, forms.open),
        s.button(cc, "keys_refresh", i18n.tr("Refresh"), 0, client.busy, refresh),
    }));
    if (!keygen and !client.busy) try widgets.append(a, s.text(i18n.tr("Install OpenSSH to generate or change keys."), true));
    if (client.busy) try widgets.append(a, named(s.text(i18n.tr("Working…"), true), "keys_status"));
    if (client.failure) try widgets.append(a, named(s.text(if (client.timed_out) i18n.tr("Loading SSH keys timed out. Refresh to try again.") else i18n.tr("Could not load SSH keys. Refresh to try again."), false), "keys_error"));
    if (client.current) |current| {
        const reply = current.value;
        try s.copyInventory(self, a, reply.inventory);
        if (!client.busy) if (reply.failure) |err| try widgets.append(a, named(s.text(s.failure(err), false), "keys_error"));
        if (reply.inventory.directory_permissions) try widgets.append(a, s.text(i18n.tr("The .ssh directory is accessible to other users. Fix permissions from a key's details."), false));
        if (reply.inventory.skipped > 0) try widgets.append(a, s.text(i18n.tr("Some files were skipped: unsupported, unreadable, too large or unsafe to open."), true));
    }
    if (self.message.len > 0) try widgets.append(a, named(s.text(self.message, false), "keys_message"));
    if (self.form == .generate) {
        try widgets.append(a, try forms.build(self, cc, a));
    } else if (s.chosen(self)) |item| {
        try details.build(self, cc, a, &widgets, item);
    } else {
        self.selected_len = 0;
        if (self.items.len == 0 and !client.busy and !client.failure) try widgets.append(a, s.text(i18n.tr("No supported SSH keys found."), true));
        for (self.items, 0..) |item, i| {
            const title = if (item.label.len > 0) item.label else if (item.comment.len > 0) item.comment else std.fs.path.basename(item.locations[0].path);
            var path = item.locations[0].path;
            for (item.locations) |place| if (place.private) {
                path = place.path;
                break;
            };
            try widgets.append(a, try s.card(a, &.{
                s.button(cc, try std.fmt.allocPrint(a, "keys_item_{d}", .{i}), title, i, client.busy, select),
                s.text(try std.fmt.allocPrint(a, "~/.ssh/{s}", .{std.fs.path.basename(path)}), true),
                s.text(try std.fmt.allocPrint(a, "{s} · {d}", .{ item.algorithm, item.bits }), true),
                named(s.text(item.fingerprint, true), "keys_fingerprint"),
                s.text(try health(a, item), true),
            }));
        }
    }
    return s.group(a, widgets.items);
}
pub fn named(widget: s.W, name: []const u8) s.W {
    var result = widget;
    result.name = name;
    return result;
}
pub fn health(a: s.A, item: @import("keys").model.Item) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var private = false;
    var unencrypted = false;
    var permissions = false;
    var missing = false;
    var mismatch = false;
    for (item.locations) |place| {
        private = private or place.private;
        unencrypted = unencrypted or (place.private and !place.encrypted);
        permissions = permissions or place.permissions;
        missing = missing or place.missing_public;
        mismatch = mismatch or place.mismatched_public;
    }
    if (private) try parts.append(a, if (unencrypted) i18n.tr("No passphrase") else i18n.tr("Passphrase protected")) else try parts.append(a, i18n.tr("Public key only"));
    if (permissions) try parts.append(a, i18n.tr("Unsafe permissions"));
    if (missing) try parts.append(a, i18n.tr("Missing .pub file"));
    if (mismatch) try parts.append(a, i18n.tr("Public file does not match"));
    if (item.weak()) try parts.append(a, i18n.tr("Weak algorithm or key size"));
    return std.mem.join(a, " · ", parts.items);
}
fn refresh(raw: ?*anyopaque, _: usize) void {
    const cc = s.owner(raw);
    if (cc.key_settings.client) |client| client.act(.{}) catch {};
    cc.key_settings.message = "";
    cc.refresh();
}
fn select(raw: ?*anyopaque, id: usize) void {
    const cc = s.owner(raw);
    const self = &cc.key_settings;
    if (id >= self.items.len or s.busy(self)) return;
    const item = self.items[id];
    self.selected_len = item.fingerprint.len;
    @memcpy(self.selected[0..self.selected_len], item.fingerprint);
    self.location = 0;
    for (item.locations, 0..) |place, i| if (place.private) {
        self.location = i;
        break;
    };
    self.message = "";
    self.form = .none;
    cc.refresh();
}

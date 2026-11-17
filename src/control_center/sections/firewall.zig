//! Settings → Network → Firewall: the overview card on the Network page and,
//! behind Manage, the Firewall sub-view (rules, listening programs, networks,
//! advanced settings, other programs' rules, recent blocks). Everything comes
//! from `rediwm-firewall-helper` through `firewall_client.zig`; changes need
//! Unlock (the helper's `authorize`, then polkit remembers the password for a
//! few minutes). The helper's client lives only while the Network page is on
//! screen. Strings from a reply are copied into the tree's arena: the next
//! reply frees them.
const std = @import("std");
const i18n = @import("i18n");
const ui = @import("ui");
const fw = @import("firewall");
const panel = @import("../panel.zig");
const Client = @import("firewall_client.zig").Client;
const widgets = @import("network_ui.zig");
const fields = @import("network_fields.zig");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const model = fw.model;
const text = widgets.text;
const group = widgets.group;
const card = widgets.card;
const action = widgets.action;

pub const Field = enum { port, address, source, comment };

pub const Form = struct {
    kind: usize = 0,
    service: usize = 0,
    rule_action: usize = 0,
    proto: usize = 0,
    direction: usize = 0,
    source: usize = 0,
    scope: usize = 0,
    fields: fields.Slots(Field) = .{},
};

pub const Section = struct {
    client: ?*Client = null,
    unlocked: bool = false,
    managing: bool = false,
    adding: bool = false,
    /// Reading needs the password here (FreeBSD's polkit today).
    read_denied: bool = false,
    show_blocks: bool = false,
    /// A rule whose Remove waits for a second click.
    remove_armed: ?usize = null,
    message: []const u8 = "",
    form: Form = .{},
    /// Whether polkit has our actions, checked once per visit to the page.
    policy: ?bool = null,

    pub fn capture(s: *Section) void {
        s.form.fields.capture();
    }

    /// The page went away (another page, search, close, lock): stop the
    /// helper and forget the unlock.
    pub fn hide(s: *Section) void {
        if (s.client) |client| client.destroy();
        s.client = null;
        s.unlocked = false;
        s.adding = false;
        s.show_blocks = false;
        s.remove_armed = null;
        s.message = "";
        s.policy = null;
    }

    pub fn deinit(s: *Section) void {
        s.hide();
        s.form.fields.release();
    }
};

pub fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}

/// Starts the helper's client when the Network page is built.
pub fn start(cc: *panel.ControlCenter) void {
    const s = &cc.firewall;
    if (s.client != null or cc.server.greeter_mode or cc.server.locker != null) return;
    if (s.policy == null) s.policy = @import("firewall_client.zig").policyInstalled(cc.server.io);
    if (!s.policy.?) {
        s.message = i18n.tr("Firewall settings are not installed for this build: its polkit policy is missing.");
        return;
    }
    s.client = Client.create(cc.server.io, cc.server.wl_server.getEventLoop(), cc, changed) catch return;
    s.client.?.send(.{ .op = .status }, .read) catch {
        s.message = i18n.tr("The firewall helper could not be started.");
    };
}

fn changed(raw: *anyopaque) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw));
    const s = &cc.firewall;
    const client = s.client orelse return;
    s.message = "";
    switch (client.outcome) {
        .denied => {
            if (client.op == .status or client.op == .blocks) {
                if (client.mode == .read) s.read_denied = true;
            } else {
                s.unlocked = false;
                s.message = i18n.tr("Authentication was cancelled or denied.");
            }
        },
        .broken => s.message = i18n.tr("The firewall helper did not answer."),
        .failed => s.message = client.failure(),
        .ok => if (client.op == .authorize) {
            s.unlocked = true;
            if (s.read_denied or client.status() == null) client.send(.{ .op = .status }, readMode(s)) catch {};
        } else if (client.op == .add_rule) {
            s.adding = false;
            s.form.fields.release();
        },
        .none => {},
    }
    client.flush();
    cc.refresh();
}

pub fn readMode(s: *const Section) @import("firewall_client.zig").Mode {
    return if (s.read_denied) .manage else .read;
}

/// Sends a change; the reply carries the new status.
pub fn change(cc: *panel.ControlCenter, req: fw.protocol.Request) void {
    const s = &cc.firewall;
    const client = s.client orelse return;
    if (!s.unlocked) return;
    s.remove_armed = null;
    client.send(req, .manage) catch {
        s.message = i18n.tr("Another firewall change is still running.");
    };
    cc.refresh();
}

pub fn busy(cc: *const panel.ControlCenter) bool {
    const client = cc.firewall.client orelse return true;
    return client.busy;
}

/// Whether controls that change something are usable now.
pub fn editable(cc: *const panel.ControlCenter) bool {
    const client = cc.firewall.client orelse return false;
    const status = client.status() orelse return false;
    return cc.firewall.unlocked and !client.busy and status.capabilities.edit;
}

pub fn policyLabel(p: model.Policy) []const u8 {
    return switch (p) {
        .accept => i18n.tr("Allow"),
        .drop => i18n.tr("Block"),
        .reject => i18n.tr("Reject"),
    };
}

pub fn backendName(b: model.Backend, system: model.System) []const u8 {
    return switch (b) {
        .none => i18n.tr("None"),
        .own => if (system == .freebsd) i18n.tr("pf (RediWM rules)") else i18n.tr("RediWM (nftables)"),
        .ufw => "ufw",
        .firewalld => "firewalld",
        .redi => "RediOS",
        .foreign => i18n.tr("another firewall"),
    };
}

fn loggingLabel(level: model.Logging) []const u8 {
    return switch (level) {
        .off => i18n.tr("Off"),
        .low => i18n.tr("Low"),
        .medium => i18n.tr("Medium"),
        .high => i18n.tr("High"),
    };
}

pub const Id = enum(usize) {
    refresh = 1,
    unlock,
    manage,
    back,
    keep,
    lockdown_off,
    lockdown_on,
    add_open,
    add_cancel,
    add_submit,
    blocks,
    _,
};
pub const remove_base: usize = 1000;
pub const block_base: usize = 2000;
pub const allow_base: usize = 3000;
pub const trust_base: usize = 4000;

pub fn clicked(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    const s = &cc.firewall;
    const client = s.client orelse return;
    s.form.fields.capture();
    switch (@as(Id, @fromBackingInt(@intCast(id)))) {
        .refresh => client.send(.{ .op = .status }, readMode(s)) catch {},
        .unlock => {
            if (s.unlocked) {
                s.unlocked = false;
                s.adding = false;
            } else client.send(.{ .op = .authorize }, .manage) catch {};
        },
        .manage => s.managing = true,
        .back => {
            s.managing = false;
            s.adding = false;
            s.show_blocks = false;
        },
        .keep => change(cc, .{ .op = .confirm }),
        .lockdown_off => change(cc, .{ .op = .lockdown, .on = false }),
        .lockdown_on => change(cc, .{ .op = .lockdown, .on = true, .revert_after = 20 }),
        .add_open => {
            s.form.fields.release();
            s.form = .{};
            s.form.fields.set(cc, .port, "", i18n.tr("8080 or 6000-6010"));
            s.form.fields.set(cc, .address, "", i18n.tr("203.0.113.9 or 10.0.0.0/8"));
            s.form.fields.set(cc, .source, "", i18n.tr("192.168.1.0/24"));
            s.form.fields.set(cc, .comment, "", i18n.tr("Optional"));
            s.adding = true;
        },
        .add_cancel => {
            s.adding = false;
            s.form.fields.release();
            s.message = "";
        },
        .add_submit => @import("firewall_rules.zig").submit(cc),
        .blocks => {
            s.show_blocks = true;
            client.send(.{ .op = .blocks }, readMode(s)) catch {};
        },
        _ => @import("firewall_cards.zig").rowClicked(cc, id),
    }
    cc.refresh();
}

fn toggled(raw: ?*anyopaque, id: usize, on: bool) void {
    const cc = owner(raw);
    const status = (cc.firewall.client orelse return).status() orelse return;
    if (id == 0) {
        if (on) change(cc, .{ .op = .enable, .backend = status.backend }) else change(cc, .{ .op = .disable });
    }
}

fn fact(a: Allocator, label: []const u8, value: []const u8) !W {
    var column = try group(a, .column, &.{ text(label, 12, true), text(value, 14, false) });
    column.gap = 3;
    column.width = .{ .flex = 1 };
    return column;
}

fn headline(status: *const model.Status) []const u8 {
    if (status.lockdown) return i18n.tr("Blocking all connections");
    if (status.backend == .none) return i18n.tr("Not available");
    if (status.running) return i18n.tr("On");
    return i18n.tr("Off");
}

fn summary(a: Allocator, status: *const model.Status) ![]const u8 {
    var buffer: [256]u8 = undefined;
    if (status.backend == .none) return i18n.tr("No firewall tool is installed (nftables, ufw, firewalld or pf).");
    if (!status.running) return a.dupe(u8, i18n.fmt(&buffer, i18n.tr("{name} is installed but not filtering. Unprotected."), .{ .name = backendName(status.backend, status.system) }) catch "");
    const incoming: []const u8 = switch (status.incoming) {
        .accept => i18n.tr("allows incoming"),
        .drop, .reject => i18n.tr("blocks incoming"),
    };
    const outgoing: []const u8 = if (status.outgoing == .accept) i18n.tr("allows outgoing") else i18n.tr("blocks outgoing");
    return a.dupe(u8, i18n.fmt(&buffer, i18n.tr("Protected by {name} · {incoming}, {outgoing}"), .{ .name = backendName(status.backend, status.system), .incoming = incoming, .outgoing = outgoing }) catch "");
}

/// The line under the facts: the most exposed listening program.
fn exposure(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !?W {
    var reachable: usize = 0;
    var first: ?usize = null;
    for (status.listeners, 0..) |l, i| if (l.verdict == .everywhere) {
        reachable += 1;
        if (first == null) first = i;
    };
    var buffer: [256]u8 = undefined;
    if (first) |i| {
        const l = status.listeners[i];
        const name = if (l.process.len != 0) l.process else i18n.tr("A program");
        const line = try a.dupe(u8, i18n.fmt(&buffer, i18n.tr("{name} (port {port}) can be reached from any network."), .{ .name = name, .port = l.port }) catch "");
        var label = text(line, 13, false);
        label.width = .{ .flex = 1 };
        label.kind.text.color = panel.palette().danger;
        var items: std.ArrayList(W) = .empty;
        try items.append(a, label);
        if (status.capabilities.edit) {
            var block = action(cc, "firewall_expose_block", i18n.tr("Block"), block_base + i, clicked, !editable(cc));
            block.width = .auto;
            block.kind.button.variant = .secondary;
            try items.append(a, block);
        }
        var row = try group(a, .row, items.items);
        row.name = "firewall_exposure";
        return row;
    }
    if (!status.running) return null;
    const line: []const u8 = if (status.listeners.len == 0) i18n.tr("No program is listening for connections.") else i18n.tr("No listening program can be reached from every network.");
    return text(line, 13, true);
}

fn rulesLine(a: Allocator, status: *const model.Status) ![]const u8 {
    var allow: usize = 0;
    var block: usize = 0;
    for (status.rules) |r| switch (r.action) {
        .allow, .limit => allow += 1,
        .deny, .reject => block += 1,
    };
    var out: std.Io.Writer.Allocating = .init(a);
    var buffer: [128]u8 = undefined;
    try out.writer.writeAll(i18n.fmt(&buffer, i18n.tr("{allow} allowed · {block} blocked"), .{ .allow = allow, .block = block }) catch "");
    if (status.foreign.len != 0) {
        try out.writer.print("  ·  {s} ", .{i18n.tr("Also active:")});
        for (status.foreign, 0..) |f, i| {
            const who = if (f.owner.len != 0) f.owner else f.name;
            try out.writer.print("{s}{s} ({d})", .{ if (i == 0) "" else ", ", who, f.rules });
        }
    }
    return out.written();
}

fn noticeRow(cc: *panel.ControlCenter, a: Allocator, message: []const u8, label: []const u8, id: Id, name: []const u8) !W {
    var line = text(message, 13, false);
    line.width = .{ .flex = 1 };
    line.kind.text.color = panel.palette().danger;
    var button = action(cc, name, label, @backingInt(id), clicked, busy(cc) or !cc.firewall.unlocked);
    button.width = .auto;
    return group(a, .row, &.{ line, button });
}

/// The overview card: always on the Network page and at the top of the
/// sub-view.
pub fn overview(cc: *panel.ControlCenter, a: Allocator) !W {
    const s = &cc.firewall;
    const client = s.client;
    const status = if (client) |cl| cl.status() else null;
    var items: std.ArrayList(W) = .empty;
    const on = if (status) |st| st.running and !st.lockdown else false;
    var labels = try group(a, .column, &.{
        text(i18n.tr("Firewall"), 20, false),
        try widgets.status(a, if (status) |st| headline(st) else if (s.read_denied) i18n.tr("Locked") else if (client == null) i18n.tr("Unavailable") else i18n.tr("Reading…"), on),
    });
    labels.width = .{ .flex = 1 };
    labels.gap = 4;
    var header: std.ArrayList(W) = .empty;
    try header.appendSlice(a, &.{ widgets.icon(.shield, 30, on), labels });
    if (status) |st| if (st.backend != .none and st.backend != .redi) {
        const disabled = !editable(cc) and !(s.unlocked and !busy(cc) and st.conflicts.len == 0);
        try header.append(a, .{ .name = "firewall_enabled", .kind = .{ .toggle = .{ .style = .settings, .on = st.running, .disabled = disabled or st.conflicts.len != 0, .owner = cc, .id = 0, .on_change = toggled } } });
    };
    try items.append(a, try group(a, .row, header.items));

    if (status) |st| {
        try items.append(a, text(try summary(a, st), 13, true));
        if (st.backend == .redi) try items.append(a, text(i18n.tr("Managed by RediOS. Change it with redi; it is shown here read-only."), 13, true));
        if (st.conflicts.len != 0) {
            var line = text(i18n.tr("More than one firewall is active. Turn all but one off to make changes here."), 13, false);
            line.kind.text.color = panel.palette().danger;
            try items.append(a, line);
        }
        if (st.needs_anchor and !st.running) try items.append(a, text(i18n.tr("Turning on adds RediWM's anchor to pf.conf (a backup is kept)."), 12, true));
        if (st.revert_in != 0) {
            var buffer: [128]u8 = undefined;
            const line = try a.dupe(u8, i18n.fmt(&buffer, i18n.tr("The last change is undone in about {seconds} s unless you keep it."), .{ .seconds = st.revert_in }) catch "");
            try items.append(a, try noticeRow(cc, a, line, i18n.tr("Keep change"), .keep, "firewall_keep"));
        }
        if (st.lockdown) try items.append(a, try noticeRow(cc, a, i18n.tr("All network connections are blocked."), i18n.tr("Stop blocking"), .lockdown_off, "firewall_lockdown_off"));
        if (st.backend != .none) {
            try items.append(a, try group(a, .row, &.{
                try fact(a, i18n.tr("Incoming"), policyLabel(st.incoming)),
                try fact(a, i18n.tr("Outgoing"), policyLabel(st.outgoing)),
                try fact(a, i18n.tr("Forwarding"), policyLabel(st.forward)),
            }));
            try items.append(a, try group(a, .row, &.{
                try fact(a, i18n.tr("Ping"), if (st.ping) i18n.tr("Answered") else i18n.tr("Ignored")),
                try fact(a, i18n.tr("Logging"), loggingLabel(st.logging)),
                try fact(a, i18n.tr("Starts at boot"), if (st.boot) i18n.tr("Yes") else i18n.tr("No")),
            }));
            if (try exposure(cc, a, st)) |row| try items.append(a, row);
            try items.append(a, text(try rulesLine(a, st), 12, true));
        }
    } else if (s.read_denied) {
        try items.append(a, text(i18n.tr("Unlock to view the firewall."), 13, true));
    }

    const message: []const u8 = if (client != null and client.?.busy and client.?.mode == .manage) (if (client.?.op == .authorize) i18n.tr("Waiting for authentication…") else i18n.tr("Applying…")) else if (s.message.len != 0) s.message else if (!s.unlocked and status != null and status.?.capabilities.edit) i18n.tr("Unlock to change firewall settings.") else "";
    if (message.len != 0) try items.append(a, text(try a.dupe(u8, message), 12, true));

    var buttons: std.ArrayList(W) = .empty;
    var refresh = action(cc, "firewall_refresh", i18n.tr("Refresh"), @backingInt(Id.refresh), clicked, busy(cc) or (s.read_denied and !s.unlocked));
    refresh.kind.button.variant = .secondary;
    refresh.kind.button.leading_icon = .refresh;
    refresh.width = .auto;
    try buttons.append(a, refresh);
    var unlock = action(cc, "firewall_unlock", if (s.unlocked) i18n.tr("Lock") else i18n.tr("Unlock"), @backingInt(Id.unlock), clicked, busy(cc) or client == null);
    unlock.kind.button.leading_icon = if (s.unlocked) .checkmark else .lock;
    unlock.kind.button.variant = .secondary;
    unlock.width = .auto;
    try buttons.append(a, unlock);
    if (!s.managing) {
        var manage = action(cc, "firewall_manage", i18n.tr("Manage…"), @backingInt(Id.manage), clicked, status == null);
        manage.width = .auto;
        try buttons.append(a, manage);
    }
    var row = try group(a, .row, buttons.items);
    row.@"align" = .center;
    try items.append(a, row);
    var result = try card(a, items.items);
    result.name = "firewall_card";
    return result;
}

/// The Firewall sub-view that replaces the Network page behind Manage.
pub fn view(cc: *panel.ControlCenter, a: Allocator) !W {
    const cards = @import("firewall_cards.zig");
    const rules = @import("firewall_rules.zig");
    var back = action(cc, "firewall_back", i18n.tr("Network"), @backingInt(Id.back), clicked, false);
    back.kind.button.leading_icon = .chevron_left;
    back.kind.button.variant = .secondary;
    back.width = .auto;
    var page: std.ArrayList(W) = .empty;
    try page.append(a, try group(a, .row, &.{back}));
    try page.append(a, try overview(cc, a));
    const status = (cc.firewall.client orelse return group(a, .column, page.items)).status() orelse return group(a, .column, page.items);
    if (status.backend == .none) return group(a, .column, page.items);
    try page.append(a, try rules.rulesCard(cc, a, status));
    if (cc.firewall.adding) try page.append(a, try rules.formCard(cc, a, status));
    try page.append(a, try cards.listeners(cc, a, status));
    if (status.networks.len != 0) try page.append(a, try cards.networks(cc, a, status));
    try page.append(a, try cards.advanced(cc, a, status));
    if (status.foreign.len != 0) try page.append(a, try cards.foreign(a, status));
    try page.append(a, try cards.blocks(cc, a, status));
    return group(a, .column, page.items);
}

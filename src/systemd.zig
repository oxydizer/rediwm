//! Settings' systemd client. Queries and runtime actions use D-Bus; editing
//! Type uses an authorized systemctl drop-in edit, completed through eventfd.
//! All requests target the discovered unique owner; generations discard replies
//! from a previous daemon. The Settings window owns this connection.
//!
//! Changes are locked until the user unlocks them: that asks polkit once for
//! manage-unit-files, whose `imply` annotation also covers manage-units and
//! reload-daemon, so later enable/disable/start/stop/restart calls reuse the
//! retained authorization instead of prompting again. The lock is a session
//! gate in the UI and in `act`/`setType`; polkit still decides every request.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("main.zig").gpa;
const panel = @import("control_center/panel.zig");
const name = "org.freedesktop.systemd1";
const path = "/org/freedesktop/systemd1";
const manager = name ++ ".Manager";
const properties = "org.freedesktop.DBus.Properties";
const edit = @import("systemd_edit.zig");
const polkit_name = "org.freedesktop.PolicyKit1";
const polkit_path = "/org/freedesktop/PolicyKit1/Authority";
const polkit_authority = polkit_name ++ ".Authority";
const unlock_action = "org.freedesktop.systemd1.manage-unit-files";
const unlock_cancellation = "rediwm-settings-services-unlock";

pub const service_types: []const []const u8 = &.{ "exec", "dbus", "simple", "forking", "notify", "oneshot", "idle", "notify-reload" };

pub fn typeIndex(value: []const u8) ?usize {
    for (service_types, 0..) |candidate, i| if (std.mem.eql(u8, value, candidate)) return i;
    return null;
}

pub const Unit = struct {
    name: []const u8,
    description: []const u8 = "Not loaded",
    path: []const u8 = "",
    active: []const u8 = "inactive",
    sub: []const u8 = "dead",
    load: []const u8 = "unloaded",
    startup: []const u8 = "unknown",
    service_type: []const u8 = "",
    transient: bool = false,
    trigger: []const u8 = "",
    time_us: ?u64 = null,

    pub fn enabled(u: Unit) bool {
        return std.mem.eql(u8, u.startup, "enabled") or std.mem.eql(u8, u.startup, "enabled-runtime");
    }
    pub fn editable(u: Unit) bool {
        return u.enabled() or std.mem.eql(u8, u.startup, "disabled");
    }
    pub fn typeEditable(u: Unit) bool {
        return u.service_type.len > 0 and std.mem.eql(u8, u.load, "loaded") and
            !std.mem.startsWith(u8, u.startup, "masked") and
            !u.transient and !std.mem.eql(u8, u.startup, "transient");
    }
};

const Snapshot = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    units: std.ArrayList(Unit) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(s: *Snapshot) void {
        s.arena.deinit();
        s.* = .{};
    }
    fn copy(s: *Snapshot, value: []const u8) ![]const u8 {
        return s.arena.allocator().dupe(u8, value);
    }
    fn get(s: *Snapshot, unit_name: []const u8) !*Unit {
        if (s.index.get(unit_name)) |i| return &s.units.items[i];
        const owned = try s.copy(unit_name);
        try s.units.append(s.arena.allocator(), .{ .name = owned });
        try s.index.put(s.arena.allocator(), owned, s.units.items.len - 1);
        return &s.units.items[s.units.items.len - 1];
    }
};

pub const Action = enum { enable, disable, start, stop, restart };
const Kind = enum { subscribe, units, files, pin, load, detail, service, timing, boot, action, reload, unlock };
const Request = struct { client: *Client, generation: u64, kind: Kind, index: usize = 0 };

pub const Client = struct {
    server: *@import("Server.zig"),
    conn: ?*dbus.Connection = null,
    owner: ?[]u8 = null,
    generation: u64 = 0,
    closing: bool = false,
    watching: bool = false,
    subscribed: bool = false,
    snapshot: Snapshot = .{},
    staging: Snapshot = .{},
    loading: bool = false,
    analyzing: bool = false,
    analyzed: bool = false,
    boot_pending: bool = false,
    action_pending: bool = false,
    unlocked: bool = false,
    unlocking: bool = false,
    unlock_generation: usize = 0,
    edit_request: ?*edit.Request = null,
    edited_unit: ?[]u8 = null,
    edited_type: ?usize = null,
    action_job: ?[]u8 = null,
    again: bool = false,
    next_detail: usize = 0,
    pending_details: usize = 0,
    boot_us: ?u64 = null,
    message: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn create(server: *@import("Server.zig")) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .server = server };
        errdefer gpa.destroy(self);
        const conn = try dbus.Connection.openSystem(gpa, server.wl_server.getEventLoop(), server.environ);
        self.conn = conn;
        errdefer conn.destroy();
        _ = try conn.hello(self, hello);
        conn.on_disconnect = .{ .owner = self, .callback = disconnected };
        return self;
    }
    pub fn destroy(self: *Client) void {
        self.closing = true;
        edit.cancel(self);
        self.cancelUnlock();
        if (self.edited_unit) |unit| gpa.free(unit);
        if (self.conn) |conn| conn.destroy();
        if (self.owner) |old| gpa.free(old);
        if (self.action_job) |job| gpa.free(job);
        self.snapshot.deinit();
        self.staging.deinit();
        gpa.destroy(self);
    }
    pub fn available(self: *const Client) bool {
        return self.owner != null;
    }
    pub fn busy(self: *const Client) bool {
        return self.loading or self.analyzing or self.action_pending;
    }
    pub fn status(self: *const Client) []const u8 {
        return self.message[0..self.message_len];
    }
    /// True until the first list arrives: nothing to show yet and no failure.
    pub fn awaitingList(self: *const Client) bool {
        if (self.snapshot.units.items.len > 0) return false;
        return self.loading or (!self.subscribed and self.message_len == 0);
    }
    fn inform(self: *Client, value: []const u8) void {
        self.message_len = @min(value.len, self.message.len);
        @memcpy(self.message[0..self.message_len], value[0..self.message_len]);
        self.changed();
    }
    fn changed(self: *Client) void {
        if (!self.closing) if (self.server.input.open_control_center) |cc| {
            if (cc.page == .services) cc.refresh();
        };
    }
    pub fn open(self: *Client) void {
        if (self.watching or !self.available()) return;
        self.watching = true;
        self.subscribe() catch self.inform("Could not subscribe to service updates.");
    }
    fn subscribe(self: *Client) !void {
        const body: wire.Writer = .{ .allocator = gpa };
        try self.call(.subscribe, 0, path, manager, "Subscribe", "", &body, false);
    }
    pub fn refresh(self: *Client) void {
        if (!self.available() or !self.subscribed) return;
        if (self.busy()) {
            self.again = true;
            return;
        }
        self.again = false;
        self.loading = true;
        self.staging.deinit();
        const body: wire.Writer = .{ .allocator = gpa };
        self.call(.units, 0, path, manager, "ListUnits", "", &body, false) catch {
            self.loading = false;
            self.inform("Could not load services. Try Refresh.");
        };
        self.changed();
    }
    pub fn analyze(self: *Client) void {
        if (self.busy() or !self.available()) return;
        self.analyzing = true;
        self.analyzed = false;
        self.boot_us = null;
        self.message_len = 0;
        self.next_detail = 0;
        self.pending_details = 0;
        for (self.snapshot.units.items) |*unit| unit.time_us = null;
        self.boot_pending = true;
        self.getProperties(.boot, 0, path, manager) catch {
            self.boot_pending = false;
            self.inform("Boot summary is unavailable.");
        };
        self.pump();
        self.changed();
    }
    pub fn detachSettings(self: *Client) void {
        self.cancelUnlock();
        self.lock();
        if (self.edit_request != null) {
            edit.cancel(self);
            self.action_pending = false;
            self.edited_type = null;
            self.refresh();
        }
    }
    pub fn lock(self: *Client) void {
        if (!self.unlocked) return;
        self.unlocked = false;
        self.changed();
    }
    pub fn unlock(self: *Client) void {
        if (self.unlocked or self.unlocking or !self.available()) return;
        self.unlock_generation +%= 1;
        self.unlocking = true;
        self.message_len = 0;
        self.checkAuthorization() catch {
            self.unlocking = false;
            self.inform("Could not start the authentication request.");
        };
        self.changed();
    }
    fn checkAuthorization(self: *Client) !void {
        const conn = self.conn orelse return error.Disconnected;
        // The subject is this connection; polkit resolves it to our process,
        // which is also what systemd reports for later calls on it.
        const unique = conn.unique_name orelse return error.Disconnected;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.alignTo(8);
        try body.string("system-bus-name");
        const subject = try body.beginArray(8);
        try body.string("name");
        try body.variant("s");
        try body.string(unique);
        try body.endArray(subject);
        try body.string(unlock_action);
        const details = try body.beginArray(8);
        try body.endArray(details);
        try body.uint32(1); // AllowUserInteraction
        try body.string(unlock_cancellation);
        const req = try gpa.create(Request);
        errdefer gpa.destroy(req);
        req.* = .{ .client = self, .generation = self.generation, .kind = .unlock, .index = self.unlock_generation };
        _ = try conn.callWithFlags(polkit_name, polkit_path, polkit_authority, "CheckAuthorization", "(sa{sv})sa{ss}us", &body, req, reply, 120000, 0);
    }
    /// Withdraw a pending prompt so no dialog outlives its Settings window.
    /// Best effort: polkit also ignores unknown ids.
    fn cancelUnlock(self: *Client) void {
        if (!self.unlocking) return;
        self.unlocking = false;
        const conn = self.conn orelse return;
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        body.string(unlock_cancellation) catch return;
        _ = conn.call(polkit_name, polkit_path, polkit_authority, "CancelCheckAuthorization", "s", &body, null, null, 1000) catch return;
        conn.flush() catch {};
    }
    pub fn act(self: *Client, unit_name: []const u8, action: Action) void {
        if (!self.unlocked or self.busy() or !self.available()) return;
        const i = self.snapshot.index.get(unit_name) orelse return;
        const unit = self.snapshot.units.items[i];
        if ((action == .enable or action == .disable) and !unit.editable()) return;
        self.action_pending = true;
        self.message_len = 0;
        self.sendAction(unit, action) catch {
            self.action_pending = false;
            self.inform("Could not send the service action.");
        };
        self.changed();
    }
    /// IPC goes through systemd's own interactive authorization on this bus.
    /// Startup edits never implicitly start or stop a running service.
    pub fn setMode(self: *Client, unit_name: []const u8, mode: @import("ipc/protocol.zig").ServiceMode) !void {
        if (mode == .deferred) return error.UnsupportedServiceMode;
        if (!self.available()) return error.ServicesUnavailable;
        if (self.busy() or self.awaitingList()) return error.ServicesBusy;
        const i = self.snapshot.index.get(unit_name) orelse return error.UnknownService;
        const unit = self.snapshot.units.items[i];
        if (!unit.editable()) return error.ServiceModeReadOnly;
        if (mode == .@"on-demand" and unit.trigger.len == 0) return error.ServiceHasNoTrigger;
        self.action_pending = true;
        errdefer self.action_pending = false;
        self.message_len = 0;
        try self.sendAction(unit, if (mode == .on) .enable else .disable);
        self.changed();
    }
    fn sendAction(self: *Client, unit: Unit, action: Action) !void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        const install = action == .enable or action == .disable;
        if (install) {
            const array = try body.beginArray(4);
            try body.string(unit.name);
            try body.endArray(array);
            try body.boolean(false);
            if (action == .enable) try body.boolean(false);
        } else {
            try body.string(unit.name);
            try body.string("replace");
        }
        const method: []const u8 = switch (action) {
            .enable => "EnableUnitFiles",
            .disable => "DisableUnitFiles",
            .start => "StartUnit",
            .stop => "StopUnit",
            .restart => "RestartUnit",
        };
        const signature: []const u8 = if (action == .enable) "asbb" else if (action == .disable) "asb" else "ss";
        try self.call(.action, @intFromBool(install), path, manager, method, signature, &body, true);
    }
    pub fn setType(self: *Client, unit_name: []const u8, index: usize) void {
        if (!self.unlocked or self.busy() or !self.available() or index >= service_types.len) return;
        const unit = self.snapshot.units.items[self.snapshot.index.get(unit_name) orelse return];
        if (!unit.typeEditable() or std.mem.eql(u8, unit.service_type, service_types[index])) return;
        const owned_name = gpa.dupe(u8, unit_name) catch return;
        if (self.edited_unit) |old| gpa.free(old);
        self.edited_unit = owned_name;
        self.edited_type = index;
        self.action_pending = true;
        self.message_len = 0;
        edit.start(self, unit_name, service_types[index]) catch {
            self.edited_type = null;
            self.action_pending = false;
            self.inform("Could not open the service edit for authorization.");
        };
        self.changed();
    }
    pub fn edited(self: *Client, status_code: i32) void {
        if (status_code != 0) {
            self.edited_type = null;
            self.action_pending = false;
            self.inform(if (status_code == 126 or status_code == 127)
                "Authentication was cancelled or denied. Notify setting is unchanged."
            else
                "Could not save Notify. Service editing requires systemd 256 or newer.");
            self.refresh();
            return;
        }
        const empty: wire.Writer = .{ .allocator = gpa };
        self.call(.reload, 1, path, manager, "Reload", "", &empty, true) catch {
            self.edited_type = null;
            self.action_pending = false;
            self.inform("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload.");
        };
        self.changed();
    }
    fn call(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8, method: []const u8, signature: []const u8, body: *const wire.Writer, auth: bool) !void {
        const destination = self.owner orelse return error.Disconnected;
        const req = try gpa.create(Request);
        errdefer gpa.destroy(req);
        req.* = .{ .client = self, .generation = self.generation, .kind = kind, .index = index };
        _ = try self.conn.?.callWithFlags(destination, object, interface, method, signature, body, req, reply, if (auth) 120000 else 10000, if (auth) wire.flag_allow_interactive_authorization else 0);
    }
    fn getProperties(self: *Client, kind: Kind, index: usize, object: []const u8, interface: []const u8) !void {
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(interface);
        try self.call(kind, index, object, properties, "GetAll", "s", &body, false);
    }
    fn pump(self: *Client) void {
        const units = if (self.analyzing) self.snapshot.units.items else self.staging.units.items;
        while (self.pending_details < 4 and self.next_detail < units.len) {
            const i = self.next_detail;
            self.next_detail += 1;
            if (units[i].path.len == 0) {
                if (self.analyzing or std.mem.startsWith(u8, units[i].startup, "masked")) continue;
                var body: wire.Writer = .{ .allocator = gpa };
                defer body.deinit();
                body.string(units[i].name) catch continue;
                // Keep newly loaded inactive units alive while Settings uses
                // them. The bus disconnect drops these references, preventing
                // UnitNew/UnitRemoved from causing a refresh/GC feedback loop.
                self.call(.pin, i, path, manager, "RefUnit", "s", &body, false) catch continue;
            } else {
                self.getProperties(if (self.analyzing) .timing else .detail, i, units[i].path, name ++ ".Unit") catch continue;
            }
            self.pending_details += 1;
        }
        if (self.pending_details != 0 or self.boot_pending) return;
        if (self.analyzing) {
            self.analyzing = false;
            self.analyzed = true;
        } else {
            for (self.staging.units.items) |*unit| {
                if (self.snapshot.index.get(unit.name)) |i| unit.time_us = self.snapshot.units.items[i].time_us;
            }
            self.snapshot.deinit();
            self.snapshot = self.staging;
            self.staging = .{};
            self.loading = false;
            if (self.edited_type) |expected| {
                self.edited_type = null;
                const i = self.snapshot.index.get(self.edited_unit.?);
                if (i == null or !std.mem.eql(u8, self.snapshot.units.items[i.?].service_type, service_types[expected]))
                    self.inform("Notify override saved, but the selected type is not active in systemd. Check other service overrides.");
            }
        }
        self.changed();
        if (self.again) self.refresh();
    }
    fn reply(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const req: *Request = @ptrCast(@alignCast(ctx orelse return));
        defer gpa.destroy(req);
        const self = req.client;
        if (self.closing or req.generation != self.generation) return;
        const msg = result catch {
            self.failed(req, "Service request timed out or the connection was lost.");
            return;
        };
        if (msg.kind == .error_reply) {
            self.failed(req, msg.headers.error_name orelse "Service request failed.");
            return;
        }
        // polkit answers the unlock check; everything else must be systemd.
        if (req.kind != .unlock and !self.fromOwner(msg)) return;
        self.accept(req, msg) catch self.failed(req, "Could not read the systemd response.");
    }
    fn failed(self: *Client, req: *const Request, reason: []const u8) void {
        switch (req.kind) {
            .unlock => {
                self.unlocking = false;
                self.inform("Could not request authentication. Check that polkit is running.");
            },
            .pin, .load, .detail, .service, .timing => {
                self.pending_details -= 1;
                if (req.kind == .timing) self.inform("Some startup times are unavailable.");
                self.pump();
            },
            .boot => {
                self.boot_pending = false;
                self.inform("Boot summary is unavailable.");
                self.pump();
            },
            .action, .reload => {
                self.action_pending = false;
                if (req.kind == .reload and req.index == 1) {
                    self.edited_type = null;
                    self.inform("Notify override saved, but systemd could not reload it. Try Refresh after a daemon reload.");
                } else self.inform(reason);
                self.refresh();
            },
            else => {
                self.loading = false;
                self.inform(reason);
            },
        }
    }
    fn accept(self: *Client, req: *const Request, msg: wire.Message) !void {
        var body = msg.body;
        switch (req.kind) {
            .subscribe => {
                self.subscribed = true;
                self.refresh();
            },
            .units => {
                if (!std.mem.eql(u8, msg.headers.signature, "a(ssssssouso)")) return error.InvalidMessage;
                var array = try body.array(8);
                while (array.offset < array.bytes.len) {
                    try array.alignTo(8);
                    const id = try array.string();
                    const description = try array.string();
                    const load_state = try array.string();
                    const active = try array.string();
                    const sub = try array.string();
                    _ = try array.string();
                    const object = try array.string();
                    _ = try array.uint32();
                    _ = try array.string();
                    _ = try array.string();
                    if (!std.mem.endsWith(u8, id, ".service")) continue;
                    const unit = try self.staging.get(id);
                    unit.description = try self.staging.copy(description);
                    unit.load = try self.staging.copy(load_state);
                    unit.active = try self.staging.copy(active);
                    unit.sub = try self.staging.copy(sub);
                    unit.path = try self.staging.copy(object);
                }
                const empty: wire.Writer = .{ .allocator = gpa };
                try self.call(.files, 0, path, manager, "ListUnitFiles", "", &empty, false);
            },
            .files => {
                if (!std.mem.eql(u8, msg.headers.signature, "a(ss)")) return error.InvalidMessage;
                var array = try body.array(8);
                while (array.offset < array.bytes.len) {
                    try array.alignTo(8);
                    const id = std.fs.path.basename(try array.string());
                    const state = try array.string();
                    if (!std.mem.endsWith(u8, id, ".service")) continue;
                    const unit = try self.staging.get(id);
                    unit.startup = try self.staging.copy(state);
                }
                self.next_detail = 0;
                self.pending_details = 0;
                self.pump();
            },
            .pin => {
                var request: wire.Writer = .{ .allocator = gpa };
                defer request.deinit();
                try request.string(self.staging.units.items[req.index].name);
                try self.call(.load, req.index, path, manager, "LoadUnit", "s", &request, false);
            },
            .load => {
                if (!std.mem.eql(u8, msg.headers.signature, "o")) return error.InvalidMessage;
                const unit = &self.staging.units.items[req.index];
                unit.path = try self.staging.copy(try body.string());
                try self.getProperties(.detail, req.index, unit.path, name ++ ".Unit");
            },
            .detail, .service, .timing, .boot => {
                if (!std.mem.eql(u8, msg.headers.signature, "a{sv}")) return error.InvalidMessage;
                var entries = try body.array(8);
                var start: u64 = 0;
                var end: u64 = 0;
                while (entries.offset < entries.bytes.len) {
                    try entries.alignTo(8);
                    const key = try entries.string();
                    const sig = try entries.variant();
                    if (std.mem.eql(u8, sig, "t")) {
                        const value = try entries.uint64();
                        if (std.mem.eql(u8, key, "InactiveExitTimestampMonotonic")) start = value;
                        if (std.mem.eql(u8, key, "ActiveEnterTimestampMonotonic")) end = value;
                        if (req.kind == .boot and std.mem.eql(u8, key, "FinishTimestampMonotonic")) self.boot_us = if (value > 0) value else null;
                    } else if (req.kind == .service and std.mem.eql(u8, key, "Type") and std.mem.eql(u8, sig, "s")) {
                        self.staging.units.items[req.index].service_type = try self.staging.copy(try entries.string());
                    } else if (req.kind == .detail and std.mem.eql(u8, key, "LoadState") and std.mem.eql(u8, sig, "s")) {
                        self.staging.units.items[req.index].load = try self.staging.copy(try entries.string());
                    } else if (req.kind == .detail and std.mem.eql(u8, key, "Transient") and std.mem.eql(u8, sig, "b")) {
                        self.staging.units.items[req.index].transient = try entries.boolean();
                    } else if (req.kind == .detail and std.mem.eql(u8, sig, "s")) {
                        const value = try self.staging.copy(try entries.string());
                        const unit = &self.staging.units.items[req.index];
                        if (std.mem.eql(u8, key, "Description")) unit.description = value;
                        if (std.mem.eql(u8, key, "ActiveState")) unit.active = value;
                        if (std.mem.eql(u8, key, "SubState")) unit.sub = value;
                    } else if (req.kind == .detail and std.mem.eql(u8, key, "TriggeredBy") and std.mem.eql(u8, sig, "as")) {
                        var triggers = try entries.array(4);
                        var value: std.ArrayList(u8) = .empty;
                        const a = self.staging.arena.allocator();
                        while (triggers.offset < triggers.bytes.len) {
                            const trigger = try triggers.string();
                            if (value.items.len > 0) try value.appendSlice(a, ", ");
                            try value.appendSlice(a, trigger);
                        }
                        self.staging.units.items[req.index].trigger = value.items;
                    } else try entries.skip(sig);
                }
                if (req.kind == .boot) {
                    self.boot_pending = false;
                    self.pump();
                } else if (req.kind == .detail) {
                    try self.getProperties(.service, req.index, self.staging.units.items[req.index].path, name ++ ".Service");
                } else {
                    if (req.kind == .timing) self.snapshot.units.items[req.index].time_us = if (start > 0 and end > start) end - start else null;
                    self.pending_details -= 1;
                    self.pump();
                }
            },
            .action => {
                if (req.index == 1) {
                    const empty: wire.Writer = .{ .allocator = gpa };
                    try self.call(.reload, 0, path, manager, "Reload", "", &empty, true);
                } else {
                    if (self.action_job) |job| gpa.free(job);
                    self.action_job = null;
                    self.action_job = try gpa.dupe(u8, try body.string());
                    self.action_pending = false;
                    self.inform("Request accepted. Status updates when the job completes.");
                    self.refresh();
                }
            },
            .unlock => {
                if (!self.unlocking or req.index != self.unlock_generation) return;
                if (!std.mem.eql(u8, msg.headers.signature, "(bba{ss})")) return error.InvalidMessage;
                try body.alignTo(8);
                const authorized = try body.boolean();
                self.unlocking = false;
                self.unlocked = authorized;
                if (authorized) self.changed() else self.inform("Authentication was cancelled or denied.");
            },
            .reload => {
                self.action_pending = false;
                self.inform(if (req.index == 1) "Notify setting saved. Applies on the next service start." else "Startup setting saved. Running status is unchanged.");
                self.refresh();
            },
        }
    }
    fn fromOwner(self: *Client, msg: wire.Message) bool {
        return std.mem.eql(u8, self.owner orelse return false, msg.headers.sender orelse return false);
    }
    fn setOwner(self: *Client, unique: []const u8) void {
        edit.cancel(self);
        self.cancelUnlock();
        self.edited_type = null;
        if (self.edited_unit) |unit| gpa.free(unit);
        self.edited_unit = null;
        self.generation += 1;
        if (self.action_job) |job| gpa.free(job);
        self.action_job = null;
        if (self.owner) |old| gpa.free(old);
        self.owner = if (unique.len > 0) gpa.dupe(u8, unique) catch null else null;
        self.snapshot.deinit();
        self.staging.deinit();
        self.loading = false;
        self.analyzing = false;
        self.analyzed = false;
        self.boot_pending = false;
        self.action_pending = false;
        self.subscribed = false;
        self.pending_details = 0;
        self.boot_us = null;
        self.message_len = 0;
        if (self.available() and self.watching) self.subscribe() catch {};
        if (!self.closing) if (self.server.input.open_control_center) |cc| {
            cc.refresh();
        };
    }
    fn disconnected(ctx: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (!self.closing) self.setOwner("");
    }
    fn hello(ctx: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (self.closing) return;
        const msg = result catch return;
        if (msg.kind != .method_return) return;
        self.setup(conn) catch self.inform("Could not connect to systemd.");
    }
    fn setup(self: *Client, conn: *dbus.Connection) !void {
        try conn.registerSignal(.{ .owner = self, .callback = signal });
        _ = try conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ name ++ "'", null, null);
        _ = try conn.addMatch("type='signal',sender='" ++ name ++ "',interface='" ++ manager ++ "'", null, null);
        _ = try conn.addMatch("type='signal',sender='" ++ name ++ "',interface='" ++ properties ++ "',path_namespace='" ++ path ++ "/unit'", null, null);
        var body: wire.Writer = .{ .allocator = gpa };
        defer body.deinit();
        try body.string(name);
        _ = try conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, discovered, 5000);
    }
    fn discovered(ctx: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (self.closing or self.generation != 0) return;
        var msg = result catch return;
        if (msg.kind != .method_return) return;
        self.setOwner(msg.body.string() catch return);
    }
    fn signal(ctx: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
        const self: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (self.closing) return;
        const member = msg.headers.member orelse return;
        const interface = msg.headers.interface orelse return;
        var body = msg.body;
        if (std.mem.eql(u8, interface, "org.freedesktop.DBus") and std.mem.eql(u8, member, "NameOwnerChanged") and std.mem.eql(u8, msg.headers.sender orelse "", "org.freedesktop.DBus")) {
            if (!std.mem.eql(u8, try body.string(), name)) return;
            _ = try body.string();
            self.setOwner(try body.string());
        } else if (self.fromOwner(msg) and self.watching) {
            if (std.mem.eql(u8, interface, manager)) {
                // Type is a constant property until daemon reload; systemd
                // does not have to emit Service.PropertiesChanged for it.
                if (std.mem.eql(u8, member, "Reloading")) {
                    if (!try body.boolean()) self.refresh();
                    return;
                }
                if (std.mem.eql(u8, member, "JobRemoved")) {
                    _ = try body.uint32();
                    const job = try body.string();
                    _ = try body.string();
                    const outcome = try body.string();
                    if (self.action_job) |requested| {
                        if (std.mem.eql(u8, requested, job)) {
                            if (!std.mem.eql(u8, outcome, "done")) self.inform(outcome);
                            gpa.free(requested);
                            self.action_job = null;
                        }
                    }
                }
                if (std.mem.eql(u8, member, "UnitNew") or std.mem.eql(u8, member, "UnitRemoved") or std.mem.eql(u8, member, "UnitFilesChanged") or std.mem.eql(u8, member, "JobRemoved")) self.refresh();
            } else if (std.mem.eql(u8, interface, properties) and std.mem.eql(u8, member, "PropertiesChanged")) {
                const changed_interface = try body.string();
                if (std.mem.eql(u8, changed_interface, name ++ ".Unit") or std.mem.eql(u8, changed_interface, name ++ ".Service")) self.refresh();
            }
        }
    }
};

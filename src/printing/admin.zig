//! Page-owned asynchronous printer administration. Use the installed helper
//! for polkit authorization, or `rediwm-cups` (libcups in a process of its own)
//! for CUPS authentication. RediWM never becomes root or runs a shell. Destruction closes outstanding requests before releasing their owner.
const std = @import("std");
const dbus = @import("dbus");
const wl = @import("wayland").server.wl;
const direct = @import("direct.zig");
const setup = @import("setup.zig");
const cups = @import("cups.zig");
const wire = dbus.wire;
const a = std.heap.c_allocator;

pub const helper_name = "org.opensuse.CupsPkHelper.Mechanism";
pub const helper_path = "/";
pub const Availability = enum { loading, available, missing };
pub const Device = struct {
    uri: []const u8 = "",
    info: []const u8 = "",
    make_model: []const u8 = "",
    device_id: []const u8 = "",
    class: []const u8 = "",
};
pub const Add = struct {
    name: []const u8,
    uri: []const u8,
    ppd: []const u8,
    info: []const u8 = "",
    location: []const u8 = "",
    discovered: bool = false,
    /// Names from a fresh inventory: PrinterAdd itself is an upsert in CUPS,
    /// which has no create-exclusive primitive. Never knowingly modify a queue.
    existing_names: []const []const u8 = &.{},
};
pub const Toggle = struct { name: []const u8, value: bool };
pub const Text = struct { name: []const u8, value: []const u8 };
pub const Option = struct { name: []const u8, key: []const u8, values: []const []const u8 };
pub const OptionKey = struct { name: []const u8, key: []const u8 };
pub const Rename = struct { name: []const u8, new_name: []const u8, existing_names: []const []const u8 };
pub const DeviceChange = struct { name: []const u8, uri: []const u8, discovered: bool = false };
pub const Action = union(enum) {
    discover,
    add: Add,
    remove: []const u8,
    enabled: Toggle,
    accepting: Toggle,
    system_default: []const u8,
    info: Text,
    rename: Rename,
    device: DeviceChange,
    option: Option,
    ppd_option: Option,
    clear_option: OptionKey,
    start_service,
};

const Stage = enum { idle, discovery, mutation, add, rename, device, enable_added, accept_added, ppd_option, clear_ppd_override, clear_ppd_alias, start_service };

pub const Manager = struct {
    io: std.Io,
    owner: *anyopaque,
    changed: *const fn (*anyopaque) void,
    bus: ?*dbus.Connection = null,
    loop: ?*wl.EventLoop = null,
    worker: ?*direct.Worker = null,
    authentication: bool = false,
    closing: bool = false,
    availability: Availability = .loading,
    busy: bool = true,
    status: []const u8 = "",
    /// Increases after successful mutations or uncertain add/rename results;
    /// owners refresh CUPS when it changes. Discovery does not reload CUPS.
    generation: u64 = 0,
    devices: []const Device = &.{},
    arena: std.heap.ArenaAllocator = .init(a),
    stage: Stage = .idle,
    added_name: [setup.max_name]u8 = undefined,
    added_len: usize = 0,
    option_queue: [setup.max_name]u8 = undefined,
    option_queue_len: usize = 0,
    option_key: [127]u8 = undefined,
    option_key_len: usize = 0,
    option_alias: ?[]const u8 = null,
    /// Complete validated setter arguments, retained until default cleanup
    /// finishes. At most 64 bounded values; never borrowed from page widgets.
    option_body: wire.Writer = .{ .allocator = a },

    pub fn create(io: std.Io, loop: *wl.EventLoop, env: std.process.Environ, owner: *anyopaque, changed: *const fn (*anyopaque) void) !*Manager {
        const self = try a.create(Manager);
        errdefer a.destroy(self);
        self.* = .{ .io = io, .owner = owner, .changed = changed, .loop = loop, .status = @import("i18n").tr("Checking printer administration…") };
        self.bus = dbus.Connection.openSystem(a, loop, env) catch {
            self.useDirect();
            return self;
        };
        _ = self.bus.?.hello(self, hello) catch {
            self.bus.?.destroy();
            self.bus = null;
            self.useDirect();
        };
        if (self.bus) |bus| bus.on_disconnect = .{ .owner = self, .callback = disconnected };
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.closing = true;
        if (self.worker) |worker| worker.destroy();
        if (self.bus) |bus| bus.destroy();
        self.option_body.deinit();
        self.arena.deinit();
        a.destroy(self);
    }

    fn notify(self: *Manager) void {
        if (!self.closing) self.changed(self.owner);
    }

    fn disconnected(owner: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        if (self.worker != null) return;
        self.stage = .idle;
        self.unavailable(@import("i18n").tr("System bus connection lost. Reopen Printers to reconnect."));
    }

    fn hello(owner: ?*anyopaque, bus: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const msg = result catch {
            self.useDirect();
            return;
        };
        if (msg.kind != .method_return) {
            self.useDirect();
            return;
        }
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        _ = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListActivatableNames", "", &body, self, activatable, 5000) catch {
            self.useDirect();
        };
    }

    fn activatable(owner: ?*anyopaque, bus: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const msg = result catch {
            self.useDirect();
            return;
        };
        if (msg.kind == .method_return and std.mem.eql(u8, msg.headers.signature, "as")) {
            var body = msg.body;
            var names = body.array(4) catch {
                self.unavailable(@import("i18n").tr("Invalid system bus reply."));
                return;
            };
            var found = false;
            while (names.offset < names.bytes.len) {
                const value = names.string() catch {
                    self.unavailable(@import("i18n").tr("Invalid system bus reply."));
                    return;
                };
                found = found or std.mem.eql(u8, value, helper_name);
            }
            body.done() catch {
                self.unavailable(@import("i18n").tr("Invalid system bus reply."));
                return;
            };
            if (found) {
                self.available();
                return;
            }
        }
        // A manually running helper need not have a service activation file.
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        body.string(helper_name) catch {
            self.useDirect();
            return;
        };
        _ = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", &body, self, hasOwner, 5000) catch {
            self.useDirect();
        };
    }

    fn hasOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const msg = result catch {
            self.useDirect();
            return;
        };
        if (msg.kind == .method_return and std.mem.eql(u8, msg.headers.signature, "b")) {
            var body = msg.body;
            const found = body.boolean() catch false;
            body.done() catch {
                self.unavailable(@import("i18n").tr("Invalid system bus reply."));
                return;
            };
            if (found) {
                self.available();
                return;
            }
        }
        self.useDirect();
    }

    fn useDirect(self: *Manager) void {
        if (self.worker == null) {
            const loop = self.loop orelse {
                self.unavailable(@import("i18n").tr("Could not start CUPS administration."));
                return;
            };
            self.worker = direct.Worker.create(self.io, loop, self, directReady) catch {
                self.unavailable(@import("i18n").tr("Could not start CUPS administration."));
                return;
            };
        }
        self.available();
    }

    fn send(self: *Manager, method: Method, body: *wire.Writer, reset: bool) !void {
        if (self.worker) |worker| return worker.submit(method.member, method.signature, body.bytes.items, reset);
        const bus = self.bus orelse return error.Disconnected;
        _ = try bus.callWithFlags(helper_name, helper_path, helper_name, method.member, method.signature, body, self, reply, 120000, wire.flag_allow_interactive_authorization);
    }

    fn directReady(raw: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(raw));
        if (self.closing) return;
        const worker = self.worker.?;
        switch (worker.state()) {
            1 => {
                self.authentication = true;
                self.status = @import("i18n").tr("CUPS requires an administrator username and password.");
                self.notify();
            },
            2 => {
                self.authentication = false;
                const result = worker.result();
                if (result != 0) {
                    self.fail(switch (result) {
                        2 => @import("i18n").tr("Printer administration was cancelled."),
                        3 => @import("i18n").tr("CUPS authentication failed after three attempts. Check the administrator account and permissions."),
                        4 => @import("i18n").tr("Queue rename only partly completed. Refresh and check both queues before retrying."),
                        5 => @import("i18n").tr("This printer belongs to a CUPS class. Manage its class membership before renaming it here."),
                        else => @import("i18n").tr("CUPS refused or could not complete the request. Check authorization and refresh before retrying."),
                    });
                    return;
                }
                if (self.stage == .discovery) {
                    var body: wire.Writer = .{ .allocator = a };
                    defer body.deinit();
                    worker.devices(&body) catch {
                        self.fail(@import("i18n").tr("Invalid or oversized printer discovery reply."));
                        return;
                    };
                    var reader: wire.Reader = .{ .bytes = body.bytes.items };
                    self.readDevices(&reader) catch {
                        self.fail(@import("i18n").tr("Invalid or oversized printer discovery reply."));
                        return;
                    };
                    worker.finish();
                    self.stage = .idle;
                    self.busy = false;
                    self.status = if (self.devices.len == 0) @import("i18n").tr("CUPS discovered no supported printer addresses. You can enter a network address.") else @import("i18n").tr("Printer discovery complete.");
                    self.notify();
                } else self.advance();
            },
            else => {},
        }
    }

    pub fn authenticate(self: *Manager, user: []const u8, password: []const u8) !void {
        if (!self.authentication) return error.NoChallenge;
        try self.worker.?.credentials(user, password);
        self.authentication = false;
        self.status = @import("i18n").tr("Authenticating with CUPS…");
    }
    pub fn cancelAuthentication(self: *Manager) void {
        if (self.worker) |worker| worker.cancel();
        self.authentication = false;
    }

    fn available(self: *Manager) void {
        self.availability = .available;
        self.busy = false;
        self.status = "";
        self.notify();
    }

    fn unavailable(self: *Manager, status: []const u8) void {
        self.availability = .missing;
        self.busy = false;
        self.status = status;
        self.notify();
    }

    /// Arguments are encoded/copied before returning. A successful return means
    /// queued, not authorized or committed; busy/status and changed report that.
    pub fn request(self: *Manager, action: Action) !void {
        if (self.closing or self.busy) return error.Busy;
        switch (action) {
            .add => |add| try self.requireDiscovered(add.uri, add.discovered),
            .device => |device| try self.requireDiscovered(device.uri, device.discovered),
            else => {},
        }
        if (self.bus == null and self.worker == null) return error.Disconnected;
        if (action != .start_service and self.availability != .available) return error.HelperUnavailable;
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        var method = try encode(&body, action);
        self.stage = switch (action) {
            .discover => .discovery,
            .add => |add| blk: {
                self.added_len = add.name.len;
                @memcpy(self.added_name[0..add.name.len], add.name);
                break :blk .add;
            },
            .start_service => .start_service,
            .rename => .rename,
            .device => .device,
            .ppd_option => |option| blk: {
                self.option_queue_len = option.name.len;
                @memcpy(self.option_queue[0..option.name.len], option.name);
                self.option_key_len = option.key.len;
                @memcpy(self.option_key[0..option.key.len], option.key);
                self.option_alias = canonicalAlias(option.key);
                break :blk .clear_ppd_override;
            },
            else => .mutation,
        };
        if (action == .ppd_option) {
            // CUPS must see the PPD update last: deleting a canonical default
            // after setting it can reset generated defaults such as colour.
            self.option_body.deinit();
            self.option_body = body;
            body = .{ .allocator = a };
            method = encode(&body, .{ .clear_option = .{
                .name = self.option_queue[0..self.option_queue_len],
                .key = self.option_key[0..self.option_key_len],
            } }) catch |err| {
                self.option_body.deinit();
                self.option_body = .{ .allocator = a };
                self.stage = .idle;
                return err;
            };
        }
        self.busy = true;
        self.status = switch (action) {
            .discover => @import("i18n").tr("Discovering printers; authorization may be required…"),
            .start_service => @import("i18n").tr("Requesting CUPS start; authorization may be required…"),
            else => @import("i18n").tr("Applying printer change; authorization may be required…"),
        };
        if (action == .start_service) {
            const bus = self.bus orelse {
                self.fail(@import("i18n").tr("The system service manager is unavailable."));
                return error.Disconnected;
            };
            _ = bus.callWithFlags("org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", method.member, method.signature, &body, self, reply, 120000, 4) catch |err| {
                self.fail(@import("i18n").tr("Could not request CUPS start."));
                return err;
            };
        } else {
            self.send(method, &body, true) catch |err| {
                self.fail(@import("i18n").tr("Could not send printer administration request."));
                return err;
            };
        }
    }

    fn reply(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const msg = result catch |err| {
            self.fail(if (err == error.Timeout) @import("i18n").tr("Printer administration timed out. Refresh before trying again.") else @import("i18n").tr("System bus disconnected during printer administration."));
            return;
        };
        if (msg.kind == .error_reply) {
            const error_name = msg.headers.error_name orelse "";
            if (std.mem.eql(u8, error_name, "org.freedesktop.DBus.Error.ServiceUnknown") or std.mem.eql(u8, error_name, "org.freedesktop.DBus.Error.NameHasNoOwner")) {
                if (self.stage != .start_service) self.availability = .missing;
                self.fail(if (self.stage == .start_service) @import("i18n").tr("The system service manager is unavailable; start CUPS using your distribution's service tools.") else @import("i18n").tr("Printer authorization helper unavailable. Refresh before trying again."));
            } else if (std.mem.indexOf(u8, error_name, "NotPrivileged") != null or std.mem.indexOf(u8, error_name, "AccessDenied") != null or std.mem.indexOf(u8, error_name, "NotAuthorized") != null or std.mem.indexOf(u8, error_name, "InteractiveAuthorizationRequired") != null) {
                self.fail(@import("i18n").tr("Printer administration was not authorized or was cancelled."));
            } else self.fail(@import("i18n").tr("Printer administration failed; refresh and check the printer status."));
            return;
        }
        if (msg.kind != .method_return) {
            self.fail(@import("i18n").tr("Invalid printer administration reply."));
            return;
        }
        if (self.stage == .start_service) {
            if (!std.mem.eql(u8, msg.headers.signature, "o")) {
                self.fail(@import("i18n").tr("Invalid service-manager reply."));
                return;
            }
            var body = msg.body;
            _ = body.objectPath() catch {
                self.fail(@import("i18n").tr("Invalid service-manager reply."));
                return;
            };
            body.done() catch {
                self.fail(@import("i18n").tr("Invalid service-manager reply."));
                return;
            };
            self.succeed(@import("i18n").tr("CUPS start requested. Refresh to check when it is ready."));
            return;
        }
        const expected = if (self.stage == .discovery) "sa{ss}" else "s";
        if (!std.mem.eql(u8, msg.headers.signature, expected)) {
            self.fail(@import("i18n").tr("Invalid cups-pk-helper reply."));
            return;
        }
        var body = msg.body;
        const error_message = body.string() catch {
            self.fail(@import("i18n").tr("Invalid cups-pk-helper reply."));
            return;
        };
        if (error_message.len != 0) {
            self.fail(@import("i18n").tr("CUPS refused the printer change. Check authorization, the address and driver, then refresh."));
            return;
        }
        if (self.stage == .discovery) {
            self.readDevices(&body) catch {
                self.fail(@import("i18n").tr("Invalid or oversized printer discovery reply."));
                return;
            };
            self.busy = false;
            self.stage = .idle;
            self.status = if (self.devices.len == 0) @import("i18n").tr("CUPS discovered no supported printer addresses. You can enter a network address.") else @import("i18n").tr("Printer discovery complete.");
            self.notify();
            return;
        }
        body.done() catch {
            self.fail(@import("i18n").tr("Invalid cups-pk-helper reply."));
            return;
        };
        self.advance();
    }

    fn advance(self: *Manager) void {
        switch (self.stage) {
            .add => {
                self.stage = .enable_added;
                self.sendAdded(.{ .enabled = .{ .name = self.added_name[0..self.added_len], .value = true } });
            },
            .enable_added => {
                self.stage = .accept_added;
                self.sendAdded(.{ .accepting = .{ .name = self.added_name[0..self.added_len], .value = true } });
            },
            .accept_added => self.succeed(@import("i18n").tr("Printer added, enabled and accepting jobs.")),
            .rename => self.succeed(@import("i18n").tr("Queue rename request completed. Check the refreshed queues and options.")),
            .device => self.succeed(@import("i18n").tr("Printer connection changed.")),
            .clear_ppd_override => {
                if (self.option_alias != null) {
                    self.stage = .clear_ppd_alias;
                    self.clearOptionAlias();
                } else {
                    self.stage = .ppd_option;
                    self.sendPpdOption();
                }
            },
            .clear_ppd_alias => {
                self.stage = .ppd_option;
                self.sendPpdOption();
            },
            .ppd_option => self.succeed(@import("i18n").tr("Printer option applied.")),
            else => self.succeed(@import("i18n").tr("Printer change applied.")),
        }
    }

    fn sendAdded(self: *Manager, action: Action) void {
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        const method = encode(&body, action) catch {
            self.fail(@import("i18n").tr("Printer was added, but could not be enabled. Refresh and resume it."));
            return;
        };
        self.send(method, &body, false) catch {
            self.fail(@import("i18n").tr("Printer was added, but could not be enabled. Refresh and resume it."));
        };
    }

    fn requireDiscovered(self: *Manager, uri: []const u8, discovered: bool) !void {
        if (!discovered) return;
        for (self.devices) |device| if (std.mem.eql(u8, device.uri, uri)) return;
        return error.UntrustedDevice;
    }

    fn sendPpdOption(self: *Manager) void {
        self.send(.{ .member = "PrinterAddOption", .signature = "ssas" }, &self.option_body, false) catch {
            self.fail(@import("i18n").tr("Could not apply the printer option."));
        };
    }

    fn clearOptionAlias(self: *Manager) void {
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        const method = encode(&body, .{ .clear_option = .{
            .name = self.option_queue[0..self.option_queue_len],
            .key = self.option_alias.?,
        } }) catch {
            self.fail(@import("i18n").tr("Could not clear the canonical default override."));
            return;
        };
        self.send(method, &body, false) catch {
            self.fail(@import("i18n").tr("Could not clear the canonical default override."));
        };
    }

    fn fail(self: *Manager, status: []const u8) void {
        self.authentication = false;
        if (self.worker) |worker| worker.finish();
        if (self.worker != null and self.stage == .mutation) self.generation +%= 1;
        // A chained add may already have changed CUPS; force an inventory reload
        // and describe its partial result rather than deleting anyone's queue.
        const partial = self.stage == .enable_added or self.stage == .accept_added;
        // A timed-out Add can already have created a queue. Close its form and
        // fetch fresh names before allowing a retry, even without a valid reply.
        const option_partial = self.stage == .ppd_option;
        const alias_partial = self.stage == .clear_ppd_alias;
        if (partial or option_partial or alias_partial or self.stage == .clear_ppd_override or self.stage == .add or self.stage == .rename or self.stage == .device) self.generation +%= 1;
        self.status = if (partial)
            @import("i18n").tr("Printer was added, but enabling or accepting jobs failed. Refresh, then resume it and allow jobs.")
        else if (option_partial)
            @import("i18n").tr("Old printer default override cleared, but the new printer option could not be applied. Refresh and review the option.")
        else if (alias_partial)
            @import("i18n").tr("Printer default cleanup partly completed, but the new printer option could not be applied. Refresh and review the option.")
        else
            status;
        self.busy = false;
        self.stage = .idle;
        self.option_body.deinit();
        self.option_body = .{ .allocator = a };
        self.option_alias = null;
        self.notify();
    }

    fn succeed(self: *Manager, status: []const u8) void {
        self.authentication = false;
        if (self.worker) |worker| worker.finish();
        self.generation +%= 1;
        self.status = status;
        self.busy = false;
        self.stage = .idle;
        self.option_body.deinit();
        self.option_body = .{ .allocator = a };
        self.option_alias = null;
        self.notify();
    }

    fn readDevices(self: *Manager, body: *wire.Reader) !void {
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const mem = arena.allocator();
        var devices: [128]Device = @splat(.{});
        var dict = try body.array(8);
        var count: usize = 0;
        while (dict.offset < dict.bytes.len) {
            count += 1;
            if (count > 2048) return error.TooLarge;
            try dict.alignTo(8);
            const key = try dict.string();
            const value = try dict.string();
            const colon = std.mem.lastIndexOfScalar(u8, key, ':') orelse continue;
            const index = std.fmt.parseInt(usize, key[colon + 1 ..], 10) catch continue;
            if (index >= devices.len) continue;
            const field = key[0..colon];
            if (std.mem.eql(u8, field, "device-uri")) {
                setup.validateUri(value, true) catch continue;
                if (devices[index].uri.len != 0) return error.InvalidReply;
                devices[index].uri = try mem.dupe(u8, value);
            } else if (std.mem.eql(u8, field, "device-id")) {
                if (value.len > setup.max_uri) return error.TooLarge;
                // Driver matching must use complete identity, never display
                // truncation or strings changed by stripping control bytes.
                if (!std.unicode.utf8ValidateSlice(value)) continue;
                var valid = true;
                for (value) |ch| if (ch < 0x20 or ch == 0x7f) {
                    valid = false;
                    break;
                };
                if (valid) devices[index].device_id = try mem.dupe(u8, value);
            } else if (std.mem.eql(u8, field, "device-info")) {
                devices[index].info = try cups.clean(mem, value);
            } else if (std.mem.eql(u8, field, "device-make-and-model")) {
                devices[index].make_model = try cups.clean(mem, value);
            } else if (std.mem.eql(u8, field, "device-class")) {
                devices[index].class = try cups.clean(mem, value);
            }
        }
        try body.done();
        var selected: std.ArrayList(Device) = .empty;
        for (devices) |device| {
            if (device.uri.len == 0) continue;
            var duplicate = false;
            for (selected.items) |previous| if (std.mem.eql(u8, previous.uri, device.uri)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try selected.append(mem, device);
        }
        const result = try selected.toOwnedSlice(mem);
        self.arena.deinit();
        self.arena = arena;
        self.devices = result;
    }
};

const Method = struct { member: []const u8, signature: []const u8 };

fn canonicalAlias(key: []const u8) ?[]const u8 {
    for ([_][]const u8{ "Resolution", "SetResolution", "JCLResolution", "CNRes_PGP" }) |native| if (std.mem.eql(u8, key, native)) return "printer-resolution";
    if (std.mem.eql(u8, key, "PageSize") or std.mem.eql(u8, key, "PageRegion")) return "media";
    if (std.mem.eql(u8, key, "Duplex")) return "sides";
    if (std.mem.eql(u8, key, "ColorModel")) return "print-color-mode";
    if (std.mem.eql(u8, key, "cupsPrintQuality")) return "print-quality";
    return null;
}

fn name(writer: *wire.Writer, value: []const u8) !void {
    if (!setup.validName(value)) return error.InvalidName;
    try writer.string(value);
}

fn text(writer: *wire.Writer, value: []const u8, limit: usize) !void {
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
    for (value) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidValue;
    try writer.string(value);
}

fn optionKey(writer: *wire.Writer, value: []const u8) !void {
    if (value.len == 0 or value.len > 127) return error.InvalidOption;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidOption;
    try writer.string(value);
}

/// Method ABI used by installed system-config-printer/cupspk.py for the
/// cups-pk-helper 0.2.x interface. Discovery is (timeout, limit,
/// include_schemes, exclude_schemes); every helper method returns an error string.
fn encode(writer: *wire.Writer, action: Action) !Method {
    return switch (action) {
        .discover => blk: {
            try writer.int(i32, 10);
            try writer.int(i32, 128);
            const includes = try writer.beginArray(4);
            try writer.endArray(includes);
            const excludes = try writer.beginArray(4);
            for ([_][]const u8{ "file", "smb", "smbs", "pdf", "pipe", "exec", "command", "beh", "hpfax", "mailto" }) |scheme| try writer.string(scheme);
            try writer.endArray(excludes);
            break :blk .{ .member = "DevicesGet", .signature = "iiasas" };
        },
        .add => |add| blk: {
            try name(writer, add.name);
            if (setup.nameExists(add.name, add.existing_names)) return error.QueueExists;
            try setup.validateUri(add.uri, add.discovered);
            try writer.string(add.uri);
            if (add.ppd.len == 0 or add.ppd.len > 1024) return error.InvalidDriver;
            try text(writer, add.ppd, 1024);
            try text(writer, add.info, 512);
            try text(writer, add.location, 512);
            break :blk .{ .member = "PrinterAdd", .signature = "sssss" };
        },
        .remove => |value| blk: {
            try name(writer, value);
            break :blk .{ .member = "PrinterDelete", .signature = "s" };
        },
        .enabled => |toggle| blk: {
            try name(writer, toggle.name);
            try writer.boolean(toggle.value);
            break :blk .{ .member = "PrinterSetEnabled", .signature = "sb" };
        },
        .accepting => |toggle| blk: {
            try name(writer, toggle.name);
            try writer.boolean(toggle.value);
            try writer.string("");
            break :blk .{ .member = "PrinterSetAcceptJobs", .signature = "sbs" };
        },
        .system_default => |value| blk: {
            try name(writer, value);
            break :blk .{ .member = "PrinterSetDefault", .signature = "s" };
        },
        .info => |value| blk: {
            try name(writer, value.name);
            try text(writer, value.value, 512);
            break :blk .{ .member = "PrinterSetInfo", .signature = "ss" };
        },
        .rename => |value| blk: {
            try name(writer, value.name);
            if (!setup.validName(value.new_name)) return error.InvalidName;
            if (std.ascii.eqlIgnoreCase(value.name, value.new_name)) return error.SameName;
            if (setup.nameExists(value.new_name, value.existing_names)) return error.QueueExists;
            try writer.string(value.new_name);
            break :blk .{ .member = "PrinterRename", .signature = "ss" };
        },
        .device => |value| blk: {
            try name(writer, value.name);
            try setup.validateUri(value.uri, value.discovered);
            try writer.string(value.uri);
            break :blk .{ .member = "PrinterSetDevice", .signature = "ss" };
        },
        .option, .ppd_option => |option| blk: {
            try name(writer, option.name);
            try optionKey(writer, option.key);
            if (option.values.len == 0 or option.values.len > 64) return error.InvalidOption;
            const array = try writer.beginArray(4);
            for (option.values) |value| try text(writer, value, 1024);
            try writer.endArray(array);
            break :blk .{ .member = if (action == .ppd_option) "PrinterAddOption" else "PrinterAddOptionDefault", .signature = "ssas" };
        },
        .clear_option => |option| blk: {
            try name(writer, option.name);
            try optionKey(writer, option.key);
            break :blk .{ .member = "PrinterDeleteOptionDefault", .signature = "ss" };
        },
        .start_service => blk: {
            try writer.string("cups.service");
            try writer.string("replace");
            break :blk .{ .member = "StartUnit", .signature = "ss" };
        },
    };
}

test "printer administration validates and encodes the actual helper ABI" {
    std.testing.refAllDecls(Manager);
    var writer: wire.Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    const discovery = try encode(&writer, .discover);
    try std.testing.expectEqualStrings("DevicesGet", discovery.member);
    try std.testing.expectEqualStrings("iiasas", discovery.signature);
    var reader: wire.Reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectEqual(@as(i32, 10), try reader.int(i32));
    try std.testing.expectEqual(@as(i32, 128), try reader.int(i32));
    const schemes = try reader.array(4);
    try schemes.done();
    var excludes = try reader.array(4);
    for ([_][]const u8{ "file", "smb", "smbs", "pdf", "pipe", "exec", "command", "beh", "hpfax", "mailto" }) |scheme| try std.testing.expectEqualStrings(scheme, try excludes.string());
    try excludes.done();
    try reader.done();
    writer.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.QueueExists, encode(&writer, .{ .add = .{ .name = "Office", .uri = "ipp://printer/ipp/print", .ppd = "everywhere", .existing_names = &.{"office"} } }));
    writer.bytes.clearRetainingCapacity();
    const accepting = try encode(&writer, .{ .accepting = .{ .name = "Office", .value = true } });
    try std.testing.expectEqualStrings("PrinterSetAcceptJobs", accepting.member);
    try std.testing.expectEqualStrings("sbs", accepting.signature);
    reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectEqualStrings("Office", try reader.string());
    try std.testing.expect(try reader.boolean());
    try std.testing.expectEqualStrings("", try reader.string());
    try reader.done();
    writer.bytes.clearRetainingCapacity();
    const renamed = try encode(&writer, .{ .rename = .{ .name = "Office", .new_name = "Office_New", .existing_names = &.{ "Office", "Label" } } });
    try std.testing.expectEqualStrings("PrinterRename", renamed.member);
    try std.testing.expectEqualStrings("ss", renamed.signature);
    reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectEqualStrings("Office", try reader.string());
    try std.testing.expectEqualStrings("Office_New", try reader.string());
    try reader.done();
    writer.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.QueueExists, encode(&writer, .{ .rename = .{ .name = "Office", .new_name = "LABEL", .existing_names = &.{ "Office", "Label" } } }));
    writer.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.SameName, encode(&writer, .{ .rename = .{ .name = "Office", .new_name = "office", .existing_names = &.{"Office"} } }));
    writer.bytes.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidName, encode(&writer, .{ .rename = .{ .name = "Office", .new_name = "New/Office", .existing_names = &.{"Office"} } }));
    writer.bytes.clearRetainingCapacity();
    const ppd_option = try encode(&writer, .{ .ppd_option = .{ .name = "Office", .key = "Darkness", .values = &.{"12"} } });
    try std.testing.expectEqualStrings("PrinterAddOption", ppd_option.member);
    try std.testing.expectEqualStrings("ssas", ppd_option.signature);
    reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectEqualStrings("Office", try reader.string());
    try std.testing.expectEqualStrings("Darkness", try reader.string());
    var values = try reader.array(4);
    try std.testing.expectEqualStrings("12", try values.string());
    try values.done();
    try reader.done();
    writer.bytes.clearRetainingCapacity();
    const device = try encode(&writer, .{ .device = .{ .name = "Office", .uri = "ipps://printer.local/ipp/print" } });
    try std.testing.expectEqualStrings("PrinterSetDevice", device.member);
    try std.testing.expectEqualStrings("ss", device.signature);
    reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectEqualStrings("Office", try reader.string());
    try std.testing.expectEqualStrings("ipps://printer.local/ipp/print", try reader.string());
    try reader.done();
}

test "discovery owns complete identities and rejects unsafe backend addresses" {
    var writer: wire.Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    const dict = try writer.beginArray(8);
    const fields = [_][2][]const u8{
        .{ "device-uri:0", "usb://Acme/Label?serial=complete" },
        .{ "device-info:0", "Label\nprinter\x1b" },
        .{ "device-uri:1", "file:/tmp/unsafe" },
        .{ "device-info:1", "Must not be offered" },
        .{ "device-uri:2", "smb://user:password@private/queue" },
        .{ "device-uri:3", "usb://Acme/Label?serial=complete" },
    };
    for (fields) |field| {
        try writer.alignTo(8);
        try writer.string(field[0]);
        try writer.string(field[1]);
    }
    const long_id = "MFG:Acme;" ++ @as([600]u8, @splat('X')) ++ ";MDL:Label;";
    try writer.alignTo(8);
    try writer.string("device-id:0");
    try writer.string(long_id);
    try writer.endArray(dict);
    var self: Manager = .{ .io = std.testing.io, .owner = undefined, .changed = undefined };
    defer self.arena.deinit();
    var reader: wire.Reader = .{ .bytes = writer.bytes.items };
    try self.readDevices(&reader);
    try std.testing.expectEqual(@as(usize, 1), self.devices.len);
    try std.testing.expectEqualStrings("usb://Acme/Label?serial=complete", self.devices[0].uri);
    try std.testing.expectEqualStrings("Labelprinter", self.devices[0].info);
    try std.testing.expectEqualStrings(long_id, self.devices[0].device_id);
    writer.bytes.clearRetainingCapacity();
    try std.testing.expectEqualStrings(long_id, self.devices[0].device_id);
}

test "failed PPD setter after legacy cleanup reports partial changes and refreshes inventory" {
    const Recorder = struct {
        changes: usize = 0,
        fn changed(raw: *anyopaque) void {
            const recorder: *@This() = @ptrCast(@alignCast(raw));
            recorder.changes += 1;
        }
    };
    var recorder: Recorder = .{};
    var manager: Manager = .{ .io = std.testing.io, .owner = &recorder, .changed = Recorder.changed, .stage = .ppd_option, .busy = true };
    defer manager.arena.deinit();
    manager.fail("Fixture denied setter");
    try std.testing.expectEqual(@as(u64, 1), manager.generation);
    try std.testing.expectEqual(@as(usize, 1), recorder.changes);
    try std.testing.expect(!manager.busy);
    try std.testing.expectEqual(Stage.idle, manager.stage);
    try std.testing.expect(std.mem.indexOf(u8, manager.status, "new printer option could not be applied") != null);
}

test "native PPD cleanup aliases are explicit and retain the original setter key" {
    const pairs = [_][2][]const u8{
        .{ "Resolution", "printer-resolution" },    .{ "SetResolution", "printer-resolution" },
        .{ "JCLResolution", "printer-resolution" }, .{ "CNRes_PGP", "printer-resolution" },
        .{ "PageSize", "media" },                   .{ "PageRegion", "media" },
        .{ "Duplex", "sides" },                     .{ "ColorModel", "print-color-mode" },
        .{ "cupsPrintQuality", "print-quality" },
    };
    for (pairs) |pair| {
        try std.testing.expectEqualStrings(pair[1], canonicalAlias(pair[0]).?);
        var writer: wire.Writer = .{ .allocator = std.testing.allocator };
        defer writer.deinit();
        for ([_][]const u8{ pair[0], canonicalAlias(pair[0]).? }) |key| {
            writer.bytes.clearRetainingCapacity();
            const method = try encode(&writer, .{ .clear_option = .{ .name = "Office", .key = key } });
            try std.testing.expectEqualStrings("PrinterDeleteOptionDefault", method.member);
            var reader: wire.Reader = .{ .bytes = writer.bytes.items };
            try std.testing.expectEqualStrings("Office", try reader.string());
            try std.testing.expectEqualStrings(key, try reader.string());
            try reader.done();
        }
        writer.bytes.clearRetainingCapacity();
        const method = try encode(&writer, .{ .ppd_option = .{ .name = "Office", .key = pair[0], .values = &.{"Choice"} } });
        try std.testing.expectEqualStrings("PrinterAddOption", method.member);
        var reader: wire.Reader = .{ .bytes = writer.bytes.items };
        try std.testing.expectEqualStrings("Office", try reader.string());
        try std.testing.expectEqualStrings(pair[0], try reader.string());
    }
    try std.testing.expect(canonicalAlias("printer-resolution") == null);
    try std.testing.expect(canonicalAlias("Darkness") == null);
}

test "a discovered add must use the complete URI in this manager's discovery catalog" {
    var manager: Manager = .{ .io = std.testing.io, .owner = undefined, .changed = undefined, .busy = false, .availability = .available };
    defer manager.arena.deinit();
    manager.devices = &.{.{ .uri = "usb://Acme/Label?serial=complete" }};
    try std.testing.expectError(error.UntrustedDevice, manager.request(.{ .add = .{ .name = "Label", .uri = "usb://Acme/Label?serial=different", .ppd = "raw", .discovered = true } }));
    try std.testing.expectError(error.UntrustedDevice, manager.request(.{ .add = .{ .name = "Label", .uri = "tspl:/dev/usb/lp0", .ppd = "raw", .discovered = true } }));
    try std.testing.expectError(error.UntrustedDevice, manager.request(.{ .device = .{ .name = "Label", .uri = "usb://Acme/Label?serial=different", .discovered = true } }));
    // Exact catalog identity passes the guard and reaches the intentionally
    // absent transport. This unit test never opens a bus or a printer node.
    try std.testing.expectError(error.Disconnected, manager.request(.{ .add = .{ .name = "Label", .uri = "usb://Acme/Label?serial=complete", .ppd = "raw", .discovered = true } }));
    try std.testing.expectError(error.Disconnected, manager.request(.{ .device = .{ .name = "Label", .uri = "usb://Acme/Label?serial=complete", .discovered = true } }));
}

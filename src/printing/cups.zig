//! Local, unprivileged CUPS queries. Snapshots own all data; no document titles
//! or contents are requested. Administrative operations are deliberately absent.
const std = @import("std");
pub const ipp = @import("ipp.zig");
const http = @import("http.zig");
const endpoint = @import("endpoint.zig");
const preferences = @import("preferences.zig");
const c = @import("native.zig").c;
const A = std.mem.Allocator;
pub const max_printers = 128;
pub const max_jobs = 100;
const eq = std.mem.eql;

pub const Printer = struct {
    name: []const u8 = "",
    info: []const u8 = "",
    model: []const u8 = "",
    device_uri: []const u8 = "",
    state: ?i32 = null,
    accepting: ?bool = null,
    reasons: []const u8 = "",
    message: []const u8 = "",
    media: []const u8 = "",
    resolution: ?ipp.Resolution = null,
    color: []const u8 = "",
    sides: []const u8 = "",
    markers: []const Marker = &.{},
    is_default: bool = false,
    device_id: []const u8 = "",
    attributes: []const ipp.Attribute = &.{},
    network_reachable: ?bool = null,
    user: preferences.UserState = .{},
    node_kind: ?@import("usb_sysfs.zig").NodeKind = null,
    label_media: bool = false,
    inconsistent_defaults: bool = false,
};
pub const Marker = struct { name: []const u8, level: ?i32 };
pub const Job = struct {
    id: i32 = 0,
    printer: []const u8 = "",
    state: ?i32 = null,
    sheets: ?i32 = null,
    reasons: []const u8 = "",
    message: []const u8 = "",
    own: bool = false,
    pub fn cancellable(self: Job) bool {
        return self.own and self.id > 0 and self.state != null and self.state.? >= 3 and self.state.? <= 6;
    }
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    printers: []Printer = &.{},
    jobs: []Job = &.{},
    jobs_error: ?anyerror = null,
    drivers: []const Driver = &.{},
    drivers_error: ?anyerror = null,
    user_default: []const u8 = "",
    cups_version: []const u8 = "",
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Where the local daemon listens: /run/cups on most Linux systems,
/// /var/run/cups elsewhere (FreeBSD).
pub const local_sockets = [_][]const u8{ "/run/cups/cups.sock", "/var/run/cups/cups.sock" };

/// The socket that exists, else the first (the daemon may not be running yet).
fn localSocket(io: std.Io) []const u8 {
    for (local_sockets) |path| {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        if (stat.kind == .unix_domain_socket) return path;
    }
    return local_sockets[0];
}

/// Reject unsupported remote/encrypted settings explicitly; never contact the
/// local daemon when the user's CUPS configuration points somewhere else.
pub fn server(a: A, io: std.Io, env: std.process.Environ) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    var configured: []const u8 = localSocket(io);
    var encryption: []const u8 = "IfRequested";
    const system = try readClientConfig(mem, io, "/etc/cups/client.conf");
    const system_config = try clientConfig(system);
    configured = system_config.server orelse configured;
    encryption = system_config.encryption orelse encryption;
    if (env.getPosix("HOME")) |home| {
        const path = try std.fs.path.join(mem, &.{ home, ".cups/client.conf" });
        const user_config = try clientConfig(try readClientConfig(mem, io, path));
        configured = user_config.server orelse configured;
        encryption = user_config.encryption orelse encryption;
    }
    configured = env.getPosix("CUPS_SERVER") orelse configured;
    encryption = env.getPosix("CUPS_ENCRYPTION") orelse encryption;
    if (!std.ascii.eqlIgnoreCase(encryption, "IfRequested") and !std.ascii.eqlIgnoreCase(encryption, "Never")) return error.UnsupportedServer;
    _ = try endpoint.parseServer(configured);
    return a.dupe(u8, configured);
}

fn readClientConfig(a: A, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(65536)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => error.InvalidClientConfiguration,
    };
}
const ClientConfig = struct { server: ?[]const u8 = null, encryption: ?[]const u8 = null };
fn clientConfig(bytes: []const u8) !ClientConfig {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var result: ClientConfig = .{};
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        const key_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const key = trimmed[0..key_end];
        if (key.len == 0) continue;
        const value = std.mem.trim(u8, trimmed[key_end..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "ServerName")) {
            // Preserve spaces in Unix paths. Escaped CUPS directives are not
            // implemented yet: reject them instead of selecting another path.
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\\') != null) return error.InvalidClientConfiguration;
            result.server = value;
        } else if (std.ascii.eqlIgnoreCase(key, "Encryption")) {
            if (value.len == 0 or std.mem.indexOfAny(u8, value, " \t\\") != null) return error.InvalidClientConfiguration;
            result.encryption = value;
        }
    }
    return result;
}

pub fn user(a: A) ![]const u8 {
    var pw: c.struct_passwd = undefined;
    var result: [*c]c.struct_passwd = null;
    var buffer: [16384]u8 = undefined;
    if (c.getpwuid_r(c.getuid(), &pw, &buffer, buffer.len, &result) != 0 or result == null or pw.pw_name == null) return error.NoUser;
    const value = std.mem.span(pw.pw_name);
    if (value.len == 0 or value.len > 255 or !std.unicode.utf8ValidateSlice(value)) return error.NoUser;
    return a.dupe(u8, value);
}

fn begin(a: A, code: u16, username: []const u8) !ipp.Encoder {
    return beginTarget(a, code, username, "ipp://localhost/");
}
fn beginTarget(a: A, code: u16, username: []const u8, uri: []const u8) !ipp.Encoder {
    var encoder = try ipp.Encoder.init(a, code, 1);
    errdefer encoder.deinit();
    try encoder.group(.operation);
    try encoder.string(.charset, "attributes-charset", "utf-8");
    try encoder.string(.natural_language, "attributes-natural-language", "en");
    // Target precedes other operation attributes (RFC 8011 section 4.1.5).
    try encoder.string(.uri, "printer-uri", uri);
    try encoder.string(.name, "requesting-user-name", username);
    return encoder;
}

fn requested(encoder: *ipp.Encoder, names: []const []const u8) !void {
    for (names, 0..) |name, i| try encoder.string(.keyword, if (i == 0) "requested-attributes" else "", name);
}

fn exchange(a: A, io: std.Io, socket: []const u8, path: []const u8, encoder: *ipp.Encoder, cancel: c_int) !ipp.Message {
    return exchangeDocument(a, io, socket, path, encoder, &.{}, cancel, null);
}
fn exchangeDocument(a: A, io: std.Io, socket: []const u8, path: []const u8, encoder: *ipp.Encoder, document: []const u8, cancel: c_int, info: ?*http.Info) !ipp.Message {
    if (document.len > 1024 * 1024) return error.DocumentTooLarge;
    const encoded = try encoder.finish();
    const configured = try endpoint.parseServer(socket);
    encoder.bytes.items[1] = configured.version_minor;
    const body = if (document.len == 0) encoded else try std.mem.concat(a, u8, &.{ encoded, document });
    const bytes = if (info) |metadata| try http.requestIoInfo(a, io, socket, path, body, cancel, metadata) else try http.requestIo(a, io, socket, path, body, cancel);
    // bytes belong to the snapshot arena, just like the decoded attributes.
    var message = try ipp.decode(a, bytes, .{ .allow_duplicate_names = true });
    if (message.request_id != 1) {
        message.deinit(a);
        return error.InvalidResponse;
    }
    if (message.code >= 0x100) {
        const code = message.code;
        message.deinit(a);
        return switch (code) {
            0x0401, 0x0402, 0x0403 => error.NotAuthorized,
            0x0406 => error.NotFound,
            0x0501 => error.OperationUnsupported,
            0x040b => error.UnsupportedPrintSettings,
            else => error.IppError,
        };
    }
    return message;
}

pub fn load(a: A, io: std.Io, socket: []const u8, username: []const u8, cancel: c_int) !Snapshot {
    var result: Snapshot = .{ .arena = .init(a) };
    errdefer result.deinit();
    const mem = result.arena.allocator();
    var query = try begin(mem, 0x4002, username); // CUPS-Get-Printers
    defer query.deinit();
    try requested(&query, &.{ "printer-name", "printer-info", "printer-make-and-model", "printer-device-id", "device-uri", "printer-state", "printer-is-accepting-jobs", "printer-state-reasons", "printer-state-message", "media-default", "media-supported", "media-type-default", "print-darkness-supported", "print-darkness-default", "print-speed-supported", "print-speed-default", "printer-resolution-default", "printer-resolution-supported", "print-color-mode-default", "print-color-mode-supported", "sides-default", "sides-supported", "print-quality-default", "print-quality-supported", "marker-names", "marker-levels", "printer-type", "document-format-supported" });
    var info: http.Info = .{};
    var response = exchangeDocument(mem, io, socket, "/", &query, &.{}, cancel, &info) catch |err| switch (err) {
        // CUPS returns not-found when there are no destinations.
        error.NotFound => return result,
        else => return err,
    };
    defer response.deinit(mem);
    result.cups_version = try mem.dupe(u8, info.version());
    result.printers = try printers(mem, response);
    var jobs_query = try begin(mem, 0x000a, username); // Get-Jobs
    defer jobs_query.deinit();
    try jobs_query.string(.keyword, "which-jobs", "all");
    try jobs_query.boolean("my-jobs", true);
    try jobs_query.integer(.integer, "limit", max_jobs);
    try requested(&jobs_query, &.{ "job-id", "job-printer-uri", "job-state", "job-state-reasons", "job-media-sheets-completed", "job-printer-state-message", "job-originating-user-name" });
    var job_response = exchange(mem, io, socket, "/", &jobs_query, cancel) catch |err| {
        if (err == error.Cancelled) return err;
        result.jobs_error = err;
        return result;
    };
    defer job_response.deinit(mem);
    result.jobs = try jobs(mem, job_response, username);
    return result;
}

pub fn cancelJob(a: A, io: std.Io, socket: []const u8, username: []const u8, id: i32, cancel: c_int) !void {
    if (id <= 0) return error.InvalidJob;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var encoder = try begin(arena.allocator(), 0x0008, username);
    defer encoder.deinit();
    try encoder.integer(.integer, "job-id", id);
    var result = try exchange(arena.allocator(), io, socket, "/jobs/", &encoder, cancel);
    result.deinit(arena.allocator());
}

pub const Field = struct {
    group: ipp.Tag = .operation,
    name: []const u8,
    tag: ipp.Tag = .keyword,
    value: union(enum) { text: []const u8, integer: i32, boolean: bool, raw: []const u8 },
};
/// Response and all borrowed fields belong to a caller-owned arena.
pub fn request(a: A, io: std.Io, socket: []const u8, username: []const u8, code: u16, target: []const u8, path: []const u8, fields: []const Field, document: []const u8, cancel: c_int) !ipp.Message {
    var encoder = try beginTarget(a, code, username, target);
    defer encoder.deinit();
    var group: ipp.Tag = .operation;
    for (fields) |field| {
        if (field.group != group) {
            try encoder.group(field.group);
            group = field.group;
        }
        switch (field.value) {
            .text => |value| try encoder.string(field.tag, field.name, value),
            .integer => |value| try encoder.integer(field.tag, field.name, value),
            .boolean => |value| try encoder.boolean(field.name, value),
            .raw => |value| try encoder.value(field.tag, field.name, value),
        }
    }
    return exchangeDocument(a, io, socket, path, &encoder, document, cancel, null);
}
pub fn queueUri(a: A, name: []const u8) ![]const u8 {
    if (name.len == 0 or name.len > 255) return error.InvalidPrinterName;
    var escaped: std.Io.Writer.Allocating = .init(a);
    errdefer escaped.deinit();
    try escaped.writer.writeAll("ipp://localhost/printers/");
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') try escaped.writer.writeByte(ch) else try escaped.writer.print("%{X:0>2}", .{ch});
    }
    return escaped.toOwnedSlice();
}

pub const Driver = struct { name: []const u8, model: []const u8, device_id: []const u8 };
pub fn drivers(a: A, io: std.Io, server_name: []const u8, username: []const u8, cancel: c_int) ![]const Driver {
    var message = try request(a, io, server_name, username, 0x400c, "ipp://localhost/", "/", &.{
        .{ .name = "limit", .tag = .integer, .value = .{ .integer = 512 } },
        .{ .name = "requested-attributes", .value = .{ .text = "ppd-name" } },
        .{ .name = "", .value = .{ .text = "ppd-make-and-model" } },
        .{ .name = "", .value = .{ .text = "ppd-device-id" } },
    }, &.{}, cancel);
    defer message.deinit(a);
    var out: std.ArrayList(Driver) = .empty;
    var offset: usize = 0;
    while (offset < message.attributes.len) {
        var end = offset + 1;
        while (end < message.attributes.len and message.attributes[end].group_index == message.attributes[offset].group_index) : (end += 1) {}
        const attrs = message.attributes[offset..end];
        offset = end;
        if (attrs[0].group != .printer) continue;
        const name = try identity(a, attrs, "ppd-name", 1024);
        if (name.len == 0) continue;
        if (out.items.len >= 512) break;
        try out.append(a, .{ .name = name, .model = try txt(a, attrs, "ppd-make-and-model"), .device_id = try identity(a, attrs, "ppd-device-id", 8192) });
    }
    return out.toOwnedSlice(a);
}

pub fn print(a: A, io: std.Io, server_name: []const u8, username: []const u8, queue: []const u8, raw: bool, media: []const u8, document: []const u8, cancel: c_int) !i32 {
    const target = try queueUri(a, queue);
    const path = target["ipp://localhost".len..];
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(a, &.{
        .{ .name = "job-name", .tag = .name, .value = .{ .text = "RediWM printer test" } },
        .{ .name = "document-format", .tag = .mime_type, .value = .{ .text = if (raw) "application/vnd.cups-raw" else "application/pdf" } },
        .{ .name = "ipp-attribute-fidelity", .tag = .boolean, .value = .{ .boolean = true } },
    });
    try fields.appendSlice(a, &.{
        .{ .group = .job, .name = "copies", .tag = .integer, .value = .{ .integer = 1 } },
        .{ .group = .job, .name = "job-sheets", .value = .{ .text = "none" } },
    });
    if (media.len > 0) try fields.append(a, .{ .group = .job, .name = "media", .value = .{ .text = media } });
    if (!raw) try fields.appendSlice(a, &.{
        .{ .group = .job, .name = "print-scaling", .value = .{ .text = "none" } },
        .{ .group = .job, .name = "number-up", .tag = .integer, .value = .{ .integer = 1 } },
    });
    var result = try request(a, io, server_name, username, 2, target, path, fields.items, document, cancel);
    defer result.deinit(a);
    return int(result.attributes, "job-id") orelse return error.InvalidResponse;
}

pub fn subscribe(a: A, io: std.Io, server_name: []const u8, username: []const u8, cancel: c_int) !i32 {
    var result = try request(a, io, server_name, username, 0x0016, "ipp://localhost/", "/", &.{
        .{ .group = .subscription, .name = "notify-recipient-uri", .tag = .uri, .value = .{ .text = "dbus://" } },
        .{ .group = .subscription, .name = "notify-events", .value = .{ .text = "printer-state-changed" } },
        .{ .group = .subscription, .name = "", .value = .{ .text = "printer-config-changed" } },
        .{ .group = .subscription, .name = "", .value = .{ .text = "printer-added" } },
        .{ .group = .subscription, .name = "", .value = .{ .text = "printer-deleted" } },
        .{ .group = .subscription, .name = "", .value = .{ .text = "job-state-changed" } },
        .{ .group = .subscription, .name = "", .value = .{ .text = "server-restarted" } },
        .{ .group = .subscription, .name = "notify-lease-duration", .tag = .integer, .value = .{ .integer = 0 } },
    }, &.{}, cancel);
    defer result.deinit(a);
    const id = int(result.attributes, "notify-subscription-id") orelse return error.OperationUnsupported;
    if (id <= 0) return error.InvalidResponse;
    var lease = int(result.attributes, "notify-lease-duration");
    if (lease == null) {
        var attrs = request(a, io, server_name, username, 0x0018, "ipp://localhost/", "/", &.{
            .{ .name = "notify-subscription-id", .tag = .integer, .value = .{ .integer = id } },
        }, &.{}, cancel) catch |err| {
            unsubscribeNoWait(server_name, username, id);
            return err;
        };
        defer attrs.deinit(a);
        lease = int(attrs.attributes, "notify-lease-duration");
    }
    if (lease != 0) {
        unsubscribeNoWait(server_name, username, id);
        return error.OperationUnsupported;
    }
    return id;
}
pub fn unsubscribe(a: A, io: std.Io, server_name: []const u8, username: []const u8, id: i32, cancel: c_int) !void {
    var result = try request(a, io, server_name, username, 0x001b, "ipp://localhost/", "/", &.{
        .{ .name = "notify-subscription-id", .tag = .integer, .value = .{ .integer = id } },
    }, &.{}, cancel);
    result.deinit(a);
}
pub fn unsubscribeNoWait(server_name: []const u8, username: []const u8, id: i32) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var encoder = begin(arena.allocator(), 0x001b, username) catch return;
    defer encoder.deinit();
    encoder.integer(.integer, "notify-subscription-id", id) catch return;
    http.sendNoWait(server_name, "/", encoder.finish() catch return) catch {};
}
pub fn ppd(a: A, io: std.Io, server_name: []const u8, username: []const u8, queue: []const u8, cancel: c_int) ![]const u8 {
    const target = try queueUri(a, queue);
    var result = try request(a, io, server_name, username, 0x400f, target, "/", &.{}, &.{}, cancel);
    defer result.deinit(a);
    if (result.data.len == 0 or result.data.len > 1024 * 1024) return error.NotFound;
    return result.data;
}
pub fn probe(a: A, io: std.Io, uri: []const u8, username: []const u8, cancel: c_int) !bool {
    const target = try endpoint.parsePrinterUri(uri);
    var response = try request(a, io, target.server, username, 11, uri, target.resource, &.{
        .{ .name = "requested-attributes", .value = .{ .text = "printer-state" } },
        .{ .name = "", .value = .{ .text = "document-format-supported" } },
        .{ .name = "", .value = .{ .text = "ipp-features-supported" } },
    }, &.{}, cancel);
    defer response.deinit(a);
    var format = false;
    var everywhere = false;
    for (response.attributes) |attr| {
        const text = attr.text() orelse continue;
        if (eq(u8, attr.name, "document-format-supported") and (eq(u8, text, "image/pwg-raster") or eq(u8, text, "image/urf"))) format = true;
        if (eq(u8, attr.name, "ipp-features-supported") and eq(u8, text, "ipp-everywhere")) everywhere = true;
    }
    return format or everywhere;
}

fn find(attrs: []const ipp.Attribute, name: []const u8) ?ipp.Attribute {
    for (attrs) |attr| if (eq(u8, attr.name, name)) return attr;
    return null;
}
fn int(attrs: []const ipp.Attribute, name: []const u8) ?i32 {
    var result: ?i32 = null;
    for (attrs) |attr| if (eq(u8, attr.name, name)) {
        const value = attr.integer() orelse return null;
        if (result) |previous| if (previous != value) return null;
        result = value;
    };
    return result;
}
fn txt(a: A, attrs: []const ipp.Attribute, name: []const u8) ![]const u8 {
    const attr = find(attrs, name) orelse return "";
    return clean(a, attr.text() orelse return "");
}
fn deviceUri(a: A, attrs: []const ipp.Attribute) ![]const u8 {
    return identity(a, attrs, "device-uri", 8192);
}
fn identity(a: A, attrs: []const ipp.Attribute, name: []const u8, limit: usize) ![]const u8 {
    const value = (find(attrs, name) orelse return "").text() orelse return "";
    for (attrs) |attr| if (eq(u8, attr.name, name) and !eq(u8, attr.text() orelse return "", value)) return "";
    // Identity must never use display truncation or removal of characters.
    // An unusable URI gives an unknown diagnostic instead of a false mismatch.
    if (value.len > limit or !std.unicode.utf8ValidateSlice(value)) return "";
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return "";
    var iter = std.unicode.Utf8View.initUnchecked(value).iterator();
    while (iter.nextCodepoint()) |cp| if ((cp >= 0x80 and cp <= 0x9f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) return "";
    return a.dupe(u8, value);
}
fn conflictingDefaults(attrs: []const ipp.Attribute) bool {
    for (attrs, 0..) |attr, i| {
        if (!std.mem.endsWith(u8, attr.name, "-default")) continue;
        for (attrs[0..i]) |previous| if (eq(u8, attr.name, previous.name) and (attr.tag != previous.tag or !eq(u8, attr.value, previous.value))) return true;
    }
    return false;
}
pub fn clean(a: A, value: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return a.dupe(u8, "Invalid printer text");
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var iter = std.unicode.Utf8View.initUnchecked(value).iterator();
    while (iter.nextCodepointSlice()) |ch| {
        if (list.items.len + ch.len > 512) break;
        const cp = std.unicode.utf8Decode(ch) catch unreachable;
        // Strip controls and directional overrides from all widget text.
        if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) continue;
        try list.appendSlice(a, ch);
    }
    return list.toOwnedSlice(a);
}
fn reasons(a: A, attrs: []const ipp.Attribute, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (attrs) |attr| {
        if (!eq(u8, attr.name, name) or attr.text() == null) continue;
        const text = try clean(a, attr.text().?);
        if (out.items.len + text.len + 2 > 2048) break;
        if (out.items.len != 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, text);
    }
    return out.toOwnedSlice(a);
}

pub fn printers(a: A, message: ipp.Message) ![]Printer {
    var out: std.ArrayList(Printer) = .empty;
    var offset: usize = 0;
    while (offset < message.attributes.len) {
        var end = offset + 1;
        while (end < message.attributes.len and message.attributes[end].group_index == message.attributes[offset].group_index) : (end += 1) {}
        const attrs = message.attributes[offset..end];
        offset = end;
        if (attrs[0].group != .printer) continue;
        if (out.items.len == max_printers) return error.TooManyPrinters;
        const name = try identity(a, attrs, "printer-name", 127);
        if (!preferences.validQueue(name)) continue;
        var markers: std.ArrayList(Marker) = .empty;
        for (attrs) |attr| if (eq(u8, attr.name, "marker-names") and markers.items.len < 32) {
            try markers.append(a, .{ .name = try clean(a, attr.text() orelse continue), .level = null });
        };
        var index: usize = 0;
        for (attrs) |attr| if (eq(u8, attr.name, "marker-levels") and index < markers.items.len) {
            const value = attr.integer();
            markers.items[index].level = if (value != null and value.? >= 0 and value.? <= 100) value else null;
            index += 1;
        };
        try out.append(a, .{
            .name = name,
            .info = try txt(a, attrs, "printer-info"),
            .model = try txt(a, attrs, "printer-make-and-model"),
            .device_uri = try deviceUri(a, attrs),
            .state = int(attrs, "printer-state"),
            .accepting = if (find(attrs, "printer-is-accepting-jobs")) |attr| attr.boolean() else null,
            .reasons = try reasons(a, attrs, "printer-state-reasons"),
            .message = try txt(a, attrs, "printer-state-message"),
            .media = try txt(a, attrs, "media-default"),
            .resolution = if (find(attrs, "printer-resolution-default")) |attr| attr.resolution() else null,
            .color = try txt(a, attrs, "print-color-mode-default"),
            .sides = try txt(a, attrs, "sides-default"),
            .markers = try markers.toOwnedSlice(a),
            .is_default = if (int(attrs, "printer-type")) |value| value & 0x20000 != 0 else false,
            .device_id = try identity(a, attrs, "printer-device-id", 8192),
            .label_media = if (find(attrs, "media-type-default")) |attr| std.ascii.eqlIgnoreCase(attr.text() orelse "", "labels") else false,
            .inconsistent_defaults = conflictingDefaults(attrs),
            .attributes = try a.dupe(ipp.Attribute, attrs),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn jobs(a: A, message: ipp.Message, username: []const u8) ![]Job {
    var out: std.ArrayList(Job) = .empty;
    var offset: usize = 0;
    while (offset < message.attributes.len) {
        var end = offset + 1;
        while (end < message.attributes.len and message.attributes[end].group_index == message.attributes[offset].group_index) : (end += 1) {}
        const attrs = message.attributes[offset..end];
        offset = end;
        if (attrs[0].group != .job) continue;
        if (out.items.len == max_jobs) return error.TooManyJobs;
        const uri = try identity(a, attrs, "job-printer-uri", 8192);
        if (find(attrs, "job-originating-user-name") == null) continue;
        const owner = try identity(a, attrs, "job-originating-user-name", 255);
        const segment = uri[(std.mem.lastIndexOfScalar(u8, uri, '/') orelse continue) + 1 ..];
        const decoded = std.Uri.percentDecodeInPlace(try a.dupe(u8, segment));
        if (!preferences.validQueue(decoded)) continue;
        try out.append(a, .{
            .id = int(attrs, "job-id") orelse continue,
            .printer = try a.dupe(u8, decoded),
            .state = int(attrs, "job-state"),
            .sheets = int(attrs, "job-media-sheets-completed"),
            .reasons = try reasons(a, attrs, "job-state-reasons"),
            .message = try txt(a, attrs, "job-printer-state-message"),
            .own = eq(u8, owner, username),
        });
    }
    std.mem.sort(Job, out.items, {}, struct {
        fn less(_: void, lhs: Job, rhs: Job) bool {
            return lhs.id > rhs.id;
        }
    }.less);
    return out.toOwnedSlice(a);
}

pub fn printerState(value: ?i32) []const u8 {
    return switch (value orelse 0) {
        3 => @import("i18n").tr("Ready"),
        4 => @import("i18n").tr("Printing"),
        5 => @import("i18n").tr("Stopped"),
        else => @import("i18n").tr("State unavailable"),
    };
}
pub fn jobState(value: ?i32) []const u8 {
    return switch (value orelse 0) {
        3 => @import("i18n").tr("Pending"),
        4 => @import("i18n").tr("Held"),
        5 => @import("i18n").tr("Processing"),
        6 => @import("i18n").tr("Stopped"),
        7 => @import("i18n").tr("Cancelled"),
        8 => @import("i18n").tr("Aborted"),
        9 => @import("i18n").tr("Completed"),
        else => @import("i18n").tr("State unavailable"),
    };
}
pub fn failure(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => @import("i18n").tr("Not enough memory to load printer status. Refresh to check the result."),
        error.CupsUnavailable => @import("i18n").tr("CUPS is unavailable. Install or start CUPS, then refresh."),
        error.UnsupportedServer => @import("i18n").tr("This print server requires an unsupported encrypted or authenticated connection."),
        error.InvalidMedia, error.MediaTooSmall => @import("i18n").tr("Choose the actual paper dimensions before printing this test."),
        error.InvalidPreferences, error.AmbiguousPreferences => @import("i18n").tr("Printer preferences could not be saved safely. Check the existing preferences file."),
        error.PreferencesMigration => @import("i18n").tr("The queue changed, but personal preferences could not be moved. Check your default printer."),
        error.InvalidClientConfiguration => @import("i18n").tr("The CUPS client configuration could not be read or is invalid."),
        error.NotAuthorized => @import("i18n").tr("CUPS denied permission. The operation requires authorization."),
        error.Timeout => @import("i18n").tr("CUPS did not respond in time. Refresh to try again."),
        error.NotFound => @import("i18n").tr("The printer or job no longer exists. Refresh the list."),
        error.OperationUnsupported => @import("i18n").tr("This CUPS server does not support the requested operation."),
        error.UnsupportedPrintSettings => @import("i18n").tr("CUPS cannot honor the requested print settings. Check the paper, format and scaling options."),
        else => @import("i18n").tr("CUPS returned an invalid response or the connection failed. Refresh to try again."),
    };
}

test "display text and configuration parsing" {
    const a = std.testing.allocator;
    const cleaned = try clean(a, "Ready\x1b\n\xe2\x80\xae printer");
    defer a.free(cleaned);
    try std.testing.expectEqualStrings("Ready printer", cleaned);
    try std.testing.expectEqualStrings("/tmp/private.sock", (try clientConfig("# ServerName ignored\nServerName /tmp/private.sock # comment\n")).server.?);
    try std.testing.expectError(error.InvalidClientConfiguration, clientConfig("ServerName\n"));
    try std.testing.expectEqualStrings("Required", (try clientConfig("Encryption Required\n")).encryption.?);
    try std.testing.expectEqualStrings("/tmp/print server.sock", (try clientConfig("ServerName /tmp/print server.sock\n")).server.?);
    try std.testing.expectError(error.InvalidClientConfiguration, clientConfig("ServerName /tmp/print\\#server.sock\n"));
    try std.testing.expect(!(Job{ .id = 1, .state = 5, .own = false }).cancellable());
}

test "printer parser keeps groups defaults marker levels and safe display text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder = try ipp.Encoder.init(a, 0, 1);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.string(.name, "printer-name", "Ignored operation attribute");
    try encoder.group(.printer);
    try encoder.string(.name, "printer-name", "Office_Printer");
    try encoder.string(.text, "printer-make-and-model", "Example Laser");
    try encoder.string(.uri, "device-uri", "usb://Example/Laser?serial=abc");
    try encoder.integer(.enum_value, "printer-state", 5);
    try encoder.boolean("printer-is-accepting-jobs", false);
    try encoder.integer(.integer, "printer-type", 0x20000);
    try encoder.string(.keyword, "printer-state-reasons", "media-empty-error");
    try encoder.string(.keyword, "", "toner-low-warning");
    try encoder.string(.keyword, "media-default", "iso_a4_210x297mm");
    try encoder.string(.name, "media-default", "iso_a5_148x210mm");
    try encoder.value(.resolution, "printer-resolution-default", &.{ 0, 0, 2, 88, 0, 0, 2, 88, 3 });
    try encoder.string(.name, "marker-names", "Black");
    try encoder.string(.name, "", "Cyan");
    try encoder.integer(.integer, "marker-levels", 83);
    try encoder.integer(.integer, "", -2);
    try encoder.group(.printer);
    try encoder.string(.name, "printer-name", "Label");
    try encoder.group(.printer);
    try encoder.string(.text, "printer-info", "Missing name is skipped");
    try encoder.group(.printer);
    try encoder.string(.name, "printer-name", "Office\n_Printer");
    try encoder.group(.printer);
    try encoder.string(.name, "printer-name", "Conflicting_Queue");
    try encoder.string(.name, "printer-name", "Other_Queue");
    var message = try ipp.decode(a, try encoder.finish(), .{ .allow_duplicate_names = true });
    defer message.deinit(a);
    const result = try printers(a, message);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("Office_Printer", result[0].name);
    try std.testing.expectEqualStrings("Example Laser", result[0].model);
    try std.testing.expectEqualStrings("usb://Example/Laser?serial=abc", result[0].device_uri);
    try std.testing.expectEqual(@as(?i32, 5), result[0].state);
    try std.testing.expectEqual(@as(?bool, false), result[0].accepting);
    try std.testing.expect(result[0].is_default);
    try std.testing.expectEqualStrings("media-empty-error, toner-low-warning", result[0].reasons);
    try std.testing.expectEqualStrings("iso_a4_210x297mm", result[0].media);
    try std.testing.expect(result[0].inconsistent_defaults);
    try std.testing.expectEqual(@as(i32, 600), result[0].resolution.?.x);
    try std.testing.expectEqual(@as(usize, 2), result[0].markers.len);
    try std.testing.expectEqual(@as(?i32, 83), result[0].markers[0].level);
    try std.testing.expectEqual(@as(?i32, null), result[0].markers[1].level);
    try std.testing.expectEqualStrings("Label", result[1].name);
    try std.testing.expect(result[1].state == null and result[1].accepting == null);
    try std.testing.expect(result[1].markers.len == 0 and !result[1].is_default);
}

test "job parser preserves zero sheets decodes queue names and checks raw ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoder = try ipp.Encoder.init(a, 0, 1);
    defer encoder.deinit();
    try encoder.group(.operation);
    try encoder.group(.job);
    try encoder.integer(.integer, "job-id", 3);
    try encoder.string(.uri, "job-printer-uri", "ipp://localhost/printers/Office%5FPrinter");
    try encoder.string(.name, "job-originating-user-name", "alice");
    try encoder.integer(.enum_value, "job-state", 9);
    try encoder.integer(.integer, "job-media-sheets-completed", 0);
    try encoder.string(.text, "job-printer-state-message", "No pages were found.\n");
    try encoder.group(.job);
    try encoder.integer(.integer, "job-id", 99);
    try encoder.string(.uri, "job-printer-uri", "ipp://localhost/printers/Label");
    try encoder.string(.name, "job-originating-user-name", "alice\n");
    try encoder.integer(.enum_value, "job-state", 5);
    try encoder.group(.job);
    try encoder.integer(.integer, "job-id", 101);
    try encoder.string(.uri, "job-printer-uri", "ipp://localhost/printers/Label");
    // A record without an owner must never acquire cancellation permission.
    var message = try ipp.decode(a, try encoder.finish(), .{});
    defer message.deinit(a);
    const result = try jobs(a, message, "alice");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(i32, 99), result[0].id);
    try std.testing.expect(!result[0].own and !result[0].cancellable());
    try std.testing.expectEqual(@as(i32, 3), result[1].id);
    try std.testing.expectEqualStrings("Office_Printer", result[1].printer);
    try std.testing.expectEqual(@as(?i32, 0), result[1].sheets);
    try std.testing.expectEqualStrings("No pages were found.", result[1].message);
    try std.testing.expect(result[1].own and !result[1].cancellable());
    for (3..7) |state| try std.testing.expect((Job{ .id = 1, .state = @intCast(state), .own = true }).cancellable());
    try std.testing.expect(!(Job{ .id = 0, .state = 5, .own = true }).cancellable());
    try std.testing.expect(!(Job{ .id = 1, .own = true }).cancellable());
}

test "printer and job parsers bound result counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var printer_encoder = try ipp.Encoder.init(a, 0, 1);
    defer printer_encoder.deinit();
    try printer_encoder.group(.operation);
    for (0..max_printers + 1) |_| {
        try printer_encoder.group(.printer);
        try printer_encoder.string(.name, "printer-name", "Queue");
    }
    var printer_message = try ipp.decode(a, try printer_encoder.finish(), .{});
    defer printer_message.deinit(a);
    try std.testing.expectError(error.TooManyPrinters, printers(a, printer_message));
    var job_encoder = try ipp.Encoder.init(a, 0, 1);
    defer job_encoder.deinit();
    try job_encoder.group(.operation);
    for (0..max_jobs + 1) |index| {
        try job_encoder.group(.job);
        try job_encoder.integer(.integer, "job-id", @intCast(index + 1));
        try job_encoder.string(.uri, "job-printer-uri", "ipp://localhost/printers/Queue");
        try job_encoder.string(.name, "job-originating-user-name", "alice");
    }
    var job_message = try ipp.decode(a, try job_encoder.finish(), .{});
    defer job_message.deinit(a);
    try std.testing.expectError(error.TooManyJobs, jobs(a, job_message, "alice"));
}

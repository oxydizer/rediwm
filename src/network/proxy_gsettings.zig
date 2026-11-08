//! The system proxy in GSettings (`org.gnome.system.proxy`), through the GIO
//! ABI declared by hand (GLib's headers never go through translate-c). The
//! schemas come with gsettings-desktop-schemas; `g_settings_new` aborts on a
//! missing schema, so every entry point checks first.

const std = @import("std");
const proxy = @import("proxy.zig");
const Text = @import("types.zig").Text;
const a = std.heap.c_allocator;

extern fn g_settings_schema_source_get_default() ?*anyopaque;
extern fn g_settings_schema_source_lookup(source: *anyopaque, schema_id: [*:0]const u8, recursive: c_int) ?*anyopaque;
extern fn g_settings_schema_unref(schema: *anyopaque) void;
extern fn g_settings_new(schema_id: [*:0]const u8) *anyopaque;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_settings_get_string(settings: *anyopaque, key: [*:0]const u8) [*:0]u8;
extern fn g_settings_get_int(settings: *anyopaque, key: [*:0]const u8) c_int;
extern fn g_settings_get_strv(settings: *anyopaque, key: [*:0]const u8) [*:null]?[*:0]u8;
extern fn g_settings_set_string(settings: *anyopaque, key: [*:0]const u8, value: [*:0]const u8) c_int;
extern fn g_settings_set_int(settings: *anyopaque, key: [*:0]const u8, value: c_int) c_int;
extern fn g_settings_set_strv(settings: *anyopaque, key: [*:0]const u8, value: ?[*:null]const ?[*:0]const u8) c_int;
extern fn g_settings_sync() void;
extern fn g_free(memory: ?*anyopaque) void;
extern fn g_strfreev(strings: [*:null]?[*:0]u8) void;

const base = "org.gnome.system.proxy";
const schemas = [_][*:0]const u8{ base, base ++ ".http", base ++ ".https", base ++ ".socks" };

/// All four schemas are installed.
pub fn available() bool {
    const source = g_settings_schema_source_get_default() orelse return false;
    for (schemas) |id| {
        const schema = g_settings_schema_source_lookup(source, id, 1) orelse return false;
        g_settings_schema_unref(schema);
    }
    return true;
}

fn string(settings: *anyopaque, key: [*:0]const u8, out: anytype) void {
    const value = g_settings_get_string(settings, key);
    defer g_free(value);
    out.set(std.mem.span(value));
}

fn endpoint(id: [*:0]const u8) proxy.Endpoint {
    const settings = g_settings_new(id);
    defer g_object_unref(settings);
    var out: proxy.Endpoint = .{};
    string(settings, "host", &out.host);
    const port = g_settings_get_int(settings, "port");
    out.port = if (port > 0 and port <= 65535) @intCast(port) else 0;
    return out;
}

/// The current setting; the defaults when the schemas are missing.
pub fn read() proxy.Config {
    var out: proxy.Config = .{};
    if (!available()) return out;
    const settings = g_settings_new(base);
    defer g_object_unref(settings);
    var mode: Text(16) = .{};
    string(settings, "mode", &mode);
    out.mode = if (std.mem.eql(u8, mode.slice(), "manual")) .manual else if (std.mem.eql(u8, mode.slice(), "auto")) .auto else .off;
    string(settings, "autoconfig-url", &out.pac);
    const hosts = g_settings_get_strv(settings, "ignore-hosts");
    defer g_strfreev(hosts);
    var i: usize = 0;
    while (hosts[i]) |host| : (i += 1) @import("manager_props.zig").append(&out.ignore, std.mem.span(host));
    out.http = endpoint(base ++ ".http");
    out.https = endpoint(base ++ ".https");
    out.socks = endpoint(base ++ ".socks");
    return out;
}

fn writeEndpoint(id: [*:0]const u8, e: proxy.Endpoint) void {
    const settings = g_settings_new(id);
    defer g_object_unref(settings);
    var host: [129]u8 = undefined;
    @memcpy(host[0..e.host.len], e.host.slice());
    host[e.host.len] = 0;
    _ = g_settings_set_string(settings, "host", @ptrCast(&host));
    _ = g_settings_set_int(settings, "port", e.port);
}

/// Stores `config`. Blocks until the backend has it, so call it off the main thread.
pub fn write(config: *const proxy.Config) void {
    if (!available()) return;
    const settings = g_settings_new(base);
    defer g_object_unref(settings);
    _ = g_settings_set_string(settings, "mode", switch (config.mode) {
        .off => "none",
        .manual => "manual",
        .auto => "auto",
    });
    if (config.pac.len != 0) {
        var pac: [257]u8 = undefined;
        @memcpy(pac[0..config.pac.len], config.pac.slice());
        pac[config.pac.len] = 0;
        _ = g_settings_set_string(settings, "autoconfig-url", @ptrCast(&pac));
    }
    // The ignore list: one NUL-terminated copy of the text, split in place.
    var text: [513]u8 = undefined;
    var pointers: [65:null]?[*:0]const u8 = @splat(null);
    var len: usize = 0;
    var count: usize = 0;
    var entries = proxy.ignoreEntries(config.ignore.slice());
    while (entries.next()) |entry| {
        if (count == pointers.len or len + entry.len + 1 > text.len) break;
        @memcpy(text[len..][0..entry.len], entry);
        text[len + entry.len] = 0;
        pointers[count] = @ptrCast(text[len..].ptr);
        count += 1;
        len += entry.len + 1;
    }
    _ = g_settings_set_strv(settings, "ignore-hosts", &pointers);
    writeEndpoint(base ++ ".http", config.http);
    writeEndpoint(base ++ ".https", config.https);
    writeEndpoint(base ++ ".socks", config.socks);
    g_settings_sync();
}

const Job = struct { config: proxy.Config };

fn work(job: *Job) void {
    defer a.destroy(job);
    write(&job.config);
}

/// `write` on a short-lived thread: a dconf write talks to the session bus.
pub fn writeAsync(config: proxy.Config) void {
    const job = a.create(Job) catch return;
    job.* = .{ .config = config };
    const thread = std.Thread.spawn(.{}, work, .{job}) catch {
        a.destroy(job);
        return;
    };
    thread.detach();
}

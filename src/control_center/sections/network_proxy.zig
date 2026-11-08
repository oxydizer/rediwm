//! The Proxy card: Off, Manual (HTTP, HTTPS, SOCKS and a bypass list) or an
//! automatic configuration script. Applying stores the setting in GSettings
//! (what GTK/GIO apps and Firefox's "system proxy" read) and updates the
//! environment of apps RediWM starts from then on. It is per user and never
//! needs authentication.

const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const proxy = @import("../../network/proxy.zig");
const gsettings = @import("../../network/proxy_gsettings.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");
const fields = @import("network_fields.zig");
const text = widgets.text;
const group = widgets.group;
const card = widgets.card;
const action = widgets.action;

pub const Field = enum { http_host, http_port, https_host, https_port, socks_host, socks_port, ignore, pac };

pub const State = struct {
    loaded: bool = false,
    available: bool = true,
    mode: usize = 0,
    problem: []const u8 = "",
    message: []const u8 = "",
    fields: fields.Slots(Field) = .{},

    pub fn capture(s: *State) void {
        s.fields.capture();
    }
    pub fn deinit(s: *State) void {
        s.fields.release();
    }
};

fn modeLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Off"), i18n.msg("Manual"), i18n.msg("Automatic") });
}

fn fill(cc: *panel.ControlCenter) void {
    const s = &cc.network.proxy;
    const config = cc.server.systemProxy();
    s.fields.release();
    s.available = gsettings.available();
    s.mode = @intFromEnum(config.mode);
    var port: [8]u8 = undefined;
    const pairs = [_]struct { host: Field, port: Field, endpoint: proxy.Endpoint }{
        .{ .host = .http_host, .port = .http_port, .endpoint = config.http },
        .{ .host = .https_host, .port = .https_port, .endpoint = config.https },
        .{ .host = .socks_host, .port = .socks_port, .endpoint = config.socks },
    };
    for (pairs) |pair| {
        s.fields.set(cc, pair.host, pair.endpoint.host.slice(), i18n.tr("proxy.example.com"));
        s.fields.set(cc, pair.port, if (pair.endpoint.port == 0) "" else std.fmt.bufPrint(&port, "{d}", .{pair.endpoint.port}) catch "", i18n.tr("8080"));
    }
    s.fields.set(cc, .ignore, config.ignore.slice(), i18n.tr("localhost, 127.0.0.0/8, ::1"));
    s.fields.set(cc, .pac, config.pac.slice(), i18n.tr("http://wpad.example.com/wpad.dat"));
    s.loaded = true;
}

fn endpointRow(s: *State, a: Allocator, host: Field, port: Field, name: []const u8, title: []const u8) !W {
    var host_name: [32]u8 = undefined;
    var port_name: [32]u8 = undefined;
    var row = try group(a, .row, &.{
        try s.fields.input(a, host, try a.dupe(u8, std.fmt.bufPrint(&host_name, "proxy_{s}_host", .{name}) catch name), title),
        try s.fields.input(a, port, try a.dupe(u8, std.fmt.bufPrint(&port_name, "proxy_{s}_port", .{name}) catch name), i18n.tr("Port")),
    });
    row.@"align" = .start;
    row.children[0].width = .{ .flex = 4 };
    row.children[1].width = .{ .flex = 1 };
    return row;
}

pub fn build(cc: *panel.ControlCenter, a: Allocator) !W {
    const s = &cc.network.proxy;
    if (!s.loaded) fill(cc);
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(i18n.tr("Proxy"), 20, false));
    try items.append(a, text(i18n.tr("Apps that follow the system proxy use this. A manual proxy is also given to apps started from RediWM."), 12, true));
    if (!s.available) {
        try items.append(a, text(i18n.tr("System proxy settings need the gsettings-desktop-schemas package."), 12, true));
        var unavailable = try card(a, items.items);
        unavailable.name = "proxy_card";
        return unavailable;
    }
    const mode = fields.labeled(a, i18n.tr("Proxy"), .{ .name = "proxy_mode", .kind = .{ .select = .{ .labels = modeLabels(), .selected = s.mode, .owner = cc, .on_change = modeChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
    try items.append(a, try mode);
    if (s.mode == @intFromEnum(proxy.Mode.manual)) {
        try items.append(a, try endpointRow(s, a, .http_host, .http_port, "http", i18n.tr("HTTP proxy")));
        try items.append(a, try endpointRow(s, a, .https_host, .https_port, "https", i18n.tr("HTTPS proxy")));
        try items.append(a, try endpointRow(s, a, .socks_host, .socks_port, "socks", i18n.tr("SOCKS host")));
        try items.append(a, try s.fields.input(a, .ignore, "proxy_ignore", i18n.tr("Bypass the proxy for")));
    } else if (s.mode == @intFromEnum(proxy.Mode.auto)) {
        try items.append(a, try s.fields.input(a, .pac, "proxy_pac", i18n.tr("Configuration URL")));
    }
    const message = if (s.problem.len != 0) s.problem else s.message;
    if (message.len != 0) try items.append(a, text(message, 12, true));
    var apply = action(cc, "proxy_apply", i18n.tr("Apply"), 0, applyClicked, false);
    apply.kind.button.variant = .primary;
    apply.width = .auto;
    var row = try group(a, .row, &.{apply});
    row.justify = .end;
    try items.append(a, row);
    var result = try card(a, items.items);
    result.name = "proxy_card";
    return result;
}

fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}

fn modeChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    const s = &cc.network.proxy;
    s.fields.capture();
    s.mode = index;
    s.problem = "";
    s.message = "";
    cc.refresh();
}

fn endpoint(s: *const State, host: Field, port: Field, out: *proxy.Endpoint, label: []const u8) ?[]const u8 {
    const h = std.mem.trim(u8, s.fields.value(host), " ");
    const p = std.mem.trim(u8, s.fields.value(port), " ");
    out.* = .{};
    // The schema's default port is filled in even when there is no host: no host, no proxy.
    if (h.len == 0) return null;
    if (!proxy.validHost(h)) return label;
    out.port = proxy.parsePort(p) orelse return label;
    out.host.set(h);
    return null;
}

fn applyClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const s = &cc.network.proxy;
    var config = cc.server.systemProxy().*;
    s.problem = "";
    s.message = "";
    config.mode = @enumFromInt(s.mode);
    switch (config.mode) {
        .off => {},
        .manual => {
            if (endpoint(s, .http_host, .http_port, &config.http, i18n.tr("Check the HTTP proxy host and port (1–65535).")) orelse
                endpoint(s, .https_host, .https_port, &config.https, i18n.tr("Check the HTTPS proxy host and port (1–65535).")) orelse
                endpoint(s, .socks_host, .socks_port, &config.socks, i18n.tr("Check the SOCKS host and port (1–65535).")) orelse
                (if (!config.http.set() and !config.https.set() and !config.socks.set()) i18n.tr("Enter at least one proxy.") else null)) |problem|
            {
                s.problem = problem;
                return cc.refresh();
            }
            config.ignore = .{};
            var entries = proxy.ignoreEntries(s.fields.value(.ignore));
            while (entries.next()) |entry| {
                if (entry.len > 64) {
                    s.problem = i18n.tr("Each bypass entry must be at most 64 characters.");
                    return cc.refresh();
                }
                @import("../../network/manager_props.zig").append(&config.ignore, entry);
            }
        },
        .auto => {
            const url = std.mem.trim(u8, s.fields.value(.pac), " ");
            if (!proxy.validPac(url)) {
                s.problem = i18n.tr("Enter an http://, https:// or file:// address.");
                return cc.refresh();
            }
            config.pac.set(url);
        },
    }
    cc.server.proxy = config;
    gsettings.writeAsync(config);
    s.message = if (config.mode == .manual) i18n.tr("Applied. Apps you start from now on use this proxy.") else i18n.tr("Applied.");
    cc.refresh();
}

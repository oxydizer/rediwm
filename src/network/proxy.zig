//! The system proxy setting: its model, input checks and the environment
//! variables spawned apps get. Storage is GSettings (`proxy_gsettings.zig`),
//! the same keys GTK/GIO apps and Firefox's "system proxy" already read.
//! NetworkManager has no manual proxy at all (only a per-connection PAC URL).

const std = @import("std");
const types = @import("types.zig");
const Text = types.Text;

pub const Mode = enum { off, manual, auto };
pub const Endpoint = struct {
    host: Text(128) = .{},
    port: u16 = 0,
    pub fn set(self: Endpoint) bool {
        return self.host.len != 0 and self.port != 0;
    }
};
pub const Config = struct {
    mode: Mode = .off,
    http: Endpoint = .{},
    https: Endpoint = .{},
    socks: Endpoint = .{},
    /// Hosts that bypass the proxy, comma separated.
    ignore: Text(512) = .{},
    /// Where an automatic configuration script lives.
    pac: Text(256) = .{},
};

/// A host name or address as a proxy host: no scheme, path, port or spaces.
pub fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 128) return false;
    for (host) |c| {
        if (c <= ' ' or c == '/' or c == '@' or c == '[' or c == ']' or c == '\\') return false;
    }
    // A colon belongs to an IPv6 literal; anything else with one is host:port.
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return false;
    }
    return true;
}

pub fn parsePort(value: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, value, " "), 10) catch return null;
    return if (n == 0) null else n;
}

pub fn validPac(url: []const u8) bool {
    if (url.len == 0 or url.len > 256) return false;
    for (url) |c| if (c <= ' ') return false;
    for ([_][]const u8{ "http://", "https://", "file://" }) |scheme| {
        if (std.mem.startsWith(u8, url, scheme) and url.len > scheme.len) return true;
    }
    return false;
}

/// The ignore list as separate entries (commas and spaces both separate).
pub fn ignoreEntries(list: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, list, ", ");
}

fn endpointUrl(buffer: []u8, scheme: []const u8, e: Endpoint) ![]const u8 {
    const v6 = std.mem.indexOfScalar(u8, e.host.slice(), ':') != null;
    return std.fmt.bufPrint(buffer, "{s}://{s}{s}{s}:{d}", .{ scheme, if (v6) "[" else "", e.host.slice(), if (v6) "]" else "", e.port });
}

fn put(map: *std.process.Environ.Map, lower: []const u8, upper: []const u8, value: []const u8) !void {
    try map.put(lower, value);
    try map.put(upper, value);
}

/// Adds the proxy variables for children. Only a manual setting exports
/// anything: a script cannot be written as a variable, and Off must not strip
/// what the user's own login environment sets.
pub fn environment(map: *std.process.Environ.Map, config: *const Config) !void {
    if (config.mode != .manual) return;
    var buffer: [300]u8 = undefined;
    if (config.http.set()) try put(map, "http_proxy", "HTTP_PROXY", try endpointUrl(&buffer, "http", config.http));
    if (config.https.set()) try put(map, "https_proxy", "HTTPS_PROXY", try endpointUrl(&buffer, "http", config.https));
    if (config.socks.set()) try put(map, "all_proxy", "ALL_PROXY", try endpointUrl(&buffer, "socks5h", config.socks));
    if (config.ignore.len != 0) {
        var joined: [520]u8 = undefined;
        var len: usize = 0;
        var entries = ignoreEntries(config.ignore.slice());
        while (entries.next()) |entry| {
            if (len + entry.len + 1 > joined.len) break;
            if (len != 0) {
                joined[len] = ',';
                len += 1;
            }
            @memcpy(joined[len..][0..entry.len], entry);
            len += entry.len;
        }
        if (len != 0) try put(map, "no_proxy", "NO_PROXY", joined[0..len]);
    }
}

test "manual proxies export both spellings and bracket IPv6 hosts" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    var config: Config = .{ .mode = .manual };
    config.http = .{ .host = Text(128).init("proxy.example"), .port = 3128 };
    config.https = .{ .host = Text(128).init("2001:db8::1"), .port = 3129 };
    config.socks = .{ .host = Text(128).init("127.0.0.1"), .port = 1080 };
    config.ignore.set("localhost, 10.0.0.0/8 ::1");
    try environment(&map, &config);
    try std.testing.expectEqualStrings("http://proxy.example:3128", map.get("http_proxy").?);
    try std.testing.expectEqualStrings("http://proxy.example:3128", map.get("HTTP_PROXY").?);
    try std.testing.expectEqualStrings("http://[2001:db8::1]:3129", map.get("https_proxy").?);
    try std.testing.expectEqualStrings("socks5h://127.0.0.1:1080", map.get("ALL_PROXY").?);
    try std.testing.expectEqualStrings("localhost,10.0.0.0/8,::1", map.get("no_proxy").?);
}

test "off and automatic leave the environment alone" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("http_proxy", "http://mine:1");
    var config: Config = .{ .mode = .off };
    config.http = .{ .host = Text(128).init("proxy.example"), .port = 3128 };
    try environment(&map, &config);
    config.mode = .auto;
    try environment(&map, &config);
    try std.testing.expectEqualStrings("http://mine:1", map.get("http_proxy").?);
    try std.testing.expect(map.get("HTTP_PROXY") == null);
}

test "input checks" {
    try std.testing.expect(validHost("proxy.example") and validHost("10.1.2.3") and validHost("2001:db8::1"));
    try std.testing.expect(!validHost("") and !validHost("http://proxy") and !validHost("proxy:8080") and !validHost("a b") and !validHost("[::1]"));
    try std.testing.expectEqual(@as(?u16, 8080), parsePort(" 8080 "));
    try std.testing.expect(parsePort("0") == null and parsePort("70000") == null and parsePort("x") == null and parsePort("") == null);
    try std.testing.expect(validPac("http://wpad.local/wpad.dat") and validPac("file:///etc/proxy.pac"));
    try std.testing.expect(!validPac("wpad.local/wpad.dat") and !validPac("http://") and !validPac("http://a b"));
}

//! Reading and writing NetworkManager connection settings: addresses, saved Wi-Fi, wired and wireless settings and password updates.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const eq = std.mem.eql;
const manager = @import("manager.zig");
const Text = manager.Text;
const Path = manager.Path;
const Network = manager.Network;
const Saved = manager.Saved;

pub fn parseMethod(value: []const u8) manager.Method {
    if (eq(u8, value, "auto") or eq(u8, value, "dhcp")) return .auto;
    if (eq(u8, value, "manual")) return .manual;
    if (eq(u8, value, "link-local")) return .link_local;
    if (eq(u8, value, "shared")) return .shared;
    if (eq(u8, value, "disabled") or eq(u8, value, "ignore")) return .disabled;
    return .other;
}

pub fn writeWiredSettings(b: *wire.Writer, name: []const u8) !void {
    const all = try b.beginArray(8);
    const conn = try section(b, "connection");
    try str(b, "id", name);
    try str(b, "type", "802-3-ethernet");
    try str(b, "interface-name", name);
    try b.endArray(conn);
    const eth = try section(b, "802-3-ethernet");
    try b.endArray(eth);
    const ip4 = try section(b, "ipv4");
    try str(b, "method", "auto");
    try b.endArray(ip4);
    const ip6 = try section(b, "ipv6");
    try str(b, "method", "auto");
    try b.endArray(ip6);
    try b.endArray(all);
}

pub fn parseSaved(b: *wire.Reader, path: Path) !Saved {
    var out: Saved = .{ .path = path, .loaded = true };
    var sections = try b.array(8);
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const section_name = try sections.string();
        var props = try sections.array(8);
        while (props.offset < props.bytes.len) {
            try props.alignTo(8);
            const key = try props.string();
            const sig = try props.variant();
            if (eq(u8, section_name, "connection") and eq(u8, key, "id") and eq(u8, sig, "s")) {
                out.id.set(try props.string());
            } else if (eq(u8, section_name, "connection") and eq(u8, key, "type") and eq(u8, sig, "s")) {
                out.kind.set(try props.string());
            } else if (eq(u8, section_name, "connection") and eq(u8, key, "autoconnect") and eq(u8, sig, "b")) {
                out.autoconnect = try props.boolean();
            } else if ((eq(u8, section_name, "ipv4") or eq(u8, section_name, "ipv6")) and eq(u8, key, "method") and eq(u8, sig, "s")) {
                const method = parseMethod(try props.string());
                if (eq(u8, section_name, "ipv4")) out.method4 = method else out.method6 = method;
            } else if (eq(u8, section_name, "802-11-wireless") and eq(u8, key, "ssid") and eq(u8, sig, "ay")) {
                var bytes = try props.array(1);
                out.ssid.set(try bytes.take(bytes.bytes.len - bytes.offset));
            } else if (eq(u8, section_name, "802-11-wireless-security") and eq(u8, key, "key-mgmt") and eq(u8, sig, "s")) {
                const value = try props.string();
                out.security = if (eq(u8, value, "wpa-psk")) .personal else if (eq(u8, value, "sae")) .sae else .unsupported;
            } else try props.skip(sig);
        }
    }
    return out;
}

pub fn section(b: *wire.Writer, name: []const u8) !wire.Writer.Array {
    try b.alignTo(8);
    try b.string(name);
    return b.beginArray(8);
}

pub fn prop(b: *wire.Writer, name: []const u8, sig: []const u8) !void {
    try b.alignTo(8);
    try b.string(name);
    try b.variant(sig);
}

pub fn str(b: *wire.Writer, name: []const u8, value: []const u8) !void {
    try prop(b, name, "s");
    try b.string(value);
}

pub fn writeSettings(b: *wire.Writer, net: Network, password: []const u8, autojoin: bool, hidden: bool) !void {
    const all = try b.beginArray(8);
    const conn = try section(b, "connection");
    // SSIDs are byte strings. Use a valid UTF-8 display name for connection.id.
    try str(b, "id", if (std.unicode.utf8ValidateSlice(net.ssid.slice())) net.ssid.slice() else i18n.tr("Wi-Fi network"));
    try str(b, "type", "802-11-wireless");
    try prop(b, "autoconnect", "b");
    try b.boolean(autojoin);
    try b.endArray(conn);
    const wifi = try section(b, "802-11-wireless");
    try prop(b, "ssid", "ay");
    const bytes = try b.beginArray(1);
    try b.raw(net.ssid.slice());
    try b.endArray(bytes);
    try str(b, "mode", "infrastructure");
    try prop(b, "hidden", "b");
    try b.boolean(hidden);
    try b.endArray(wifi);
    if (net.security != .open) {
        const security = try section(b, "802-11-wireless-security");
        try str(b, "key-mgmt", if (net.security == .sae) "sae" else "wpa-psk");
        try str(b, "psk", password);
        try b.endArray(security);
    }
    try b.endArray(all);
}

/// Dict entries start at an 8-byte boundary in both readers and writers, so
/// copying a complete unchanged entry preserves every nested value's alignment.
pub fn replacePassword(reader: *wire.Reader, b: *wire.Writer, password: []const u8) !void {
    b.endian = reader.endian;
    const all = try b.beginArray(8);
    var sections = try reader.array(8);
    var found_security = false;
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const name = try sections.string();
        const out = try section(b, name);
        const security = eq(u8, name, "802-11-wireless-security");
        var entries = try sections.array(8);
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const start = entries.offset;
            const key = try entries.string();
            const sig = try entries.variant();
            try entries.skip(sig);
            if (security and (eq(u8, key, "psk") or eq(u8, key, "psk-flags"))) continue;
            try b.alignTo(8);
            try b.raw(entries.bytes[start..entries.offset]);
        }
        if (security) {
            found_security = true;
            try str(b, "psk", password);
            try prop(b, "psk-flags", "u");
            try b.uint32(0);
        }
        try b.endArray(out);
    }
    if (!found_security) return error.MissingSecurity;
    try b.endArray(all);
}

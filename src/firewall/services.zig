//! Services the page offers by name. A service expands into port rules for
//! managers without their own catalog (our table, our anchor, ufw); with
//! firewalld the helper uses firewalld's service of the same name when it
//! exists (`firewalld`).
const std = @import("std");
const model = @import("model.zig");

pub const Port = struct { proto: model.Proto, port: []const u8 };

pub const Service = struct {
    id: []const u8,
    /// English; the page translates it through its own copy of these names
    /// (`control_center/sections/firewall_rules.zig`), which must match.
    name: []const u8,
    ports: []const Port,
    /// Suggested scope: discovery and sharing belong on home networks.
    scope: model.Scope = .home,
    /// firewalld's service name: null when it is `id`, "" when firewalld has
    /// none (the helper then opens the ports).
    firewalld: ?[]const u8 = null,
};

pub const all = [_]Service{
    .{ .id = "ssh", .name = "SSH (remote login)", .ports = &.{.{ .proto = .tcp, .port = "22" }} },
    .{ .id = "http", .name = "Web server (HTTP)", .ports = &.{.{ .proto = .tcp, .port = "80" }}, .scope = .everywhere },
    .{ .id = "https", .name = "Web server (HTTPS)", .ports = &.{.{ .proto = .tcp, .port = "443" }}, .scope = .everywhere },
    .{ .id = "mdns", .name = "Local network discovery (mDNS)", .ports = &.{.{ .proto = .udp, .port = "5353" }} },
    .{ .id = "kdeconnect", .name = "KDE Connect / GSConnect", .ports = &.{ .{ .proto = .tcp, .port = "1714-1764" }, .{ .proto = .udp, .port = "1714-1764" } } },
    .{ .id = "syncthing", .name = "Syncthing", .ports = &.{ .{ .proto = .tcp, .port = "22000" }, .{ .proto = .udp, .port = "22000" }, .{ .proto = .udp, .port = "21027" } } },
    .{ .id = "steam-streaming", .name = "Steam Remote Play", .ports = &.{ .{ .proto = .udp, .port = "27031-27036" }, .{ .proto = .tcp, .port = "27036" }, .{ .proto = .tcp, .port = "27037" } } },
    .{ .id = "samba", .name = "Windows file sharing (Samba)", .ports = &.{ .{ .proto = .udp, .port = "137-138" }, .{ .proto = .tcp, .port = "139" }, .{ .proto = .tcp, .port = "445" } } },
    .{ .id = "ipp", .name = "Printer sharing (IPP)", .ports = &.{.{ .proto = .tcp, .port = "631" }} },
    .{ .id = "dlna", .name = "Media sharing (DLNA)", .ports = &.{ .{ .proto = .udp, .port = "1900" }, .{ .proto = .tcp, .port = "8200" } }, .firewalld = "upnp-client" },
    .{ .id = "spotify-sync", .name = "Spotify local discovery", .ports = &.{ .{ .proto = .tcp, .port = "57621" }, .{ .proto = .udp, .port = "57621" } } },
    .{ .id = "torrent", .name = "Files transfers (BitTorrent)", .ports = &.{ .{ .proto = .tcp, .port = "6881-6889" }, .{ .proto = .udp, .port = "6881-6889" } }, .scope = .everywhere, .firewalld = "" },
    .{ .id = "vnc-server", .name = "Screen sharing (VNC)", .ports = &.{.{ .proto = .tcp, .port = "5900-5903" }} },
    .{ .id = "rdp", .name = "Remote desktop (RDP)", .ports = &.{.{ .proto = .tcp, .port = "3389" }} },
    .{ .id = "wireguard", .name = "WireGuard server", .ports = &.{.{ .proto = .udp, .port = "51820" }}, .scope = .everywhere },
    .{ .id = "nfs", .name = "NFS file sharing", .ports = &.{ .{ .proto = .tcp, .port = "2049" }, .{ .proto = .udp, .port = "2049" } } },
    .{ .id = "minecraft", .name = "Minecraft server", .ports = &.{.{ .proto = .tcp, .port = "25565" }}, .scope = .everywhere },
};

pub fn find(id: []const u8) ?*const Service {
    for (&all) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

/// The catalog service a rule's port and protocol match exactly, for naming
/// rules that came in as bare ports.
pub fn named(proto: model.Proto, port: []const u8) ?*const Service {
    for (&all) |*s| {
        if (s.ports.len != 1) continue;
        if (s.ports[0].proto == proto and std.mem.eql(u8, s.ports[0].port, port)) return s;
    }
    return null;
}

test "catalog ids are unique and valid" {
    const validate = @import("validate.zig");
    for (all, 0..) |s, i| {
        try std.testing.expect(validate.service(s.id));
        for (s.ports) |p| try std.testing.expect(validate.port(p.port));
        for (all[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, s.id, other.id));
    }
    try std.testing.expect(find("ssh") != null);
    try std.testing.expectEqualStrings("ssh", named(.tcp, "22").?.id);
}

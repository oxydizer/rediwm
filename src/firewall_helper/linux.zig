//! Linux: detects which manager runs (our nftables table, firewalld, ufw,
//! RediOS's generated ruleset), reads it into the model and applies changes
//! through it. Our own table is written only when nothing else manages the
//! firewall.
const std = @import("std");
const fw = @import("firewall");
const model = fw.model;
const run = @import("run.zig");
const state = @import("state.zig");
const nm = @import("networks.zig");
const Ctx = run.Ctx;
const Request = fw.protocol.Request;

const Detected = struct {
    tables: []const fw.inventory.Table = &.{},
    own: fw.own.State = .{},
    own_live: bool = false,
    ufw_installed: bool = false,
    ufw_active: bool = false,
    firewalld_installed: bool = false,
    firewalld_running: bool = false,
    redi: bool = false,
    nft: bool = false,
};

fn detect(ctx: Ctx) Detected {
    var d: Detected = .{ .own = state.load(ctx) };
    if (run.tryTool(ctx, "nft", &.{ "-j", "list", "ruleset" })) |result| {
        d.nft = true;
        if (result.ok) d.tables = fw.inventory.parseNft(ctx.a, result.out) catch &.{};
    }
    d.own_live = fw.inventory.hasTable(d.tables, fw.own.table);
    d.redi = fw.inventory.hasTable(d.tables, "redi");
    if (run.tool(ctx, "ufw") != null) {
        d.ufw_installed = true;
        if (run.tryTool(ctx, "ufw", &.{"status"})) |result| d.ufw_active = fw.ufw.active(result.out);
    }
    if (run.tool(ctx, "firewall-cmd") != null) {
        d.firewalld_installed = true;
        if (run.tryTool(ctx, "firewall-cmd", &.{"--state"})) |result| d.firewalld_running = result.ok;
    }
    return d;
}

fn manager(d: Detected) model.Backend {
    if (d.own.enabled) return .own;
    if (d.firewalld_running) return .firewalld;
    if (d.ufw_active) return .ufw;
    if (d.redi) return .redi;
    if (d.ufw_installed) return .ufw;
    if (d.firewalld_installed) return .firewalld;
    if (d.nft) return .own;
    return .none;
}

fn ownerName(backend: model.Backend) []const u8 {
    return switch (backend) {
        .ufw => "ufw",
        .firewalld => "firewalld",
        .redi => "RediOS",
        else => "",
    };
}

pub fn status(ctx: Ctx) !model.Status {
    const d = detect(ctx);
    const backend = manager(d);
    var s: model.Status = .{ .system = .linux, .backend = backend };
    var conflicts: std.ArrayList(model.Backend) = .empty;
    var installed: std.ArrayList(model.Backend) = .empty;
    const actives = [_]struct { b: model.Backend, on: bool }{
        .{ .b = .own, .on = d.own.enabled },
        .{ .b = .firewalld, .on = d.firewalld_running },
        .{ .b = .ufw, .on = d.ufw_active },
        .{ .b = .redi, .on = d.redi },
    };
    for (actives) |entry| if (entry.on and entry.b != backend) try conflicts.append(ctx.a, entry.b);
    if (d.ufw_installed and !d.ufw_active) try installed.append(ctx.a, .ufw);
    if (d.firewalld_installed and !d.firewalld_running) try installed.append(ctx.a, .firewalld);
    if (d.nft) try installed.append(ctx.a, .own);
    s.conflicts = conflicts.items;
    s.installed = installed.items;

    switch (backend) {
        .own => {
            const view = try fw.own.status(ctx.a, d.own);
            s.incoming = view.incoming;
            s.outgoing = view.outgoing;
            s.forward = view.forward;
            s.ping = view.ping;
            s.logging = view.logging;
            s.ssh_limit = view.ssh_limit;
            s.rules = view.rules;
            s.running = d.own.enabled and d.own_live;
            s.boot = d.own.enabled and systemdEnabled(ctx, "rediwm-firewall.service");
            s.capabilities = .{ .edit = true, .trust = true, .sources = true, .limit = true, .reject = true, .outgoing_rules = true, .outgoing_policy = true, .forward_policy = true, .ping = true, .logging = true, .ssh_limit = true, .boot = run.tool(ctx, "systemctl") != null, .lockdown = true };
        },
        .ufw => try ufwStatus(ctx, &s, d),
        .firewalld => try firewalldStatus(ctx, &s, d),
        .redi => {
            s.running = true;
            s.boot = true;
        },
        .none, .foreign => {},
    }
    if (conflicts.items.len != 0) s.capabilities.edit = false;
    s.foreign = try fw.inventory.foreign(ctx.a, d.tables, ownerName(backend));
    if (backend != .firewalld) s.lockdown = fw.inventory.hasTable(d.tables, fw.own.lockdown_table);
    s.networks = try nm.networks(ctx, if (backend == .own) d.own.home_ifaces else &.{});
    s.listeners = try listeners(ctx, s);
    s.revert_in = state.revertIn(ctx);
    return s;
}

fn systemdEnabled(ctx: Ctx, name: []const u8) bool {
    const result = run.tryTool(ctx, "systemctl", &.{ "is-enabled", name }) orelse return false;
    return result.ok;
}

fn listeners(ctx: Ctx, s: model.Status) ![]const model.Listener {
    const proc = @import("../system_monitor/proc.zig");
    var sockets: std.ArrayList(fw.sockets.Socket) = .empty;
    inline for (.{ .{ "tcp", model.Proto.tcp }, .{ "tcp6", model.Proto.tcp }, .{ "udp", model.Proto.udp }, .{ "udp6", model.Proto.udp } }) |entry| {
        if (proc.sockets.netTable(ctx.a, @field(proc.sockets.NetTable, entry[0]))) |text| try fw.sockets.parseProcNet(ctx.a, text, entry[1], &sockets);
    }
    const owners = proc.sockets.socketOwners(ctx.a) catch &.{};
    for (sockets.items) |*sock| {
        for (owners) |o| if (o.inode == sock.inode and sock.inode != 0) {
            sock.pid = o.pid;
            sock.process = o.name;
            break;
        };
    }
    return fw.sockets.listeners(ctx.a, sockets.items, s);
}

// ---------------------------------------------------------------- ufw

fn ufwStatus(ctx: Ctx, s: *model.Status, d: Detected) !void {
    const settings = fw.ufw.parseSettings(run.readFile(ctx, fw.ufw.defaults, 64 << 10) orelse "", run.readFile(ctx, fw.ufw.conf, 64 << 10) orelse "");
    s.running = d.ufw_active;
    s.boot = settings.boot;
    s.incoming = settings.incoming;
    s.outgoing = settings.outgoing;
    s.forward = settings.forward;
    s.logging = settings.logging;
    const rules = try fw.ufw.parseRules(ctx.a, run.readFile(ctx, fw.ufw.rules_v4, 4 << 20) orelse "", run.readFile(ctx, fw.ufw.rules_v6, 4 << 20) orelse "");
    s.rules = rules;
    for (s.rules) |rule| if (rule.action == .limit and std.mem.eql(u8, rule.port, "22")) {
        s.ssh_limit = true;
    };
    s.capabilities = .{ .edit = true, .sources = true, .limit = true, .reject = true, .outgoing_rules = true, .outgoing_policy = true, .forward_policy = true, .logging = true, .lockdown = true };
}

fn ufw(ctx: Ctx, args: []const []const u8) !void {
    try run.must(ctx, "ufw", args);
}

fn ufwAdd(ctx: Ctx, rule: model.Rule) !void {
    const commands = try fw.ufw.commands(ctx.a, rule, false);
    const existing = try fw.ufw.parseRules(ctx.a, run.readFile(ctx, fw.ufw.rules_v4, 4 << 20) orelse "", run.readFile(ctx, fw.ufw.rules_v6, 4 << 20) orelse "");
    const first = rule.action == .deny or rule.action == .reject;
    for (commands) |argv| {
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(ctx.a, "--force");
        // ufw matches in order: a block goes before the allows it overrides.
        if (first and existing.len != 0) try full.appendSlice(ctx.a, &.{ "insert", "1" });
        try full.appendSlice(ctx.a, argv);
        try ufw(ctx, full.items);
    }
}

fn ufwRemove(ctx: Ctx, rule: model.Rule) !void {
    if (rule.raw.len != 0) {
        // Rules we cannot spell are deleted by their number in `ufw status
        // numbered`: the IPv4 file's rules, then the IPv6 file's.
        const v4 = try fw.ufw.parseRules(ctx.a, run.readFile(ctx, fw.ufw.rules_v4, 4 << 20) orelse "", "");
        const v6 = try fw.ufw.parseRules(ctx.a, "", run.readFile(ctx, fw.ufw.rules_v6, 4 << 20) orelse "");
        for ([_][]model.Rule{ v4, v6 }, 0..) |list, part| for (list, 0..) |r, i| {
            if (!std.mem.eql(u8, r.raw, rule.raw)) continue;
            const number = try std.fmt.allocPrint(ctx.a, "{d}", .{i + 1 + (if (part == 1) v4.len else 0)});
            return ufw(ctx, &.{ "--force", "delete", number });
        };
        return error.NoSuchRule;
    }
    var spelled = rule;
    if (spelled.service.len != 0 and fw.services.find(spelled.service) == null) spelled.service = "";
    for (try fw.ufw.commands(ctx.a, spelled, true)) |argv| {
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(ctx.a, "--force");
        try full.appendSlice(ctx.a, argv);
        try ufw(ctx, full.items);
    }
}

// ---------------------------------------------------------------- firewalld

fn fwcmd(ctx: Ctx, args: []const []const u8) !run.Result {
    return run.tryTool(ctx, "firewall-cmd", args) orelse error.ToolMissing;
}

fn defaultZone(ctx: Ctx) []const u8 {
    const result = fwcmd(ctx, &.{"--get-default-zone"}) catch return "public";
    const name = std.mem.trim(u8, result.out, " \n");
    return if (result.ok and fw.validate.service(name)) name else "public";
}

fn zone(ctx: Ctx, name: []const u8) ?fw.firewalld.Zone {
    const arg = std.fmt.allocPrint(ctx.a, "--zone={s}", .{name}) catch return null;
    const result = fwcmd(ctx, &.{ arg, "--list-all" }) catch return null;
    if (!result.ok) return null;
    return fw.firewalld.parseZone(ctx.a, result.out) catch null;
}

fn firewalldStatus(ctx: Ctx, s: *model.Status, d: Detected) !void {
    s.running = d.firewalld_running;
    s.boot = systemdEnabled(ctx, "firewalld.service");
    s.capabilities = .{ .edit = true, .trust = true, .sources = true, .limit = true, .reject = true, .ping = true, .logging = true, .boot = true, .lockdown = true };
    if (!d.firewalld_running) return;
    const public_name = defaultZone(ctx);
    s.zone = public_name;
    const public = zone(ctx, public_name) orelse return;
    const home = if (std.mem.eql(u8, public_name, fw.firewalld.home_zone)) null else zone(ctx, fw.firewalld.home_zone);
    s.incoming = fw.firewalld.incoming(public.target);
    s.ping = fw.firewalld.pingAllowed(public);
    if (fwcmd(ctx, &.{"--get-log-denied"})) |result| s.logging = fw.firewalld.logging(result.out) else |_| {}
    if (fwcmd(ctx, &.{"--query-panic"})) |result| s.lockdown = result.ok else |_| {}
    const rules = try fw.firewalld.rules(ctx.a, public, home);
    for (rules) |*rule| if (rule.port.len == 0 and rule.service.len != 0) resolveService(ctx, rule);
    s.rules = rules;
}

/// A firewalld service's ports from its definition, so listeners can be
/// matched against it.
fn resolveService(ctx: Ctx, rule: *model.Rule) void {
    if (!fw.validate.service(rule.service)) return;
    for (fw.firewalld.service_dirs) |dir| {
        const path = std.fmt.allocPrint(ctx.a, "{s}/{s}.xml", .{ dir, rule.service }) catch return;
        const xml = run.readFile(ctx, path, 256 << 10) orelse continue;
        const ports = fw.firewalld.servicePorts(ctx.a, xml) catch return;
        if (ports.len == 0) return;
        var joined: std.ArrayList(u8) = .empty;
        var proto = ports[0].proto;
        for (ports, 0..) |p, i| {
            if (i != 0) joined.append(ctx.a, ',') catch return;
            joined.appendSlice(ctx.a, p.port) catch return;
            if (p.proto != proto) proto = .both;
        }
        rule.port = joined.items;
        rule.proto = proto;
        return;
    }
}

fn zonesFor(ctx: Ctx, scope: model.Scope) []const []const u8 {
    const public = defaultZone(ctx);
    if (scope == .home or std.mem.eql(u8, public, fw.firewalld.home_zone)) return ctx.a.dupe([]const u8, &.{fw.firewalld.home_zone}) catch &.{};
    return ctx.a.dupe([]const u8, &.{ public, fw.firewalld.home_zone }) catch &.{};
}

fn firewalldRule(ctx: Ctx, rule: model.Rule, delete: bool) !void {
    // Status rules carry resolved port lists; a service rule is spelled by name.
    var spelled = rule;
    if (rule.service.len != 0 and rule.raw.len == 0) spelled.port = "";
    const args = try fw.firewalld.arguments(ctx.a, spelled, delete);
    for (zonesFor(ctx, rule.scope)) |z| {
        const zone_arg = try std.fmt.allocPrint(ctx.a, "--zone={s}", .{z});
        for (args) |arg| {
            const result = try fwcmd(ctx, &.{ "--permanent", zone_arg, arg });
            // Removing from a zone that never had it is not a failure.
            if (!result.ok and !delete) return error.ToolFailed;
        }
    }
    _ = try fwcmd(ctx, &.{"--reload"});
}

fn firewalldBoth(ctx: Ctx, arg: []const u8) !void {
    for (zonesFor(ctx, .everywhere)) |z| {
        const zone_arg = try std.fmt.allocPrint(ctx.a, "--zone={s}", .{z});
        _ = try fwcmd(ctx, &.{ "--permanent", zone_arg, arg });
    }
    _ = try fwcmd(ctx, &.{"--reload"});
}

// ---------------------------------------------------------------- own

const unit =
    \\[Unit]
    \\Description=RediWM firewall (nftables table inet rediwm)
    \\DefaultDependencies=no
    \\Before=network-pre.target
    \\Wants=network-pre.target
    \\After=local-fs.target
    \\
    \\[Service]
    \\Type=oneshot
    \\RemainAfterExit=yes
    \\ExecStart=@HELPER@ sync
    \\
    \\[Install]
    \\WantedBy=multi-user.target
    \\
;
const unit_path = "/etc/systemd/system/rediwm-firewall.service";

const dispatcher =
    \\#!/bin/sh
    \\# Keeps RediWM's firewall in step with each connection's trust (its
    \\# NetworkManager zone). Installed and removed by RediWM Settings.
    \\case "$2" in
    \\up|down|vpn-up|vpn-down|reapply) exec @HELPER@ sync ;;
    \\esac
    \\exit 0
    \\
;
const dispatcher_path = "/etc/NetworkManager/dispatcher.d/90-rediwm-firewall";

fn fill(ctx: Ctx, template: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, ctx.a, template, "@HELPER@", state.helper_path);
}

/// Loads our table from the saved state, with the live trust from
/// NetworkManager when it runs.
fn applyOwn(ctx: Ctx, s: fw.own.State) !void {
    var out: std.Io.Writer.Allocating = .init(ctx.a);
    if (s.enabled) {
        const live = nm.homeIfaces(ctx);
        try fw.own.renderNft(&out.writer, s, live orelse s.home_ifaces);
    } else {
        try out.writer.print("table inet {s}\ndelete table inet {s}\n", .{ fw.own.table, fw.own.table });
    }
    try run.writeAtomic(ctx, state.nft_path, out.written(), 0o600);
    const check = run.tryTool(ctx, "nft", &.{ "-c", "-f", state.nft_path }) orelse return error.ToolMissing;
    if (!check.ok) return error.RulesetRejected;
    try run.must(ctx, "nft", &.{ "-f", state.nft_path });
}

fn installHooks(ctx: Ctx, on: bool) void {
    if (run.tool(ctx, "systemctl") != null) {
        if (on) {
            const text = fill(ctx, unit) catch return;
            run.writeAtomic(ctx, unit_path, text, 0o644) catch return;
            run.must(ctx, "systemctl", &.{"daemon-reload"}) catch {};
            run.must(ctx, "systemctl", &.{ "enable", "rediwm-firewall.service" }) catch {};
        } else if (run.exists(ctx, unit_path)) {
            run.must(ctx, "systemctl", &.{ "disable", "rediwm-firewall.service" }) catch {};
        }
    }
    if (run.exists(ctx, "/etc/NetworkManager/dispatcher.d")) {
        if (on) {
            const text = fill(ctx, dispatcher) catch return;
            run.writeAtomic(ctx, dispatcher_path, text, 0o755) catch {};
        } else run.remove(ctx, dispatcher_path);
    }
}

fn ownChange(ctx: Ctx, req: Request) !void {
    var s = state.load(ctx);
    switch (req.op) {
        .enable => s.enabled = true,
        .disable => s.enabled = false,
        .set_defaults => {
            if (req.incoming) |p| s.incoming = p;
            if (req.outgoing) |p| s.outgoing = p;
            if (req.forward) |p| s.forward = p;
        },
        .add_rule => {
            const rule = req.rule.?;
            for (s.rules) |r| if (fw.own.sameRule(r, rule)) return;
            if (s.rules.len >= model.max_rules) return error.TooManyRules;
            var list: std.ArrayList(model.Rule) = .empty;
            try list.appendSlice(ctx.a, s.rules);
            try list.append(ctx.a, rule);
            s.rules = list.items;
        },
        .remove_rule => {
            var list: std.ArrayList(model.Rule) = .empty;
            var found = false;
            for (s.rules) |r| {
                if (!found and fw.own.sameRule(r, req.rule.?)) {
                    found = true;
                    continue;
                }
                try list.append(ctx.a, r);
            }
            if (!found) return error.NoSuchRule;
            s.rules = list.items;
        },
        .set_option => switch (req.option.?) {
            .ping => s.ping = req.on,
            .ssh_limit => s.ssh_limit = req.on,
            .logging => s.logging = req.logging orelse .off,
            .boot => {
                if (run.tool(ctx, "systemctl") == null) return error.Unsupported;
                if (req.on) installHooks(ctx, true) else run.must(ctx, "systemctl", &.{ "disable", "rediwm-firewall.service" }) catch {};
                return;
            },
        },
        .set_trust => if (req.uuid.len == 0) {
            var list: std.ArrayList([]const u8) = .empty;
            for (s.home_ifaces) |name| if (!std.mem.eql(u8, name, req.iface)) try list.append(ctx.a, name);
            if (req.trust == .home) try list.append(ctx.a, req.iface);
            s.home_ifaces = list.items;
        },
        else => return error.Unsupported,
    }
    try state.save(ctx, s);
    try applyOwn(ctx, s);
    if (req.op == .enable or req.op == .disable) installHooks(ctx, s.enabled);
}

/// `sync`: reload our table (boot, NetworkManager changes).
pub fn sync(ctx: Ctx) !void {
    const s = state.load(ctx);
    if (!s.enabled) return;
    try applyOwn(ctx, s);
    if (state.lockdown(ctx)) try lockdownNft(ctx, true);
}

fn lockdownNft(ctx: Ctx, on: bool) !void {
    var out: std.Io.Writer.Allocating = .init(ctx.a);
    try fw.own.renderLockdownNft(&out.writer, on);
    const path = state.run_dir ++ "/lockdown.nft";
    try run.writeAtomic(ctx, path, out.written(), 0o600);
    try run.must(ctx, "nft", &.{ "-f", path });
    try state.setLockdown(ctx, on);
}

// ---------------------------------------------------------------- changes

pub fn change(ctx: Ctx, req: Request) !void {
    const d = detect(ctx);
    var backend = manager(d);
    // Turn on with nothing set up: what the page asked for, if installed.
    if (req.op == .enable and !d.own.enabled and !d.firewalld_running and !d.ufw_active and !d.redi) {
        backend = switch (req.backend) {
            .ufw => if (d.ufw_installed) .ufw else return error.Unsupported,
            .firewalld => if (d.firewalld_installed) .firewalld else return error.Unsupported,
            else => if (d.nft) .own else return error.ToolMissing,
        };
    }
    if (req.op != .enable and req.op != .lockdown) {
        for ([_]bool{ d.own.enabled and backend != .own, d.firewalld_running and backend != .firewalld, d.ufw_active and backend != .ufw }) |other| {
            if (other) return error.Conflict;
        }
    }
    if (req.op == .set_trust and req.uuid.len != 0) {
        try nm.setTrust(ctx, req.uuid, req.trust);
        if (backend == .own) try sync(ctx);
        return;
    }
    if (req.op == .lockdown) {
        if (backend == .firewalld and d.firewalld_running) {
            _ = try fwcmd(ctx, &.{if (req.on) "--panic-on" else "--panic-off"});
            return;
        }
        return lockdownNft(ctx, req.on);
    }
    switch (backend) {
        .own => try ownChange(ctx, req),
        .ufw => switch (req.op) {
            .enable => try ufw(ctx, &.{ "--force", "enable" }),
            .disable => try ufw(ctx, &.{"disable"}),
            .set_defaults => {
                if (req.incoming) |p| try ufw(ctx, &.{ "default", fw.ufw.policyWord(p), "incoming" });
                if (req.outgoing) |p| try ufw(ctx, &.{ "default", fw.ufw.policyWord(p), "outgoing" });
                if (req.forward) |p| try ufw(ctx, &.{ "default", fw.ufw.policyWord(p), "routed" });
            },
            .add_rule => try ufwAdd(ctx, req.rule.?),
            .remove_rule => try ufwRemove(ctx, req.rule.?),
            .set_option => switch (req.option.?) {
                .logging => try ufw(ctx, &.{ "logging", fw.ufw.loggingWord(req.logging orelse .off) }),
                else => return error.Unsupported,
            },
            else => return error.Unsupported,
        },
        .firewalld => switch (req.op) {
            .enable => try run.must(ctx, "systemctl", &.{ "enable", "--now", "firewalld.service" }),
            .disable => try run.must(ctx, "systemctl", &.{ "disable", "--now", "firewalld.service" }),
            .set_defaults => if (req.incoming) |p| {
                const arg = try std.fmt.allocPrint(ctx.a, "--set-target={s}", .{fw.firewalld.target(p)});
                const zone_arg = try std.fmt.allocPrint(ctx.a, "--zone={s}", .{defaultZone(ctx)});
                const result = try fwcmd(ctx, &.{ "--permanent", zone_arg, arg });
                if (!result.ok) return error.ToolFailed;
                _ = try fwcmd(ctx, &.{"--reload"});
            },
            .add_rule => try firewalldRule(ctx, req.rule.?, false),
            .remove_rule => try firewalldRule(ctx, req.rule.?, true),
            .set_option => switch (req.option.?) {
                .ping => try firewalldBoth(ctx, if (req.on) "--remove-icmp-block=echo-request" else "--add-icmp-block=echo-request"),
                .logging => {
                    const arg = try std.fmt.allocPrint(ctx.a, "--set-log-denied={s}", .{fw.firewalld.logWord(req.logging orelse .off)});
                    if (!(try fwcmd(ctx, &.{arg})).ok) return error.ToolFailed;
                },
                .boot => try run.must(ctx, "systemctl", &.{ if (req.on) "enable" else "disable", "firewalld.service" }),
                else => return error.Unsupported,
            },
            else => return error.Unsupported,
        },
        .redi => return error.ManagedElsewhere,
        .none, .foreign => return error.Unsupported,
    }
}

pub fn blocks(ctx: Ctx) ![]const model.Block {
    const result = run.tryTool(ctx, "journalctl", &.{ "-k", "-o", "short-iso", "--no-pager", "-n", "400", "-g", fw.blocks.journal_pattern, "--since", "-24h" }) orelse return &.{};
    return fw.blocks.parse(ctx.a, result.out, false);
}

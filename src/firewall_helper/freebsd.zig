//! FreeBSD: pf with our rules in the anchor "rediwm" (`pfctl -a rediwm`),
//! which pf.conf evaluates first and loads at boot. We write pf.conf only to
//! add those two lines (after showing the change) or, when there is none, a
//! minimal one; everything else in it is the user's and stays read-only. ipfw
//! is detected and shown, never changed.
const std = @import("std");
const fw = @import("firewall");
const model = fw.model;
const run = @import("run.zig");
const state = @import("state.zig");
const nm = @import("networks.zig");
const Ctx = run.Ctx;
const Request = fw.protocol.Request;

fn rc(ctx: Ctx, name: []const u8) []const u8 {
    const result = run.tryTool(ctx, "sysrc", &.{ "-n", name }) orelse return "";
    return if (result.ok) std.mem.trim(u8, result.out, " \n") else "";
}

fn yes(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "YES");
}

fn confPath(ctx: Ctx) []const u8 {
    const path = rc(ctx, "pf_rules");
    return if (path.len != 0 and path[0] == '/') path else "/etc/pf.conf";
}

const Pf = struct { loaded: bool, enabled: bool, main_rules: u32, anchor_rules: u32 };

fn pf(ctx: Ctx) Pf {
    const info = run.tryTool(ctx, "pfctl", &.{ "-s", "info" }) orelse return .{ .loaded = false, .enabled = false, .main_rules = 0, .anchor_rules = 0 };
    if (!info.ok) return .{ .loaded = false, .enabled = false, .main_rules = 0, .anchor_rules = 0 };
    const main = run.tryTool(ctx, "pfctl", &.{"-sr"});
    const anchor = run.tryTool(ctx, "pfctl", &.{ "-a", fw.own.table, "-sr" });
    return .{
        .loaded = true,
        .enabled = fw.inventory.pfEnabled(info.out),
        .main_rules = if (main) |r| fw.inventory.pfRuleCount(r.out) else 0,
        .anchor_rules = if (anchor) |r| fw.inventory.pfRuleCount(r.out) else 0,
    };
}

fn ipfwActive(ctx: Ctx) ?u32 {
    const result = run.tryTool(ctx, "sysctl", &.{ "-n", "net.inet.ip.fw.enable" }) orelse return null;
    if (!result.ok or !std.mem.startsWith(u8, std.mem.trim(u8, result.out, " \n"), "1")) return null;
    const rules = run.tryTool(ctx, "ipfw", &.{"list"}) orelse return 0;
    return @intCast(std.mem.count(u8, rules.out, "\n"));
}

pub fn status(ctx: Ctx) !model.Status {
    const saved = state.load(ctx);
    const p = pf(ctx);
    const conf = run.readFile(ctx, confPath(ctx), 1 << 20);
    const has = if (conf) |text| fw.own.pfConfHasAnchor(text) else @TypeOf(fw.own.pfConfHasAnchor("")){ .anchor = false, .load = false };
    const view = try fw.own.status(ctx.a, saved);
    var s = view;
    s.system = .freebsd;
    s.backend = if (run.tool(ctx, "pfctl") != null) .own else .none;
    s.running = saved.enabled and p.enabled and has.anchor;
    s.boot = saved.enabled and yes(rc(ctx, "pf_enable")) and has.load;
    s.needs_anchor = conf != null and !has.anchor;
    s.lockdown = state.lockdown(ctx);
    s.capabilities = .{ .edit = true, .trust = true, .sources = true, .limit = true, .reject = true, .outgoing_rules = true, .outgoing_policy = true, .ping = true, .logging = true, .ssh_limit = true, .boot = true, .lockdown = true };
    var foreign: std.ArrayList(model.Foreign) = .empty;
    if (p.loaded and p.main_rules > 0) try foreign.append(ctx.a, .{ .owner = "pf.conf", .name = confPath(ctx), .rules = p.main_rules });
    if (ipfwActive(ctx)) |count| {
        try foreign.append(ctx.a, .{ .owner = "ipfw", .name = "ipfw", .rules = count });
        s.conflicts = try ctx.a.dupe(model.Backend, &.{.foreign});
        s.capabilities.edit = false;
    }
    s.foreign = foreign.items;
    s.networks = try nm.networks(ctx, saved.home_ifaces);
    const listing = run.tryTool(ctx, "sockstat", &.{ "-46lqn", "-P", "tcp,udp" });
    const sockets = if (listing) |r| try fw.sockets.parseSockstat(ctx.a, r.out) else &.{};
    s.listeners = try fw.sockets.listeners(ctx.a, sockets, s);
    s.revert_in = state.revertIn(ctx);
    return s;
}

fn applyAnchor(ctx: Ctx, saved: fw.own.State, lockdown: bool) !void {
    var out: std.Io.Writer.Allocating = .init(ctx.a);
    try fw.own.renderPf(&out.writer, saved, lockdown);
    // The persistent file never holds a lockdown: a reboot ends it.
    const path = if (lockdown) state.run_dir ++ "/lockdown.pf" else state.pf_path;
    try run.writeAtomic(ctx, path, out.written(), 0o600);
    const check = run.tryTool(ctx, "pfctl", &.{ "-n", "-a", fw.own.table, "-f", path }) orelse return error.ToolMissing;
    if (!check.ok) return error.RulesetRejected;
    try run.must(ctx, "pfctl", &.{ "-a", fw.own.table, "-f", path });
}

fn ensureConf(ctx: Ctx) !void {
    const path = confPath(ctx);
    if (run.readFile(ctx, path, 1 << 20)) |text| {
        const has = fw.own.pfConfHasAnchor(text);
        if (has.anchor and has.load) return;
        try run.writeAtomic(ctx, try std.fmt.allocPrint(ctx.a, "{s}.rediwm-backup", .{path}), text, 0o600);
        const updated = try fw.own.pfConfWithAnchor(ctx.a, text, state.pf_path);
        try run.writeAtomic(ctx, path, updated, 0o600);
    } else {
        const text = try std.mem.replaceOwned(u8, ctx.a, fw.own.pf_conf, "@ANCHOR@", state.pf_path);
        try run.writeAtomic(ctx, path, text, 0o600);
    }
    const check = run.tryTool(ctx, "pfctl", &.{ "-n", "-f", path }) orelse return error.ToolMissing;
    if (!check.ok) return error.RulesetRejected;
}

fn startPf(ctx: Ctx) !void {
    try run.must(ctx, "sysrc", &.{"pf_enable=YES"});
    _ = run.tryTool(ctx, "kldload", &.{ "-n", "pf" });
    try run.must(ctx, "pfctl", &.{ "-f", confPath(ctx) });
    // "pf already enabled" is an error exit; the state is what matters.
    _ = run.tryTool(ctx, "pfctl", &.{"-e"});
    if (!pf(ctx).enabled) return error.ToolFailed;
}

fn logging(ctx: Ctx, on: bool) void {
    if (on) {
        run.must(ctx, "sysrc", &.{"pflog_enable=YES"}) catch return;
        _ = run.tryTool(ctx, "service", &.{ "pflog", "start" });
    }
}

pub fn change(ctx: Ctx, req: Request) !void {
    var saved = state.load(ctx);
    if (ipfwActive(ctx) != null and req.op != .lockdown) return error.Conflict;
    switch (req.op) {
        .enable => {
            saved.enabled = true;
            try state.save(ctx, saved);
            try applyAnchor(ctx, saved, false);
            try ensureConf(ctx);
            try startPf(ctx);
            logging(ctx, saved.logging != .off);
            return;
        },
        .disable => {
            saved.enabled = false;
            try state.save(ctx, saved);
            _ = run.tryTool(ctx, "pfctl", &.{ "-a", fw.own.table, "-F", "rules" });
            _ = run.tryTool(ctx, "pfctl", &.{"-d"});
            _ = run.tryTool(ctx, "sysrc", &.{"pf_enable=NO"});
            return;
        },
        .lockdown => {
            try state.setLockdown(ctx, req.on);
            return applyAnchor(ctx, saved, req.on);
        },
        .set_defaults => {
            if (req.incoming) |p| saved.incoming = p;
            if (req.outgoing) |p| saved.outgoing = p;
        },
        .add_rule => {
            for (saved.rules) |r| if (fw.own.sameRule(r, req.rule.?)) return;
            var list: std.ArrayList(model.Rule) = .empty;
            try list.appendSlice(ctx.a, saved.rules);
            try list.append(ctx.a, req.rule.?);
            saved.rules = list.items;
        },
        .remove_rule => {
            var list: std.ArrayList(model.Rule) = .empty;
            var found = false;
            for (saved.rules) |r| {
                if (!found and fw.own.sameRule(r, req.rule.?)) {
                    found = true;
                    continue;
                }
                try list.append(ctx.a, r);
            }
            if (!found) return error.NoSuchRule;
            saved.rules = list.items;
        },
        .set_option => switch (req.option.?) {
            .ping => saved.ping = req.on,
            .ssh_limit => saved.ssh_limit = req.on,
            .logging => {
                saved.logging = req.logging orelse .off;
                logging(ctx, saved.logging != .off);
            },
            .boot => {
                try run.must(ctx, "sysrc", &.{if (req.on) "pf_enable=YES" else "pf_enable=NO"});
                return;
            },
        },
        .set_trust => {
            var list: std.ArrayList([]const u8) = .empty;
            for (saved.home_ifaces) |name| if (!std.mem.eql(u8, name, req.iface)) try list.append(ctx.a, name);
            if (req.trust == .home) try list.append(ctx.a, req.iface);
            saved.home_ifaces = list.items;
        },
        else => return error.Unsupported,
    }
    try state.save(ctx, saved);
    if (saved.enabled) try applyAnchor(ctx, saved, state.lockdown(ctx));
}

pub fn sync(ctx: Ctx) !void {
    const saved = state.load(ctx);
    if (saved.enabled) try applyAnchor(ctx, saved, state.lockdown(ctx));
}

pub fn blocks(ctx: Ctx) ![]const model.Block {
    if (!run.exists(ctx, "/var/log/pflog")) return &.{};
    const result = run.tryTool(ctx, "tcpdump", &.{ "-n", "-e", "-tttt", "-r", "/var/log/pflog" }) orelse return &.{};
    return fw.blocks.parse(ctx.a, result.out, true);
}

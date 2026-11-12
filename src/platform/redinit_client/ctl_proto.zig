//! v1: bounded ASCII request lines; newline-delimited JSON replies. Every
//! finite response ends with `done`. Streaming replies use explicit overflow.
const std = @import("std");
pub const max_request = 8192;
pub const max_line = 8192;
/// Where the control socket is. A per-user instance moves it under $XDG_RUNTIME_DIR.
pub var socket_path: [:0]const u8 = "/run/" ++ @import("config").name ++ "/ctl";
pub const Verb = enum { start, stop, restart, status, list, enable, disable, reload, why, logs, subscribe, clients, trace_dump, poweroff, reboot, log_attach, reload_unit, run, scope, adopt, environment };
pub const verb_count = std.meta.tags(Verb).len;
pub const Request = struct {
    verb: Verb,
    unit: []const u8 = "",
    lines: u32 = 10,
    follow: bool = false,
    since: ?u64 = null,
    epoch: u64 = 0,
    glob: []const u8 = "*",
    kinds: u8 = 15,
    /// `run`: encoded arguments; `scope`: validated scope operation tokens.
    rest: []const u8 = "",
};
pub const Error = error{ InvalidRequest, TooLarge };

pub fn parse(line: []const u8) Error!Request {
    if (line.len > max_request) return error.TooLarge;
    for (line) |c| if (c < 0x20 or c > 0x7e) return error.InvalidRequest;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const command = tokens.next() orelse return error.InvalidRequest;
    var verb: ?Verb = null;
    inline for (std.meta.tags(Verb)) |v| if (std.mem.eql(u8, command, name(v))) {
        verb = v;
    };
    var req: Request = .{ .verb = verb orelse return error.InvalidRequest };
    switch (req.verb) {
        .adopt => {
            req.unit = tokens.next() orelse return error.InvalidRequest;
            if (!validName(req.unit)) return error.InvalidRequest;
            req.rest = tokens.next() orelse return error.InvalidRequest;
            const pid = try number(u32, req.rest);
            if (pid <= 1 or pid > std.math.maxInt(i32)) return error.InvalidRequest;
        },
        .environment => {
            req.rest = tokens.rest();
            for (req.rest) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-/=:+,@%~ ", c) != null)) return error.InvalidRequest;
            return req;
        },
        .start, .stop, .restart, .status, .enable, .disable, .why, .logs, .reload_unit => {
            req.unit = tokens.next() orelse return error.InvalidRequest;
            if (!validName(req.unit)) return error.InvalidRequest;
            if (req.verb == .logs) {
                req.lines = number(u32, tokens.next() orelse return error.InvalidRequest) catch return error.InvalidRequest;
                if (req.lines > 10000) return error.InvalidRequest;
                const follow = tokens.next() orelse return error.InvalidRequest;
                if (!std.mem.eql(u8, follow, "0") and !std.mem.eql(u8, follow, "1")) return error.InvalidRequest;
                req.follow = follow[0] == '1';
            }
        },
        .run => {
            // run NAME|- WORKDIR|~ NENV ENV... ARG...   (tokens are percent-encoded)
            req.unit = tokens.next() orelse return error.InvalidRequest;
            if (!std.mem.eql(u8, req.unit, "-") and !validName(req.unit)) return error.InvalidRequest;
            req.rest = tokens.rest();
            if (req.rest.len == 0) return error.InvalidRequest;
            for (req.rest) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-/=:+,@%~ ", c) != null)) return error.InvalidRequest;
            return req;
        },
        .scope => {
            req.rest = tokens.rest();
            _ = try parseScope(req.rest);
            return req;
        },
        .subscribe => {
            const since = tokens.next() orelse return error.InvalidRequest;
            if (!std.mem.eql(u8, since, "now")) req.since = try number(u64, since);
            req.epoch = try number(u64, tokens.next() orelse return error.InvalidRequest);
            req.glob = tokens.next() orelse return error.InvalidRequest;
            if (req.glob.len > 63) return error.InvalidRequest;
            for (req.glob) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-@*?", c) != null)) return error.InvalidRequest;
            req.kinds = try number(u8, tokens.next() orelse return error.InvalidRequest);
            if (req.kinds == 0 or req.kinds > 15) return error.InvalidRequest;
        },
        else => {},
    }
    if (tokens.next() != null) return error.InvalidRequest;
    return req;
}

pub const ScopeAction = enum { list, create, status, stop, kill, abandon };
pub const max_scope_pids = 16;
pub const ScopeRequest = struct {
    action: ScopeAction = .list,
    name: []const u8 = "",
    uid: u32 = 0,
    pids: [max_scope_pids]i32 = @splat(0),
    pid_count: usize = 0,
    signal: u8 = 0,
    main_only: bool = false,
};

/// Session names are also directory components and D-Bus unit names. Only
/// logind's session-ID.scope shape is accepted; arbitrary paths are never used.
pub fn validScopeName(unit: []const u8) bool {
    const prefix = "session-";
    const suffix = ".scope";
    if (unit.len > 47 or unit.len <= prefix.len + suffix.len or !std.mem.startsWith(u8, unit, prefix) or !std.mem.endsWith(u8, unit, suffix)) return false;
    for (unit[prefix.len .. unit.len - suffix.len]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

pub fn scopeSliceUid(unit: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, unit, "user-") or !std.mem.endsWith(u8, unit, ".slice") or unit.len <= 11) return null;
    const value = unit[5 .. unit.len - 6];
    if (value.len > 1 and value[0] == '0') return null;
    const uid = number(u32, value) catch return null;
    return if (uid == std.math.maxInt(u32)) null else uid;
}

/// `scope` alone enumerates the session registry. All other operations have
/// strict arity and bounded input, before PID 1 touches a process or cgroup.
pub fn parseScope(rest: []const u8) Error!ScopeRequest {
    var tokens = std.mem.tokenizeScalar(u8, rest, ' ');
    const action = tokens.next() orelse return .{};
    var req: ScopeRequest = .{};
    req.action = std.meta.stringToEnum(ScopeAction, action) orelse return error.InvalidRequest;
    if (req.action == .list) {
        if (tokens.next() != null) return error.InvalidRequest;
        return req;
    }
    req.name = tokens.next() orelse return error.InvalidRequest;
    if (!validScopeName(req.name) and !(req.action == .kill and scopeSliceUid(req.name) != null)) return error.InvalidRequest;
    switch (req.action) {
        .create => {
            req.uid = try number(u32, tokens.next() orelse return error.InvalidRequest);
            if (req.uid == std.math.maxInt(u32)) return error.InvalidRequest;
            while (tokens.next()) |pid| {
                if (req.pid_count == req.pids.len) return error.InvalidRequest;
                const value = try number(u32, pid);
                if (value <= 1 or value > std.math.maxInt(i32)) return error.InvalidRequest;
                for (req.pids[0..req.pid_count]) |existing| if (existing == value) return error.InvalidRequest;
                req.pids[req.pid_count] = @intCast(value);
                req.pid_count += 1;
            }
            if (req.pid_count == 0) return error.InvalidRequest;
            return req;
        },
        .kill => {
            req.signal = try number(u8, tokens.next() orelse return error.InvalidRequest);
            if (req.signal == 0 or req.signal > 64) return error.InvalidRequest;
            if (tokens.next()) |who| {
                if (std.mem.eql(u8, who, "main")) req.main_only = true else if (!std.mem.eql(u8, who, "all")) return error.InvalidRequest;
            }
            if (req.main_only and scopeSliceUid(req.name) != null) return error.InvalidRequest;
        },
        else => {},
    }
    if (tokens.next() != null) return error.InvalidRequest;
    return req;
}

/// A token that is safe on a request line: letters, digits and `._-/=:+,@` pass,
/// every other byte is `%XX`, and an empty value is `~` (a real `~` is `%7E`).
pub fn encodeToken(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return w.writeByte('~');
    for (bytes) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-/=:+,@", c) != null) {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

pub const DecodeError = error{ InvalidToken, NoSpace };

/// The inverse of `encodeToken`. Never produces a NUL: a command line cannot carry one.
pub fn decodeToken(out: []u8, token: []const u8) DecodeError![]u8 {
    if (std.mem.eql(u8, token, "~")) return out[0..0];
    var n: usize = 0;
    var i: usize = 0;
    while (i < token.len) {
        if (n == out.len) return error.NoSpace;
        if (token[i] == '%') {
            if (i + 3 > token.len) return error.InvalidToken;
            const value = std.fmt.parseInt(u8, token[i + 1 .. i + 3], 16) catch return error.InvalidToken;
            if (value == 0) return error.InvalidToken;
            out[n] = value;
            i += 3;
        } else {
            out[n] = token[i];
            i += 1;
        }
        n += 1;
    }
    return out[0..n];
}

pub fn validName(unit: []const u8) bool {
    if (unit.len == 0 or unit.len > 47 or std.mem.eql(u8, unit, ".") or std.mem.eql(u8, unit, "..")) return false;
    for (unit) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-@", c) != null)) return false;
    return true;
}

fn number(comptime T: type, text: []const u8) Error!T {
    if (text.len == 0) return error.InvalidRequest;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidRequest;
    return std.fmt.parseInt(T, text, 10) catch error.InvalidRequest;
}

pub fn name(verb: Verb) []const u8 {
    return switch (verb) {
        .trace_dump => "trace-dump",
        .log_attach => "log-attach",
        .reload_unit => "reload-unit",
        else => @tagName(verb),
    };
}

pub fn privileged(verb: Verb) bool {
    return switch (verb) {
        .list, .status, .why, .subscribe, .clients, .trace_dump => false,
        else => true,
    };
}

/// Iterative wildcard match, bounded by input length. No recursive backtracking.
pub fn matches(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = v;
        } else if (star) |s| {
            retry += 1;
            v = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Escape bytes, including non-ASCII log bytes, without trusting UTF-8 input.
pub fn string(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20 or c >= 0x7f) try w.print("\\u00{x:0>2}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub const Bucket = struct {
    credit: u64 = 20 * std.time.ns_per_s,
    at: u64 = 0,
    pub fn allow(self: *Bucket, now: u64) bool {
        if (self.at == 0) self.at = now;
        self.credit = @min(20 * std.time.ns_per_s, self.credit +| ((now -| self.at) *| 20));
        self.at = now;
        if (self.credit < std.time.ns_per_s) return false;
        self.credit -= std.time.ns_per_s;
        return true;
    }
};

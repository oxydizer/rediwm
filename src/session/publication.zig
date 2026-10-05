//! Activation-environment lease for one login. Only the verified primary
//! login publishes to the shared user manager; a journal in the runtime dir
//! lets a successor roll back after a supervisor failure. Restoration only
//! touches values this lease still owns.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("login_sys.zig");

pub const owner_key = "REDIWM_ACTIVATION_OWNER";
pub const allowlist = [_][]const u8{ "WAYLAND_DISPLAY", "DISPLAY", "REDIWM_SOCKET", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "PATH", owner_key };

pub const Env = std.StringArrayHashMapUnmanaged([]const u8);
pub const Pair = struct { key: []const u8, value: []const u8 };

/// Same JSON shape the Python supervisor wrote, so stale journals from
/// either implementation roll back.
const Journal = struct {
    published: std.json.ArrayHashMap([]const u8),
    previous: std.json.ArrayHashMap(?[]const u8),
};

/// `Bus` provides environment(arena) !Env, conflict(arena, session) !?[]const u8,
/// systemd(values, absent) !void and activation(values) !void.
pub fn Publication(comptime Bus: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        bus: *Bus,
        session: []const u8,
        journal_path: [:0]u8,
        lock_path: [:0]u8,
        temp_path: [:0]u8,
        lock: ?i32 = null,
        record: ?Journal = null,
        record_arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator, bus: *Bus, runtime: []const u8, session: []const u8) !Self {
            const journal_path = try std.fmt.allocPrintSentinel(allocator, "{s}/rediwm-activation.json", .{runtime}, 0);
            errdefer allocator.free(journal_path);
            const lock_path = try std.fmt.allocPrintSentinel(allocator, "{s}/rediwm-activation.lock", .{runtime}, 0);
            errdefer allocator.free(lock_path);
            const temp_path = try std.fmt.allocPrintSentinel(allocator, "{s}/rediwm-activation.tmp", .{runtime}, 0);
            return .{
                .allocator = allocator,
                .bus = bus,
                .session = session,
                .journal_path = journal_path,
                .lock_path = lock_path,
                .temp_path = temp_path,
                .record_arena = .init(allocator),
            };
        }

        /// Restores (best effort through `close`) and frees.
        pub fn deinit(self: *Self) void {
            self.close() catch |err| sys.diagnostic("activation cleanup pending: {t}", .{err});
            self.record_arena.deinit();
            self.allocator.free(self.journal_path);
            self.allocator.free(self.lock_path);
            self.allocator.free(self.temp_path);
        }

        pub fn acquire(self: *Self) !void {
            const fd = try sys.openZ(self.lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
            _ = sys.retry(linux.flock, .{ fd, std.posix.LOCK.EX | std.posix.LOCK.NB }) catch {
                sys.close(fd);
                sys.diagnostic("another RediWM session owns activation publication", .{});
                return error.PublicationLocked;
            };
            self.lock = fd;
            if (try self.loadJournal()) try self.restore();
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            if (try self.bus.conflict(arena.allocator(), self.session)) |other| {
                sys.diagnostic("graphical session {s} already uses this user bus", .{other});
                return error.GraphicalSessionConflict;
            }
        }

        fn loadJournal(self: *Self) !bool {
            const fd = sys.openZ(self.journal_path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            defer sys.close(fd);
            _ = self.record_arena.reset(.retain_capacity);
            const arena = self.record_arena.allocator();
            const bytes = try sys.readAll(arena, fd);
            self.record = try std.json.parseFromSliceLeaky(Journal, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            return true;
        }

        pub fn publish(self: *Self, values: []const Pair) !void {
            for (values) |pair| {
                if (std.mem.eql(u8, pair.key, owner_key) or !allowed(pair.key)) return error.InvalidActivationEnvironment;
            }
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            // A compositor exec restart reuses the lease but replaces the display.
            if (try self.bus.conflict(arena.allocator(), self.session)) |other| {
                sys.diagnostic("graphical session {s} now uses this user bus", .{other});
                return error.GraphicalSessionConflict;
            }
            try self.restore();
            const previous = try self.bus.environment(arena.allocator());

            _ = self.record_arena.reset(.retain_capacity);
            const ra = self.record_arena.allocator();
            var journal: Journal = .{ .published = .{}, .previous = .{} };
            for (values) |pair| try journal.published.map.put(ra, try ra.dupe(u8, pair.key), try ra.dupe(u8, pair.value));
            try journal.published.map.put(ra, owner_key, try ownerToken(ra));
            for (journal.published.map.keys()) |key| {
                const prior: ?[]const u8 = if (previous.get(key)) |v| try ra.dupe(u8, v) else null;
                try journal.previous.map.put(ra, key, prior);
            }
            self.record = journal;
            try self.writeJournal(arena.allocator(), journal);
            // Establish the readable ownership marker before touching the bus. If
            // either write fails, the journal permits conditional rollback.
            const published = try pairs(arena.allocator(), journal.published.map);
            try self.bus.systemd(published, &.{});
            try self.bus.activation(published);
        }

        fn writeJournal(self: *Self, arena: std.mem.Allocator, journal: Journal) !void {
            const text = try std.json.Stringify.valueAlloc(arena, journal, .{});
            const fd = try sys.openZ(self.temp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
            defer sys.close(fd);
            try sys.writeAll(fd, text);
            try sys.renameZ(self.temp_path, self.journal_path);
        }

        pub fn restore(self: *Self) !void {
            const record = self.record orelse return;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const current = try self.bus.environment(a);
            const published = record.published.map;
            const token = published.get(owner_key) orelse "";
            const owns = if (current.get(owner_key)) |v| std.mem.eql(u8, v, token) else false;
            if (owns and try self.bus.conflict(a, self.session) == null) {
                var activation: std.ArrayList(Pair) = .empty;
                var set: std.ArrayList(Pair) = .empty;
                var absent: std.ArrayList([]const u8) = .empty;
                var it = published.iterator();
                while (it.next()) |entry| {
                    const now = current.get(entry.key_ptr.*) orelse continue;
                    if (!std.mem.eql(u8, now, entry.value_ptr.*)) continue;
                    const prior = record.previous.map.get(entry.key_ptr.*) orelse null;
                    // Traditional D-Bus has neither GetEnvironment nor UnsetEnvironment.
                    // The shared manager snapshot is the best known prior value; absent
                    // bus values must become empty. Never claim independent bus snapshots.
                    try activation.append(a, .{ .key = entry.key_ptr.*, .value = prior orelse "" });
                    if (prior) |value| {
                        try set.append(a, .{ .key = entry.key_ptr.*, .value = value });
                    } else {
                        try absent.append(a, entry.key_ptr.*);
                    }
                }
                try self.bus.activation(activation.items);
                try self.bus.systemd(set.items, absent.items);
            }
            sys.unlinkZ(self.journal_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            self.record = null;
        }

        pub fn close(self: *Self) !void {
            defer if (self.lock) |fd| {
                sys.close(fd);
                self.lock = null;
            };
            try self.restore();
        }
    };
}

fn allowed(key: []const u8) bool {
    for (allowlist) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

fn pairs(arena: std.mem.Allocator, map: std.StringArrayHashMapUnmanaged([]const u8)) ![]Pair {
    const out = try arena.alloc(Pair, map.count());
    for (map.keys(), map.values(), out) |key, value, *pair| pair.* = .{ .key = key, .value = value };
    return out;
}

fn ownerToken(arena: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    _ = try sys.check(linux.getrandom(&bytes, bytes.len, 0));
    return std.fmt.allocPrint(arena, "{x}", .{&bytes});
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

const FakeBus = struct {
    arena: std.heap.ArenaAllocator,
    env: Env = .empty,
    activated: Env = .empty,
    other: ?[]const u8 = null,
    fail_activation: bool = false,

    fn init() !FakeBus {
        var bus: FakeBus = .{ .arena = .init(testing.allocator) };
        errdefer bus.arena.deinit();
        const a = bus.arena.allocator();
        for ([_]Pair{ .{ .key = "PATH", .value = "/old/bin" }, .{ .key = "DISPLAY", .value = ":old" }, .{ .key = "UNRELATED", .value = "keep" } }) |pair| {
            try bus.env.put(a, pair.key, pair.value);
            try bus.activated.put(a, pair.key, pair.value);
        }
        return bus;
    }
    fn deinit(self: *FakeBus) void {
        self.arena.deinit();
    }
    pub fn environment(self: *FakeBus, arena: std.mem.Allocator) !Env {
        var copy: Env = .empty;
        var it = self.env.iterator();
        while (it.next()) |e| try copy.put(arena, e.key_ptr.*, e.value_ptr.*);
        return copy;
    }
    pub fn conflict(self: *FakeBus, _: std.mem.Allocator, _: []const u8) !?[]const u8 {
        return self.other;
    }
    pub fn systemd(self: *FakeBus, values: []const Pair, absent: []const []const u8) !void {
        const a = self.arena.allocator();
        for (values) |p| try self.env.put(a, try a.dupe(u8, p.key), try a.dupe(u8, p.value));
        for (absent) |key| _ = self.env.orderedRemove(key);
    }
    pub fn activation(self: *FakeBus, values: []const Pair) !void {
        if (self.fail_activation) {
            self.fail_activation = false;
            return error.InjectedBusRefusal;
        }
        const a = self.arena.allocator();
        for (values) |p| try self.activated.put(a, try a.dupe(u8, p.key), try a.dupe(u8, p.value));
    }
    fn expectEnv(self: *FakeBus, expected: []const Pair) !void {
        try testing.expectEqual(expected.len, self.env.count());
        for (expected) |p| try testing.expectEqualStrings(p.value, self.env.get(p.key) orelse return error.TestExpectedEqual);
    }
};

const TestPublication = Publication(FakeBus);

const Fixture = struct {
    tmp: testing.TmpDir,
    runtime: []u8,
    bus: FakeBus,
    owner: TestPublication,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.runtime = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        errdefer testing.allocator.free(self.runtime);
        self.bus = try FakeBus.init();
        errdefer self.bus.deinit();
        self.owner = try TestPublication.init(testing.allocator, &self.bus, self.runtime, "c1");
        errdefer self.owner.deinit();
        try self.owner.acquire();
    }
    fn deinit(self: *Fixture) void {
        self.owner.deinit();
        self.bus.deinit();
        testing.allocator.free(self.runtime);
        self.tmp.cleanup();
    }
    fn publish(self: *Fixture) !void {
        try self.owner.publish(&.{ .{ .key = "WAYLAND_DISPLAY", .value = "wayland-owned" }, .{ .key = "DISPLAY", .value = ":12" }, .{ .key = "PATH", .value = "/new/bin" } });
    }
};

const original = [_]Pair{ .{ .key = "PATH", .value = "/old/bin" }, .{ .key = "DISPLAY", .value = ":old" }, .{ .key = "UNRELATED", .value = "keep" } };

test "restore unsets or restores only allowlisted values" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    try f.owner.restore();
    try f.bus.expectEnv(&original);
    try testing.expectEqualStrings("", f.bus.activated.get("WAYLAND_DISPLAY").?);
    try testing.expectEqualStrings(":old", f.bus.activated.get("DISPLAY").?);
}

test "a value changed by someone else is not clobbered" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    try f.bus.env.put(f.bus.arena.allocator(), "DISPLAY", ":newer");
    try f.bus.activated.put(f.bus.arena.allocator(), "DISPLAY", ":newer");
    try f.owner.restore();
    try testing.expectEqualStrings(":newer", f.bus.env.get("DISPLAY").?);
    try testing.expectEqualStrings(":newer", f.bus.activated.get("DISPLAY").?);
}

test "a changed owner is not clobbered" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    try f.bus.env.put(f.bus.arena.allocator(), owner_key, "successor");
    const before = f.bus.env.count();
    try f.owner.restore();
    try testing.expectEqual(before, f.bus.env.count());
    try testing.expectEqualStrings("wayland-owned", f.bus.env.get("WAYLAND_DISPLAY").?);
}

test "a new graphical login prevents cleanup of a reused display" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    f.bus.other = "c2";
    try f.owner.restore();
    try testing.expectEqualStrings("wayland-owned", f.bus.env.get("WAYLAND_DISPLAY").?);
    try testing.expectEqualStrings(":12", f.bus.env.get("DISPLAY").?);
}

test "a conflict appearing before readiness prevents publication" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.bus.other = "c2";
    try testing.expectError(error.GraphicalSessionConflict, f.publish());
    try testing.expect(f.bus.env.get("WAYLAND_DISPLAY") == null);
}

test "a competing launcher is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var contender = try TestPublication.init(testing.allocator, &f.bus, f.runtime, "c2");
    defer contender.deinit();
    try testing.expectError(error.PublicationLocked, contender.acquire());
}

test "another graphical login is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.owner.close();
    f.bus.other = "gnome-session";
    try testing.expectError(error.GraphicalSessionConflict, f.owner.acquire());
    try testing.expect(f.bus.env.get(owner_key) == null);
}

test "a partial publication rolls back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.bus.fail_activation = true;
    try testing.expectError(error.InjectedBusRefusal, f.publish());
    try f.owner.restore();
    try testing.expectEqualStrings(":old", f.bus.env.get("DISPLAY").?);
    try testing.expect(f.bus.env.get("WAYLAND_DISPLAY") == null);
}

test "a stale journal recovers after supervisor failure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    sys.close(f.owner.lock.?);
    f.owner.lock = null;
    f.owner.record = null;
    var successor = try TestPublication.init(testing.allocator, &f.bus, f.runtime, "c2");
    defer successor.deinit();
    try successor.acquire();
    try successor.close();
    try testing.expectEqualStrings(":old", f.bus.env.get("DISPLAY").?);
    try testing.expect(f.bus.env.get("WAYLAND_DISPLAY") == null);
}

test "a compositor exec restart replaces the display" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.publish();
    try f.owner.publish(&.{.{ .key = "WAYLAND_DISPLAY", .value = "wayland-restarted" }});
    try testing.expectEqualStrings("wayland-restarted", f.bus.env.get("WAYLAND_DISPLAY").?);
    try f.owner.restore();
    try testing.expect(f.bus.env.get("WAYLAND_DISPLAY") == null);
}

test "unrestricted publication is rejected" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectError(error.InvalidActivationEnvironment, f.owner.publish(&.{.{ .key = "SECRET", .value = "never publish" }}));
    try testing.expectError(error.InvalidActivationEnvironment, f.owner.publish(&.{.{ .key = owner_key, .value = "forged" }}));
}

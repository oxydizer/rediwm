//! Lock and greeter tests: password editing, guards, rasters, authentication and sign-in.

const std = @import("std");
const lock_src = @import("lock.zig");
const c = lock_src.c;
const rediwm_auth_poll = lock_src.rediwm_auth_poll;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const text = @import("ui").text;
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const lock_controls = @import("lock_controls.zig");
const Greeter = greeter_mod.Greeter;
const login_appearance = @import("login_appearance.zig");
const Lock = @import("lock.zig").Lock;
const controlsPick = @import("lock.zig").controlsPick;
const focus_account = @import("lock.zig").focus_account;
const focus_session = @import("lock.zig").focus_session;
const Geometry = @import("lock.zig").Geometry;
const View = @import("lock.zig").View;
const paint = @import("lock.zig").paint;

test "lock password editing clears complete UTF-8 characters and Escape never unlocks" {
    var server: Server = undefined;
    server.polkit = null;
    server.outputs.init();
    var lock = Lock{ .server = &server, .timer = undefined };
    server.locker = &lock;
    lock.key(@enumFromInt('a'), "a", .{});
    lock.key(@enumFromInt('e'), "é", .{});
    try std.testing.expectEqualStrings("aé", lock.field().value());
    lock.key(xkb.Keysym.BackSpace, "", .{});
    try std.testing.expectEqualStrings("a", lock.field().value());
    try std.testing.expectEqual(@as(u8, 0), lock.password[2]);
    lock.reveal = true;
    lock.key(xkb.Keysym.Escape, "", .{});
    try std.testing.expect(server.locker == &lock);
    try std.testing.expect(!lock.reveal);
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    for (lock.password) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Oversized input must not produce a partial UTF-8 sequence or overrun.
    const full = @as([511]u8, @splat('a'));
    lock.key(@enumFromInt('a'), &full, .{});
    lock.key(@enumFromInt('e'), "é", .{});
    try std.testing.expectEqual(@as(usize, 511), lock.input.len);
    try std.testing.expectEqual(@as(u8, 0), lock.password[511]);
    lock.clear();
}

test "lock IPC and client focus requests stop before touching desktop state" {
    var server: Server = undefined;
    var lock = Lock{ .server = &server, .timer = undefined };
    server.locker = &lock;
    const response = try @import("../ipc/handlers.zig").handleRequest(&server, null, .version, std.testing.allocator, null);
    try std.testing.expectEqualStrings("SessionLocked", response.err);
    var world: @import("../World.zig") = undefined;
    world.server = &server;
    var top: @import("../Toplevel.zig") = undefined;
    world.focusSurface(&top, null);
    var layer: @import("../LayerSurface.zig") = undefined;
    layer.server = &server;
    layer.focus();
    var input: @import("../Input.zig") = undefined;
    input.server = &server;
    input.processCursorMotion(1);
    input.warpCursor(100, 100, 1);
    // These deliberately undefined desktop structures would fault if any of
    // the locked guards reached their ordinary client-facing paths.
}

test "lock output guard is opaque independent of wallpaper and UI buffers" {
    var fixture = try sn.TestScene.create();
    defer fixture.destroy();
    var view = try View.create(&fixture.nodes.tree);
    try std.testing.expect(!view.tree.node.enabled);
    try std.testing.expectEqual(@as(f32, 1), view.guard.color[3]);
    view.tree.node.setEnabled(true);
    view.guard.setSize(1920, 1080);
    try std.testing.expectEqual(@as(i32, 1920), view.guard.width);
    try std.testing.expect(view.ui_node.getBuffer() == null);
    view.hide();
    try std.testing.expect(!view.tree.node.enabled);
}

test "lock raster scales to small outputs and renders a solid accent unlock button" {
    var lock = Lock{ .server = undefined, .timer = undefined, .controls_visible = true };
    @memcpy(lock.name[0..11], "Alex Morgan");
    @memcpy(lock.user[0..10], "alexmorgan");
    lock.controls = .{ .has_volume = true, .volume = 0.5, .has_brightness = true, .brightness = 0.25, .active = .volume };
    var fixture = try sn.TestScene.create();
    defer fixture.destroy();
    var view = try View.create(&fixture.nodes.tree);
    for ([_][3]i32{ .{ 1672, 941, 1 }, .{ 640, 480, 1 }, .{ 1280, 720, 2 } }) |size| {
        const scale: f32 = if (size[2] == 2) 1.5 else 1;
        const buf = try Buffer.create(size[0], size[1], scale);
        defer buf.base.drop();
        @memset(buf.pixels, 0xff090b12);
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
        _ = paint(&renderer, &lock, @floatFromInt(size[0]), @floatFromInt(size[1]), size[0] == 640);
        const geo = Geometry.init(@floatFromInt(size[0]), @floatFromInt(size[1]));
        const px: usize = @intFromFloat((geo.left + 15 * geo.s) * scale);
        const py: usize = @intFromFloat((geo.top + 530 * geo.s) * scale);
        // The volume/brightness block is its own raster, bottom centre, and
        // never reaches the power buttons however small the output.
        view.syncControls(&lock, .{ .x = 0, .y = 0, .width = size[0], .height = size[1] }, scale);
        const placed = geo.controlsBox(lock.controls.height());
        const node = &view.controls_node.node;
        try std.testing.expect(node.enabled and view.controls_node.getBuffer() != null);
        try std.testing.expectEqual(placed.x, node.x);
        try std.testing.expectEqual(placed.y, node.y);
        try std.testing.expect(node.y >= 0 and node.y + placed.h <= size[1]);
        try std.testing.expect(node.x + placed.w <= @as(i32, @intFromFloat(geo.powerAction(0).x * geo.s)));
        // Pointer: the volume track is found where it is drawn, and a drag
        // maps the pointer across exactly that track, clamped at its ends.
        var no_audio: Server = undefined;
        no_audio.audio = null;
        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        const row_y: f32 = @as(f32, @floatFromInt(placed.y)) + 16 * geo.s;
        const track = controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 100 * geo.s, row_y) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(lock_controls.Kind.volume, track.hit.kind);
        try std.testing.expectEqual(lock_controls.Part.track, track.hit.part);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(placed.x)) + lock_controls.track_x * geo.s, track.left, 0.01);
        try std.testing.expectEqual(lock_controls.Part.icon, controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 10 * geo.s, row_y).?.hit.part);
        try std.testing.expectEqual(lock_controls.Kind.brightness, controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 100 * geo.s, row_y + 40 * geo.s).?.hit.kind);
        try std.testing.expect(controlsPick(&lock.controls, w, h, w / 2, h / 4) == null);
        var drag = lock.controls;
        drag.beginDrag(&no_audio, .volume, track.left, track.span, track.left + track.span * 0.75);
        try std.testing.expectApproxEqAbs(@as(f32, 0.75), drag.volume, 0.0001);
        drag.dragTo(&no_audio, track.left + track.span * 3);
        try std.testing.expectEqual(@as(f32, 1), drag.volume);
        drag.dragTo(&no_audio, track.left - 50);
        try std.testing.expectEqual(@as(f32, 0), drag.volume);
        try std.testing.expect(drag.endDrag() and !drag.endDrag());
        const actual = buf.pixels[py * @as(usize, @intCast(buf.width)) + px];
        try std.testing.expectEqual(@as(u32, 255), actual >> 24);
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
            const got: f32 = @floatFromInt((actual >> shift) & 255);
            try std.testing.expectApproxEqAbs(ui.theme.shellPalette().accent[channel] * 255, got, 1);
        }
        if (size[0] == 1672) {
            const env = @import("c");
            if (env.getenv("REDIWM_LOCK_PREVIEW")) |path| {
                const bytes = try @import("../screenshot/encode.zig").encodePng(std.testing.allocator, @intCast(buf.width), @intCast(buf.height), buf.pixels, @intCast(buf.width));
                defer std.testing.allocator.free(bytes);
                try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = std.mem.span(path), .data = bytes });
            }
        }
    }
    // No backend, no block: the greeter and a desktop without a backlight or
    // a sound server show nothing there.
    lock.controls = .{};
    view.syncControls(&lock, .{ .x = 0, .y = 0, .width = 1280, .height = 720 }, 1);
    try std.testing.expect(!view.controls_node.node.enabled and view.controls_node.getBuffer() == null);
    Buffer.drainPool();
}

test "lock authentication failure stays locked and success releases lock state" {
    // This symbol is provided exclusively by tests/auth_test.c, never by the
    // production executable. It controls PAM results at link time.
    const fixture = struct {
        extern fn rediwm_test_auth_scenario(c_int) void;
    };
    const display = try wl.Server.create();
    defer display.destroy();
    const seat = try wlr.Seat.create(display, "lock-test");
    defer seat.destroy();
    var server: Server = undefined;
    // Resume the real agent only after successful PAM, without opening a bus.
    var conn: @import("dbus").Connection = undefined;
    conn.closed = true;
    var agent = @import("../polkit/agent.zig").Agent{
        .allocator = gpa,
        .conn = &conn,
        .loop = display.getEventLoop(),
        .locale = "C",
        .suspended = true,
    };
    server.polkit = &agent;
    server.undo = .{};
    server.wl_server = display;
    server.outputs.init();
    server.world.toplevels.init();
    server.input.seat = seat;
    // Releasing announces the unlock: no supervisor fd and no logind here.
    server.environ = std.process.Environ.empty;
    server.power = null;
    for ([_]c_int{ 1, 2, 3, 4, 0 }) |scenario| {
        fixture.rediwm_test_auth_scenario(scenario);
        const lock = try gpa.create(Lock);
        lock.* = .{ .server = &server, .timer = undefined };
        lock.timer = try display.getEventLoop().addTimer(*Lock, Lock.tick, lock);
        server.locker = lock;
        try std.testing.expect(lock.field().insert("fixture-password"));
        lock.submit();
        try std.testing.expectEqual(@as(usize, 0), lock.input.len);
        try std.testing.expect(lock.auth != null);
        for (0..10000) |_| {
            if (rediwm_auth_poll(lock.auth.?) != 0) break;
            _ = c.usleep(1000);
        }
        try std.testing.expect(rediwm_auth_poll(lock.auth.?) != 0);
        // The worker's eventfd, not a timer, reports the result.
        try std.testing.expect(lock.auth_source != null);
        try display.getEventLoop().dispatch(1000);
        if (scenario == 0) {
            try std.testing.expect(server.locker == null);
            try std.testing.expect(!agent.suspended);
        } else {
            try std.testing.expect(server.locker == lock);
            try std.testing.expect(agent.suspended);
            try std.testing.expect(lock.auth == null);
            try std.testing.expect(lock.retry_at > @import("ui").anim.nowMs());
            for (lock.password) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            lock.destroy();
            server.locker = null;
        }
    }
}

test "lock covers new outputs and follows layout and mode changes without UI" {
    const display = try wl.Server.create();
    defer display.destroy();
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const output_layout = try wlr.OutputLayout.create(display);
    defer output_layout.destroy();
    var fixture = try sn.TestScene.create();
    defer fixture.destroy();
    var server: Server = undefined;
    server.output_layout = output_layout;
    server.lock_tree = try fixture.nodes.tree.createSceneTree();
    for (0..2) |i| {
        const output = try backend.headlessAddOutput(1280, 720);
        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(true);
        try std.testing.expect(output.commitState(&state));
        const x: i32 = if (i == 0) -1280 else 0;
        _ = try output_layout.add(output, x, 100);
        var out = Output{ .server = &server, .wlr_output = output, .lock_view = try View.create(server.lock_tree) };
        out.lock_view.cover(&out);
        try std.testing.expect(out.lock_view.tree.node.enabled);
        try std.testing.expectEqual(x, out.lock_view.tree.node.x);
        try std.testing.expectEqual(@as(i32, 100), out.lock_view.tree.node.y);
        try std.testing.expectEqual(@as(i32, 1280), out.lock_view.guard.width);
        try std.testing.expectEqual(@as(i32, 720), out.lock_view.guard.height);
        try std.testing.expect(out.lock_view.ui_node.getBuffer() == null);
        state.setCustomMode(1920, 1080, 60000);
        try std.testing.expect(output.commitState(&state));
        _ = try output_layout.add(output, x, -50);
        out.lock_view.cover(&out);
        try std.testing.expectEqual(@as(i32, 1920), out.lock_view.guard.width);
        try std.testing.expectEqual(@as(i32, 1080), out.lock_view.guard.height);
        try std.testing.expectEqual(@as(i32, -50), out.lock_view.tree.node.y);
    }
}

test "greeter signs in through rediwm-dm and exits only once the session starts" {
    const sock = @import("c");
    const peer = struct {
        fd: c_int,
        buf: [4096]u8 = undefined,
        fn read(self: *@This()) ![]const u8 {
            var header: [4]u8 = undefined;
            if (sock.read(self.fd, &header, 4) != 4) return error.Short;
            const n = std.mem.readInt(u32, &header, @import("builtin").cpu.arch.endian());
            var got: usize = 0;
            while (got < n) {
                const r = sock.read(self.fd, self.buf[got..].ptr, n - got);
                if (r <= 0) return error.Short;
                got += @intCast(r);
            }
            return self.buf[0..n];
        }
        fn write(self: *@This(), json: []const u8) void {
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(json.len), @import("builtin").cpu.arch.endian());
            _ = sock.write(self.fd, &header, 4);
            _ = sock.write(self.fd, json.ptr, json.len);
        }
    };
    const display = try wl.Server.create();
    defer display.destroy();
    var server: Server = undefined;
    server.outputs.init();
    server.wl_server = display;
    server.io = std.testing.io;
    server.shutting_down = false;
    server.layout_autosave = null;
    server.reveal = .{};
    var users = [_]greeter_mod.User{
        .{ .name = "rediwm-test-a", .real = "Test A", .home = "", .uid = 1000 },
        .{ .name = "rediwm-test-b", .real = "", .home = "", .uid = 1001 },
    };
    var sessions = [_]greeter_mod.Session{
        .{ .id = "rediwm", .name = "RediWM", .exec = "/usr/local/bin/rediwm-session", .desktops = "rediwm" },
        .{ .id = "sway", .name = "Sway", .exec = "sway", .desktops = "sway" },
    };
    // Greeter.destroy frees through libc, as Greeter.create allocates.
    const greeter = try std.heap.c_allocator.create(Greeter);
    greeter.* = .{ .arena = .init(std.heap.c_allocator), .io = std.testing.io, .loop = display.getEventLoop(), .users = &users, .sessions = &sessions };
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), sock.socketpair(sock.AF_UNIX, sock.SOCK_STREAM | sock.SOCK_CLOEXEC, 0, &fds));
    defer _ = sock.close(fds[1]);
    try greeter.adopt(fds[0]);
    var daemon = peer{ .fd = fds[1] };
    var lock = Lock{ .server = &server, .timer = undefined, .greeter = greeter, .greeter_appearance_root = "" };
    greeter.owner = &lock;
    greeter.notify = Lock.greeterEvent;
    server.locker = &lock;
    defer {
        greeter.destroy();
        if (lock.avatar) |avatar| avatar.deinit(gpa);
        lock.clear();
    }
    lock.showAccount();
    try std.testing.expectEqualStrings("rediwm-test-a", std.mem.sliceTo(&lock.user, 0));

    // Account and session choice.
    lock.key(xkb.Keysym.Down, "", .{});
    try std.testing.expectEqualStrings("rediwm-test-b", std.mem.sliceTo(&lock.user, 0));
    lock.key(xkb.Keysym.Up, "", .{});
    try std.testing.expectEqualStrings("Test A", std.mem.sliceTo(&lock.name, 0));
    lock.key(xkb.Keysym.ISO_Left_Tab, "", .{ .shift = true });
    try std.testing.expectEqual(focus_account, lock.focus);
    lock.key(xkb.Keysym.Tab, "", .{});
    try std.testing.expectEqual(@as(u8, 0), lock.focus);
    for (0..3) |_| lock.key(xkb.Keysym.Tab, "", .{});
    try std.testing.expectEqual(focus_session, lock.focus);
    lock.key(xkb.Keysym.Right, "", .{});
    try std.testing.expectEqualStrings("sway", greeter.selectedSession().?.id);
    lock.key(xkb.Keysym.Left, "", .{});
    lock.focus = 0;

    // The password typed up front answers dm's first question.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(xkb.Keysym.Return, "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"login\",\"user\":\"rediwm-test-a\"}", try daemon.read());
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    lock.key(@enumFromInt('x'), "x", .{});
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    try std.testing.expect(lock.busy());
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Password:\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":\"pw\"}", try daemon.read());
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // A second factor is asked of the user; info messages need an empty reply.
    daemon.write("{\"type\":\"question\",\"kind\":\"info\",\"text\":\"Touch the key\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Touch the key", lock.status);
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":null}", try daemon.read());
    daemon.write("{\"type\":\"question\",\"kind\":\"visible\",\"text\":\"Code: \"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Code:", lock.status);
    try std.testing.expect(lock.prompting() and lock.reveal and !lock.busy());
    for ("123") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    try std.testing.expectEqualStrings("Code:", lock.status);
    lock.key(xkb.Keysym.Return, "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":\"123\"}", try daemon.read());

    // Wrong answers cancel the attempt and never start a session.
    daemon.write("{\"type\":\"denied\",\"text\":\"pam_authenticate: AUTH_ERR\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Incorrect password. Try again.", lock.status);
    try std.testing.expectEqualStrings("{\"type\":\"cancel\"}", try daemon.read());
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);
    try std.testing.expect(!server.shutting_down);

    // Escape abandons a question.
    lock.retry_at = 0;
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(xkb.Keysym.Return, "", .{});
    _ = try daemon.read();
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Password:\"}");
    greeter.pump();
    _ = try daemon.read();
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"New password:\"}");
    greeter.pump();
    lock.key(xkb.Keysym.Escape, "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"cancel\"}", try daemon.read());
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);

    // Success starts the chosen session with its desktop identity, and the
    // greeter exits only after dm accepts it.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(xkb.Keysym.Return, "", .{});
    _ = try daemon.read();
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqualStrings(
        "{\"type\":\"start\",\"session\":\"rediwm\"}",
        try daemon.read(),
    );
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(!server.shutting_down);
    lock.key(xkb.Keysym.Down, "", .{});
    try std.testing.expectEqualStrings("rediwm-test-a", std.mem.sliceTo(&lock.user, 0));
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expect(server.shutting_down);
    try std.testing.expectEqual(greeter_mod.Phase.done, greeter.phase);
}

test "greeter reports a lost login service and exits to be replaced" {
    const sock = @import("c");
    const display = try wl.Server.create();
    defer display.destroy();
    var server: Server = undefined;
    server.outputs.init();
    server.wl_server = display;
    server.shutting_down = false;
    server.layout_autosave = null;
    server.reveal = .{};
    var users = [_]greeter_mod.User{.{ .name = "rediwm-test-a", .real = "", .home = "", .uid = 1000 }};
    var sessions = [_]greeter_mod.Session{.{ .id = "rediwm", .name = "RediWM", .exec = "rediwm-session", .desktops = "rediwm" }};
    const greeter = try std.heap.c_allocator.create(Greeter);
    greeter.* = .{ .arena = .init(std.heap.c_allocator), .io = std.testing.io, .loop = display.getEventLoop(), .users = &users, .sessions = &sessions };
    var lock = Lock{ .server = &server, .timer = undefined, .greeter = greeter };
    greeter.owner = &lock;
    greeter.notify = Lock.greeterEvent;
    defer {
        greeter.destroy();
        lock.clear();
    }
    // No REDIWM_GREETER_FD: a clear message, not a crash or an unlock.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(xkb.Keysym.Return, "", .{});
    try std.testing.expectEqualStrings("No login service", lock.status);
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), sock.socketpair(sock.AF_UNIX, sock.SOCK_STREAM | sock.SOCK_CLOEXEC, 0, &fds));
    try greeter.adopt(fds[0]);
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(xkb.Keysym.Return, "", .{});
    try std.testing.expect(lock.busy());
    _ = sock.close(fds[1]);
    greeter.pump();
    try std.testing.expectEqualStrings("Lost contact with login service. Try again.", lock.status);
    try std.testing.expect(!lock.busy() and greeter.client == null);
    try std.testing.expect(server.shutting_down);
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "greeter raster shows account arrows and the session chooser" {
    var users = [_]greeter_mod.User{
        .{ .name = "alexmorgan", .real = "Alex Morgan", .home = "", .uid = 1000 },
        .{ .name = "sam", .real = "", .home = "", .uid = 1001 },
    };
    var sessions = [_]greeter_mod.Session{
        .{ .id = "rediwm", .name = "RediWM", .exec = "", .desktops = "" },
        .{ .id = "sway", .name = "Sway", .exec = "", .desktops = "" },
    };
    var greeter = Greeter{ .arena = .init(gpa), .io = undefined, .loop = undefined, .users = &users, .sessions = &sessions };
    defer greeter.arena.deinit();
    var lock = Lock{ .server = undefined, .timer = undefined, .greeter = &greeter, .focus = focus_session };
    lock.status = lock.idleStatus();
    @memcpy(lock.name[0..11], "Alex Morgan");
    @memcpy(lock.user[0..10], "alexmorgan");
    const width = 1672;
    const height = 941;
    const buf = try Buffer.create(width, height, 1);
    defer buf.base.drop();
    @memset(buf.pixels, 0xff090b12);
    var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = 1 };
    _ = paint(&renderer, &lock, width, height, false);
    const geo = Geometry.init(width, height);
    // Something is drawn in the session corner and beside the picture.
    const lit = struct {
        fn any(b: *Buffer, x0: f32, y0: f32, x1: f32, y1: f32) bool {
            var y: usize = @intFromFloat(y0);
            while (y < @as(usize, @intFromFloat(y1))) : (y += 1) {
                var x: usize = @intFromFloat(x0);
                while (x < @as(usize, @intFromFloat(x1))) : (x += 1) {
                    if (b.pixels[y * @as(usize, @intCast(b.width)) + x] & 0xff != 0x12) return true;
                }
            }
            return false;
        }
    };
    try std.testing.expect(lit.any(buf, 30 * geo.s, height - 90 * geo.s, 120 * geo.s, height - 60 * geo.s));
    try std.testing.expect(lit.any(buf, width / 2 - 130 * geo.s, geo.top + 244 * geo.s, width / 2 - 90 * geo.s, geo.top + 304 * geo.s));
    const env = @import("c");
    if (env.getenv("REDIWM_GREETER_PREVIEW")) |path| {
        const bytes = try @import("../screenshot/encode.zig").encodePng(std.testing.allocator, @intCast(buf.width), @intCast(buf.height), buf.pixels, @intCast(buf.width));
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = std.mem.span(path), .data = bytes });
    }
    Buffer.drainPool();
}

test "greeter appearance follows account selection and resets missing or broken snapshots" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const old_theme = ui.theme.global;
    defer {
        ui.theme.global = old_theme;
        text.setPreferredFamilies(old_theme.font, old_theme.mono_font);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const uid = c.getuid();
    const path = try login_appearance.directory(a, base, uid);
    defer a.free(path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    var server: Server = undefined;
    server.outputs.init();
    var users = [_]greeter_mod.User{
        .{ .name = "saved", .real = "", .home = "", .uid = uid },
        .{ .name = "new", .real = "", .home = "", .uid = uid + 1 },
    };
    var greeter = Greeter{ .arena = .init(gpa), .io = io, .loop = undefined, .users = &users };
    defer greeter.arena.deinit();
    var lock = Lock{ .server = &server, .timer = undefined, .greeter = &greeter, .greeter_appearance_root = base };
    defer lock.clearAccountAppearance();
    var pixels = [_]u32{0xff123456};
    try login_appearance.saveWallpaper(a, path, .{ .width = 1, .height = 1, .pixels = &pixels, .has_alpha = false });
    for (@import("ui").theme_presets.bundled) |preset| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tokens = try ui.theme.parse(arena.allocator(), preset.bytes);
        try login_appearance.saveTheme(a, path, tokens);
        greeter.user = 0;
        lock.applyAccountAppearance(greeter.selectedUser().?.uid);
        // Theme serialization compares colours at 8-bit precision.
        for (tokens.lock_bg, ui.theme.global.lock_bg) |want, got| try std.testing.expectApproxEqAbs(want, got, 1.0 / 255.0);
        for (tokens.lock_fg, ui.theme.global.lock_fg) |want, got| try std.testing.expectApproxEqAbs(want, got, 1.0 / 255.0);
        try std.testing.expectEqualSlices(u32, &pixels, lock.greeter_wallpaper.?.pixels);
        greeter.user = 1;
        lock.applyAccountAppearance(greeter.selectedUser().?.uid);
        try std.testing.expectEqual(lock.greeter_default_theme.lock_bg, ui.theme.global.lock_bg);
        try std.testing.expect(lock.greeter_wallpaper == null and lock.greeter_appearance == null);
    }
    const file = try std.fs.path.join(a, &.{ path, "theme.toml" });
    defer a.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "[theme]\nlock_bg = \"invalid\"\n" });
    lock.applyAccountAppearance(uid);
    try std.testing.expect(lock.greeter_appearance == null);
    try std.testing.expectEqual(lock.greeter_default_theme.lock_bg, ui.theme.global.lock_bg);
}

test "the lock shows the active keyboard layout only while there are several" {
    var lock = Lock{ .server = undefined, .timer = undefined };
    const width: i32 = 1280;
    const height: i32 = 720;
    const geo = Geometry.init(@floatFromInt(width), @floatFromInt(height));
    const button = geo.layoutButton();
    var counts: [2]usize = undefined;
    for ([_][]const u8{ "", "DE" }, 0..) |label, i| {
        @memcpy(lock.layout_label[0..label.len], label);
        lock.layout_label_len = @intCast(label.len);
        const buf = try Buffer.create(width, height, 1);
        defer buf.base.drop();
        @memset(buf.pixels, 0xff090b12);
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = 1 };
        _ = paint(&renderer, &lock, @floatFromInt(width), @floatFromInt(height), true);
        var changed: usize = 0;
        const x0: usize = @intFromFloat(button.x * geo.s);
        const y0: usize = @intFromFloat(button.y * geo.s);
        for (y0..y0 + @as(usize, @intFromFloat(button.h * geo.s))) |y| {
            for (x0..x0 + @as(usize, @intFromFloat(button.w * geo.s))) |x| {
                if (buf.pixels[y * @as(usize, @intCast(width)) + x] != 0xff090b12) changed += 1;
            }
        }
        counts[i] = changed;
    }
    // One layout draws nothing there; several draw the keyboard and its code.
    try std.testing.expectEqual(@as(usize, 0), counts[0]);
    try std.testing.expect(counts[1] > 50);
}

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Server = @import("../Server.zig");
const Keyboard = @import("../Keyboard.zig");
const Pointer = @import("../Pointer.zig");

const log = std.log.scoped(.virtual_input);

pub const PointerImpl = extern struct {
    name: [*:0]const u8,
};

pub const KeyboardImpl = extern struct {
    name: [*:0]const u8,
    led_update: ?*const fn (keyboard: *wlr.Keyboard, leds: u32) callconv(.c) void = null,
};

extern fn wlr_pointer_init(pointer: *wlr.Pointer, impl: *const PointerImpl, name: [*:0]const u8) void;
extern fn wlr_pointer_finish(pointer: *wlr.Pointer) void;

pub const KeyInfo = struct {
    evdev_keycode: u32,
    shift: bool,
};

pub const Step = union(enum) {
    move_cursor: struct { x: f64, y: f64 },
    pointer_button: struct { button: u32, state: wl.Pointer.ButtonState },
    key: struct { keycode: u32, state: wl.Keyboard.KeyState },
    shift_modifier: struct { active: bool },
    axis: struct { orientation: wl.Pointer.Axis, delta: f64 },
};

pub const Sequence = struct {
    client_id: ?u64 = null,
    request_id: ?@import("../ipc/protocol.zig").RequestId = null,
    steps: std.ArrayList(Step),
    current_index: usize = 0,
    timer_source: ?*wl.EventSource = null,
    on_complete: ?*const fn (vi: *VirtualInput, seq: *Sequence, err: ?[]const u8) void = null,
};

pub const SyntheticKeyboard = struct {
    // wlroots retains the implementation pointer for the device lifetime.
    const impl = KeyboardImpl{ .name = "synthetic-keyboard" };
    server: *Server,
    wlr_kbd: wlr.Keyboard = undefined,
    sym_map: std.AutoHashMap(xkb.Keysym, KeyInfo),
    allocator: std.mem.Allocator,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*SyntheticKeyboard {
        const synthetic = try allocator.create(SyntheticKeyboard);
        errdefer allocator.destroy(synthetic);

        synthetic.* = .{
            .server = server,
            .sym_map = std.AutoHashMap(xkb.Keysym, KeyInfo).init(allocator),
            .allocator = allocator,
        };

        const context = xkb.Context.new(.no_flags) orelse return error.KeyboardInitFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, &.{ .rules = null, .model = null, .layout = "us", .variant = "", .options = "" }, .no_flags) orelse return error.KeyboardInitFailed;
        defer keymap.unref();

        wlr.Keyboard.init(&synthetic.wlr_kbd, @ptrCast(&impl), "synthetic-keyboard");
        errdefer wlr.Keyboard.finish(&synthetic.wlr_kbd);
        errdefer synthetic.sym_map.deinit();

        if (!synthetic.wlr_kbd.setKeymap(keymap)) return error.KeyboardInitFailed;
        synthetic.wlr_kbd.setRepeatInfo(25, 600);

        try synthetic.populateLookupTable(keymap);
        try Keyboard.createSynthetic(server, &synthetic.wlr_kbd.base);

        return synthetic;
    }

    pub fn destroy(synthetic: *SyntheticKeyboard) void {
        synthetic.sym_map.deinit();
        wlr.Keyboard.finish(&synthetic.wlr_kbd);
        synthetic.allocator.destroy(synthetic);
    }

    fn populateLookupTable(synthetic: *SyntheticKeyboard, keymap: *xkb.Keymap) !void {
        const min_k = keymap.minKeycode();
        const max_k = keymap.maxKeycode();
        var k: xkb.Keycode = min_k;
        while (k <= max_k) : (k += 1) {
            const num_layouts = keymap.numLayoutsForKey(k);
            var g: u32 = 0;
            while (g < num_layouts) : (g += 1) {
                const num_levels = keymap.numLevelsForKey(k, g);
                var l: u32 = 0;
                while (l < num_levels) : (l += 1) {
                    const syms = keymap.keyGetSymsByLevel(k, g, l);
                    const shift = (l > 0);
                    for (syms) |sym| {
                        if (k >= 8) {
                            const evdev_code = k - 8;
                            if (synthetic.sym_map.get(sym) == null) {
                                try synthetic.sym_map.put(sym, .{
                                    .evdev_keycode = evdev_code,
                                    .shift = shift,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn lookupChar(synthetic: *SyntheticKeyboard, c: u8) ?KeyInfo {
        const sym = xkb.Keysym.fromUTF32(c);
        if (@intFromEnum(sym) == 0) return null;
        return synthetic.sym_map.get(sym);
    }

    pub fn lookupKeyName(synthetic: *SyntheticKeyboard, name: []const u8) ?KeyInfo {
        var buf: [128:0]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;

        const sym = xkb.Keysym.fromName(&buf, .no_flags);
        if (@intFromEnum(sym) != 0) {
            if (synthetic.sym_map.get(sym)) |info| return info;
        }
        if (name.len == 1) {
            return synthetic.lookupChar(name[0]);
        }
        return null;
    }

    pub fn sendKey(synthetic: *SyntheticKeyboard, time_msec: u32, keycode: u32, state: wl.Keyboard.KeyState) void {
        var event = wlr.Keyboard.event.Key{
            .time_msec = time_msec,
            .keycode = keycode,
            .update_state = true,
            .state = state,
        };
        synthetic.wlr_kbd.notifyKey(&event);
    }

    pub fn sendShiftModifier(synthetic: *SyntheticKeyboard, active: bool) void {
        if (synthetic.wlr_kbd.keymap) |km| {
            const shift_idx = km.modGetIndex("Shift");
            const shift_mask: u32 = if (shift_idx != xkb.mod_invalid) (@as(u32, 1) << @intCast(shift_idx)) else 1;
            const depressed = if (active) shift_mask else 0;
            synthetic.wlr_kbd.notifyModifiers(.{
                .depressed = depressed,
                .latched = 0,
                .locked = 0,
                .group = 0,
            });
        }
    }
};

pub const SyntheticPointer = struct {
    const impl = PointerImpl{ .name = "synthetic-pointer" };
    server: *Server,
    wlr_ptr: CPointer = undefined,
    allocator: std.mem.Allocator,

    /// zig-wlroots 0.20.1's `wlr.Pointer` omits the C struct's trailing
    /// `void *data` (336 vs 344 bytes), which `wlr_pointer_init` zeroes. The
    /// extern wrapper keeps that write inside this field; it used to clear
    /// `allocator.ptr`, which only libc malloc could ignore.
    const CPointer = extern struct { base: wlr.Pointer, data: ?*anyopaque };

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*SyntheticPointer {
        const synthetic = try allocator.create(SyntheticPointer);
        errdefer allocator.destroy(synthetic);

        synthetic.* = .{
            .server = server,
            .allocator = allocator,
        };

        wlr_pointer_init(&synthetic.wlr_ptr.base, &impl, "synthetic-pointer");
        errdefer wlr_pointer_finish(&synthetic.wlr_ptr.base);

        server.input.cursor.attachInputDevice(&synthetic.wlr_ptr.base.base);
        try Pointer.create(&server.input, &synthetic.wlr_ptr.base.base);

        return synthetic;
    }

    pub fn destroy(synthetic: *SyntheticPointer) void {
        wlr_pointer_finish(&synthetic.wlr_ptr.base);
        synthetic.allocator.destroy(synthetic);
    }

    pub fn sendButton(synthetic: *SyntheticPointer, time_msec: u32, button: u32, state: wl.Pointer.ButtonState) void {
        synthetic.server.input.processButton(&synthetic.wlr_ptr.base.base, button, state, time_msec);
        synthetic.server.input.seat.pointerNotifyFrame();
    }
};

pub const VirtualInput = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    keyboard: *SyntheticKeyboard,
    pointer: *SyntheticPointer,
    active_sequence: ?*Sequence = null,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*VirtualInput {
        const vi = try allocator.create(VirtualInput);
        errdefer allocator.destroy(vi);

        const kbd = try SyntheticKeyboard.create(server, allocator);
        errdefer kbd.destroy();

        const ptr = try SyntheticPointer.create(server, allocator);
        errdefer ptr.destroy();

        // Headless backends have no physical new_input event to advertise these
        // capabilities. Clients must still bind the synthetic keyboard/pointer.
        server.input.seat.setCapabilities(.{ .keyboard = true, .pointer = true });

        vi.* = .{
            .server = server,
            .allocator = allocator,
            .keyboard = kbd,
            .pointer = ptr,
        };

        return vi;
    }

    pub fn destroy(vi: *VirtualInput) void {
        if (vi.active_sequence) |seq| {
            vi.cancelSequence(seq);
        }
        vi.keyboard.destroy();
        vi.pointer.destroy();
        vi.allocator.destroy(vi);
    }

    pub fn startSequence(vi: *VirtualInput, seq: *Sequence) !void {
        if (vi.active_sequence != null) return error.Busy;
        vi.active_sequence = seq;
        errdefer vi.active_sequence = null;

        const event_loop = vi.server.wl_server.getEventLoop();
        const source = try event_loop.addTimer(
            *VirtualInput,
            handleSequenceTimer,
            vi,
        );
        seq.timer_source = source;
        source.timerUpdate(1) catch {};
    }

    pub fn cancelSequence(vi: *VirtualInput, seq: *Sequence) void {
        if (seq.timer_source) |source| {
            source.remove();
            seq.timer_source = null;
        }
        seq.steps.deinit(vi.allocator);
        if (seq.request_id) |rid| {
            switch (rid) {
                .string => |s| vi.allocator.free(s),
                .integer => {},
            }
        }
        if (vi.active_sequence == seq) {
            vi.active_sequence = null;
        }
        vi.allocator.destroy(seq);
    }

    fn handleSequenceTimer(vi: *VirtualInput) c_int {
        const seq = vi.active_sequence orelse return 0;
        if (vi.server.locker != null or vi.server.polkit_dialog != null) {
            if (seq.on_complete) |done| done(vi, seq, "SessionLocked");
            vi.cancelSequence(seq);
            return 0;
        }
        const now = nowMs();

        if (seq.current_index < seq.steps.items.len) {
            const step = seq.steps.items[seq.current_index];
            seq.current_index += 1;

            switch (step) {
                .move_cursor => |m| {
                    vi.server.input.warpCursor(m.x, m.y, now);
                },
                .pointer_button => |b| {
                    vi.pointer.sendButton(now, b.button, b.state);
                },
                .key => |k| {
                    vi.keyboard.sendKey(now, k.keycode, k.state);
                },
                .shift_modifier => |s| {
                    vi.keyboard.sendShiftModifier(s.active);
                },
                .axis => |a| {
                    vi.server.input.processAxis(now, a.orientation, a.delta, 0, .continuous);
                    vi.server.input.seat.pointerNotifyFrame();
                },
            }

            if (seq.current_index < seq.steps.items.len) {
                if (seq.timer_source) |source| {
                    source.timerUpdate(8) catch {};
                }
                return 0;
            }
        }

        // Sequence finished
        const on_complete = seq.on_complete;
        const target_seq = seq;
        vi.active_sequence = null;
        if (seq.timer_source) |source| {
            source.remove();
            target_seq.timer_source = null;
        }

        if (on_complete) |func| {
            func(vi, target_seq, null);
        }

        target_seq.steps.deinit(vi.allocator);
        if (target_seq.request_id) |rid| {
            switch (rid) {
                .string => |s| vi.allocator.free(s),
                .integer => {},
            }
        }
        vi.allocator.destroy(target_seq);

        return 0;
    }

    pub fn nowMs() u32 {
        const timespec = extern struct {
            tv_sec: c_long,
            tv_nsec: c_long,
        };
        const clock_gettime_fn = struct {
            extern fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
        }.clock_gettime;
        var ts: timespec = undefined;
        _ = clock_gettime_fn(1, &ts); // 1 = CLOCK_MONOTONIC
        const ms: u64 = @intCast(@as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
        return @truncate(ms);
    }
};

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const loader = @import("config").loader;
const NightLightConfig = loader.NightLightConfig;
const color = @import("color.zig");
const schedule = @import("config").schedule;
const solar = @import("solar.zig");
const protocol = @import("../ipc/protocol.zig");

const log = std.log.scoped(.night_light);

const c_time = @cImport({
    @cInclude("time.h");
});

pub const NightLight = struct {
    server: ?*Server = null,
    config: NightLightConfig = .{},
    clock_override: ?i64 = null,
    timer_source: ?*wl.EventSource = null,

    current_temperature: u16 = 6500,
    current_phase: protocol.NightLightPhase = .off,
    next_change_unix: ?i64 = null,

    pub fn init(self: *NightLight, server: *Server, config: NightLightConfig) !void {
        self.server = server;
        self.config = config;
        self.clock_override = null;

        const loop = server.wl_server.getEventLoop();
        self.timer_source = loop.addTimer(*NightLight, handleTimerCallback, self) catch |err| blk: {
            log.warn("init: failed to register timer: {}", .{err});
            break :blk null;
        };

        self.tick();
    }

    pub fn deinit(self: *NightLight) void {
        if (self.timer_source) |source| {
            source.remove();
            self.timer_source = null;
        }
    }

    fn handleTimerCallback(self: *NightLight) c_int {
        self.tick();
        return 0;
    }

    pub fn setClockOverride(self: *NightLight, override_sec: ?i64) void {
        self.clock_override = override_sec;
        self.tick();
    }

    pub fn reconfigure(self: *NightLight, new_config: NightLightConfig) void {
        self.config = new_config;
        self.tick();
    }

    fn disarmTimer(self: *NightLight) void {
        if (self.timer_source) |source| {
            source.timerUpdate(0) catch {};
        }
    }

    fn setTimerMs(self: *NightLight, ms: u32) void {
        if (self.timer_source) |source| {
            source.timerUpdate(@intCast(ms)) catch |err| {
                log.warn("setTimerMs: timerUpdate failed: {}", .{err});
            };
        }
    }

    pub fn tick(self: *NightLight) void {
        c_time.tzset();
        const now: c_time.time_t = if (self.clock_override) |ov| @intCast(ov) else c_time.time(null);
        var tm_storage: c_time.struct_tm = undefined;
        const tm = c_time.localtime_r(&now, &tm_storage);
        const utc_offset_s: i32 = if (tm) |t| @intCast(t.*.tm_gmtoff) else 0;
        const now_unix: i64 = @intCast(now);

        if (!self.config.enabled) {
            self.current_temperature = 6500;
            self.current_phase = .off;
            self.next_change_unix = null;
            self.disarmTimer();
            self.retargetAll();
            return;
        }

        switch (self.config.schedule) {
            .always => {
                self.current_temperature = self.config.temperature;
                self.current_phase = .night;
                self.next_change_unix = null;
                self.disarmTimer();
                self.retargetAll();
            },
            .fixed => {
                const eval = schedule.evaluate(self.config, now_unix, utc_offset_s);
                self.current_temperature = eval.temperature;
                self.current_phase = switch (eval.phase) {
                    .off => .off,
                    .day => .day,
                    .to_night => .to_night,
                    .night => .night,
                    .to_day => .to_day,
                };
                self.next_change_unix = eval.next_change_unix;
                self.retargetAll();

                // Re-arm timer:
                // 10s during a ramp; otherwise min(next_change - now, 60s)
                if (eval.phase == .to_night or eval.phase == .to_day) {
                    self.setTimerMs(10_000);
                } else {
                    const diff = if (eval.next_change_unix) |ncu| ncu - now_unix else 60;
                    const secs = @max(1, @min(diff, 60));
                    self.setTimerMs(@intCast(secs * 1000));
                }
            },
            .sun => {
                const lat = self.config.latitude orelse 0.0;
                const lon = self.config.longitude orelse 0.0;
                const el = solar.elevation(now_unix, lat, lon);
                const el_next = solar.elevation(now_unix + 60, lat, lon);
                const rising = el_next > el;

                const day_temp = self.config.day_temperature;
                const night_temp = self.config.temperature;

                if (el >= 0.0) {
                    self.current_phase = .day;
                    self.current_temperature = day_temp;
                } else if (el <= -6.0) {
                    self.current_phase = .night;
                    self.current_temperature = night_temp;
                } else {
                    self.current_phase = if (rising) .to_day else .to_night;
                    const t = -el / 6.0; // 0.0 at day (0°), 1.0 at night (-6°)
                    // Interpolate in mireds:
                    const mired_day = 1_000_000.0 / @as(f64, @floatFromInt(day_temp));
                    const mired_night = 1_000_000.0 / @as(f64, @floatFromInt(night_temp));
                    const mired = mired_day + t * (mired_night - mired_day);
                    self.current_temperature = @intFromFloat(@round(1_000_000.0 / mired));
                }
                self.next_change_unix = null;
                self.retargetAll();
                // Sun mode always uses the 60s cap:
                self.setTimerMs(60_000);
            },
        }
    }

    pub fn retargetAll(self: *NightLight) void {
        const server = self.server orelse return;
        var it = server.outputs.iterator(.forward);
        while (it.next()) |output| {
            self.retargetOutput(output);
        }
    }

    pub fn outputTemperature(self: *NightLight, output: *Output) u16 {
        const server = self.server orelse return 6500;
        if (!self.config.enabled) return 6500;
        const name = std.mem.span(output.wlr_output.name);
        for (server.config.outputs) |out_cfg| {
            if (std.mem.eql(u8, out_cfg.name, name)) {
                if (!out_cfg.night_light) return 6500;
                break;
            }
        }
        return self.current_temperature;
    }

    pub fn queryInfo(self: *NightLight) struct {
        enabled: bool,
        schedule: []const u8,
        phase: protocol.NightLightPhase,
        temperature: u16,
        next_change_unix: ?i64,
        clock_overridden: bool,
    } {
        return .{
            .enabled = self.config.enabled,
            .schedule = @tagName(self.config.schedule),
            .phase = self.current_phase,
            .temperature = self.current_temperature,
            .next_change_unix = self.next_change_unix,
            .clock_overridden = self.clock_override != null,
        };
    }

    pub fn retargetOutput(self: *NightLight, output: *Output) void {
        const server = self.server orelse return;
        if (output.user_disabled) {
            output.color.status = .disabled;
            return;
        }

        const name = std.mem.span(output.wlr_output.name);
        var nl_enabled = true;
        var gamma: f32 = 1.0;
        for (server.config.outputs) |out_cfg| {
            if (std.mem.eql(u8, out_cfg.name, name)) {
                nl_enabled = out_cfg.night_light;
                gamma = out_cfg.gamma;
                break;
            }
        }

        const target_temp: u16 = if (self.config.enabled and nl_enabled) self.current_temperature else 6500;
        const is_neutral = (target_temp == 6500 and gamma == 1.0);

        const gamma_size = output.wlr_output.getGammaSize();
        const target_key: Output.ColorKey = .{
            .temperature = @intCast(((target_temp + 5) / 10) * 10),
            .gamma_milli = @intFromFloat(@round(gamma * 1000.0)),
            .gamma_size = gamma_size,
        };

        if (is_neutral) {
            if (output.color.transform == null and (output.color.status == .neutral or output.color.status == .unsupported)) {
                // Already neutral and no transform attached.
                output.color.status = .neutral;
                output.color.key = target_key;
                return;
            }
            if (gamma_size < 2) {
                if (output.color.transform) |tr| {
                    Output.wlr_color_transform_unref(tr);
                    output.color.transform = null;
                }
                output.color.status = .neutral;
                output.color.pending = false;
                output.color.key = target_key;
                return;
            }
            // Transitioning to neutral with gamma_size >= 2! Commit NULL transform to restore default.
            if (output.color.transform) |tr| {
                Output.wlr_color_transform_unref(tr);
                output.color.transform = null;
            }
            output.color.key = target_key;
            output.color.pending = true;
            output.color.consecutive_failures = 0;
            output.wlr_output.scheduleFrame();
            return;
        }

        // Non-neutral target: check hardware gamma LUT support
        if (gamma_size < 2) {
            if (output.color.status != .unsupported) {
                output.color.status = .unsupported;
                if (!output.color.logged_unsupported) {
                    output.color.logged_unsupported = true;
                    log.warn("{s}: hardware gamma LUT unsupported (gamma size {})", .{ output.wlr_output.name, gamma_size });
                }
            }
            return;
        }

        // Non-neutral target:
        if (output.color.key) |k| {
            if (std.meta.eql(k, target_key) and output.color.status != .pending) {
                // Dedupe: target unchanged!
                return;
            }
        }

        // Build LUT:
        const gpa = @import("../main.zig").gpa;
        const r = gpa.alloc(u16, gamma_size) catch return;
        defer gpa.free(r);
        const g = gpa.alloc(u16, gamma_size) catch return;
        defer gpa.free(g);
        const b = gpa.alloc(u16, gamma_size) catch return;
        defer gpa.free(b);

        const wp = color.whitepoint(target_temp);
        color.fillLut(r, g, b, wp, gamma);

        const new_transform = Output.wlr_color_transform_init_lut_3x1d(gamma_size, r.ptr, g.ptr, b.ptr);
        if (new_transform == null) {
            log.err("failed to create color transform for output '{s}'", .{output.wlr_output.name});
            return;
        }

        if (output.color.transform) |old_tr| {
            Output.wlr_color_transform_unref(old_tr);
        }
        output.color.transform = new_transform;
        output.color.key = target_key;
        output.color.pending = true;
        output.color.status = .pending;
        output.color.consecutive_failures = 0;
        output.wlr_output.scheduleFrame();
    }
};

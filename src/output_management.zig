//! wlr-output-management-v1: wlr-randr, kanshi and nwg-displays. A client's
//! configuration becomes one `Output.applyAndPersist` patch per changed head,
//! the path Settings and IPC use, so it is validated and saved to the config
//! like any other display change. Heads a configuration leaves out keep
//! their state.
//!
//! Heads are applied one at a time: enables first, then changes, then
//! disables (so a swap never passes through "no outputs"). Every head is
//! validated and backend-tested before the first one is touched, but a
//! failure midway leaves the earlier heads applied; the client sees `failed`
//! and a fresh `done` with the resulting state.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Output = @import("Output.zig");
const Patch = @import("config").output_config.Patch;
const output_transform = @import("config").output_transform;
const gpa = @import("main.zig").gpa;

const log = std.log.scoped(.output_management);

pub const Manager = struct {
    server: *Server,
    manager: *wlr.OutputManagerV1,
    apply: wl.Listener(*wlr.OutputConfigurationV1) = .init(handleApply),
    @"test": wl.Listener(*wlr.OutputConfigurationV1) = .init(handleTest),

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .manager = try wlr.OutputManagerV1.create(server.wl_server) };
        self.manager.events.apply.add(&self.apply);
        self.manager.events.@"test".add(&self.@"test");
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.apply.link.remove();
        self.@"test".link.remove();
        gpa.destroy(self);
    }

    /// Publishes the current heads. wlroots sends `done` only when something
    /// differs, so calling this after every layout sync is cheap.
    pub fn publish(self: *Manager) void {
        const config = wlr.OutputConfigurationV1.create() catch return;
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |output| {
            const head = wlr.OutputConfigurationV1.Head.create(config, output.wlr_output) catch {
                config.destroy();
                return;
            };
            // Idle blanking disables the wlr_output; to clients it stays on.
            head.state.enabled = output.isLogicallyEnabled();
            var box: wlr.Box = undefined;
            self.server.output_layout.getBox(output.wlr_output, &box);
            head.state.x = box.x;
            head.state.y = box.y;
        }
        self.manager.setConfiguration(config);
    }

    fn handleApply(listener: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
        const self: *Manager = @fieldParentPtr("apply", listener);
        defer config.destroy();
        if (self.run(config, true)) config.sendSucceeded() else config.sendFailed();
        self.publish();
    }

    fn handleTest(listener: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
        const self: *Manager = @fieldParentPtr("test", listener);
        defer config.destroy();
        if (self.run(config, false)) config.sendSucceeded() else config.sendFailed();
    }

    fn run(self: *Manager, config: *wlr.OutputConfigurationV1, commit: bool) bool {
        var enabled_after: usize = 0;
        var outputs = self.server.outputs.iterator(.forward);
        while (outputs.next()) |output| {
            const head = findHead(config, output.wlr_output) orelse {
                if (output.isLogicallyEnabled()) enabled_after += 1;
                continue;
            };
            if (head.state.enabled) enabled_after += 1;
        }
        if (enabled_after == 0) {
            log.info("refusing client configuration: no output would stay enabled", .{});
            return false;
        }

        // Validate and backend-test everything before changing anything.
        var heads = config.heads.iterator(.forward);
        while (heads.next()) |head| {
            const output = Output.fromWlr(head.state.output) orelse return false;
            const p = diff(self.server, output, &head.state);
            if (isEmpty(p)) continue;
            p.validate() catch return refuse(output, "invalid settings");
            if (p.scale != null and self.server.scale_override != null) return refuse(output, "REDIWM_SCALE overrides scale");
            if (!head.state.enabled or !output.wlr_output.enabled) continue;
            var state = wlr.Output.State.init();
            defer state.finish();
            head.state.apply(&state);
            if (!output.wlr_output.testState(&state)) return refuse(output, "rejected by the backend");
        }
        if (!commit) return true;

        for ([_]Phase{ .enable, .change, .disable }) |phase| {
            heads = config.heads.iterator(.forward);
            while (heads.next()) |head| {
                const output = Output.fromWlr(head.state.output) orelse return false;
                const p = phase.select(diff(self.server, output, &head.state));
                if (isEmpty(p)) continue;
                output.applyAndPersist(p) catch |err| {
                    log.warn("{s}: could not apply client configuration: {}", .{ output.wlr_output.name, err });
                    return false;
                };
            }
        }
        return true;
    }
};

fn refuse(output: *Output, reason: []const u8) bool {
    log.info("{s}: refusing client configuration: {s}", .{ output.wlr_output.name, reason });
    return false;
}

const Phase = enum {
    enable,
    change,
    disable,

    fn select(phase: Phase, p: Patch) Patch {
        return switch (phase) {
            .enable => if (p.enabled == true) .{ .output = p.output, .enabled = true } else .{},
            .change => blk: {
                var changed = p;
                changed.enabled = null;
                break :blk changed;
            },
            .disable => if (p.enabled == false) .{ .output = p.output, .enabled = false } else .{},
        };
    }
};

fn isEmpty(p: Patch) bool {
    return p.enabled == null and p.width == null and p.height == null and p.refresh_mhz == null and
        p.x == null and p.y == null and p.scale == null and p.transform == null;
}

fn findHead(config: *wlr.OutputConfigurationV1, output: *wlr.Output) ?*wlr.OutputConfigurationV1.Head {
    var it = config.heads.iterator(.forward);
    while (it.next()) |head| {
        if (head.state.output == output) return head;
    }
    return null;
}

/// The fields of `state` that differ from `output` now. A disabled head only
/// reports the disable; a head being enabled also carries its other settings.
fn diff(server: *Server, output: *Output, state: *const wlr.OutputHeadV1.State) Patch {
    const out = output.wlr_output;
    var p: Patch = .{ .output = std.mem.span(out.name) };
    if (state.enabled != output.isLogicallyEnabled()) p.enabled = state.enabled;
    if (!state.enabled) return p;

    const width, const height, const refresh = if (state.mode) |mode|
        .{ mode.width, mode.height, mode.refresh }
    else
        .{ state.custom_mode.width, state.custom_mode.height, state.custom_mode.refresh };
    if (width != out.width or height != out.height or (refresh != 0 and refresh != out.refresh)) {
        p.width = width;
        p.height = height;
        if (refresh != 0) p.refresh_mhz = refresh;
    }
    var box: wlr.Box = undefined;
    server.output_layout.getBox(out, &box);
    if (state.x != box.x or state.y != box.y) {
        p.x = state.x;
        p.y = state.y;
    }
    if (@abs(state.scale - out.scale) > 0.001) p.scale = state.scale;
    if (state.transform != out.transform) {
        p.transform = @enumFromInt(@intFromEnum(state.transform));
    }
    return p;
}

comptime {
    // `diff` converts transforms by value.
    for (@typeInfo(output_transform.Transform).@"enum".fields) |field| {
        const wl_value = @intFromEnum(@field(wl.Output.Transform, field.name));
        if (wl_value != field.value) @compileError("output_transform.Transform must match wl_output.transform");
    }
}

//! The outputs a window can be on and the scale it should draw at: the
//! largest among the outputs its surface has entered, 1 before the first
//! wl_surface.enter.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zxdg = @import("wayland").client.zxdg;
const a = std.heap.c_allocator;

pub const Output = struct {
    outputs: *Outputs,
    proxy: *wl.Output,
    name: u32,
    scale: i32 = 1,
    logical: ?*zxdg.OutputV1 = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    mode_width: i32 = 0,
    mode_height: i32 = 0,

    /// Physical pixels per logical pixel. `wl_output.scale` is the integer
    /// ceiling, so a 1.5 output reads as 2; the mode and the logical size
    /// give the real factor. Anything outside (scale - 1, scale] (a rotated
    /// or nested output) falls back to the integer.
    fn density(self: Output) f64 {
        const whole: f64 = @floatFromInt(self.scale);
        const logical = @max(self.logical_width, self.logical_height);
        const mode = @max(self.mode_width, self.mode_height);
        if (logical <= 0 or mode <= 0) return whole;
        const real = @as(f64, @floatFromInt(mode)) / @as(f64, @floatFromInt(logical));
        return if (real > whole - 1 and real <= whole + 0.01) real else whole;
    }

    fn bindLogical(self: *Output, manager: *zxdg.OutputManagerV1) void {
        if (self.logical != null) return;
        self.logical = manager.getXdgOutput(self.proxy) catch return;
        self.logical.?.setListener(*Output, logicalEvent, self);
    }

    fn logicalEvent(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, self: *Output) void {
        if (event == .logical_size) {
            self.logical_width = event.logical_size.width;
            self.logical_height = event.logical_size.height;
            self.outputs.changed();
        }
    }

    fn outputEvent(_: *wl.Output, event: wl.Output.Event, self: *Output) void {
        switch (event) {
            .scale => |ev| {
                self.scale = std.math.clamp(ev.factor, 1, 4);
                self.outputs.changed();
            },
            .mode => |ev| if (ev.flags.current) {
                self.mode_width = ev.width;
                self.mode_height = ev.height;
                self.outputs.changed();
            },
            else => {},
        }
    }

    fn destroy(self: *Output) void {
        if (self.logical) |logical| logical.destroy();
        self.proxy.destroy();
        a.destroy(self);
    }
};

pub const Outputs = struct {
    all: std.ArrayList(*Output) = .empty,
    entered: std.ArrayList(*Output) = .empty,
    manager: ?*zxdg.OutputManagerV1 = null,
    /// Told whenever the scale inputs may have changed.
    owner: *anyopaque = undefined,
    on_change: *const fn (*anyopaque) void = undefined,

    fn changed(self: *Outputs) void {
        self.on_change(self.owner);
    }

    /// Binds a `wl_output` global.
    pub fn add(self: *Outputs, registry: *wl.Registry, name: u32, version: u32) void {
        const proxy = registry.bind(name, wl.Output, @min(version, 4)) catch return;
        const info = a.create(Output) catch {
            proxy.destroy();
            return;
        };
        info.* = .{ .outputs = self, .proxy = proxy, .name = name };
        self.all.append(a, info) catch {
            proxy.destroy();
            a.destroy(info);
            return;
        };
        proxy.setListener(*Output, Output.outputEvent, info);
        if (self.manager) |manager| info.bindLogical(manager);
    }

    /// Binds `zxdg_output_manager_v1` and asks it for every known output.
    pub fn setManager(self: *Outputs, registry: *wl.Registry, name: u32, version: u32) void {
        self.manager = registry.bind(name, zxdg.OutputManagerV1, @min(version, 3)) catch null;
        if (self.manager) |manager| for (self.all.items) |info| info.bindLogical(manager);
    }

    /// Drops the output of a removed global, if it is one.
    pub fn remove(self: *Outputs, name: u32) void {
        for (self.all.items, 0..) |info, i| {
            if (info.name == name) {
                _ = self.all.swapRemove(i);
                self.leaveInfo(info);
                info.destroy();
                self.changed();
                return;
            }
        }
    }

    pub fn enter(self: *Outputs, proxy: *wl.Output) void {
        for (self.all.items) |info| {
            if (info.proxy == proxy) {
                self.entered.append(a, info) catch {};
                self.changed();
                return;
            }
        }
    }

    pub fn leave(self: *Outputs, proxy: *wl.Output) void {
        for (self.all.items) |info| {
            if (info.proxy == proxy) {
                self.leaveInfo(info);
                self.changed();
                return;
            }
        }
    }

    fn leaveInfo(self: *Outputs, info: *Output) void {
        for (self.entered.items, 0..) |o, i| {
            if (o == info) {
                _ = self.entered.swapRemove(i);
                return;
            }
        }
    }

    pub const Scale = struct { scale: i32, density: f64 };

    /// The integer buffer scale and real density of the entered outputs.
    pub fn current(self: *const Outputs) Scale {
        var result: Scale = .{ .scale = 1, .density = 1 };
        for (self.entered.items) |info| {
            result.scale = @max(result.scale, info.scale);
            result.density = @max(result.density, info.density());
        }
        return result;
    }

    /// Logical size of the first output, zero when unknown.
    pub fn firstLogicalSize(self: *const Outputs) struct { w: i32, h: i32 } {
        if (self.all.items.len == 0) return .{ .w = 0, .h = 0 };
        const output = self.all.items[0];
        return .{ .w = output.logical_width, .h = output.logical_height };
    }

    pub fn deinit(self: *Outputs) void {
        for (self.all.items) |info| info.destroy();
        self.all.deinit(a);
        self.entered.deinit(a);
        if (self.manager) |manager| manager.destroy();
    }
};

// Specialized zxdg_output_manager_v1 global visible only to the Xwayland client.
// Tells Xwayland the screen is N times larger than its logical geometry, so X11
// apps render at panel resolution instead of 1x.
const std = @import("std");
const xscale = @import("xwayland_scale.zig");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zxdg = wayland.server.zxdg;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const gpa = @import("main.zig").gpa;

const log = std.log.scoped(.xwayland_output);

pub const XwaylandOutputManager = struct {
    server: *Server,
    global: *wl.Global,
    outputs: wl.list.Head(XwaylandOutput, .link) = undefined,
    on_layout_change: wl.Listener(*wlr.OutputLayout) = .init(handleLayoutChange),

    pub fn create(server: *Server) !*XwaylandOutputManager {
        const self = try gpa.create(XwaylandOutputManager);
        errdefer gpa.destroy(self);

        self.* = .{
            .server = server,
            .global = undefined,
            .outputs = undefined,
            .on_layout_change = .init(handleLayoutChange),
        };
        self.outputs.init();

        const global = try wl.Global.create(
            server.wl_server,
            zxdg.OutputManagerV1,
            3,
            *XwaylandOutputManager,
            self,
            bindManager,
        );
        self.global = global;
        server.output_layout.events.change.add(&self.on_layout_change);

        return self;
    }

    pub fn destroy(self: *XwaylandOutputManager) void {
        self.on_layout_change.link.remove();
        self.global.destroy();
        while (self.outputs.first()) |out| {
            out.destroy();
        }
        gpa.destroy(self);
    }

    fn bindManager(client: *wl.Client, self: *XwaylandOutputManager, version: u32, id: u32) void {
        const resource = zxdg.OutputManagerV1.create(client, version, id) catch |err| {
            log.err("failed to create xdg_output_manager resource: {}", .{err});
            client.postNoMemory();
            return;
        };
        resource.setHandler(*XwaylandOutputManager, handleManagerRequest, null, self);
    }

    fn handleManagerRequest(manager_res: *zxdg.OutputManagerV1, request: zxdg.OutputManagerV1.Request, self: *XwaylandOutputManager) void {
        switch (request) {
            .destroy => manager_res.destroy(),
            .get_xdg_output => |args| {
                self.createOutputResource(manager_res.getClient(), manager_res.getVersion(), args.id, args.output);
            },
        }
    }

    fn createOutputResource(self: *XwaylandOutputManager, client: *wl.Client, version: u32, id: u32, wl_output_res: *wl.Output) void {
        const wlr_out = wlr.Output.fromWlOutput(wl_output_res) orelse return;
        const xdg_output = zxdg.OutputV1.create(client, version, id) catch |err| {
            log.err("failed to create xdg_output resource: {}", .{err});
            client.postNoMemory();
            return;
        };

        const out = self.findOrCreateOutput(wlr_out) catch |err| {
            log.err("failed to track Xwayland output: {}", .{err});
            xdg_output.postNoMemory();
            return;
        };

        const r = gpa.create(OutputResource) catch {
            xdg_output.postNoMemory();
            return;
        };
        r.* = .{
            .output = out,
            .resource = xdg_output,
        };
        out.resources.append(r);
        xdg_output.setHandler(*OutputResource, handleOutputRequest, handleOutputResourceDestroy, r);

        out.sendState(r);
    }

    fn findOrCreateOutput(self: *XwaylandOutputManager, wlr_out: *wlr.Output) !*XwaylandOutput {
        var it = self.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.wlr_output == wlr_out) return out;
        }

        const out = try gpa.create(XwaylandOutput);
        errdefer gpa.destroy(out);
        out.* = .{
            .manager = self,
            .wlr_output = wlr_out,
        };
        out.resources.init();
        wlr_out.events.destroy.add(&out.on_output_destroy);
        wlr_out.events.description.add(&out.on_output_description);
        self.outputs.append(out);
        return out;
    }

    fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
        const self: *XwaylandOutputManager = @fieldParentPtr("on_layout_change", listener);
        self.refreshAll();
    }

    /// Re-sends logical geometry for every output Xwayland has already bound,
    /// using whatever `server.xwaylandScale()` returns right now. Used both
    /// for ordinary layout changes and when `Xwayland.refreshScale` corrects
    /// the scale factor itself after real hardware settles.
    pub fn refreshAll(self: *XwaylandOutputManager) void {
        var it = self.outputs.iterator(.forward);
        while (it.next()) |out| {
            out.syncGeometry();
        }
    }
};

const OutputResource = struct {
    /// Null once the output is gone and the resource is inert.
    output: ?*XwaylandOutput,
    resource: *zxdg.OutputV1,
    link: wl.list.Link = undefined,
};

const XwaylandOutput = struct {
    manager: *XwaylandOutputManager,
    wlr_output: *wlr.Output,
    link: wl.list.Link = undefined,
    resources: wl.list.Head(OutputResource, .link) = undefined,
    on_output_destroy: wl.Listener(*wlr.Output) = .init(handleOutputDestroy),
    on_output_description: wl.Listener(*wlr.Output) = .init(handleOutputDescription),
    last_x: i32 = std.math.minInt(i32),
    last_y: i32 = std.math.minInt(i32),
    last_width: i32 = 0,
    last_height: i32 = 0,

    fn destroy(self: *XwaylandOutput) void {
        self.on_output_destroy.link.remove();
        self.on_output_description.link.remove();
        self.link.remove();
        // Leave client-owned resources inert, as wlroots' xdg-output does:
        // destroying them here would free `r` via handleOutputResourceDestroy
        // (then again below), and Xwayland may still send `destroy` for them.
        // A self-linked node keeps that handler's later remove() valid.
        while (self.resources.first()) |r| {
            r.link.remove();
            r.link.init();
            r.output = null;
        }
        gpa.destroy(self);
    }

    fn handleOutputDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const out: *XwaylandOutput = @fieldParentPtr("on_output_destroy", listener);
        out.destroy();
    }

    fn handleOutputDescription(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const out: *XwaylandOutput = @fieldParentPtr("on_output_description", listener);
        if (out.wlr_output.description) |desc| {
            var it = out.resources.iterator(.forward);
            while (it.next()) |r| {
                if (r.resource.getVersion() >= 2) {
                    r.resource.sendDescription(std.mem.span(desc));
                    if (r.resource.getVersion() < 3) {
                        r.resource.sendDone();
                    }
                }
            }
            out.wlr_output.scheduleDone();
        }
    }

    fn sendState(self: *XwaylandOutput, r: *OutputResource) void {
        var box: wlr.Box = undefined;
        self.manager.server.output_layout.getBox(self.wlr_output, &box);
        const n = self.manager.server.xwaylandScale();
        const lx = xscale.surfacePosition(box.x, n);
        const ly = xscale.surfacePosition(box.y, n);
        const lw = xscale.surfacePosition(box.x + box.width, n) - lx;
        const lh = xscale.surfacePosition(box.y + box.height, n) - ly;

        self.last_x = lx;
        self.last_y = ly;
        self.last_width = lw;
        self.last_height = lh;

        const ver = r.resource.getVersion();
        if (ver >= 2) {
            r.resource.sendName(std.mem.span(self.wlr_output.name));
            if (self.wlr_output.description) |desc| {
                r.resource.sendDescription(std.mem.span(desc));
            } else {
                r.resource.sendDescription("");
            }
        }
        r.resource.sendLogicalPosition(lx, ly);
        r.resource.sendLogicalSize(lw, lh);
        if (ver < 3) {
            r.resource.sendDone();
        }
        self.wlr_output.scheduleDone();
    }

    fn syncGeometry(self: *XwaylandOutput) void {
        var box: wlr.Box = undefined;
        self.manager.server.output_layout.getBox(self.wlr_output, &box);
        const n = self.manager.server.xwaylandScale();
        const lx = xscale.surfacePosition(box.x, n);
        const ly = xscale.surfacePosition(box.y, n);
        const lw = xscale.surfacePosition(box.x + box.width, n) - lx;
        const lh = xscale.surfacePosition(box.y + box.height, n) - ly;

        if (lx == self.last_x and ly == self.last_y and lw == self.last_width and lh == self.last_height) {
            return;
        }
        self.last_x = lx;
        self.last_y = ly;
        self.last_width = lw;
        self.last_height = lh;

        var it = self.resources.iterator(.forward);
        while (it.next()) |r| {
            r.resource.sendLogicalPosition(lx, ly);
            r.resource.sendLogicalSize(lw, lh);
            if (r.resource.getVersion() < 3) {
                r.resource.sendDone();
            }
        }
        self.wlr_output.scheduleDone();
    }
};

fn handleOutputRequest(output_res: *zxdg.OutputV1, request: zxdg.OutputV1.Request, r: *OutputResource) void {
    _ = r;
    switch (request) {
        .destroy => output_res.destroy(),
    }
}

fn handleOutputResourceDestroy(output_res: *zxdg.OutputV1, r: *OutputResource) void {
    _ = output_res;
    r.link.remove();
    gpa.destroy(r);
}

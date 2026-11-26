//! Server frame helpers: output state, frame done and render pass.

const std = @import("std");
const Server = @import("../Server.zig");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const scene_outputs_mod = @import("../scene_outputs.zig");

/// All output builds, including capture between frames, use the owned pass and
/// the same swapchain/damage history. Commits stay on Output.
pub fn buildOutputState(server: *Server, output: *scene_outputs_mod.SceneOutput, state: *wlr.Output.State) bool {
    @import("../output/hdr.zig").syncLinear(server, output);
    return server.output_renderer.buildState(server.world.projection, output, state);
}

/// Frame callbacks for the surfaces the output shows, from the graph.
pub fn sendFrameDone(server: *Server, output: *scene_outputs_mod.SceneOutput, now: *std.posix.timespec) void {
    server.world.projection.sendFrameDone(output, now);
}

pub fn beginRenderPass(server: *Server, buffer: *wlr.Buffer, options: ?*const wlr.Renderer.BufferPassOptions) !*wlr.RenderPass {
    return server.output_renderer.beginPass(buffer, options) orelse error.RenderPassFailed;
}

pub fn maxOutputScale(server: *Server) f32 {
    var scale: f32 = 1;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.isLogicallyEnabled()) scale = @max(scale, output.wlr_output.scale);
    }
    return scale;
}

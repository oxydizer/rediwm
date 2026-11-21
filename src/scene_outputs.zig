//! Per-output state besides the output itself (scene_outputs.h).
const wlr = @import("wlroots");

pub const SceneOutput = opaque {
    extern fn rediwm_scene_output_destroy(output: *SceneOutput) void;
    pub const destroy = rediwm_scene_output_destroy;
    extern fn rediwm_scene_output_needs_frame(output: *const SceneOutput) bool;
    /// Whether anything asks for a frame: the output itself, or damage not yet committed.
    pub const needsFrame = rediwm_scene_output_needs_frame;
    extern fn rediwm_scene_output_has_pending_damage(output: *const SceneOutput) bool;
    pub const hasPendingDamage = rediwm_scene_output_has_pending_damage;
    extern fn rediwm_scene_output_direct_scanout(output: *const SceneOutput) bool;
    /// Whether the last built frame scanned a client buffer out directly.
    pub const directScanout = rediwm_scene_output_direct_scanout;
    extern fn rediwm_scene_output_damage_whole(output: *SceneOutput) void;
    /// Repaints all of the output and asks for a frame.
    pub const damageWhole = rediwm_scene_output_damage_whole;
};

pub const SceneOutputs = opaque {
    extern fn rediwm_scene_outputs_create(layout: *wlr.OutputLayout) ?*SceneOutputs;
    /// Outputs follow `layout`: they take its positions as it changes.
    pub fn create(layout: *wlr.OutputLayout) !*SceneOutputs {
        return rediwm_scene_outputs_create(layout) orelse error.OutOfMemory;
    }
    extern fn rediwm_scene_outputs_destroy(outputs: ?*SceneOutputs) void;
    pub const destroy = rediwm_scene_outputs_destroy;
    extern fn rediwm_scene_output_create(outputs: *SceneOutputs, output: *wlr.Output, layout_output: ?*wlr.OutputLayout.Output) ?*SceneOutput;
    pub fn createOutput(outputs: *SceneOutputs, output: *wlr.Output, layout_output: ?*wlr.OutputLayout.Output) !*SceneOutput {
        return rediwm_scene_output_create(outputs, output, layout_output) orelse error.OutOfMemory;
    }
    extern fn rediwm_scene_outputs_get(outputs: *SceneOutputs, output: *wlr.Output) ?*SceneOutput;
    pub const get = rediwm_scene_outputs_get;
};

// Tracks a pointer input device for as long as it's plugged in, purely so
// the control center's Input section (src/control_center/sections/input.zig)
// has something to enumerate and hand to src/libinput.zig — cursor motion
// itself is handled by wlr.Cursor directly (see Input.zig's `newInput`),
// this struct adds no behavior of its own.
const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Input = @import("Input.zig");
const gpa = @import("main.zig").gpa;

const Pointer = @This();

input: *Input,
link: wl.list.Link = undefined,
device: *wlr.InputDevice,

destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

pub fn create(input: *Input, device: *wlr.InputDevice) !void {
    const pointer = try gpa.create(Pointer);
    errdefer gpa.destroy(pointer); // listener add below is infallible; this covers any later try
    pointer.* = .{ .input = input, .device = device };
    device.events.destroy.add(&pointer.destroy);
    input.pointers.append(pointer);
    @import("config_runtime/apply.zig").applyPointerDevice(device, input.server.config.input);
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const pointer: *Pointer = @fieldParentPtr("destroy", listener);
    if (pointer.input.zoom_device == pointer.device) {
        pointer.input.zoom_scroll.reset();
        pointer.input.zoom_device = null;
    }
    // Nested backends can destroy and recreate the pointer object mid-gesture
    // (e.g. when the cursor leaves and re-enters the host window), even while
    // a button is still physically held. Motion/release handling elsewhere
    // doesn't care which device delivers events, so as long as another
    // pointer remains to carry the gesture forward, just drop the stale
    // device identity instead of ending the gesture out from under the user
    // — killing it here silently converts an in-progress pan/resize to plain
    // passthrough with no way to resume short of releasing and reinitiating.
    // Only when this is the last pointer left (no device could ever deliver
    // a follow-up event again) do we tear the gesture down for real.
    const last_pointer = pointer.input.pointers.length() <= 1;
    if (pointer.input.resize_session) |*session| {
        if (session.initiating_device == pointer.device) {
            if (last_pointer) {
                pointer.input.cancelResize();
            } else {
                session.initiating_device = null;
            }
        }
    }
    if (pointer.input.pan_session) |*session| {
        if (session.initiating_device == pointer.device) {
            if (last_pointer) {
                pointer.input.endPan();
                pointer.input.pan_session = null;
            } else {
                session.initiating_device = null;
            }
        }
    }
    // Releases for this device will never arrive. Only force-clear button
    // state when no remaining device could ever deliver the matching
    // release — otherwise a still-held button is correctly left counted.
    if (last_pointer) {
        pointer.input.active_buttons = 0;
    }
    pointer.link.remove();
    pointer.destroy.link.remove();
    gpa.destroy(pointer);
}

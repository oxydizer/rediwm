//! Input drag and drop: start, icon, cancel and tiling grab end.

const std = @import("std");
const Input = @import("../Input.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

pub fn positionDragIcon(input: *Input) void {
    if (input.drag_icon_tree) |tree| {
        tree.node.setPosition(@intFromFloat(@floor(input.cursor.x)), @intFromFloat(@floor(input.cursor.y)));
    }
}

pub fn updateDragAction(seat: *wlr.Seat, ctrl: bool) void {
    const drag = seat.drag orelse return;
    const source = seat.drag_source orelse return;

    const Enum = wl.DataDeviceManager.DndAction.Enum;
    const copy_bit: u32 = @intFromEnum(Enum.copy);
    const move_bit: u32 = @intFromEnum(Enum.move);
    const both_bits = copy_bit | move_bit;

    // Only change the action for sources that explicitly support both.
    if (source.actions < 0) return;
    const source_actions: u32 = @bitCast(source.actions);
    if ((source_actions & both_bits) != both_bits) return;

    source.compositor_action = if (ctrl) copy_bit else move_bit;

    const focus_client = drag.focus_client orelse return;
    var offers = seat.drag_offers.iterator(.forward);
    while (offers.next()) |offer| {
        if (offer.type != .drag or offer.source != source) continue;
        if (offer.resource.getClient() != focus_client.client) continue;

        const version = offer.resource.getVersion();
        const offer_actions: u32 = if (version >= 3) offer.actions else copy_bit;
        const preferred_bits: u32 = if (version >= 3)
            @as(u32, @intCast(@intFromEnum(offer.preferred_action)))
        else
            0;
        const available = offer_actions & source_actions;

        const compositor_bits = source.compositor_action & available;
        const action_bits = if (compositor_bits != 0)
            compositor_bits
        else if ((preferred_bits & available) != 0)
            preferred_bits & available
        else
            available & (~available +% 1);

        const action: Enum = @enumFromInt(action_bits);

        // wlroots tracks one current action per source, shared by its offers.
        if (source.current_dnd_action == action) return;

        if (offer.in_ask) {
            source.current_dnd_action = action;
            return;
        }

        source.dndAction(action);
        if (version >= 3) {
            offer.resource.sendAction(@bitCast(action_bits));
        }
        return;
    }
}

pub fn startDrag(listener: *wl.Listener(*wlr.Drag), drag: *wlr.Drag) void {
    const input: *Input = @fieldParentPtr("start_drag", listener);
    // Ctrl may already be held before the grab starts, with no modifier
    // change during the drag. Set the preference before the first offer.
    const ctrl = if (input.seat.getKeyboard()) |keyboard| keyboard.getModifiers().ctrl else false;
    updateDragAction(input.seat, ctrl);
    input.drag_dodge.begin(drag);
    if (drag.grab_type != .keyboard_pointer) return;
    const icon = drag.icon orelse return;
    if (input.drag_icon_tree) |tree| tree.node.destroy();
    // wlroots gives drag icons an empty input region, so they cannot steal
    // the drop target. This tree stays in output coordinates, outside the camera.
    const tree = input.server.overlay_tree.createSceneDragIcon(icon) catch return;
    input.drag_icon_tree = tree;
    tree.node.events.destroy.add(&input.drag_icon_destroy);
    input.positionDragIcon();
}

/// Escape during a drag abandons it. Destroying the source tells its client the
/// drag was cancelled, and ending the grab then leaves the target, hides the
/// icon and forgets the drag. The button is still held; its release reaches
/// the client under the pointer like any other, so nothing is dropped.
pub fn finishTilingGrab(input: *Input, commit: bool) void {
    @import("../tiling_grab.zig").finish(input, commit);
}

pub fn cancelDrag(input: *Input) bool {
    if (input.dock_drag.active()) {
        input.dock_drag.cancel(input);
        return true;
    }
    if (input.tiling_grab != null) {
        input.finishTilingGrab(false);
        input.processCursorMotion(0);
        return true;
    }
    const drag = input.seat.drag orelse return false;
    if (drag.grab_type != .keyboard_pointer) return false;
    if (drag.source) |source| source.destroy();
    input.seat.pointerEndGrab();
    return true;
}

pub fn dragIconDestroyed(listener: *wl.Listener(void)) void {
    const input: *Input = @fieldParentPtr("drag_icon_destroy", listener);
    input.drag_icon_destroy.link.remove();
    input.drag_icon_tree = null;
}

pub fn requestStartDrag(listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag), event: *wlr.Seat.event.RequestStartDrag) void {
    const input: *Input = @fieldParentPtr("request_start_drag", listener);
    if (input.server.locker != null or input.server.polkit_dialog != null) {
        if (event.drag.source) |source| source.destroy();
        return;
    }
    if (input.seat.validatePointerGrabSerial(event.origin, event.serial)) {
        input.seat.startPointerDrag(event.drag, event.serial);
    } else if (event.drag.source) |source| source.destroy();
}

//! Switcher thumbnails: client-buffer synchronization and the stack of surfaces
//! one window is made of. Placement and frame callbacks stay with Switcher; a
//! binding never changes output/scale feedback.
const std = @import("std");
const sn = @import("../node.zig");
const wlr = @import("wlroots");
const gpa = @import("../main.zig").gpa;

extern fn rediwm_switcher_preview_set_surface(preview: *sn.Buffer, surface: ?*wlr.Surface) bool;

/// Bind once: the node then follows every commit of the surface by itself.
/// Null clears. The preview node owns the binding; its destruction or the
/// source's destruction detaches it safely.
pub const setSurface = rediwm_switcher_preview_set_surface;

extern fn rediwm_switcher_preview_get_surface(preview: *sn.Buffer) ?*wlr.Surface;

/// The surface the node follows; null once that surface is gone.
pub const getSurface = rediwm_switcher_preview_get_surface;

extern fn rediwm_switcher_preview_set_owned(preview: *sn.Buffer, source: *sn.Buffer) bool;

/// Mirror a compositor-owned buffer node (a `.shell` window's body). Call after
/// each present; false when the source has no buffer to share.
pub const setOwned = rediwm_switcher_preview_set_owned;

/// A client that nests deeper or stacks more than this shows its first layers.
const max_depth = 8;
const max_layers = 32;

/// One surface of a window, shown by its own node: the toplevel's surface or a
/// mapped subsurface. Browsers of the Firefox family, video players and GTK's
/// graphics offload draw their content into subsurfaces; the toplevel's own
/// buffer is then little more than a background.
pub const Layer = struct {
    node: *sn.Buffer,
    /// Where the surface sits in the toplevel surface's coordinates.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// The part of its buffer the surface shows.
    source: wlr.FBox = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

/// A window's layers, bottom to top. Nodes are made once, in stacking order,
/// and kept: when the client restacks, adds or removes subsurfaces the nodes
/// are bound again in order instead of being moved.
pub const Stack = struct {
    /// Every node made so far; the first `shown` hold the window's surfaces.
    layers: std.ArrayList(Layer) = .empty,
    shown: usize = 0,
    /// The toplevel surface's size, the space `Layer` positions are in.
    width: i32 = 0,
    height: i32 = 0,

    pub fn deinit(self: *Stack) void {
        self.layers.deinit(gpa);
    }

    pub fn active(self: *const Stack) []Layer {
        return self.layers.items[0..self.shown];
    }

    /// A node above the ones already made. `open` makes the first while it
    /// builds the card, so later ones can be stacked right above it.
    pub fn addNode(self: *Stack, parent: *sn.Tree, accepts_input: @FieldType(sn.Buffer, "point_accepts_input")) !*sn.Buffer {
        try self.layers.ensureUnusedCapacity(gpa, 1);
        const node = try parent.createSceneBuffer(null);
        node.setFilterMode(.bilinear);
        node.point_accepts_input = accepts_input;
        node.node.setEnabled(false);
        if (self.layers.items.len > 0) node.node.placeAbove(&self.layers.items[self.layers.items.len - 1].node.node);
        self.layers.appendAssumeCapacity(.{ .node = node });
        return node;
    }

    /// Show nothing: every node lets go of its surface.
    pub fn clear(self: *Stack) void {
        self.release(0);
        self.width = 0;
        self.height = 0;
    }

    /// Only the nodes in use: this runs every frame, and clearing an idle node
    /// again would report a change and keep a settled switcher drawing.
    fn release(self: *Stack, from: usize) void {
        if (from >= self.shown) return;
        for (self.layers.items[from..self.shown]) |layer| {
            _ = setSurface(layer.node, null);
            layer.node.node.setEnabled(false);
        }
        self.shown = from;
    }

    /// Follow `root` and its mapped subsurfaces. False (and nothing shown)
    /// when the toplevel surface itself cannot be shown.
    pub fn follow(self: *Stack, root: *wlr.Surface) bool {
        if (!showable(root) or self.layers.items.len == 0) {
            self.clear();
            return false;
        }
        var count: usize = 0;
        self.collect(root, 0, 0, 0, &count);
        self.release(count);
        self.shown = count;
        self.width = @max(1, root.current.width);
        self.height = @max(1, root.current.height);
        return true;
    }

    /// The compositor's stacking order: subsurfaces below their parent, the
    /// parent, the ones above, each with its own children around it.
    fn collect(self: *Stack, surface: *wlr.Surface, x: i32, y: i32, depth: usize, count: *usize) void {
        self.collectChildren(&surface.current.subsurfaces_below, x, y, depth, count);
        if (showable(surface) and count.* < max_layers) add: {
            if (count.* == self.layers.items.len) {
                const below = self.layers.items[count.* - 1].node;
                const parent = below.node.parent orelse break :add;
                _ = self.addNode(parent, below.point_accepts_input) catch break :add;
            }
            const layer = &self.layers.items[count.*];
            if (getSurface(layer.node) != surface and !setSurface(layer.node, surface)) break :add;
            layer.x = x;
            layer.y = y;
            layer.width = surface.current.width;
            layer.height = surface.current.height;
            surface.getBufferSourceBox(&layer.source);
            count.* += 1;
        }
        self.collectChildren(&surface.current.subsurfaces_above, x, y, depth, count);
    }

    fn collectChildren(self: *Stack, list: anytype, x: i32, y: i32, depth: usize, count: *usize) void {
        if (depth >= max_depth) return;
        var it = list.iterator(.forward);
        while (it.next()) |state| {
            const sub: *wlr.Subsurface = @fieldParentPtr("current", state);
            if (!sub.surface.mapped) continue;
            self.collect(sub.surface, x + state.x, y + state.y, depth + 1, count);
        }
    }
};

/// A rotated or flipped buffer is left out, as it always was for the toplevel.
fn showable(surface: *wlr.Surface) bool {
    return surface.buffer != null and surface.current.transform == .normal and
        surface.current.width > 0 and surface.current.height > 0;
}

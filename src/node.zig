//! The compositor's own scene nodes (node.h): what wlr.Scene* was as a data model.
//! Method names are wlr_scene's, so a call site changes its type and little else.
//!
//! A client's surfaces are own nodes too (node_surface.h): an xdg surface is a tree, a
//! surface an own buffer node that follows its wl_surface.
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const pixman = @import("pixman");
const wlr = @import("wlroots");

pub const Node = extern struct {
    pub const Type = enum(c_int) { tree, rect, buffer };

    type: Type,
    parent: ?*Tree,
    link: wl.list.Link,
    enabled: bool,
    x: c_int,
    y: c_int,
    data: ?*anyopaque,
    events: extern struct {
        destroy: wl.Signal(void),
    },
    addons: wlr.AddonSet,
    props: ?*anyopaque,
    group: ?*anyopaque,
    leaf: ?*anyopaque,
    scene: *Scene,

    extern fn rediwm_node_destroy(node: *Node) void;
    pub const destroy = rediwm_node_destroy;
    extern fn rediwm_node_touch(node: *Node) void;
    /// Reports a change the node's setters cannot see: asks for a frame and a fresh
    /// resolve.
    pub const touch = rediwm_node_touch;
    extern fn rediwm_node_set_enabled(node: *Node, enabled: bool) void;
    pub const setEnabled = rediwm_node_set_enabled;
    extern fn rediwm_node_set_position(node: *Node, x: c_int, y: c_int) void;
    pub const setPosition = rediwm_node_set_position;
    extern fn rediwm_node_raise_to_top(node: *Node) void;
    pub const raiseToTop = rediwm_node_raise_to_top;
    extern fn rediwm_node_lower_to_bottom(node: *Node) void;
    pub const lowerToBottom = rediwm_node_lower_to_bottom;
    extern fn rediwm_node_place_above(node: *Node, sibling: *Node) void;
    pub const placeAbove = rediwm_node_place_above;
    extern fn rediwm_node_place_below(node: *Node, sibling: *Node) void;
    pub const placeBelow = rediwm_node_place_below;
    extern fn rediwm_node_reparent(node: *Node, parent: *Tree) void;
    pub const reparent = rediwm_node_reparent;
    extern fn rediwm_node_coords(node: *Node, lx: *c_int, ly: *c_int) bool;
    pub const coords = rediwm_node_coords;
    extern fn rediwm_node_visible(node: *const Node) bool;
    /// Whether the node and every ancestor are enabled.
    pub const visible = rediwm_node_visible;

    extern fn rediwm_node_for_each_buffer(
        node: *Node,
        iterator: *const fn (buffer: *Buffer, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void,
        user_data: ?*anyopaque,
    ) void;
    /// The own buffers of the subtree, positions relative to this node.
    pub inline fn forEachBuffer(
        node: *Node,
        comptime T: type,
        comptime iterator: fn (buffer: *Buffer, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        rediwm_node_for_each_buffer(
            node,
            struct {
                fn wrapper(b: *Buffer, sx: c_int, sy: c_int, d: ?*anyopaque) callconv(.c) void {
                    iterator(b, sx, sy, @ptrCast(@alignCast(d)));
                }
            }.wrapper,
            data,
        );
    }

    /// The buffers of the clients' surfaces under this node, positions relative to it.
    pub inline fn forEachSurfaceBuffer(
        node: *Node,
        comptime T: type,
        comptime iterator: fn (buffer: *Buffer, sx: c_int, sy: c_int, data: T) void,
        data: T,
    ) void {
        const Filter = struct {
            fn visit(b: *Buffer, sx: c_int, sy: c_int, d: T) void {
                if (b.surface != null) iterator(b, sx, sy, d);
            }
        };
        node.forEachBuffer(T, Filter.visit, data);
    }

    extern fn rediwm_subsurface_tree_set_clip(node: *Node, clip: ?*const wlr.Box) bool;
    /// Clips every surface of the subsurface trees at or under this node to `clip`
    /// (in the tree's coordinates), or lifts the clip when null.
    pub fn subsurfaceTreeSetClip(node: *Node, clip: ?*const wlr.Box) void {
        _ = rediwm_subsurface_tree_set_clip(node, clip);
    }

    pub fn tree(node: *Node) ?*Tree {
        return if (node.type == .tree) @fieldParentPtr("node", node) else null;
    }
    pub fn buffer(node: *Node) ?*Buffer {
        return if (node.type == .buffer) @fieldParentPtr("node", node) else null;
    }
};

pub const Tree = extern struct {
    node: Node,
    children: wl.list.Head(Node, .link),

    extern fn rediwm_tree_create(parent: *Tree) ?*Tree;
    pub fn createSceneTree(parent: *Tree) !*Tree {
        return rediwm_tree_create(parent) orelse error.OutOfMemory;
    }

    extern fn rediwm_rect_create(parent: *Tree, width: c_int, height: c_int, color: *const [4]f32) ?*Rect;
    pub fn createSceneRect(parent: *Tree, width: c_int, height: c_int, color: *const [4]f32) !*Rect {
        return rediwm_rect_create(parent, width, height, color) orelse error.OutOfMemory;
    }

    extern fn rediwm_buffer_create(parent: *Tree, buffer: ?*wlr.Buffer) ?*Buffer;
    pub fn createSceneBuffer(parent: *Tree, buffer: ?*wlr.Buffer) !*Buffer {
        return rediwm_buffer_create(parent, buffer) orelse error.OutOfMemory;
    }

    extern fn rediwm_xdg_surface_create(parent: *Tree, xdg_surface: *wlr.XdgSurface) ?*Tree;
    pub fn createSceneXdgSurface(parent: *Tree, xdg_surface: *wlr.XdgSurface) !*Tree {
        return rediwm_xdg_surface_create(parent, xdg_surface) orelse error.OutOfMemory;
    }

    extern fn rediwm_subsurface_tree_create(parent: *Tree, surface: *wlr.Surface) ?*Tree;
    pub fn createSceneSubsurfaceTree(parent: *Tree, surface: *wlr.Surface) !*Tree {
        return rediwm_subsurface_tree_create(parent, surface) orelse error.OutOfMemory;
    }

    extern fn rediwm_drag_icon_create(parent: *Tree, drag_icon: *wlr.Drag.Icon) ?*Tree;
    pub fn createSceneDragIcon(parent: *Tree, drag_icon: *wlr.Drag.Icon) !*Tree {
        return rediwm_drag_icon_create(parent, drag_icon) orelse error.OutOfMemory;
    }

    pub fn fromNode(node: *Node) *Tree {
        return @fieldParentPtr("node", node);
    }
};

pub const Rect = extern struct {
    node: Node,
    width: c_int,
    height: c_int,
    color: [4]f32,

    extern fn rediwm_rect_set_color(rect: *Rect, color: *const [4]f32) void;
    pub const setColor = rediwm_rect_set_color;
    extern fn rediwm_rect_set_size(rect: *Rect, width: c_int, height: c_int) void;
    pub const setSize = rediwm_rect_set_size;

    pub fn fromNode(node: *Node) *Rect {
        return @fieldParentPtr("node", node);
    }
};

pub const Buffer = extern struct {
    node: Node,
    point_accepts_input: ?*const fn (buffer: *Buffer, sx: *f64, sy: *f64) callconv(.c) bool,
    opacity: f32,
    filter_mode: wlr.RenderPass.ScaleFilterMode,
    src_box: wlr.FBox,
    dst_width: c_int,
    dst_height: c_int,
    transform: wl.Output.Transform,
    sector_rect: [4]f32,
    opaque_region: pixman.Region32,
    buffer_width: c_int,
    buffer_height: c_int,
    /// The client surface this node shows, if it is one.
    surface: ?*Surface,
    /// The content (see node.h): null `buffer` once the renderer uploaded it and let it go.
    buffer: ?*wlr.Buffer,
    own_buffer: bool,
    buffer_release: wl.Listener(void),
    texture: ?*wlr.Texture,
    renderer_destroy: wl.Listener(void),
    wait_timeline: ?*wlr.DrmSyncobjTimeline,
    wait_point: u64,
    buffer_is_opaque: bool,
    is_single_pixel_buffer: bool,
    single_pixel_buffer_color: [4]u32,
    transfer_function: u32,
    primaries: u32,
    color_encoding: u32,
    color_range: u32,
    events: extern struct {
        outputs_update: wl.Signal(?*anyopaque),
        output_sample: wl.Signal(?*anyopaque),
        frame_done: wl.Signal(?*anyopaque),
    },

    extern fn rediwm_buffer_set_buffer(buffer: *Buffer, wlr_buffer: ?*wlr.Buffer) void;
    pub const setBuffer = rediwm_buffer_set_buffer;
    extern fn rediwm_buffer_get_buffer(buffer: *const Buffer) ?*wlr.Buffer;
    /// The buffer the node holds; null once the renderer released it after upload.
    pub const getBuffer = rediwm_buffer_get_buffer;
    extern fn rediwm_buffer_set_buffer_with_damage(buffer: *Buffer, wlr_buffer: ?*wlr.Buffer, damage: *const pixman.Region32) void;
    pub const setBufferWithDamage = rediwm_buffer_set_buffer_with_damage;
    extern fn rediwm_buffer_set_dest_size(buffer: *Buffer, width: c_int, height: c_int) void;
    pub const setDestSize = rediwm_buffer_set_dest_size;
    extern fn rediwm_buffer_set_source_box(buffer: *Buffer, box: ?*const wlr.FBox) void;
    pub const setSourceBox = rediwm_buffer_set_source_box;
    extern fn rediwm_buffer_set_opacity(buffer: *Buffer, opacity: f32) void;
    pub const setOpacity = rediwm_buffer_set_opacity;
    extern fn rediwm_buffer_set_filter_mode(buffer: *Buffer, mode: wlr.RenderPass.ScaleFilterMode) void;
    pub const setFilterMode = rediwm_buffer_set_filter_mode;
    extern fn rediwm_buffer_set_transform(buffer: *Buffer, transform: wl.Output.Transform) void;
    pub const setTransform = rediwm_buffer_set_transform;
    extern fn rediwm_buffer_set_sector_rect(buffer: *Buffer, rect: ?*const [4]f32) void;
    /// Under a radially mapped tree clip: the part of the mapped image this
    /// node fills (x, y, width, height as fractions); null is all of it.
    pub const setSectorRect = rediwm_buffer_set_sector_rect;
    extern fn rediwm_buffer_set_opaque_region(buffer: *Buffer, region: ?*const pixman.Region32) void;
    pub const setOpaqueRegion = rediwm_buffer_set_opaque_region;

    pub fn fromNode(node: *Node) *Buffer {
        return @fieldParentPtr("node", node);
    }
};

/// The surface an own buffer node follows (node_surface.h); the rest of the struct is
/// the binding's own.
pub const Surface = extern struct {
    buffer: *Buffer,
    surface: *wlr.Surface,
};

/// The own scene: its root tree's children are the layers, bottom to top.
pub const Scene = extern struct {
    tree: Tree,
    changed: ?*const fn (data: ?*anyopaque, node: ?*Node, structural: bool) callconv(.c) void,
    buffer_damaged: ?*const fn (data: ?*anyopaque, buffer: *Buffer, damage: ?*const pixman.Region32) callconv(.c) void,
    changed_data: ?*anyopaque,
    /// The outputs this scene is shown on (scene_outputs.h).
    outputs: ?*anyopaque,
    /// A client surface committed with frame callbacks waiting (node.h).
    frame_callbacks: ?*const fn (output: *wlr.Output) callconv(.c) void,

    extern fn rediwm_scene_create(changed: ?*const fn (?*anyopaque, ?*Node, bool) callconv(.c) void, data: ?*anyopaque) ?*Scene;
    pub fn create() !*Scene {
        return rediwm_scene_create(null, null) orelse error.OutOfMemory;
    }
    extern fn rediwm_scene_destroy(scene: ?*Scene) void;
    pub const destroy = rediwm_scene_destroy;
};

/// A scene for unit tests.
pub const TestScene = struct {
    nodes: *Scene,

    pub fn create() !TestScene {
        return .{ .nodes = try Scene.create() };
    }

    pub fn destroy(fixture: TestScene) void {
        fixture.nodes.destroy();
    }
};

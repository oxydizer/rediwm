//! Header-backed wlroots API for RediWM. See AGENTS.md in this directory.
const output_power = @import("output_power.zig").Types(Output);
pub const OutputPowerManagerV1 = output_power.OutputPowerManagerV1;
pub const OutputPowerV1 = output_power.OutputPowerV1;

const idle_notify = @import("idle_notify.zig").Types(Seat);
pub const IdleNotifierV1 = idle_notify.IdleNotifierV1;

const idle_inhibit = @import("idle_inhibit.zig").Types(Surface);
pub const IdleInhibitManagerV1 = idle_inhibit.IdleInhibitManagerV1;
pub const IdleInhibitorV1 = idle_inhibit.IdleInhibitorV1;

const kb_shortcuts_inhibit = @import("keyboard_shortcuts_inhibit.zig").Types(Surface, Seat);
pub const KeyboardShortcutsInhibitManagerV1 = kb_shortcuts_inhibit.KeyboardShortcutsInhibitManagerV1;
pub const KeyboardShortcutsInhibitorV1 = kb_shortcuts_inhibit.KeyboardShortcutsInhibitorV1;
pub const SecurityContextManagerV1 = @import("security_context.zig").SecurityContextManagerV1;
pub const SecurityContextV1State = @import("security_context.zig").SecurityContextV1State;

const fractional_scale = @import("fractional_scale.zig").Types(Surface);
pub const FractionalScaleManagerV1 = fractional_scale.FractionalScaleManagerV1;

const relative_pointer = @import("relative_pointer.zig").Types(Seat);
pub const RelativePointerManagerV1 = relative_pointer.RelativePointerManagerV1;
pub const RelativePointerV1 = relative_pointer.RelativePointerV1;

const pointer_constraints = @import("pointer_constraints.zig").Types(Surface, Seat);
pub const PointerConstraintsV1 = pointer_constraints.PointerConstraintsV1;
pub const PointerConstraintV1 = pointer_constraints.PointerConstraintV1;
pub const Backend = @import("backend.zig").Backend;
pub const Session = @import("session.zig").Session;
pub const Presentation = @import("presentation.zig").Presentation;
pub const Renderer = @import("renderer.zig").Renderer;
pub const Allocator = @import("allocator.zig").Allocator;
pub const RenderPass = @import("render_pass.zig").RenderPass;
pub const Texture = @import("texture.zig").Texture;

const output_mod = @import("output.zig").Types(Backend, Renderer, Allocator, Buffer, ColorTransform);
pub const Output = output_mod.Output;
pub const OutputCursor = output_mod.OutputCursor;

const output_layout_mod = @import("output_layout.zig").Types(Output);
pub const OutputLayout = output_layout_mod.OutputLayout;

const output_management = @import("output_management.zig").Types(Output);
pub const OutputManagerV1 = output_management.OutputManagerV1;
pub const OutputHeadV1 = output_management.OutputHeadV1;
pub const OutputConfigurationV1 = output_management.OutputConfigurationV1;
pub const XdgOutputManagerV1 = @import("xdg_output.zig").Types(OutputLayout).XdgOutputManagerV1;
pub const Box = @import("box.zig").Box;
pub const FBox = @import("box.zig").FBox;
pub const Edges = @import("edges.zig").Edges;

pub const AddonSet = @import("addon.zig").AddonSet;
pub const Buffer = @import("buffer.zig").Buffer;
pub const gamma_control = @import("gamma_control.zig");
pub const ColorTransform = @import("c.zig").c.wlr_color_transform;
pub const Compositor = @import("compositor.zig").Compositor;
pub const Cursor = @import("cursor.zig").Cursor;
pub const CursorShapeManagerV1 = @import("cursor_shape_v1.zig").CursorShapeManagerV1;
pub const DataControlManagerV1 = @import("data_control_v1.zig").DataControlManagerV1;
pub const DataDeviceManager = @import("data_device.zig").DataDeviceManager;
pub const DataSource = @import("data_device.zig").DataSource;
pub const Drag = @import("data_device.zig").Drag;
pub const DrmFormat = @import("drm_format_set.zig").DrmFormat;
pub const DrmSyncobjTimeline = @import("c.zig").c.wlr_drm_syncobj_timeline;
pub const ExtDataControlManagerV1 = @import("ext_data_control_v1.zig").ExtDataControlManagerV1;
pub const ExtForeignToplevelHandleV1 = @import("foreign_toplevel_list_v1.zig").ExtForeignToplevelHandleV1;
pub const ExtForeignToplevelImageCaptureSourceManagerV1 = @import("ext_image_capture_source_v1.zig").ExtForeignToplevelImageCaptureSourceManagerV1;
pub const ExtForeignToplevelListV1 = @import("foreign_toplevel_list_v1.zig").ExtForeignToplevelListV1;
pub const ExtImageCaptureSourceV1 = @import("ext_image_capture_source_v1.zig").ExtImageCaptureSourceV1;
pub const ExtImageCopyCaptureFrameV1 = @import("ext_image_copy_capture_v1.zig").ExtImageCopyCaptureFrameV1;
pub const ExtImageCopyCaptureManagerV1 = @import("ext_image_copy_capture_v1.zig").ExtImageCopyCaptureManagerV1;
pub const ExtImageCopyCaptureSessionV1 = @import("ext_image_copy_capture_v1.zig").ExtImageCopyCaptureSessionV1;
pub const ExtOutputImageCaptureSourceManagerV1 = @import("ext_image_capture_source_v1.zig").ExtOutputImageCaptureSourceManagerV1;
pub const ForeignToplevelHandleV1 = @import("foreign_toplevel_management_v1.zig").ForeignToplevelHandleV1;
pub const ForeignToplevelManagerV1 = @import("foreign_toplevel_management_v1.zig").ForeignToplevelManagerV1;
pub const InputDevice = @import("input_device.zig").InputDevice;
pub const InputMethodManagerV2 = @import("input_method_v2.zig").InputMethodManagerV2;
pub const InputMethodV2 = @import("input_method_v2.zig").InputMethodV2;
pub const InputPopupSurfaceV2 = @import("input_method_v2.zig").InputPopupSurfaceV2;
pub const Keyboard = @import("keyboard.zig").Keyboard;
pub const LayerShellV1 = @import("layer_shell.zig").LayerShellV1;
pub const LayerSurfaceV1 = @import("layer_shell.zig").LayerSurfaceV1;
pub const LinuxDmabufV1 = @import("linux_dmabuf_v1.zig").LinuxDmabufV1;
pub const LinuxDrmSyncobjManagerV1 = @import("linux_drm_syncobj_v1.zig").LinuxDrmSyncobjManagerV1;
pub const Pointer = @import("pointer.zig").Pointer;
pub const PointerGesturesV1 = @import("pointer_gestures_v1.zig").PointerGesturesV1;
pub const PrimarySelectionDeviceManagerV1 = @import("primary_selection_v1.zig").PrimarySelectionDeviceManagerV1;
pub const Scene = @import("scene.zig").Scene;
pub const ScreencopyFrameV1 = @import("screencopy_v1.zig").ScreencopyFrameV1;
pub const ScreencopyManagerV1 = @import("screencopy_v1.zig").ScreencopyManagerV1;
pub const Seat = @import("seat.zig").Seat;
pub const SessionLockManagerV1 = @import("session_lock_v1.zig").SessionLockManagerV1;
pub const SessionLockSurfaceV1 = @import("session_lock_v1.zig").SessionLockSurfaceV1;
pub const SessionLockV1 = @import("session_lock_v1.zig").SessionLockV1;
pub const SinglePixelBufferManagerV1 = @import("single_pixel_buffer_v1.zig").SinglePixelBufferManagerV1;
pub const Subcompositor = @import("subcompositor.zig").Subcompositor;
pub const Surface = @import("compositor.zig").Surface;
pub const Swapchain = @import("swapchain.zig").Swapchain;
pub const Switch = @import("switch.zig").Switch;
pub const Tablet = @import("tablet_tool.zig").Tablet;
pub const TabletManagerV2 = @import("tablet_v2.zig").TabletManagerV2;
pub const TabletPad = @import("tablet_pad.zig").TabletPad;
pub const TabletTool = @import("tablet_tool.zig").TabletTool;
pub const TabletV2Tablet = @import("tablet_v2.zig").TabletV2Tablet;
pub const TabletV2TabletPad = @import("tablet_v2.zig").TabletV2TabletPad;
pub const TabletV2TabletTool = @import("tablet_v2.zig").TabletV2TabletTool;
pub const TextInputManagerV3 = @import("text_input_v3.zig").TextInputManagerV3;
pub const TextInputV3 = @import("text_input_v3.zig").TextInputV3;
pub const Touch = @import("touch.zig").Touch;
pub const Viewporter = @import("viewporter.zig").Viewporter;
pub const VirtualKeyboardManagerV1 = @import("virtual_keyboard_v1.zig").VirtualKeyboardManagerV1;
pub const VirtualKeyboardV1 = @import("virtual_keyboard_v1.zig").VirtualKeyboardV1;
pub const VirtualPointerManagerV1 = @import("virtual_pointer_v1.zig").VirtualPointerManagerV1;
pub const XcursorManager = @import("xcursor_manager.zig").XcursorManager;
pub const XdgActivationTokenV1 = @import("xdg_activation.zig").XdgActivationTokenV1;
pub const XdgActivationV1 = @import("xdg_activation.zig").XdgActivationV1;
pub const XdgDecorationManagerV1 = @import("xdg_decoration.zig").XdgDecorationManagerV1;
pub const XdgPopup = @import("xdg_shell.zig").XdgPopup;
pub const XdgShell = @import("xdg_shell.zig").XdgShell;
pub const XdgSurface = @import("xdg_shell.zig").XdgSurface;
pub const XdgToplevel = @import("xdg_shell.zig").XdgToplevel;
pub const XdgToplevelDecorationV1 = @import("xdg_decoration.zig").XdgToplevelDecorationV1;
pub const Xwayland = @import("xwayland.zig").Xwayland;
pub const XwaylandSurface = @import("xwayland.zig").XwaylandSurface;
pub const color = @import("color.zig");
pub const config = @import("config.zig");
pub const log = @import("log.zig");
pub const region = @import("region.zig");
pub const Addon = @import("addon.zig").Addon;
pub const ShmAttributes = @import("buffer.zig").ShmAttributes;
pub const BufferCap = @import("buffer.zig").BufferCap;
pub const ClientBuffer = @import("buffer.zig").ClientBuffer;
pub const DataControlDeviceV1 = @import("data_control_v1.zig").DataControlDeviceV1;
pub const DataOffer = @import("data_device.zig").DataOffer;
pub const DmabufAttributes = @import("dmabuf.zig").DmabufAttributes;
pub const DrmFormatSet = @import("drm_format_set.zig").DrmFormatSet;
pub const ExtDataControlDeviceV1 = @import("ext_data_control_v1.zig").ExtDataControlDeviceV1;
pub const DmabufBufferV1 = @import("linux_dmabuf_v1.zig").DmabufBufferV1;
pub const LinuxDmabufFeedbackV1 = @import("linux_dmabuf_v1.zig").LinuxDmabufFeedbackV1;
pub const LinuxDmabufFeedbackV1Compiled = @import("linux_dmabuf_v1.zig").LinuxDmabufFeedbackV1Compiled;
pub const PrimarySelectionDeviceV1 = @import("primary_selection_v1.zig").PrimarySelectionDeviceV1;
pub const SceneNode = @import("scene.zig").SceneNode;
pub const ScreencopyClientV1 = @import("screencopy_v1.zig").ScreencopyClientV1;
pub const Subsurface = @import("subcompositor.zig").Subsurface;
pub const XdgClient = @import("xdg_shell.zig").XdgClient;
pub const XdgPositioner = @import("xdg_shell.zig").XdgPositioner;
pub const XdgPopupGrab = @import("xdg_shell.zig").XdgPopupGrab;
pub const Xwm = @import("xwayland.zig").Xwm;
pub const KeyboardGroup = @import("keyboard_group.zig").KeyboardGroup;
pub const PrimarySelectionSource = @import("primary_selection.zig").PrimarySelectionSource;
pub const SerialRange = @import("seat.zig").SerialRange;
pub const SerialRingset = @import("seat.zig").SerialRingset;
pub const TouchPoint = @import("seat.zig").TouchPoint;
pub const SwitchType = @import("switch.zig").SwitchType;
pub const SwitchState = @import("switch.zig").SwitchState;
pub const VirtualPointerV1 = @import("virtual_pointer_v1.zig").VirtualPointerV1;
pub const XcursorImage = @import("xcursor.zig").XcursorImage;
pub const Xcursor = @import("xcursor.zig").Xcursor;
pub const XcursorTheme = @import("xcursor.zig").XcursorTheme;
pub const XcursorManagerTheme = @import("xcursor_manager.zig").XcursorManagerTheme;

comptime {
    const c = @import("c.zig").c;
    if (c.WLR_VERSION_MAJOR != 0 or c.WLR_VERSION_MINOR != 20)
        @compileError("RediWM requires wlroots 0.20 headers");
}

test {
    _ = @import("bindings_tests.zig");
    _ = @import("input_tests.zig");
}

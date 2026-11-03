//! wlr.Output / wlr.OutputCursor, backed by translate-c against
//! wlr/types/wlr_output.h. The single biggest type in the facade so far:
//! see src/wlr/AGENTS.md for the general pattern and the top-level
//! AGENTS.md's rendering/damage notes before changing anything here.
//!
//! Scoped to what RediWM actually reads, per the usage audit done before
//! writing this file, not the full wlroots API:
//!
//! - `Output` is declared field-for-field up through `data` (its last
//!   field RediWM touches, via the `output.wlr_output.data` pattern for
//!   stashing a back-pointer) and then truncated -- the trailing
//!   WLR_PRIVATE block is never declared, same as every other migrated
//!   type. `allocator`/`renderer`/`swapchain`/`addons`/`layers` sit in
//!   that range but are never read as *fields* (only ever passed as
//!   *parameters*, e.g. to `initRender`), so they're typed as opaque
//!   placeholders purely to hold their byte offset -- correctness there
//!   is about size, not type.
//! - `OutputCursor` is truncated after `hotspot_y`: nothing past it
//!   (texture, wait_timeline, link, ...) is read.
//! - Of the ten `events.*` signals, only `frame`, `commit`, `present`,
//!   `description`, `request_state` and `destroy` are ever connected to
//!   in RediWM. `frame`/`description`/`destroy` carry the output itself
//!   as payload, by wlroots convention, matching the existing listener
//!   types in Output.zig/xwayland_output.zig. `damage`/`needs_frame`/
//!   `precommit`/`bind` are typed `wl.Signal(void)` as a placeholder:
//!   still correctly *sized* (every wl.Signal(T) is one wl_list
//!   regardless of T, see signal.zig), but not a real payload type.
//!   Connecting one of those later needs its real event struct filled
//!   in first -- that's a compile error pointing here, not a silent bug.
//! - `Damage`/`Precommit`/`Bind` aren't defined at all since nothing
//!   connects those signals.
//!
//! Dependencies are supplied by wlr.zig from the same header-backed module.
const std = @import("std");
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;
const box = @import("box.zig");

pub fn Types(
    comptime Backend: type,
    comptime Renderer: type,
    comptime Allocator: type,
    comptime Buffer: type,
    comptime ColorTransform: type,
) type {
    return struct {
        pub const OutputCursor = extern struct {
            output: *Output,
            x: f64,
            y: f64,
            enabled: bool,
            visible: bool,
            width: u32,
            height: u32,
            src_box: box.FBox,
            transform: wl.Output.Transform,
            hotspot_x: i32,
            hotspot_y: i32,

            comptime {
                const Real = c.wlr_output_cursor;
                assertFieldOffset(OutputCursor, Real, "output");
                assertFieldOffset(OutputCursor, Real, "x");
                assertFieldOffset(OutputCursor, Real, "y");
                assertFieldOffset(OutputCursor, Real, "enabled");
                assertFieldOffset(OutputCursor, Real, "visible");
                assertFieldOffset(OutputCursor, Real, "width");
                assertFieldOffset(OutputCursor, Real, "height");
                assertFieldOffset(OutputCursor, Real, "src_box");
                assertFieldOffset(OutputCursor, Real, "transform");
                assertFieldOffset(OutputCursor, Real, "hotspot_x");
                assertFieldOffset(OutputCursor, Real, "hotspot_y");
            }
        };

        pub const Output = extern struct {
            pub const Mode = extern struct {
                pub const AspectRatio = enum(c_int) {
                    none,
                    @"4_3",
                    @"16_9",
                    @"64_27",
                    @"256_135",
                };

                width: i32,
                height: i32,
                refresh: i32,
                preferred: bool,
                picture_aspect_ratio: AspectRatio,
                /// Output.modes
                link: wl.list.Link,

                comptime {
                    const Real = c.wlr_output_mode;
                    assertFieldOffset(Mode, Real, "width");
                    assertFieldOffset(Mode, Real, "height");
                    assertFieldOffset(Mode, Real, "refresh");
                    assertFieldOffset(Mode, Real, "preferred");
                    assertFieldOffset(Mode, Real, "picture_aspect_ratio");
                    assertFieldOffset(Mode, Real, "link");
                    assertSameLayout(Mode, Real);
                    assertSameLayout(AspectRatio, c.wlr_output_mode_aspect_ratio);
                }
            };

            pub const AdaptiveSyncStatus = enum(c_int) {
                disabled,
                enabled,
            };

            pub const State = extern struct {
                pub const Fields = packed struct(u32) {
                    buffer: bool = false,
                    damage: bool = false,
                    mode: bool = false,
                    enabled: bool = false,
                    scale: bool = false,
                    transform: bool = false,
                    adaptive_sync_enabled: bool = false,
                    render_format: bool = false,
                    subpixel: bool = false,
                    layers: bool = false,
                    wait_timeline: bool = false,
                    signal_timeline: bool = false,
                    color_transform: bool = false,
                    image_description: bool = false,
                    _: u18 = 0,
                };

                pub const ModeType = enum(c_int) {
                    fixed,
                    custom,
                };

                committed: Fields,
                allow_reconfiguration: bool,
                damage: pixman.Region32,
                enabled: bool,
                scale: f32,
                transform: wl.Output.Transform,
                adaptive_sync_enabled: bool,
                render_format: u32,
                subpixel: wl.Output.Subpixel,

                buffer: ?*Buffer,
                buffer_src_box: box.FBox,
                buffer_dst_box: box.Box,

                tearing_page_flip: bool,

                mode_type: ModeType,
                mode: ?*Mode,
                custom_mode: extern struct {
                    width: i32,
                    height: i32,
                    refresh: i32,
                },

                layers: ?*anyopaque,
                layers_len: usize,

                wait_timeline: ?*anyopaque,
                wait_point: u64,
                signal_timeline: ?*anyopaque,
                signal_point: u64,

                color_transform: ?*ColorTransform,
                image_description: ?*anyopaque,

                pub fn init() State {
                    var state: State = undefined;
                    c.wlr_output_state_init(@ptrCast(&state));
                    return state;
                }

                pub fn finish(state: *State) void {
                    c.wlr_output_state_finish(@ptrCast(state));
                }

                pub fn setEnabled(state: *State, enabled: bool) void {
                    c.wlr_output_state_set_enabled(@ptrCast(state), enabled);
                }

                pub fn setMode(state: *State, mode: *Mode) void {
                    c.wlr_output_state_set_mode(@ptrCast(state), @ptrCast(mode));
                }

                pub fn setCustomMode(state: *State, width: i32, height: i32, refresh: i32) void {
                    c.wlr_output_state_set_custom_mode(@ptrCast(state), width, height, refresh);
                }

                pub fn setScale(state: *State, scale: f32) void {
                    c.wlr_output_state_set_scale(@ptrCast(state), scale);
                }

                pub fn setTransform(state: *State, transform: wl.Output.Transform) void {
                    c.wlr_output_state_set_transform(@ptrCast(state), @intCast(@intFromEnum(transform)));
                }

                pub fn setAdaptiveSyncEnabled(state: *State, enabled: bool) void {
                    c.wlr_output_state_set_adaptive_sync_enabled(@ptrCast(state), enabled);
                }

                pub fn setRenderFormat(state: *State, format: u32) void {
                    c.wlr_output_state_set_render_format(@ptrCast(state), format);
                }

                pub fn setSubpixel(state: *State, subpixel: wl.Output.Subpixel) void {
                    c.wlr_output_state_set_subpixel(@ptrCast(state), @intCast(@intFromEnum(subpixel)));
                }

                pub fn setBuffer(state: *State, buffer: *Buffer) void {
                    c.wlr_output_state_set_buffer(@ptrCast(state), @ptrCast(buffer));
                }

                pub fn setColorTransform(state: *State, transform: ?*ColorTransform) void {
                    c.wlr_output_state_set_color_transform(@ptrCast(state), @ptrCast(transform));
                }

                pub fn setDamage(state: *State, damage: *const pixman.Region32) void {
                    c.wlr_output_state_set_damage(@ptrCast(state), @ptrCast(damage));
                }

                pub fn copy(dst: *State, src: *const State) bool {
                    return c.wlr_output_state_copy(@ptrCast(dst), @ptrCast(src));
                }

                comptime {
                    const Real = c.wlr_output_state;
                    assertFieldOffset(State, Real, "committed");
                    assertFieldOffset(State, Real, "allow_reconfiguration");
                    assertFieldOffset(State, Real, "damage");
                    assertFieldOffset(State, Real, "enabled");
                    assertFieldOffset(State, Real, "scale");
                    assertFieldOffset(State, Real, "transform");
                    assertFieldOffset(State, Real, "adaptive_sync_enabled");
                    assertFieldOffset(State, Real, "render_format");
                    assertFieldOffset(State, Real, "subpixel");
                    assertFieldOffset(State, Real, "buffer");
                    assertFieldOffset(State, Real, "buffer_src_box");
                    assertFieldOffset(State, Real, "buffer_dst_box");
                    assertFieldOffset(State, Real, "tearing_page_flip");
                    assertFieldOffset(State, Real, "mode_type");
                    assertFieldOffset(State, Real, "mode");
                    assertFieldOffset(State, Real, "custom_mode");
                    assertFieldOffset(State, Real, "layers");
                    assertFieldOffset(State, Real, "layers_len");
                    assertFieldOffset(State, Real, "wait_timeline");
                    assertFieldOffset(State, Real, "wait_point");
                    assertFieldOffset(State, Real, "signal_timeline");
                    assertFieldOffset(State, Real, "signal_point");
                    assertFieldOffset(State, Real, "color_transform");
                    assertFieldOffset(State, Real, "image_description");
                    assertSameLayout(State, Real);
                }
            };

            pub const event = struct {
                pub const Present = extern struct {
                    output: *Output,
                    commit_seq: u32,
                    presented: bool,
                    /// When the content turned into light (the display's clock).
                    when: std.posix.timespec,
                    /// Vertical retrace counter; zero if unavailable.
                    seq: c_uint,
                    /// Predicted nanoseconds from `when` to the next refresh; zero if unknown.
                    refresh: c_int,
                    flags: u32,

                    comptime {
                        const Real = c.wlr_output_event_present;
                        assertFieldOffset(Present, Real, "output");
                        assertFieldOffset(Present, Real, "commit_seq");
                        assertFieldOffset(Present, Real, "presented");
                        assertFieldOffset(Present, Real, "when");
                        assertFieldOffset(Present, Real, "seq");
                        assertFieldOffset(Present, Real, "refresh");
                        assertFieldOffset(Present, Real, "flags");
                        assertSameLayout(Present, Real);
                    }
                };

                pub const Commit = extern struct {
                    output: *Output,
                    when: std.posix.timespec,
                    state: *const State,

                    comptime {
                        const Real = c.wlr_output_event_commit;
                        assertFieldOffset(Commit, Real, "output");
                        assertFieldOffset(Commit, Real, "when");
                        assertFieldOffset(Commit, Real, "state");
                        assertSameLayout(Commit, Real);
                    }
                };

                pub const RequestState = extern struct {
                    output: *Output,
                    state: *const State,

                    comptime {
                        const Real = c.wlr_output_event_request_state;
                        assertFieldOffset(RequestState, Real, "output");
                        assertFieldOffset(RequestState, Real, "state");
                        assertSameLayout(RequestState, Real);
                    }
                };
            };

            const Impl = opaque {};

            impl: *const Impl,
            backend: *Backend,
            event_loop: *wl.EventLoop,

            global: ?*wl.Global,
            resources: wl.list.Head(wl.Output, null),

            name: [*:0]u8,
            description: ?[*:0]u8,
            make: ?[*:0]u8,
            model: ?[*:0]u8,
            serial: ?[*:0]u8,
            phys_width: i32,
            phys_height: i32,
            default_primaries: ?*const anyopaque,

            modes: wl.list.Head(Mode, .link),
            current_mode: ?*Mode,
            width: i32,
            height: i32,
            refresh: i32,

            supported_primaries: u32,
            supported_transfer_functions: u32,

            enabled: bool,
            scale: f32,
            subpixel: wl.Output.Subpixel,
            transform: wl.Output.Transform,
            adaptive_sync_status: AdaptiveSyncStatus,
            render_format: u32,
            image_description: ?*const anyopaque,

            adaptive_sync_supported: bool,

            needs_frame: bool,
            frame_pending: bool,

            non_desktop: bool,

            commit_seq: u32,

            events: extern struct {
                /// Self-payload by wlroots convention (no dedicated event struct).
                frame: wl.Signal(*Output),
                /// Placeholder payload: nothing connects this signal (see file doc).
                damage: wl.Signal(void),
                /// Placeholder payload: nothing connects this signal (see file doc).
                needs_frame: wl.Signal(void),
                /// Placeholder payload: nothing connects this signal (see file doc).
                precommit: wl.Signal(void),
                commit: wl.Signal(*event.Commit),
                present: wl.Signal(*event.Present),
                /// Placeholder payload: nothing connects this signal (see file doc).
                bind: wl.Signal(void),
                /// Self-payload by wlroots convention (no dedicated event struct).
                description: wl.Signal(*Output),
                request_state: wl.Signal(*event.RequestState),
                /// Self-payload by wlroots convention (no dedicated event struct).
                destroy: wl.Signal(*Output),
            },

            idle_frame: ?*wl.EventSource,
            idle_done: ?*wl.EventSource,

            attach_render_locks: c_int,

            cursors: wl.list.Head(OutputCursor, .link),

            hardware_cursor: ?*OutputCursor,
            cursor_swapchain: ?*anyopaque,
            cursor_front_buffer: ?*Buffer,
            software_cursor_locks: c_int,

            layers: wl.list.Link,

            allocator: ?*anyopaque,
            renderer: ?*anyopaque,
            swapchain: ?*anyopaque,

            addons: wl.list.Link,

            data: ?*anyopaque,

            pub fn createGlobal(output: *Output, server: *wl.Server) void {
                c.wlr_output_create_global(@ptrCast(output), @ptrCast(server));
            }

            pub fn destroyGlobal(output: *Output) void {
                c.wlr_output_destroy_global(@ptrCast(output));
            }

            pub fn initRender(output: *Output, allocator: *Allocator, renderer: *Renderer) bool {
                return c.wlr_output_init_render(@ptrCast(output), @ptrCast(allocator), @ptrCast(renderer));
            }

            pub fn preferredMode(output: *Output) ?*Mode {
                return @ptrCast(c.wlr_output_preferred_mode(@ptrCast(output)));
            }

            pub fn setName(output: *Output, name: [*:0]const u8) void {
                c.wlr_output_set_name(@ptrCast(output), name);
            }

            pub fn setDescription(output: *Output, desc: [*:0]const u8) void {
                c.wlr_output_set_description(@ptrCast(output), desc);
            }

            pub fn scheduleDone(output: *Output) void {
                c.wlr_output_schedule_done(@ptrCast(output));
            }

            pub fn destroy(output: *Output) void {
                c.wlr_output_destroy(@ptrCast(output));
            }

            pub fn transformedResolution(output: *Output, width: *c_int, height: *c_int) void {
                c.wlr_output_transformed_resolution(@ptrCast(output), width, height);
            }

            pub fn effectiveResolution(output: *Output, width: *c_int, height: *c_int) void {
                c.wlr_output_effective_resolution(@ptrCast(output), width, height);
            }

            pub fn testState(output: *Output, state: *const State) bool {
                return c.wlr_output_test_state(@ptrCast(output), @ptrCast(state));
            }

            pub fn commitState(output: *Output, state: *const State) bool {
                return c.wlr_output_commit_state(@ptrCast(output), @ptrCast(state));
            }

            pub fn scheduleFrame(output: *Output) void {
                c.wlr_output_schedule_frame(@ptrCast(output));
            }

            pub fn getGammaSize(output: *Output) usize {
                return c.wlr_output_get_gamma_size(@ptrCast(output));
            }

            pub fn fromWlOutput(resource: *wl.Output) ?*Output {
                return @ptrCast(c.wlr_output_from_resource(@ptrCast(@alignCast(resource))));
            }

            pub fn lockAttachRender(output: *Output, lock: bool) void {
                c.wlr_output_lock_attach_render(@ptrCast(output), lock);
            }

            pub fn lockSoftwareCursors(output: *Output, lock: bool) void {
                c.wlr_output_lock_software_cursors(@ptrCast(output), lock);
            }

            pub fn isDirectScanoutAllowed(output: *Output) bool {
                return c.wlr_output_is_direct_scanout_allowed(@ptrCast(output));
            }

            pub fn isDrm(output: *Output) bool {
                return c.wlr_output_is_drm(@ptrCast(output));
            }

            pub fn isHeadless(output: *Output) bool {
                return c.wlr_output_is_headless(@ptrCast(output));
            }

            pub fn isWl(output: *Output) bool {
                return c.wlr_output_is_wl(@ptrCast(output));
            }

            pub fn isX11(output: *Output) bool {
                return c.wlr_output_is_x11(@ptrCast(output));
            }

            comptime {
                const Real = c.wlr_output;
                assertFieldOffset(Output, Real, "impl");
                assertFieldOffset(Output, Real, "backend");
                assertFieldOffset(Output, Real, "event_loop");
                assertFieldOffset(Output, Real, "global");
                assertFieldOffset(Output, Real, "resources");
                assertFieldOffset(Output, Real, "name");
                assertFieldOffset(Output, Real, "description");
                assertFieldOffset(Output, Real, "make");
                assertFieldOffset(Output, Real, "model");
                assertFieldOffset(Output, Real, "serial");
                assertFieldOffset(Output, Real, "phys_width");
                assertFieldOffset(Output, Real, "phys_height");
                assertFieldOffset(Output, Real, "default_primaries");
                assertFieldOffset(Output, Real, "modes");
                assertFieldOffset(Output, Real, "current_mode");
                assertFieldOffset(Output, Real, "width");
                assertFieldOffset(Output, Real, "height");
                assertFieldOffset(Output, Real, "refresh");
                assertFieldOffset(Output, Real, "supported_primaries");
                assertFieldOffset(Output, Real, "supported_transfer_functions");
                assertFieldOffset(Output, Real, "enabled");
                assertFieldOffset(Output, Real, "scale");
                assertFieldOffset(Output, Real, "subpixel");
                assertFieldOffset(Output, Real, "transform");
                assertFieldOffset(Output, Real, "adaptive_sync_status");
                assertFieldOffset(Output, Real, "render_format");
                assertFieldOffset(Output, Real, "image_description");
                assertFieldOffset(Output, Real, "adaptive_sync_supported");
                assertFieldOffset(Output, Real, "needs_frame");
                assertFieldOffset(Output, Real, "frame_pending");
                assertFieldOffset(Output, Real, "non_desktop");
                assertFieldOffset(Output, Real, "commit_seq");
                assertFieldOffset(Output, Real, "events");
                assertFieldOffset(Output, Real, "idle_frame");
                assertFieldOffset(Output, Real, "idle_done");
                assertFieldOffset(Output, Real, "attach_render_locks");
                assertFieldOffset(Output, Real, "cursors");
                assertFieldOffset(Output, Real, "hardware_cursor");
                assertFieldOffset(Output, Real, "cursor_swapchain");
                assertFieldOffset(Output, Real, "cursor_front_buffer");
                assertFieldOffset(Output, Real, "software_cursor_locks");
                assertFieldOffset(Output, Real, "layers");
                assertFieldOffset(Output, Real, "allocator");
                assertFieldOffset(Output, Real, "renderer");
                assertFieldOffset(Output, Real, "swapchain");
                assertFieldOffset(Output, Real, "addons");
                assertFieldOffset(Output, Real, "data");

                const Events = @FieldType(Output, "events");
                const RealEvents = @FieldType(Real, "events");
                for (.{ "frame", "damage", "needs_frame", "precommit", "commit", "present", "bind", "description", "request_state", "destroy" }) |field| {
                    assertSameLayout(@FieldType(Events, field), c.wl_signal);
                    assertFieldOffset(Events, RealEvents, field);
                }
                assertSameLayout(wl.list.Head(OutputCursor, .link), c.wl_list);
                assertSameLayout(wl.list.Head(Mode, .link), c.wl_list);
                assertSameLayout(wl.list.Head(wl.Output, null), c.wl_list);
                assertSameLayout(AdaptiveSyncStatus, c.wlr_output_adaptive_sync_status);
            }
        };
    };
}

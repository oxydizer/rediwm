//! wlr.OutputLayout, backed by translate-c against
//! wlr/types/wlr_output_layout.h. `OutputLayout.Output` (the per-output
//! layout entry) is declared far enough to be a valid `wl.list.Head`
//! element and to read its position: `output/auto_place.zig` walks
//! `layout.outputs` to place outputs; elsewhere RediWM uses
//! `events.change` on the layout itself.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;
const box = @import("box.zig");

pub fn Types(comptime WlrOutput: type) type {
    return struct {
        pub const OutputLayout = extern struct {
            pub const Output = extern struct {
                layout: *OutputLayout,
                output: *WlrOutput,
                x: c_int,
                y: c_int,
                /// OutputLayout.outputs
                link: wl.list.Link,
                auto_configured: bool,

                events: extern struct {
                    destroy: wl.Signal(*Output),
                },

                comptime {
                    const Real = c.wlr_output_layout_output;
                    assertFieldOffset(Output, Real, "layout");
                    assertFieldOffset(Output, Real, "output");
                    assertFieldOffset(Output, Real, "x");
                    assertFieldOffset(Output, Real, "y");
                    assertFieldOffset(Output, Real, "link");
                    assertFieldOffset(Output, Real, "auto_configured");
                    assertFieldOffset(Output, Real, "events");
                    assertSameLayout(@FieldType(Output, "events"), @FieldType(Real, "events"));
                }
            };

            outputs: wl.list.Head(Output, .link),
            server: *wl.Server,

            events: extern struct {
                add: wl.Signal(*Output),
                change: wl.Signal(*OutputLayout),
                destroy: wl.Signal(*OutputLayout),
            },

            data: ?*anyopaque,

            pub fn create(server: *wl.Server) !*OutputLayout {
                const raw = c.wlr_output_layout_create(@ptrCast(server));
                return @as(?*OutputLayout, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn destroy(layout: *OutputLayout) void {
                c.wlr_output_layout_destroy(@ptrCast(layout));
            }

            pub fn outputAt(layout: *OutputLayout, lx: f64, ly: f64) ?*WlrOutput {
                return @ptrCast(c.wlr_output_layout_output_at(@ptrCast(layout), lx, ly));
            }

            pub fn add(layout: *OutputLayout, output: *WlrOutput, lx: c_int, ly: c_int) !*Output {
                const raw = c.wlr_output_layout_add(@ptrCast(layout), @ptrCast(output), lx, ly);
                return @as(?*Output, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn addAuto(layout: *OutputLayout, output: *WlrOutput) !*Output {
                const raw = c.wlr_output_layout_add_auto(@ptrCast(layout), @ptrCast(output));
                return @as(?*Output, @ptrCast(raw)) orelse error.OutOfMemory;
            }

            pub fn remove(layout: *OutputLayout, output: *WlrOutput) void {
                c.wlr_output_layout_remove(@ptrCast(layout), @ptrCast(output));
            }

            pub fn getBox(layout: *OutputLayout, reference: ?*WlrOutput, dest_box: ?*box.Box) void {
                c.wlr_output_layout_get_box(@ptrCast(layout), @ptrCast(reference), @ptrCast(dest_box));
            }

            comptime {
                const Real = c.wlr_output_layout;
                assertFieldOffset(OutputLayout, Real, "outputs");
                assertFieldOffset(OutputLayout, Real, "events");
                assertFieldOffset(OutputLayout, Real, "data");

                const Events = @FieldType(OutputLayout, "events");
                const RealEvents = @FieldType(Real, "events");
                assertSameLayout(@FieldType(Events, "add"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "change"), c.wl_signal);
                assertSameLayout(@FieldType(Events, "destroy"), c.wl_signal);
                assertFieldOffset(Events, RealEvents, "add");
                assertFieldOffset(Events, RealEvents, "change");
                assertFieldOffset(Events, RealEvents, "destroy");
                assertSameLayout(wl.list.Head(Output, .link), c.wl_list);
            }
        };
    };
}

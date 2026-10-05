//! Explicit opt-in D-Bus client/service support. Import from a consumer and open
//! on its Wayland event loop; this module never acquires a bus name by itself.
pub const wire = @import("wire.zig");
pub const address = @import("address.zig");
pub const Connection = @import("connection.zig").Connection;
pub const Signal = Connection.Signal;
pub const SignalCallback = Connection.SignalCallback;
pub const SignalHandler = Connection.SignalHandler;
pub const connection = @import("connection.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

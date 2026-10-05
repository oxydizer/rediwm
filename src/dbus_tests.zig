test {
    _ = @import("ui").widgets.secret_input;
    _ = @import("dbus").address;
    _ = @import("dbus").wire;
    _ = @import("dbus").connection;
    _ = @import("polkit/agent.zig");
    _ = @import("polkit/identity.zig");
    _ = @import("polkit/helper.zig");
}

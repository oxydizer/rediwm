comptime {
    _ = @import("child_env.zig");
    _ = @import("session/activation.zig");
    _ = @import("share_picker/sources.zig");
    _ = @import("share_picker/diagnose.zig");
}

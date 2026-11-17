//! Firewall settings shared by Settings and `rediwm-firewall-helper`: the
//! model, the request protocol, validation, and the parsers and renderers for
//! each manager. Std only; no compositor imports. See docs/plans/firewall.md.
pub const model = @import("model.zig");
pub const protocol = @import("protocol.zig");
pub const validate = @import("validate.zig");
pub const services = @import("services.zig");
pub const own = @import("own.zig");
pub const ufw = @import("ufw.zig");
pub const firewalld = @import("firewalld.zig");
pub const inventory = @import("inventory.zig");
pub const sockets = @import("sockets.zig");
pub const blocks = @import("blocks.zig");

test {
    _ = model;
    _ = validate;
    _ = services;
    _ = ufw;
    _ = firewalld;
    _ = inventory;
    _ = sockets;
    _ = blocks;
    _ = @import("own_tests.zig");
}

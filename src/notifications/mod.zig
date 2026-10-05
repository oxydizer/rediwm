//! Public interface of the notifications subsystem.
pub const image = @import("image.zig");
pub const toast = @import("toast.zig");
pub const manager = @import("manager.zig");

pub const Toast = toast.Toast;
pub const ActionPair = toast.ActionPair;
pub const Manager = manager.Manager;
pub const NotificationRecord = manager.NotificationRecord;

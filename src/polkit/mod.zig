//! Native authentication agent. No connection is opened merely by importing.
pub const Agent = @import("agent.zig").Agent;
pub const helper = @import("helper.zig");
pub const identity = @import("identity.zig");

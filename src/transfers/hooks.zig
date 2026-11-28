//! Where a Files transfers change goes: every taskbar's item and icon, and
//! the open panel.
const Server = @import("../Server.zig");
const Model = @import("model.zig").Model;

pub fn changed(server: *Server, model: *const Model) void {
    const present = model.present();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.taskbar) |bar| bar.applyTransfers(present);
    }
    if (server.input.open_transfers) |popup| popup.changed();
}

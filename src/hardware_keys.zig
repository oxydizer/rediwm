const Server = @import("Server.zig");
const Action = @import("config").keybinds.Action;
const osd = @import("osd.zig");

pub fn audioState(server: *Server, microphone: bool) ?osd.State {
    const mgr = server.audio orelse return null;
    mgr.lock();
    defer mgr.unlock();
    if (microphone) {
        for (mgr.sources.items) |source| if (source.is_default) return .{ .kind = .microphone, .active = source.muted };
    } else {
        for (mgr.sinks.items) |sink| if (sink.is_default) return .{ .kind = .volume, .level = sink.volume, .active = sink.muted };
    }
    return null;
}

pub fn execute(server: *Server, action: Action) void {
    switch (action) {
        .brightness_up, .brightness_down => server.brightness.adjust(server, if (action == .brightness_up) 1 else -1),
        .volume_up, .volume_down, .volume_mute, .mic_mute => {
            const state = audioState(server, action == .mic_mute) orelse return;
            const mgr = server.audio.?;
            switch (action) {
                .volume_up => mgr.hardwareAction(.volume_up),
                .volume_down => mgr.hardwareAction(.volume_down),
                .volume_mute => mgr.hardwareAction(.volume_mute),
                .mic_mute => mgr.hardwareAction(.mic_mute),
                else => unreachable,
            }
            // Display only the last confirmed snapshot; the audio wake callback
            // updates the visible OSD once the server reports its actual state.
            osd.show(server, state);
        },
        else => {},
    }
}

// Control center sound controls. Each callback carries its owning Section.
const std = @import("std");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const panel = @import("../panel.zig");
const Widget = layout.Widget;
const audio = @import("../../audio/pipewire.zig");

const max_apps = 8;
const row_height: f32 = 28;
const icon_button_size: f32 = 24;
const icon_size: f32 = 15;
const volume_step: f32 = 0.05;

pub const Section = struct {
    root: Widget = undefined,
    top_children: [2]Widget = undefined,
    body_children: [8]Widget = undefined,
    balance_children: [5]Widget = undefined,
    balance_value_buf: [16]u8 = undefined,
    bass_children: [3]Widget = undefined,
    bass_value_buf: [16]u8 = undefined,
    treble_children: [3]Widget = undefined,
    treble_value_buf: [16]u8 = undefined,

    // "Audio unavailable" fallback (PipeWire/PulseAudio not reachable).
    unavailable_children: [1]Widget = undefined,

    // Output device row: [label, value].
    output_row_children: [2]Widget = undefined,
    output_desc_buf: [64]u8 = undefined,
    output_desc_len: usize = 0,

    // Master volume row: [mute button, slider, percent].
    master_children: [3]Widget = undefined,
    master_icon_child: [1]Widget = undefined,
    master_percent_buf: [6]u8 = undefined,

    // Input device row: [label, value].
    input_row_children: [2]Widget = undefined,
    input_desc_buf: [64]u8 = undefined,
    input_desc_len: usize = 0,

    // Input volume row: [mute button, slider, percent].
    input_vol_children: [3]Widget = undefined,
    input_icon_child: [1]Widget = undefined,
    input_percent_buf: [6]u8 = undefined,

    // App streams block: header + either the rows container or empty text.
    apps_block_children: [2]Widget = undefined,
    apps_empty_text: Widget = undefined,
    apps_list: [max_apps]Widget = undefined,
    app_row_children: [max_apps][4]Widget = undefined,
    app_mute_icon_child: [max_apps][1]Widget = undefined,
    app_name_bufs: [max_apps][40]u8 = undefined,
    app_name_lens: [max_apps]usize = undefined,
    app_percent_bufs: [max_apps][6]u8 = undefined,
    app_indices: [max_apps]u32 = undefined,
    app_volumes: [max_apps]f32 = undefined,
    app_muted: [max_apps]bool = undefined,
    app_count: usize = 0,

    audio_mgr: ?*audio.AudioManager = null,
};

fn dimLabel(content: []const u8) Widget {
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .color = panel.palette().dim } }, .width = .{ .flex = 1 } };
}

fn valueWidget(content: []const u8) Widget {
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .weight = 600, .color = panel.palette().fg } } };
}

/// The readout beside a slider, in a rounded label.
fn pillWidget(content: []const u8, font_size: f32) Widget {
    return ui_slider.valuePill(content, font_size, panel.palette().dim);
}

fn deviceRow(children: *[2]Widget, label: []const u8, value: []const u8) Widget {
    children.* = .{ dimLabel(label), valueWidget(value) };
    return .{
        .kind = .container,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .center,
        .height = .{ .fixed = row_height },
        .children = children,
    };
}

/// The mute-toggle icon button shared by the master/input/app-row rows —
/// a `.row`-kind widget (owner+id+on_click, the icon-button primitive this
/// engine already has, see start_menu/panel.zig's search icon usage) wrapping
/// a single centered `.icon` child. `id` disambiguates which device/stream
/// `onMuteRowClick` should act on: 0 = master, 1 = input, `2 + i` = the i'th
/// visible app row (looked up in the owning section's `app_indices`).
fn muteButton(out: *Section, icon_child: *[1]Widget, icon_id: layout.IconId, muted: bool, id: usize) Widget {
    const t = panel.palette();
    icon_child[0] = .{
        .kind = .{ .icon = .{ .id = icon_id, .color = if (muted) theme.global.danger else t.fg } },
        .width = .{ .fixed = icon_size },
        .height = .{ .fixed = icon_size },
    };
    return .{
        .kind = .{ .row = .{ .owner = out, .id = id, .on_click = &onMuteRowClick } },
        .width = .{ .fixed = icon_button_size },
        .height = .{ .fixed = icon_button_size },
        .@"align" = .center,
        .justify = .center,
        .children = icon_child,
    };
}

fn volumeIconFor(volume: f32, muted: bool) layout.IconId {
    if (muted) return .volume_muted;
    if (volume <= 0) return .volume_muted;
    if (volume < 0.5) return .volume_low;
    return .volume;
}

fn formatPercent(buf: []u8, volume: f32) []const u8 {
    const pct: i32 = @intFromFloat(@round(std.math.clamp(volume, 0, 1) * 100));
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "?";
}

fn volumeRow(
    out: *Section,
    children: *[3]Widget,
    icon_child: *[1]Widget,
    percent_buf: []u8,
    icon_id: layout.IconId,
    muted: bool,
    volume: f32,
    mute_id: usize,
    on_change: *const fn (?*anyopaque, usize, f32) void,
) Widget {
    const slider_name: ?[]const u8 = if (mute_id == 0) "output_volume" else if (mute_id == 1) "input_volume" else null;
    const mute_name: ?[]const u8 = if (mute_id == 0) "output_mute" else if (mute_id == 1) "input_mute" else null;
    children.*[0] = muteButton(out, icon_child, icon_id, muted, mute_id);
    children.*[0].name = mute_name;
    children.*[1] = .{
        .name = slider_name,
        .kind = .{ .slider = .{ .value = volume, .min = 0, .max = 1, .step = volume_step, .owner = out, .on_change = on_change } },
        .width = .{ .flex = 1 },
    };
    children.*[2] = pillWidget(formatPercent(percent_buf, volume), 12);
    children.*[2].width = .{ .fixed = 48 };
    return .{
        .kind = .container,
        .direction = .row,
        .gap = 10,
        .@"align" = .center,
        .height = .{ .fixed = row_height },
        .children = children,
    };
}

fn unavailableRow(out: *Section) Widget {
    out.unavailable_children = .{
        .{ .kind = .{ .text = .{ .content = "Audio unavailable", .font_size = 13, .color = panel.palette().dim } } },
    };
    return .{ .kind = .container, .height = .{ .fixed = row_height }, .children = &out.unavailable_children };
}

pub fn build(out: *Section, audio_mgr: ?*audio.AudioManager) void {
    out.audio_mgr = audio_mgr;
    out.output_desc_len = 0;
    out.input_desc_len = 0;
    out.app_count = 0;

    out.top_children[0] = .{ .kind = .{ .text = .{ .content = "SOUND", .font_size = 12, .weight = 700, .color = panel.palette().dim } } };

    const mgr = audio_mgr orelse {
        out.body_children[0] = unavailableRow(out);
        out.top_children[1] = .{ .name = "sound", .kind = .container, .direction = .column, .gap = 12, .children = out.body_children[0..1] };
        out.root = .{ .name = "sound", .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
        out.root.linkParents();
        return;
    };

    var master_volume: f32 = 0;
    var master_muted = false;
    var balance: f32 = 0;
    var can_balance = false;
    var input_volume: f32 = 0;
    var input_muted = false;

    mgr.lock();
    for (mgr.sinks.items) |s| {
        if (!s.is_default) continue;
        master_volume = s.volume;
        master_muted = s.muted;
        balance = s.balance;
        can_balance = s.can_balance;
        out.output_desc_len = @min(s.description.len, out.output_desc_buf.len);
        @memcpy(out.output_desc_buf[0..out.output_desc_len], s.description[0..out.output_desc_len]);
    }
    for (mgr.sources.items) |s| {
        if (!s.is_default) continue;
        input_volume = s.volume;
        input_muted = s.muted;
        out.input_desc_len = @min(s.description.len, out.input_desc_buf.len);
        @memcpy(out.input_desc_buf[0..out.input_desc_len], s.description[0..out.input_desc_len]);
    }
    out.app_count = @min(mgr.sink_inputs.items.len, max_apps);
    for (mgr.sink_inputs.items[0..out.app_count], 0..) |si, i| {
        out.app_indices[i] = si.index;
        out.app_volumes[i] = si.volume;
        out.app_muted[i] = si.muted;
        out.app_name_lens[i] = @min(si.name.len, out.app_name_bufs[i].len);
        @memcpy(out.app_name_bufs[i][0..out.app_name_lens[i]], si.name[0..out.app_name_lens[i]]);
    }
    mgr.unlock();

    out.balance_children = .{
        dimLabel("Balance"),
        valueWidget(if (can_balance) "Left" else "Unavailable"),
        if (can_balance) .{
            .name = "output_balance",
            .kind = .{ .slider = .{ .style = .settings, .value = balance, .min = -1, .max = 1, .step = 0.05, .owner = out, .on_change = onBalanceChanged } },
            .width = .{ .flex = 2 },
        } else valueWidget(""),
        valueWidget("Right"),
        pillWidget(if (can_balance) formatBalance(&out.balance_value_buf, balance) else "", 13),
    };
    out.balance_children[4].width = .{ .fixed = 76 };
    out.body_children[2] = .{ .kind = .container, .direction = .row, .gap = 10, .@"align" = .center, .height = .{ .fixed = row_height }, .children = if (can_balance) &out.balance_children else out.balance_children[0..2] };

    const bass = mgr.getBass();
    out.bass_children = .{
        dimLabel("Bass Boost"),
        if (bass.available) .{
            .name = "bass_boost",
            .kind = .{ .slider = .{ .style = .settings, .value = bass.gain, .min = 0, .max = 12, .step = 0.5, .owner = out, .on_change = onBassChanged } },
            .width = .{ .flex = 2 },
        } else valueWidget("Unavailable"),
        pillWidget(if (bass.available) formatBass(&out.bass_value_buf, bass) else "", 13),
    };
    out.bass_children[2].width = .{ .fixed = 76 };
    out.body_children[3] = .{ .kind = .container, .direction = .row, .gap = 10, .@"align" = .center, .height = .{ .fixed = row_height }, .children = &out.bass_children };

    out.treble_children = .{
        dimLabel("Treble"),
        if (bass.available) .{
            .name = "treble",
            .kind = .{ .slider = .{ .style = .settings, .value = bass.treble, .min = -6, .max = 6, .step = 0.5, .owner = out, .on_change = onTrebleChanged } },
            .width = .{ .flex = 2 },
        } else valueWidget("Unavailable"),
        pillWidget(if (bass.available) formatTreble(&out.treble_value_buf, bass) else "", 13),
    };
    out.treble_children[2].width = .{ .fixed = 76 };
    out.body_children[4] = .{ .kind = .container, .direction = .row, .gap = 10, .@"align" = .center, .height = .{ .fixed = row_height }, .children = &out.treble_children };

    out.body_children[0] = deviceRow(&out.output_row_children, "Output", out.output_desc_buf[0..out.output_desc_len]);
    out.body_children[1] = volumeRow(
        out,
        &out.master_children,
        &out.master_icon_child,
        &out.master_percent_buf,
        volumeIconFor(master_volume, master_muted),
        master_muted,
        master_volume,
        0,
        &onMasterVolumeChanged,
    );
    out.body_children[5] = deviceRow(&out.input_row_children, "Input", out.input_desc_buf[0..out.input_desc_len]);
    out.body_children[6] = volumeRow(
        out,
        &out.input_vol_children,
        &out.input_icon_child,
        &out.input_percent_buf,
        if (input_muted) .mic_muted else .mic_outline,
        input_muted,
        input_volume,
        1,
        &onInputVolumeChanged,
    );

    for (0..out.app_count) |i| {
        out.app_row_children[i][0] = .{
            .kind = .{ .text = .{ .content = out.app_name_bufs[i][0..out.app_name_lens[i]], .font_size = 13, .weight = 600, .color = panel.palette().fg } },
            .width = .{ .flex = 1 },
        };
        out.app_row_children[i][1] = .{
            .kind = .{ .slider = .{ .value = out.app_volumes[i], .min = 0, .max = 1, .step = volume_step, .owner = out, .id = i, .on_change = onAppVolumeChanged } },
            .width = .{ .flex = 2 },
        };
        out.app_row_children[i][2] = pillWidget(formatPercent(&out.app_percent_bufs[i], out.app_volumes[i]), 12);
        out.app_row_children[i][2].width = .{ .fixed = 48 };
        out.app_row_children[i][3] = muteButton(out, &out.app_mute_icon_child[i], .volume, out.app_muted[i], 2 + i);
        out.apps_list[i] = .{
            .kind = .container,
            .direction = .row,
            .gap = 8,
            .@"align" = .center,
            .height = .{ .fixed = row_height },
            .children = &out.app_row_children[i],
        };
    }

    out.apps_block_children[0] = .{ .kind = .{ .text = .{ .content = "App streams", .font_size = 13, .weight = 600, .color = panel.palette().fg } } };
    if (out.app_count > 0) {
        out.apps_block_children[1] = .{
            .kind = .container,
            .direction = .column,
            .gap = 6,
            .children = out.apps_list[0..out.app_count],
        };
    } else {
        out.apps_empty_text = .{ .kind = .{ .text = .{ .content = "No active audio streams", .font_size = 12, .color = panel.palette().dim } } };
        out.apps_block_children[1] = out.apps_empty_text;
    }
    out.body_children[7] = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.apps_block_children };

    out.top_children[1] = .{ .name = "sound", .kind = .container, .direction = .column, .gap = 12, .children = &out.body_children };
    out.root = .{ .name = "sound", .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
    out.root.linkParents();
}

fn onAppVolumeChanged(owner: ?*anyopaque, index: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    if (index >= s.app_count) return;
    mgr.setSinkInputVolume(s.app_indices[index], value);
    s.app_volumes[index] = value;
    s.app_row_children[index][2].kind.text.content = formatPercent(&s.app_percent_bufs[index], value);
    s.app_row_children[index][2].markDirty();
}

fn formatBalance(buf: []u8, balance: f32) []const u8 {
    const percent: u32 = @intFromFloat(@round(@abs(balance) * 100));
    if (percent == 0) return "Centre";
    return std.fmt.bufPrint(buf, "{s} {d}%", .{ if (balance < 0) "L" else "R", percent }) catch "?";
}

fn onBalanceChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    mgr.setMasterBalance(value);
    s.balance_children[4].kind.text.content = formatBalance(&s.balance_value_buf, value);
    s.balance_children[4].markDirty();
}

fn formatBass(buf: []u8, bass: audio.BassState) []const u8 {
    if (bass.save_failed) return "Not saved";
    if (bass.gain == 0) return "Off";
    return std.fmt.bufPrint(buf, "+{d:.1} dB", .{bass.gain}) catch "?";
}

fn onBassChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    const applied = mgr.setBass(value);
    const bass = mgr.getBass();
    s.bass_children[1].kind.slider.value = bass.gain;
    s.bass_children[1].markDirty();
    s.bass_children[2].kind.text.content = if (applied) formatBass(&s.bass_value_buf, bass) else "Unavailable";
    s.bass_children[2].markDirty();
}

fn formatTreble(buf: []u8, bass: audio.BassState) []const u8 {
    if (bass.save_failed) return "Not saved";
    if (bass.treble == 0) return "Off";
    return std.fmt.bufPrint(buf, "{s}{d:.1} dB", .{ if (bass.treble > 0) "+" else "", bass.treble }) catch "?";
}

fn onTrebleChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    const applied = mgr.setTreble(value);
    const bass = mgr.getBass();
    s.treble_children[1].kind.slider.value = bass.treble;
    s.treble_children[1].markDirty();
    s.treble_children[2].kind.text.content = if (applied) formatTreble(&s.treble_value_buf, bass) else "Unavailable";
    s.treble_children[2].markDirty();
}

fn onMasterVolumeChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    mgr.setMasterVolume(value);
    s.master_children[2].kind.text.content = formatPercent(&s.master_percent_buf, value);
    s.master_children[2].markDirty();
    const muted = mgr.isMasterMuted();
    s.master_icon_child[0].kind.icon.id = volumeIconFor(value, muted);
    s.master_icon_child[0].markDirty();
}

fn onInputVolumeChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    mgr.setInputVolume(value);
    s.input_vol_children[2].kind.text.content = formatPercent(&s.input_percent_buf, value);
    s.input_vol_children[2].markDirty();
}

fn onMuteRowClick(owner: ?*anyopaque, id: usize) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const mgr = s.audio_mgr orelse return;
    const pal = panel.palette();
    if (id == 0) {
        mgr.toggleMasterMute();
        const muted = mgr.isMasterMuted();
        s.master_icon_child[0].kind.icon.id = volumeIconFor(mgr.getMasterVolume(), muted);
        s.master_icon_child[0].kind.icon.color = if (muted) theme.global.danger else pal.fg;
        s.master_icon_child[0].markDirty();
        return;
    }
    if (id == 1) {
        mgr.toggleInputMute();
        const muted = mgr.isInputMuted();
        s.input_icon_child[0].kind.icon.id = if (muted) .mic_muted else .mic_outline;
        s.input_icon_child[0].kind.icon.color = if (muted) theme.global.danger else pal.fg;
        s.input_icon_child[0].markDirty();
        return;
    }
    const index = id - 2;
    if (index >= s.app_count) return;
    const new_muted = !s.app_muted[index];
    mgr.setSinkInputMute(s.app_indices[index], new_muted);
    s.app_muted[index] = new_muted;
    s.app_mute_icon_child[index][0].kind.icon.color = if (new_muted) theme.global.danger else pal.fg;
    s.app_mute_icon_child[index][0].markDirty();
}

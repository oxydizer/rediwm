//! Static setting destinations. Searching never builds pages or queries hardware.
const std = @import("std");
const fold = @import("ui").fold;
const i18n = @import("i18n");
pub const Page = enum { general, input, displays, audio, network, appearance, shortcuts, desktop, bluetooth, region, users, printers, services, power };
pub const Entry = struct {
    page: Page,
    title: []const u8,
    /// Empty for a page; @ prefixes a visible heading, otherwise a widget name.
    target: []const u8 = "",
    keywords: []const u8 = "",
};
const SourceEntry = struct {
    page: Page,
    title: i18n.Message,
    target: []const u8 = "",
    heading: ?i18n.Message = null,
    keywords: i18n.Message = i18n.msg(""),
};

const source_entries = [_]SourceEntry{
    .{ .page = .power, .title = i18n.msg("Power & Battery"), .target = "", .keywords = i18n.msg("sleep battery charging energy") },
    .{ .page = .power, .title = i18n.msg("Keyboard backlight"), .target = "power_keyboard", .keywords = i18n.msg("brightness plugged battery") },
    .{ .page = .power, .title = i18n.msg("Charging limit"), .target = "power_charge_limit", .keywords = i18n.msg("battery health threshold") },
    .{ .page = .power, .title = i18n.msg("Power mode"), .target = "power_mode", .keywords = i18n.msg("performance balanced saver plugged unplugged") },
    .{ .page = .power, .title = i18n.msg("Automatic brightness"), .target = "power_brightness", .keywords = i18n.msg("backlight battery plugged") },
    .{ .page = .power, .title = i18n.msg("Turn off screen after"), .target = "power_blank", .keywords = i18n.msg("idle timeout display") },
    .{ .page = .power, .title = i18n.msg("Sleep after"), .target = "power_sleep", .keywords = i18n.msg("automatic suspend idle") },
    .{ .page = .power, .title = i18n.msg("Dim screen after"), .target = "power_dim", .keywords = i18n.msg("brightness idle") },
    .{ .page = .power, .title = i18n.msg("Low battery warning"), .target = "power_warning", .keywords = i18n.msg("notification percent") },
    .{ .page = .power, .title = i18n.msg("Automatic Power Saver"), .target = "power_saver", .keywords = i18n.msg("low battery") },
    .{ .page = .power, .title = i18n.msg("Critical battery"), .target = "power_critical", .keywords = i18n.msg("sleep shutdown") },
    .{ .page = .power, .title = i18n.msg("Lock before sleep"), .target = "lock_on_suspend", .keywords = i18n.msg("security suspend") },
    .{ .page = .power, .title = i18n.msg("External display lid action"), .target = "power_docked", .keywords = i18n.msg("dock monitor laptop") },
    .{ .page = .general, .title = i18n.msg("General"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .input, .title = i18n.msg("Input"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .displays, .title = i18n.msg("Displays"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .audio, .title = i18n.msg("Audio"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .network, .title = i18n.msg("Network"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .appearance, .title = i18n.msg("Appearance"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .shortcuts, .title = i18n.msg("Keyboard Shortcuts"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .desktop, .title = i18n.msg("Desktop"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .bluetooth, .title = i18n.msg("Bluetooth"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .region, .title = i18n.msg("Region & Language"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .users, .title = i18n.msg("Users"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .printers, .title = i18n.msg("Printers"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .services, .title = i18n.msg("Services"), .target = "", .keywords = i18n.msg("") },
    .{ .page = .general, .title = i18n.msg("Brightness"), .target = "@Brightness", .heading = i18n.msg("Brightness"), .keywords = i18n.msg("backlight screen light") },
    .{ .page = .general, .title = i18n.msg("Open files with a single click"), .target = "files_single_click_open", .keywords = i18n.msg("double click folders") },
    .{ .page = .input, .title = i18n.msg("Pointer device"), .target = "pointer_device", .keywords = i18n.msg("mouse touchpad trackpad select") },
    .{ .page = .input, .title = i18n.msg("Show all devices"), .target = "pointer_show_all", .keywords = i18n.msg("mouse touchpad trackpad select") },
    .{ .page = .input, .title = i18n.msg("Reset pointer settings"), .target = "pointer_reset", .keywords = i18n.msg("mouse touchpad trackball default custom inherit") },
    .{ .page = .input, .title = i18n.msg("Pointer speed"), .target = "pointer_speed", .keywords = i18n.msg("mouse touchpad trackpad acceleration sensitivity") },
    .{ .page = .input, .title = i18n.msg("Disable while typing"), .target = "disable_while_typing", .keywords = i18n.msg("keyboard touchpad trackpad") },
    .{ .page = .input, .title = i18n.msg("Left-handed mode"), .target = "left_handed", .keywords = i18n.msg("mouse buttons swap primary") },
    .{ .page = .input, .title = i18n.msg("Tap and drag"), .target = "tap_drag", .keywords = i18n.msg("touchpad trackpad") },
    .{ .page = .input, .title = i18n.msg("Natural scroll"), .target = "natural_scroll", .keywords = i18n.msg("scrolling direction reverse invert mouse touchpad") },
    .{ .page = .input, .title = i18n.msg("Tap to click"), .target = "tap_to_click", .keywords = i18n.msg("touchpad trackpad") },
    .{ .page = .input, .title = i18n.msg("Canvas pan speed"), .target = "pan_speed", .keywords = i18n.msg("desktop panning") },
    .{ .page = .input, .title = i18n.msg("Keyboard repeat delay"), .target = "repeat_delay", .keywords = i18n.msg("typing keys") },
    .{ .page = .input, .title = i18n.msg("Keyboard repeat rate"), .target = "repeat_rate", .keywords = i18n.msg("typing keys speed") },
    .{ .page = .displays, .title = i18n.msg("Monitor"), .target = "monitor", .keywords = i18n.msg("screen output") },
    .{ .page = .displays, .title = i18n.msg("Display arrangement"), .target = "@Arrangement", .heading = i18n.msg("Arrangement"), .keywords = i18n.msg("screen position monitors main display") },
    .{ .page = .displays, .title = i18n.msg("Resolution"), .target = "resolution", .keywords = i18n.msg("screen size pixels") },
    .{ .page = .displays, .title = i18n.msg("Refresh rate"), .target = "refresh_rate", .keywords = i18n.msg("screen frequency hz") },
    .{ .page = .displays, .title = i18n.msg("Display scale"), .target = "scale", .keywords = i18n.msg("screen scaling dpi zoom") },
    .{ .page = .displays, .title = i18n.msg("Xwayland scale"), .target = "xwayland_scale", .keywords = i18n.msg("x11 legacy apps scaling") },
    .{ .page = .displays, .title = i18n.msg("Rotation"), .target = "transform", .keywords = i18n.msg("orientation portrait landscape screen") },
    .{ .page = .displays, .title = i18n.msg("Night light"), .target = "night_light", .keywords = i18n.msg("blue light warm screen") },
    .{ .page = .displays, .title = i18n.msg("Night light temperature"), .target = "night_light_temperature", .keywords = i18n.msg("warmth colour color") },
    .{ .page = .power, .title = i18n.msg("Lid close action"), .target = "lid_close", .keywords = i18n.msg("laptop suspend sleep") },
    .{ .page = .audio, .title = i18n.msg("Output volume"), .target = "output_volume", .keywords = i18n.msg("sound speakers loudness mute") },
    .{ .page = .audio, .title = i18n.msg("Microphone volume"), .target = "input_volume", .keywords = i18n.msg("sound input recording mute") },
    .{ .page = .audio, .title = i18n.msg("Output balance"), .target = "output_balance", .keywords = i18n.msg("left right speakers") },
    .{ .page = .audio, .title = i18n.msg("Bass boost"), .target = "bass_boost", .keywords = i18n.msg("sound equalizer low frequencies") },
    .{ .page = .audio, .title = i18n.msg("Treble"), .target = "treble", .keywords = i18n.msg("sound equalizer high frequencies") },
    .{ .page = .audio, .title = i18n.msg("Audio output device"), .target = "@Audio output", .heading = i18n.msg("Audio output"), .keywords = i18n.msg("speakers headphones sound default") },
    .{ .page = .network, .title = i18n.msg("Wi-Fi"), .target = "wifi_card", .keywords = i18n.msg("wireless internet wlan hotspot hidden network") },
    .{ .page = .network, .title = i18n.msg("Ethernet"), .target = "ethernet_card", .keywords = i18n.msg("wired internet adapter") },
    .{ .page = .appearance, .title = i18n.msg("Wallpaper"), .target = "@Wallpaper", .heading = i18n.msg("Wallpaper"), .keywords = i18n.msg("background desktop image folder") },
    .{ .page = .appearance, .title = i18n.msg("Theme"), .target = "@Theme", .heading = i18n.msg("Theme"), .keywords = i18n.msg("colors colours dark light preset") },
    .{ .page = .appearance, .title = i18n.msg("Icon theme"), .target = "icon_theme", .keywords = i18n.msg("icons pack") },
    .{ .page = .appearance, .title = i18n.msg("Animations"), .target = "animations", .keywords = i18n.msg("effects motion") },
    .{ .page = .appearance, .title = i18n.msg("Animation speed"), .target = "anim_speed", .keywords = i18n.msg("motion duration") },
    .{ .page = .appearance, .title = i18n.msg("Reduced motion"), .target = "reduced_motion", .keywords = i18n.msg("accessibility animations") },
    .{ .page = .appearance, .title = i18n.msg("Focus zoom"), .target = "focus_zoom", .keywords = i18n.msg("window focus") },
    .{ .page = .appearance, .title = i18n.msg("Drag feedback"), .target = "drag_feedback", .keywords = i18n.msg("window moving") },
    .{ .page = .appearance, .title = i18n.msg("Drag scale"), .target = "drag_scale", .keywords = i18n.msg("window moving size") },
    .{ .page = .appearance, .title = i18n.msg("Font"), .target = "font", .keywords = i18n.msg("typeface text") },
    .{ .page = .appearance, .title = i18n.msg("Cursor theme"), .target = "cursor_theme", .keywords = i18n.msg("pointer mouse") },
    .{ .page = .appearance, .title = i18n.msg("Font size"), .target = "font_size", .keywords = i18n.msg("text size accessibility") },
    .{ .page = .appearance, .title = i18n.msg("Corner radius"), .target = "radius", .keywords = i18n.msg("rounded windows") },
    .{ .page = .appearance, .title = i18n.msg("Window shadow"), .target = "shadow", .keywords = i18n.msg("shadows") },
    .{ .page = .appearance, .title = i18n.msg("Border glow"), .target = "border_glow", .keywords = i18n.msg("window borders") },
    .{ .page = .appearance, .title = i18n.msg("Window opacity"), .target = "chrome_opacity", .keywords = i18n.msg("transparency chrome") },
    .{ .page = .appearance, .title = i18n.msg("Window darkness"), .target = "chrome_darkness", .keywords = i18n.msg("chrome tint") },
    .{ .page = .appearance, .title = i18n.msg("Titlebar height"), .target = "chrome_height", .keywords = i18n.msg("window chrome") },
    .{ .page = .appearance, .title = i18n.msg("Window control spacing"), .target = "chrome_control_gap", .keywords = i18n.msg("buttons close maximize minimize") },
    .{ .page = .appearance, .title = i18n.msg("Inactive window opacity"), .target = "inactive_opacity", .keywords = i18n.msg("transparency unfocused") },
    .{ .page = .appearance, .title = i18n.msg("Terminal opacity"), .target = "terminal_opacity", .keywords = i18n.msg("transparency") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar position"), .target = "taskbar_position", .keywords = i18n.msg("panel top bottom") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar alignment"), .target = "taskbar_alignment", .keywords = i18n.msg("panel left center right") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar edge gap"), .target = "taskbar_edge_gap", .keywords = i18n.msg("panel margin") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar length"), .target = "taskbar_length", .keywords = i18n.msg("panel width") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar corner radius"), .target = "taskbar_radius", .keywords = i18n.msg("panel rounded") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar items"), .target = "@Taskbar", .heading = i18n.msg("Taskbar"), .keywords = i18n.msg("clock battery tray notifications capture") },
    .{ .page = .appearance, .title = i18n.msg("Bold clock"), .target = "clock_bold", .keywords = i18n.msg("time taskbar font") },
    .{ .page = .appearance, .title = i18n.msg("Italic clock"), .target = "clock_italic", .keywords = i18n.msg("time taskbar font") },
    .{ .page = .appearance, .title = i18n.msg("Start menu size"), .target = "start_menu_width", .keywords = i18n.msg("launcher width") },
    .{ .page = .appearance, .title = i18n.msg("Start menu height"), .target = "start_menu_height", .keywords = i18n.msg("launcher size") },
    .{ .page = .appearance, .title = i18n.msg("Start menu logo"), .target = "start_logo_tile", .keywords = i18n.msg("launcher icon image") },
    .{ .page = .appearance, .title = i18n.msg("Dock"), .target = "dock_enabled", .keywords = i18n.msg("enable apps launcher") },
    .{ .page = .appearance, .title = i18n.msg("Dock position"), .target = "dock_position", .keywords = i18n.msg("top bottom left right") },
    .{ .page = .appearance, .title = i18n.msg("Dock auto hide"), .target = "dock_auto_hide", .keywords = i18n.msg("hide automatically") },
    .{ .page = .appearance, .title = i18n.msg("Dock height"), .target = "dock_height", .keywords = i18n.msg("size") },
    .{ .page = .appearance, .title = i18n.msg("Dock hover zoom"), .target = "dock_hover_zoom", .keywords = i18n.msg("magnification mouse") },
    .{ .page = .appearance, .title = i18n.msg("Dock opacity"), .target = "dock_opacity", .keywords = i18n.msg("transparency") },
    .{ .page = .appearance, .title = i18n.msg("Dock corner radius"), .target = "dock_radius", .keywords = i18n.msg("rounded") },
    .{ .page = .appearance, .title = i18n.msg("Dock active highlight"), .target = "dock_active_highlight", .keywords = i18n.msg("running apps indicator") },
    .{ .page = .appearance, .title = i18n.msg("Dock trash"), .target = "dock_show_trash", .keywords = i18n.msg("recycle bin") },
    .{ .page = .shortcuts, .title = i18n.msg("Keyboard shortcuts"), .target = "@Keyboard Shortcuts", .heading = i18n.msg("Keyboard Shortcuts"), .keywords = i18n.msg("hotkeys keybindings bindings terminal screenshot volume brightness workspaces") },
    .{ .page = .desktop, .title = i18n.msg("Desktop mode"), .target = "desktop_mode", .keywords = i18n.msg("canvas workspaces tiling") },
    .{ .page = .desktop, .title = i18n.msg("Canvas size"), .target = "@Canvas Size", .heading = i18n.msg("Canvas Size"), .keywords = i18n.msg("rows columns panning area") },
    .{ .page = .desktop, .title = i18n.msg("Desktop switching"), .target = "@Desktop Switching", .heading = i18n.msg("Desktop Switching"), .keywords = i18n.msg("edge pan transitions") },
    .{ .page = .desktop, .title = i18n.msg("Mini map"), .target = "mini_map_enabled", .keywords = i18n.msg("minimap overview") },
    .{ .page = .desktop, .title = i18n.msg("Mini map position"), .target = "mini_map_position", .keywords = i18n.msg("overview location") },
    .{ .page = .desktop, .title = i18n.msg("Mini map hide delay"), .target = "mini_map_hide_ms", .keywords = i18n.msg("overview timeout") },
    .{ .page = .desktop, .title = i18n.msg("Fixed desktop icons"), .target = "desktop_icons_fixed", .keywords = i18n.msg("keep icons in place") },
    .{ .page = .desktop, .title = i18n.msg("Workspace layout"), .target = "@Workspace layout", .heading = i18n.msg("Workspace layout"), .keywords = i18n.msg("tiling master stack") },
    .{ .page = .desktop, .title = i18n.msg("Window spacing"), .target = "@Window spacing", .heading = i18n.msg("Window spacing"), .keywords = i18n.msg("gaps tiling") },
    .{ .page = .desktop, .title = i18n.msg("Floating apps"), .target = "@Floating apps", .heading = i18n.msg("Floating apps"), .keywords = i18n.msg("rules tiling windows") },
    .{ .page = .bluetooth, .title = i18n.msg("Bluetooth devices"), .target = "@Bluetooth", .heading = i18n.msg("Bluetooth"), .keywords = i18n.msg("wireless pairing paired headphones mouse keyboard") },
    .{ .page = .region, .title = i18n.msg("Application language"), .target = "language", .keywords = i18n.msg("locale translation") },
    .{ .page = .region, .title = i18n.msg("Regional formats"), .target = "formats", .keywords = i18n.msg("locale numbers currency dates") },
    .{ .page = .region, .title = i18n.msg("24-hour clock"), .target = "clock_24h", .keywords = i18n.msg("time am pm") },
    .{ .page = .region, .title = i18n.msg("Clock seconds"), .target = "clock_show_seconds", .keywords = i18n.msg("time") },
    .{ .page = .region, .title = i18n.msg("Clock day"), .target = "clock_show_day", .keywords = i18n.msg("date weekday") },
    .{ .page = .region, .title = i18n.msg("First day of week"), .target = "first_day_of_week", .keywords = i18n.msg("calendar monday sunday") },
    .{ .page = .users, .title = i18n.msg("Accounts"), .target = "@Accounts", .heading = i18n.msg("Accounts"), .keywords = i18n.msg("users login password administrator groups") },
    .{ .page = .users, .title = i18n.msg("Automatic login"), .target = "@Automatic login", .heading = i18n.msg("Automatic login"), .keywords = i18n.msg("autologin boot") },
    .{ .page = .printers, .title = i18n.msg("Printers"), .target = "@Printers", .heading = i18n.msg("Printers"), .keywords = i18n.msg("printing cups add queue jobs paper driver label") },
    .{ .page = .services, .title = i18n.msg("Services"), .target = "services_search", .keywords = i18n.msg("systemd startup boot daemon unit enabled failed slow") },
    .{ .page = .general, .title = i18n.msg("Desktop portals"), .target = "portal_default", .keywords = i18n.msg("backend gtk kde dialogs") },
    .{ .page = .general, .title = i18n.msg("File dialogs"), .target = "portal_file_chooser", .keywords = i18n.msg("chooser portal") },
    .{ .page = .general, .title = i18n.msg("Default file manager"), .target = "default_file_manager", .keywords = i18n.msg("files folders application") },
    .{ .page = .general, .title = i18n.msg("Default terminal"), .target = "default_terminal", .keywords = i18n.msg("application shell console") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar theme"), .target = "taskbar_theme", .keywords = i18n.msg("panel colors colours") },
    .{ .page = .appearance, .title = i18n.msg("Dark mode"), .target = "dark_mode", .keywords = i18n.msg("light appearance theme") },
    .{ .page = .appearance, .title = i18n.msg("Apply GTK colors"), .target = "apply_gtk_colors", .keywords = i18n.msg("application colours theme") },
    .{ .page = .appearance, .title = i18n.msg("Apply Qt colors"), .target = "apply_qt_colors", .keywords = i18n.msg("application colours theme") },
    .{ .page = .appearance, .title = i18n.msg("Launch splash"), .target = "launch_splash", .keywords = i18n.msg("startup welcome animation") },
    .{ .page = .appearance, .title = i18n.msg("Dodge file drags"), .target = "dodge_file_drags", .keywords = i18n.msg("drag drop windows") },
    .{ .page = .appearance, .title = i18n.msg("Dim inactive windows"), .target = "inactive_dim", .keywords = i18n.msg("unfocused darkness") },
    .{ .page = .appearance, .title = i18n.msg("Window tabs"), .target = "window_tabs", .keywords = i18n.msg("applications titlebar grouping") },
    .{ .page = .appearance, .title = i18n.msg("Snapped window gap"), .target = "@Snapped window gap", .heading = i18n.msg("Snapped window gap"), .keywords = i18n.msg("spacing tiled margin") },
    .{ .page = .appearance, .title = i18n.msg("Scrollbar width"), .target = "@Scrollbar width", .heading = i18n.msg("Scrollbar width"), .keywords = i18n.msg("thickness scrolling accessibility") },
    .{ .page = .appearance, .title = i18n.msg("Taskbar size"), .target = "@Taskbar size", .heading = i18n.msg("Taskbar size"), .keywords = i18n.msg("panel height") },
    .{ .page = .appearance, .title = i18n.msg("Window item width"), .target = "@Window item width", .heading = i18n.msg("Window item width"), .keywords = i18n.msg("taskbar chip size") },
    .{ .page = .appearance, .title = i18n.msg("Window item gap"), .target = "@Window item gap", .heading = i18n.msg("Window item gap"), .keywords = i18n.msg("taskbar chip spacing") },
    .{ .page = .appearance, .title = i18n.msg("Start button gap"), .target = "@Start button gap", .heading = i18n.msg("Start button gap"), .keywords = i18n.msg("taskbar launcher spacing") },
    .{ .page = .appearance, .title = i18n.msg("Start button icon size"), .target = "@Start button icon size", .heading = i18n.msg("Start button icon size"), .keywords = i18n.msg("logo launcher") },
    .{ .page = .appearance, .title = i18n.msg("Menu left padding"), .target = "@Menu left padding", .heading = i18n.msg("Menu left padding"), .keywords = i18n.msg("start menu spacing") },
    .{ .page = .appearance, .title = i18n.msg("Menu bottom padding"), .target = "@Menu bottom padding", .heading = i18n.msg("Menu bottom padding"), .keywords = i18n.msg("start menu spacing") },
    .{ .page = .appearance, .title = i18n.msg("Icon left padding"), .target = "@Icon left padding", .heading = i18n.msg("Icon left padding"), .keywords = i18n.msg("start menu spacing") },
    .{ .page = .appearance, .title = i18n.msg("Icon bottom padding"), .target = "@Icon bottom padding", .heading = i18n.msg("Icon bottom padding"), .keywords = i18n.msg("start menu spacing") },
    .{ .page = .appearance, .title = i18n.msg("Install theme"), .target = "theme_install", .keywords = i18n.msg("import pack") },
    .{ .page = .appearance, .title = i18n.msg("Remove theme"), .target = "theme_remove", .keywords = i18n.msg("delete pack") },
    .{ .page = .appearance, .title = i18n.msg("Save theme"), .target = "theme_export", .keywords = i18n.msg("export look") },
    .{ .page = .appearance, .title = i18n.msg("Reset theme"), .target = "theme_reset", .keywords = i18n.msg("defaults restore") },
};

pub const entries: [source_entries.len]Entry = blk: {
    var result: [source_entries.len]Entry = undefined;
    for (source_entries, 0..) |entry, id| result[id] = .{
        .page = entry.page,
        .title = entry.title.source,
        .target = entry.target,
        .keywords = entry.keywords.source,
    };
    break :blk result;
};

pub fn localizedEntry(id: usize) Entry {
    const entry = source_entries[id];
    return .{ .page = entry.page, .title = entry.title.get(), .target = entry.target, .keywords = entry.keywords.get() };
}

pub fn targetLabel(id: usize) []const u8 {
    return if (source_entries[id].heading) |heading| heading.get() else "";
}

/// Translated labels and keywords coexist with their English guide terms.
pub fn scoreLocalized(id: usize, query: []const u8, page_label: []const u8) ?u32 {
    return scorePair(localizedEntry(id), entries[id], query, page_label, .{ .turkish = i18n.isTurkish() });
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return needle.len > 0 and fold.contains(haystack, needle, .{ .turkish = @import("i18n").isTurkish() });
}

/// All words must match, including words supplied by the page or aliases.
/// Label matches outrank aliases; longer queries remain allocation-free.
pub fn score(entry: Entry, query: []const u8, page_label: []const u8) ?u32 {
    return scoreWithOptions(entry, query, page_label, .{ .turkish = @import("i18n").isTurkish() });
}

pub fn scoreWithOptions(entry: Entry, query: []const u8, page_label: []const u8, options: fold.Options) ?u32 {
    return scorePair(entry, entry, query, page_label, options);
}

fn scorePair(entry: Entry, english: Entry, query: []const u8, page_label: []const u8, options: fold.Options) ?u32 {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var total: u32 = 0;
    var count: usize = 0;
    while (words.next()) |word| {
        count += 1;
        if (fold.contains(entry.title, word, options) or fold.contains(english.title, word, options)) total += 8 else if (fold.contains(page_label, word, options)) total += 2 else if (fold.contains(entry.keywords, word, options) or fold.contains(english.keywords, word, options)) total += 1 else return null;
    }
    if (count == 0) return null;
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (fold.eql(entry.title, trimmed, options) or fold.eql(english.title, trimmed, options)) total += 100;
    if (entry.target.len > 0) total += 1;
    return total;
}

test "settings search ranks labels, combines words and resolves aliases" {
    const entry: Entry = .{ .page = .input, .title = "Natural scroll", .target = "natural_scroll", .keywords = "reverse direction touchpad" };
    try std.testing.expect(score(entry, "  SCROLL input  ", "Input") != null);
    try std.testing.expect(score(entry, "reverse touchpad", "Input") != null);
    try std.testing.expect(score(entry, "scroll printer", "Input") == null);
    try std.testing.expect(score(entry, "  ", "Input") == null);
    try std.testing.expect(score(entry, "natural scroll", "Input").? > score(entry, "direction", "Input").?);
    // Targets are unique within a page, apart from explicit page entries.
    for (entries, 0..) |a, i| for (entries[i + 1 ..]) |b| {
        try std.testing.expect(a.page != b.page or !std.mem.eql(u8, a.target, b.target));
    };
}

test "settings search folds translated titles keywords and page labels" {
    const entry: Entry = .{ .page = .input, .title = "Cámara", .target = "camera", .keywords = "Терминал Straße" };
    try std.testing.expect(scoreWithOptions(entry, "CAMARA", "Écran", .{}) != null);
    try std.testing.expect(scoreWithOptions(entry, "ecran терм strasse", "Écran", .{}) != null);
    try std.testing.expect(scoreWithOptions(entry, "cámara", "Écran", .{}).? > scoreWithOptions(entry, "cam", "Écran", .{}).?);
    const turkish: Entry = .{ .page = .input, .title = "IŞIK" };
    try std.testing.expect(scoreWithOptions(turkish, "ışık", "", .{ .turkish = true }) != null);
    try std.testing.expect(scoreWithOptions(turkish, "ışık", "", .{}) == null);
}

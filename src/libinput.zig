// Thin wrapper around the subset of libinput's device-config API the control
// center's Input section needs (pointer accel speed, natural scroll,
// tap-to-click). libinput.h is a clean, glib-free C API (unlike librsvg, see
// AGENTS.md, "Build and platform gotchas") so it's @cInclude'd directly rather than hand-declared.
//
// `wlr.InputDevice.getLibinputDevice()` returns a pointer to an opaque type
// private to zig-wlroots' own bindings; since it carries no fields on either
// side, a plain `@ptrCast` onto libinput.h's own `struct libinput_device*`
// is safe and avoids needing to name that private type at all.
const wlr = @import("wlroots");
const c = @cImport({
    @cInclude("libinput.h");
});

fn handle(device: *wlr.InputDevice) ?*c.libinput_device {
    const raw = device.getLibinputDevice() orelse return null;
    return @ptrCast(raw);
}

pub fn getPointerSpeed(device: *wlr.InputDevice) ?f64 {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_accel_is_available(dev) == 0) return null;
    return c.libinput_device_config_accel_get_speed(dev);
}

pub fn isTouchpad(device: *wlr.InputDevice) bool {
    const dev = handle(device) orelse return false;
    if (c.libinput_device_config_tap_get_finger_count(dev) > 0) return true;
    return c.libinput_device_has_capability(dev, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0;
}

pub fn setPointerSpeed(device: *wlr.InputDevice, speed: f64) void {
    const dev = handle(device) orelse return;
    if (c.libinput_device_config_accel_is_available(dev) == 0) return;
    _ = c.libinput_device_config_accel_set_speed(dev, speed);
}

pub fn getNaturalScroll(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_scroll_has_natural_scroll(dev) == 0) return null;
    return c.libinput_device_config_scroll_get_natural_scroll_enabled(dev) != 0;
}

pub fn setNaturalScroll(device: *wlr.InputDevice, on: bool) void {
    const dev = handle(device) orelse return;
    if (c.libinput_device_config_scroll_has_natural_scroll(dev) == 0) return;
    _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(dev, if (on) 1 else 0);
}

pub fn getTapToClick(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return null;
    return c.libinput_device_config_tap_get_enabled(dev) == c.LIBINPUT_CONFIG_TAP_ENABLED;
}

pub fn getDisableWhileTyping(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_dwt_is_available(dev) == 0) return null;
    return c.libinput_device_config_dwt_get_enabled(dev) == c.LIBINPUT_CONFIG_DWT_ENABLED;
}

pub fn setTapToClick(device: *wlr.InputDevice, on: bool) void {
    const dev = handle(device) orelse return;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return;
    const state: c.enum_libinput_config_tap_state = if (on) c.LIBINPUT_CONFIG_TAP_ENABLED else c.LIBINPUT_CONFIG_TAP_DISABLED;
    _ = c.libinput_device_config_tap_set_enabled(dev, state);
}

pub fn setTapDrag(device: *wlr.InputDevice, on: bool) void {
    const dev = handle(device) orelse return;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return;
    const state: c.enum_libinput_config_drag_state = if (on) c.LIBINPUT_CONFIG_DRAG_ENABLED else c.LIBINPUT_CONFIG_DRAG_DISABLED;
    _ = c.libinput_device_config_tap_set_drag_enabled(dev, state);
}

// DWT runs inside libinput and requires keyboard/touchpad pairing: an enabled
// flag alone does not prove typing is being suppressed. The ASUS USB keyboard
// 0b05:19b6 needs the installed 50-system-asus.quirks entry marking it internal.
// A malformed /etc/libinput/local-overrides.quirks can prevent the entire quirks
// database from loading, including that pairing fix. On our host this path was
// a directory, misleadingly reported by libinput 1.31.3 as "is an empty file".
// Diagnose with `libinput quirks validate --verbose`, then
// `libinput quirks list /dev/input/eventN` for the keyboard. Preserve the bad
// override under a backup name, validate again, and restart the compositor to
// recreate its libinput context. Test with `libinput debug-events --enable-dwt
// --show-keycodes --verbose` while typing and moving on the touchpad's center;
// edge-palm rejection alone is not evidence of DWT. This command creates its
// own context, so its enabled state does not verify the compositor's setting.
pub fn setDisableWhileTyping(device: *wlr.InputDevice, on: bool) void {
    const dev = handle(device) orelse return;
    if (c.libinput_device_config_dwt_is_available(dev) == 0) return;
    const state: c.enum_libinput_config_dwt_state = if (on) c.LIBINPUT_CONFIG_DWT_ENABLED else c.LIBINPUT_CONFIG_DWT_DISABLED;
    _ = c.libinput_device_config_dwt_set_enabled(dev, state);
}

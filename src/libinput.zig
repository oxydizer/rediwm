// Pointer identity, presentation and the libinput device-config API used by
// Control Center. libinput.h is a clean, glib-free C API (unlike librsvg, see
// AGENTS.md, "Build and platform gotchas") so it's translated directly rather than hand-declared.
//
// `wlr.InputDevice.getLibinputDevice()` returns a pointer to an opaque type
// from the wlroots facade's C import; since it carries no fields on either
// side, a plain `@ptrCast` onto libinput.h's own `struct libinput_device*`
// is safe and avoids needing to name that private type at all.
const wlr = @import("wlroots");
const c = @import("c_libinput");
const std = @import("std");
const identity = @import("pointer_identity.zig");
const presentation = @import("pointer_presentation.zig");

pub const Identity = identity.Identity;
pub const Kind = presentation.Kind;
pub const SetResult = enum { applied, unsupported, failed };

fn result(status: c.enum_libinput_config_status) SetResult {
    return switch (status) {
        c.LIBINPUT_CONFIG_STATUS_SUCCESS => .applied,
        c.LIBINPUT_CONFIG_STATUS_UNSUPPORTED => .unsupported,
        else => .failed,
    };
}

fn handle(device: *wlr.InputDevice) ?*c.libinput_device {
    const raw = device.getLibinputDevice() orelse return null;
    return @ptrCast(raw);
}

/// Borrowed strings: copy before retaining beyond the live device's lifetime.
pub fn getName(device: *wlr.InputDevice) ?[]const u8 {
    const dev = handle(device) orelse return null;
    return std.mem.span(c.libinput_device_get_name(dev));
}

pub fn getSysname(device: *wlr.InputDevice) ?[]const u8 {
    const dev = handle(device) orelse return null;
    return std.mem.span(c.libinput_device_get_sysname(dev));
}

/// Owned display text; the caller can retain it after removal of the device.
pub fn getFriendlyName(a: std.mem.Allocator, device: *wlr.InputDevice) !?[]const u8 {
    const dev = handle(device) orelse return presentation.friendlyName(a, .{
        .primary = if (device.name) |name| std.mem.span(name) else null,
    });
    const primary = std.mem.span(c.libinput_device_get_name(dev));
    if (try presentation.friendlyName(a, .{ .primary = primary })) |name| return name;
    const udev = c.libinput_device_get_udev_device(dev) orelse return null;
    defer _ = c.udev_device_unref(udev);
    return presentation.friendlyName(a, .{
        .vendor = property(udev, "ID_VENDOR_FROM_DATABASE") orelse property(udev, "ID_VENDOR"),
        .model = property(udev, "ID_MODEL_FROM_DATABASE") orelse property(udev, "ID_MODEL"),
    });
}

/// ID_INPUT_TRACKBALL is supplied by systemd's 70-mouse.hwdb. It recognizes
/// devices such as the Kensington Expert Mouse whose names omit "trackball".
/// Libinput's private ModelTrackball quirks are not a public classification API.
pub fn getKind(device: *wlr.InputDevice) Kind {
    const dev = handle(device) orelse return .pointer;
    var tags: presentation.Tags = .{ .tap = c.libinput_device_config_tap_get_finger_count(dev) > 0 };
    if (c.libinput_device_get_udev_device(dev)) |udev| {
        defer _ = c.udev_device_unref(udev);
        tags.touchpad = propertyFlag(udev, "ID_INPUT_TOUCHPAD");
        tags.trackball = propertyFlag(udev, "ID_INPUT_TRACKBALL");
        tags.mouse = propertyFlag(udev, "ID_INPUT_MOUSE");
    }
    return presentation.classify(tags);
}

/// Settings defaults to physical pointing devices. Composite HID keyboards
/// can expose wheels and even full mouse reports for macros; leave those in
/// the optional full list. Never filter a touchpad, trackball or pointing stick
/// merely because it shares a keyboard interface.
pub fn isSettingsPointer(device: *wlr.InputDevice) bool {
    const dev = handle(device) orelse return false;
    const kind = getKind(device);
    if (kind == .touchpad or kind == .trackball) return true;
    if (c.libinput_device_get_udev_device(dev)) |udev| {
        defer _ = c.udev_device_unref(udev);
        if (propertyFlag(udev, "ID_INPUT_POINTINGSTICK")) return true;
        if (std.mem.eql(u8, ancestorAttribute(udev, "bInterfaceClass") orelse "", "03") and
            std.mem.eql(u8, ancestorAttribute(udev, "bInterfaceProtocol") orelse "", "01")) return false;
    }
    if (kind == .mouse) return true;
    if (c.libinput_device_has_capability(dev, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0) return false;
    return getPointerSpeed(device) != null or getNaturalScroll(device) != null or getLeftHanded(device) != null;
}

/// Some touchpads expose a second, compatibility mouse interface. Only hide
/// that interface when its actual touchpad is connected in the same libinput
/// group. A paired pointing stick is a separate physical control.
pub fn isTouchpadCompanion(device: *wlr.InputDevice, touchpad: *wlr.InputDevice) bool {
    if (getKind(device) != .mouse or getKind(touchpad) != .touchpad) return false;
    const dev = handle(device) orelse return false;
    const pad = handle(touchpad) orelse return false;
    if (c.libinput_device_get_udev_device(dev)) |udev| {
        defer _ = c.udev_device_unref(udev);
        if (propertyFlag(udev, "ID_INPUT_POINTINGSTICK")) return false;
    }
    const group = c.libinput_device_get_device_group(dev) orelse return false;
    return group == c.libinput_device_get_device_group(pad);
}

/// The returned key owns its bytes and survives removal of the libinput device.
/// No sysname, sysfs input number, pointer address, or connection index is used.
pub fn getIdentity(device: *wlr.InputDevice) ?Identity {
    const dev = handle(device) orelse return null;
    const udev = c.libinput_device_get_udev_device(dev) orelse return null;
    defer _ = c.udev_device_unref(udev);
    return identity.build(.{
        .bus = busType(dev, udev) orelse return null,
        .vendor = c.libinput_device_get_id_vendor(dev),
        .product = c.libinput_device_get_id_product(dev),
        .name = std.mem.span(c.libinput_device_get_name(dev)),
        .uniq = ancestorAttribute(udev, "uniq"),
        .serial = property(udev, "ID_SERIAL_SHORT"),
        .interface = property(udev, "ID_USB_INTERFACE_NUM") orelse ancestorAttribute(udev, "bInterfaceNumber"),
        .path = property(udev, "ID_PATH"),
    });
}

/// libinput_device_get_id_bustype() is new in libinput 1.26 (Ubuntu 24.04 has
/// 1.25). Older headers read the same value, the kernel's input_id.bustype, from
/// the input device's sysfs `id/bustype` (hex), which is what udev rules match.
fn busType(dev: *c.libinput_device, udev: *c.udev_device) ?u32 {
    if (@hasDecl(c, "libinput_device_get_id_bustype")) return c.libinput_device_get_id_bustype(dev);
    const text = ancestorAttribute(udev, "id/bustype") orelse return null;
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " \n"), 16) catch null;
}

fn property(device: *c.udev_device, key: [*:0]const u8) ?[]const u8 {
    const value = c.udev_device_get_property_value(device, key) orelse return null;
    return std.mem.span(value);
}

fn propertyFlag(device: *c.udev_device, key: [*:0]const u8) bool {
    return std.mem.eql(u8, property(device, key) orelse "", "1");
}

fn ancestorAttribute(device: *c.udev_device, key: [*:0]const u8) ?[]const u8 {
    var ancestor: ?*c.udev_device = device;
    while (ancestor) |current| : (ancestor = c.udev_device_get_parent(current)) {
        if (c.udev_device_get_sysattr_value(current, key)) |value| {
            const bytes = std.mem.span(value);
            if (bytes.len != 0) return bytes;
        }
    }
    return null;
}

pub fn getPointerSpeed(device: *wlr.InputDevice) ?f64 {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_accel_is_available(dev) == 0) return null;
    return c.libinput_device_config_accel_get_speed(dev);
}

pub fn isTouchpad(device: *wlr.InputDevice) bool {
    return getKind(device) == .touchpad;
}

pub fn setPointerSpeed(device: *wlr.InputDevice, speed: f64) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_accel_is_available(dev) == 0) return .unsupported;
    if (!std.math.isFinite(speed) or speed < -1 or speed > 1) return .failed;
    return result(c.libinput_device_config_accel_set_speed(dev, speed));
}

pub fn getNaturalScroll(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_scroll_has_natural_scroll(dev) == 0) return null;
    return c.libinput_device_config_scroll_get_natural_scroll_enabled(dev) != 0;
}

pub fn setNaturalScroll(device: *wlr.InputDevice, on: bool) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_scroll_has_natural_scroll(dev) == 0) return .unsupported;
    return result(c.libinput_device_config_scroll_set_natural_scroll_enabled(dev, if (on) 1 else 0));
}

pub fn getLeftHanded(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_left_handed_is_available(dev) == 0) return null;
    return c.libinput_device_config_left_handed_get(dev) != 0;
}

pub fn setLeftHanded(device: *wlr.InputDevice, on: bool) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_left_handed_is_available(dev) == 0) return .unsupported;
    return result(c.libinput_device_config_left_handed_set(dev, if (on) 1 else 0));
}

pub fn getTapToClick(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return null;
    return c.libinput_device_config_tap_get_enabled(dev) == c.LIBINPUT_CONFIG_TAP_ENABLED;
}

pub fn getTapDrag(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return null;
    return c.libinput_device_config_tap_get_drag_enabled(dev) == c.LIBINPUT_CONFIG_DRAG_ENABLED;
}

pub fn getDisableWhileTyping(device: *wlr.InputDevice) ?bool {
    const dev = handle(device) orelse return null;
    if (c.libinput_device_config_dwt_is_available(dev) == 0) return null;
    return c.libinput_device_config_dwt_get_enabled(dev) == c.LIBINPUT_CONFIG_DWT_ENABLED;
}

pub fn setTapToClick(device: *wlr.InputDevice, on: bool) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return .unsupported;
    const state: c.enum_libinput_config_tap_state = if (on) c.LIBINPUT_CONFIG_TAP_ENABLED else c.LIBINPUT_CONFIG_TAP_DISABLED;
    return result(c.libinput_device_config_tap_set_enabled(dev, state));
}

pub fn setTapDrag(device: *wlr.InputDevice, on: bool) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_tap_get_finger_count(dev) == 0) return .unsupported;
    const state: c.enum_libinput_config_drag_state = if (on) c.LIBINPUT_CONFIG_DRAG_ENABLED else c.LIBINPUT_CONFIG_DRAG_DISABLED;
    return result(c.libinput_device_config_tap_set_drag_enabled(dev, state));
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
pub fn setDisableWhileTyping(device: *wlr.InputDevice, on: bool) SetResult {
    const dev = handle(device) orelse return .unsupported;
    if (c.libinput_device_config_dwt_is_available(dev) == 0) return .unsupported;
    const state: c.enum_libinput_config_dwt_state = if (on) c.LIBINPUT_CONFIG_DWT_ENABLED else c.LIBINPUT_CONFIG_DWT_DISABLED;
    return result(c.libinput_device_config_dwt_set_enabled(dev, state));
}

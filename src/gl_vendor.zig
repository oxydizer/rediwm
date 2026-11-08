//! glvnd's libEGL loads every vendor library it finds, in file-name order, at
//! the first EGL call. The NVIDIA one drags in tens of MiB of driver
//! (`libnvidia-eglcore`, `libnvidia-gpucomp`) that is read from disk and
//! relocated even when there is no NVIDIA GPU to use it: on the live medium
//! that is ~90 MiB of squashfs reads and 0.6-1.2 s of every boot, and the
//! greeter and the session both pay it.
//!
//! So when the machine has no NVIDIA GPU, EGL is told to use every vendor file
//! except NVIDIA's. The decision needs positive proof of absence: unreadable
//! sysfs, a loaded `nvidia` module or `/dev/nvidiactl` all leave glvnd alone.
//! A GPU plugged in after start (Thunderbolt eGPU) is not seen by this process
//! until the compositor restarts.
const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.gl_vendor);

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const filenames_env = "__EGL_VENDOR_LIBRARY_FILENAMES";
const dirs_env = "__EGL_VENDOR_LIBRARY_DIRS";
/// glvnd's default search path, /etc first: a file there hides one of the same
/// name below it.
const search_dirs = [_][]const u8{ "/etc/glvnd/egl_vendor.d", "/usr/share/glvnd/egl_vendor.d" };
const max_vendors = 16;
const nvidia_pci_vendor = "0x10de";

pub const Vendor = struct {
    dir: []const u8,
    name: []const u8,
    nvidia: bool,
};

/// Call before anything can reach EGL. An environment the user or a packager
/// set (either variable) is never overridden.
pub fn skipAbsentNvidia(io: Io, environ: std.process.Environ) void {
    if (environ.getPosix(filenames_env) != null or environ.getPosix(dirs_env) != null) return;
    if (nvidiaMayBePresent(io)) return;

    var names: [max_vendors][64]u8 = undefined;
    var vendors: [max_vendors]Vendor = undefined;
    var count: usize = 0;
    for (search_dirs) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json") or entry.name.len > names[0].len) continue;
            if (hidden(vendors[0..count], entry.name)) continue;
            // More vendors than any machine has: not a layout to second-guess.
            if (count == max_vendors) return;
            var contents: [2048]u8 = undefined;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch return;
            const text = Io.Dir.cwd().readFile(io, path, &contents) catch return;
            @memcpy(names[count][0..entry.name.len], entry.name);
            vendors[count] = .{
                .dir = dir_path,
                .name = names[count][0..entry.name.len],
                // By name too: a vendor file can be a stub with no library path.
                .nvidia = std.ascii.findIgnoreCase(entry.name, "nvidia") != null or
                    std.ascii.findIgnoreCase(text, "nvidia") != null,
            };
            count += 1;
        }
    }

    var list: [max_vendors * 128]u8 = undefined;
    const joined = withoutNvidia(vendors[0..count], &list) orelse return;
    if (setenv(filenames_env, joined.ptr, 0) != 0) return;
    log.info("no NVIDIA GPU: EGL vendors limited to {s}", .{joined});
}

fn hidden(seen: []const Vendor, name: []const u8) bool {
    for (seen) |v| if (std.mem.eql(u8, v.name, name)) return true;
    return false;
}

/// The vendor files glvnd should use, `dir/name:dir/name` in file-name order
/// as glvnd would load them; null when that would not differ from its own
/// search (no NVIDIA file) or would leave it nothing.
pub fn withoutNvidia(vendors: []Vendor, buf: []u8) ?[:0]const u8 {
    var any_nvidia = false;
    for (vendors) |v| any_nvidia = any_nvidia or v.nvidia;
    if (!any_nvidia) return null;
    std.mem.sort(Vendor, vendors, {}, struct {
        fn less(_: void, a: Vendor, b: Vendor) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var len: usize = 0;
    for (vendors) |v| {
        if (v.nvidia) continue;
        const sep: []const u8 = if (len == 0) "" else ":";
        const piece = std.fmt.bufPrint(buf[len..], "{s}{s}/{s}", .{ sep, v.dir, v.name }) catch return null;
        len += piece.len;
    }
    if (len == 0 or len >= buf.len) return null;
    buf[len] = 0;
    return buf[0..len :0];
}

/// False only when the PCI bus was read completely and has no NVIDIA device.
fn nvidiaMayBePresent(io: Io) bool {
    const cwd = Io.Dir.cwd();
    // The driver may be loaded for a device that is not on the PCI bus.
    for ([_][]const u8{ "/sys/module/nvidia", "/dev/nvidiactl" }) |path| {
        if (cwd.access(io, path, .{})) |_| return true else |_| {}
    }
    var dir = cwd.openDir(io, "/sys/bus/pci/devices", .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return true) |entry| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/vendor", .{entry.name}) catch return true;
        var buf: [16]u8 = undefined;
        const text = dir.readFile(io, path, &buf) catch return true;
        if (std.mem.eql(u8, std.mem.trim(u8, text, " \r\n"), nvidia_pci_vendor)) return true;
    }
    return false;
}

test "withoutNvidia keeps glvnd's order and drops NVIDIA's vendor" {
    var buf: [256]u8 = undefined;
    var v = [_]Vendor{
        .{ .dir = "/usr/share/glvnd/egl_vendor.d", .name = "50_mesa.json", .nvidia = false },
        .{ .dir = "/usr/share/glvnd/egl_vendor.d", .name = "10_nvidia.json", .nvidia = true },
        .{ .dir = "/etc/glvnd/egl_vendor.d", .name = "20_other.json", .nvidia = false },
    };
    try std.testing.expectEqualStrings(
        "/etc/glvnd/egl_vendor.d/20_other.json:/usr/share/glvnd/egl_vendor.d/50_mesa.json",
        withoutNvidia(&v, &buf).?,
    );
    // Nothing to drop, or nothing left: glvnd's own search stays in charge.
    var mesa_only = [_]Vendor{.{ .dir = "/usr/share/glvnd/egl_vendor.d", .name = "50_mesa.json", .nvidia = false }};
    try std.testing.expect(withoutNvidia(&mesa_only, &buf) == null);
    var nvidia_only = [_]Vendor{.{ .dir = "/usr/share/glvnd/egl_vendor.d", .name = "10_nvidia.json", .nvidia = true }};
    try std.testing.expect(withoutNvidia(&nvidia_only, &buf) == null);
}

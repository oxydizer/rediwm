//! Optional footer telemetry, sampled only by the monitor's active worker.
const std = @import("std");
const common = @import("proc_common.zig");
const c = common.c;

pub fn sample(buf: []u8) common.System {
    var result: common.System = .{};
    const cpus = c.sysconf(c._SC_NPROCESSORS_ONLN);
    if (cpus > 0) result.logical_cpus = @intCast(cpus);
    if (number("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", buf)) |khz| {
        if (khz > 0) result.frequency_ghz = khz / 1_000_000;
    }
    if (common.readAt(c.AT_FDCWD, "/proc/uptime", buf)) |bytes| {
        var fields = std.mem.tokenizeAny(u8, bytes, " \t\n");
        if (fields.next()) |value| {
            const seconds = std.fmt.parseFloat(f64, value) catch -1;
            if (std.math.isFinite(seconds) and seconds >= 0 and seconds < 1e15)
                result.uptime_seconds = @intFromFloat(seconds);
        }
    } else |_| {}
    if (common.readAt(c.AT_FDCWD, "/proc/net/dev", buf)) |bytes| {
        result.network = parseNetwork(bytes);
    } else |_| {}
    result.temperature_c = temperature(buf);
    return result;
}

pub fn parseNetwork(bytes: []const u8) ?common.Network {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (std.mem.indexOf(u8, lines.next() orelse return null, "Inter-") == null) return null;
    if (std.mem.indexOf(u8, lines.next() orelse return null, "bytes") == null) return null;
    var result: common.Network = .{};
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse return null;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, name, "lo")) continue;
        if (name.len == 0) return null;
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        for (0..16) |index| {
            const value = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
            if (index == 0) result.received = std.math.add(u64, result.received, value) catch return null;
            if (index == 8) result.sent = std.math.add(u64, result.sent, value) catch return null;
        }
        // Independent of enumeration order, but changes on add/remove/rename.
        result.interfaces +%= std.hash.Wyhash.hash(0, name);
    }
    return result;
}

fn number(path: [*:0]const u8, buf: []u8) ?f64 {
    const bytes = common.readAt(c.AT_FDCWD, path, buf) catch return null;
    const value = std.fmt.parseFloat(f64, std.mem.trim(u8, bytes, " \t\n")) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

/// Only CPU sensors: do not silently substitute a disk, GPU or ACPI sensor.
fn temperature(buf: []u8) ?f64 {
    var hottest: ?f64 = null;
    const dir = c.opendir("/sys/class/hwmon") orelse return thermalTemperature(buf);
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (!std.mem.startsWith(u8, name, "hwmon")) continue;
        var path_buf: [512]u8 = undefined;
        const driver_path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/hwmon/{s}/name", .{name}, 0) catch continue;
        const driver = std.mem.trim(u8, common.readAt(c.AT_FDCWD, driver_path, buf) catch continue, " \n");
        if (!std.mem.eql(u8, driver, "coretemp") and !std.mem.eql(u8, driver, "k10temp") and !std.mem.eql(u8, driver, "zenpower")) continue;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/hwmon/{s}", .{name}, 0) catch continue;
        const sensors = c.opendir(path) orelse continue;
        defer _ = c.closedir(sensors);
        while (c.readdir(sensors)) |sensor| {
            const file = std.mem.sliceTo(sensor.*.d_name[0..], 0);
            if (!std.mem.startsWith(u8, file, "temp") or !std.mem.endsWith(u8, file, "_input")) continue;
            const input = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/hwmon/{s}/{s}", .{ name, file }, 0) catch continue;
            keepTemperature(&hottest, number(input, buf));
        }
    }
    return hottest orelse thermalTemperature(buf);
}

fn thermalTemperature(buf: []u8) ?f64 {
    var hottest: ?f64 = null;
    const dir = c.opendir("/sys/class/thermal") orelse return null;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        if (!std.mem.startsWith(u8, name, "thermal_zone")) continue;
        var path_buf: [512]u8 = undefined;
        const type_path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/thermal/{s}/type", .{name}, 0) catch continue;
        const kind = std.mem.trim(u8, common.readAt(c.AT_FDCWD, type_path, buf) catch continue, " \n");
        if (!std.mem.eql(u8, kind, "x86_pkg_temp") and !std.mem.eql(u8, kind, "cpu-thermal") and !std.mem.startsWith(u8, kind, "cpu_thermal")) continue;
        const input = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/thermal/{s}/temp", .{name}, 0) catch continue;
        keepTemperature(&hottest, number(input, buf));
    }
    return hottest;
}

fn keepTemperature(hottest: *?f64, millidegrees: ?f64) void {
    const value = (millidegrees orelse return) / 1000;
    if (value < -50 or value > 200) return;
    hottest.* = @max(hottest.* orelse value, value);
}

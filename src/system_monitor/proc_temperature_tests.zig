const std = @import("std");
const linux = @import("proc_linux_system.zig");

test "CPU and GPU temperatures stay separate, reject invalid sensors and handle disappearance" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = .{
        .{ "hwmon/hwmon0/name", "coretemp\n" },
        .{ "hwmon/hwmon0/temp1_input", "51000\n" },
        .{ "hwmon/hwmon0/temp2_input", "63000\n" },
        .{ "hwmon/hwmon1/name", "amdgpu\n" },
        .{ "hwmon/hwmon1/temp1_input", "72000\n" },
        .{ "hwmon/hwmon1/temp2_input", "99000\n" }, // Junction.
        .{ "hwmon/hwmon1/temp3_input", "105000\n" }, // VRAM.
        .{ "hwmon/hwmon2/name", "nvme\n" },
        .{ "hwmon/hwmon2/temp1_input", "120000\n" },
        .{ "hwmon/hwmon3/name", "i915\n" },
        .{ "hwmon/hwmon3/temp1_input", "80000\n" },
        .{ "hwmon/hwmon4/name", "nouveau\n" },
        .{ "hwmon/hwmon4/temp1_input", "nan\n" },
        .{ "thermal/thermal_zone0/type", "acpitz\n" },
        .{ "thermal/thermal_zone0/temp", "110000\n" },
        .{ "thermal/thermal_zone1/type", "x86_pkg_temp\n" },
        .{ "thermal/thermal_zone1/temp", "65000\n" },
    };
    inline for (files) |file| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(file[0]).?);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var hwmon_buf: [1024]u8 = undefined;
    var thermal_buf: [1024]u8 = undefined;
    const hwmon = try std.fmt.bufPrintSentinel(&hwmon_buf, "{s}/hwmon", .{root}, 0);
    const thermal = try std.fmt.bufPrintSentinel(&thermal_buf, "{s}/thermal", .{root}, 0);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqual(linux.Temperatures{ .cpu = 63, .gpu = 80 }, linux.readTemperatures(hwmon, thermal, &buf));
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon/hwmon0/temp1_input", .data = "-999999\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon/hwmon0/temp2_input", .data = "garbage\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon/hwmon3/temp1_input", .data = "201000\n" });
    try std.testing.expectEqual(linux.Temperatures{ .cpu = 65, .gpu = 72 }, linux.readTemperatures(hwmon, thermal, &buf));
    try tmp.dir.deleteTree(io, "hwmon");
    try std.testing.expectEqual(linux.Temperatures{ .cpu = 65 }, linux.readTemperatures(hwmon, thermal, &buf));
    try tmp.dir.deleteTree(io, "thermal/thermal_zone1");
    try std.testing.expectEqual(linux.Temperatures{}, linux.readTemperatures(hwmon, thermal, &buf));
}

//! Optional NVIDIA telemetry. The collector owns this handle only while active;
//! no subprocess, timer, mandatory driver library or process-lifetime cache.
const std = @import("std");
const builtin = @import("builtin");

const Device = ?*opaque {};
const Init = *const fn () callconv(.c) c_uint;
const Count = *const fn (*c_uint) callconv(.c) c_uint;
const Handle = *const fn (c_uint, *Device) callconv(.c) c_uint;
const Temperature = *const fn (Device, c_uint, *c_uint) callconv(.c) c_uint;

pub const Reader = struct {
    library: ?std.DynLib = null,
    shutdown: Init,
    count: Count,
    handle: Handle,
    temperature: Temperature,

    pub fn init() ?Reader {
        if (builtin.os.tag != .linux) return null;
        var library = std.DynLib.open("libnvidia-ml.so.1") catch return null;
        var keep = false;
        defer if (!keep) library.close();
        const initialize = library.lookup(Init, "nvmlInit_v2") orelse return null;
        const shutdown = library.lookup(Init, "nvmlShutdown") orelse return null;
        const count = library.lookup(Count, "nvmlDeviceGetCount_v2") orelse return null;
        const handle = library.lookup(Handle, "nvmlDeviceGetHandleByIndex_v2") orelse return null;
        const temperature = library.lookup(Temperature, "nvmlDeviceGetTemperature") orelse return null;
        if (initialize() != 0) return null;
        keep = true;
        return .{ .library = library, .shutdown = shutdown, .count = count, .handle = handle, .temperature = temperature };
    }

    pub fn deinit(self: *Reader) void {
        _ = self.shutdown();
        if (self.library) |*library| library.close();
        self.library = null;
    }

    pub fn sample(self: *const Reader) ?f64 {
        var count: c_uint = 0;
        if (self.count(&count) != 0) return null;
        var hottest: ?f64 = null;
        for (0..@min(count, 64)) |index| {
            var device: Device = null;
            if (self.handle(@intCast(index), &device) != 0 or device == null) continue;
            var degrees: c_uint = 0;
            // NVML_TEMPERATURE_GPU = 0; NVML reports whole degrees Celsius.
            if (self.temperature(device, 0, &degrees) != 0 or degrees > 200) continue;
            const value: f64 = @floatFromInt(degrees);
            hottest = @max(hottest orelse value, value);
        }
        return hottest;
    }
};

test "GPU queries skip unsupported devices, select hottest valid die and release NVML" {
    const Fake = struct {
        var stopped: bool = false;
        fn shutdown() callconv(.c) c_uint {
            stopped = true;
            return 0;
        }
        fn count(value: *c_uint) callconv(.c) c_uint {
            value.* = 4;
            return 0;
        }
        fn handle(index: c_uint, value: *Device) callconv(.c) c_uint {
            value.* = @ptrFromInt(index + 1);
            return 0;
        }
        fn temperature(device: Device, sensor: c_uint, value: *c_uint) callconv(.c) c_uint {
            if (sensor != 0) return 1;
            const id = @intFromPtr(device.?);
            if (id == 1) return 3; // Unsupported; another GPU still works.
            value.* = switch (id) {
                2 => 61,
                3 => 74,
                else => 999,
            };
            return 0;
        }
    };
    var reader: Reader = .{ .shutdown = Fake.shutdown, .count = Fake.count, .handle = Fake.handle, .temperature = Fake.temperature };
    try std.testing.expectEqual(@as(?f64, 74), reader.sample());
    reader.deinit();
    try std.testing.expect(Fake.stopped);
}

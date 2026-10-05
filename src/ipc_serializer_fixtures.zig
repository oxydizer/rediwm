// Shared representative data for serializer compatibility tests. The baseline
// JSON was captured before replacing the manual encoders. Exercise both null
// and populated optional fields, nested arrays, and escaped strings.
const std = @import("std");
pub fn sample(comptime T: type, comptime populated: bool) T {
    return comptime switch (@typeInfo(T)) {
        .void => {},
        .bool => populated,
        .int => if (populated) 7 else 0,
        .float => if (populated) 1.23456 else 0,
        .optional => |o| if (populated) sample(o.child, populated) else null,
        .@"enum" => std.meta.tags(T)[0],
        .array => |a| [_]a.child{sample(a.child, populated)} ** a.len,
        .pointer => |p| if (p.size == .slice)
            (if (p.child == u8) "text \"quoted\"\n\\" else &[_]p.child{sample(p.child, populated)})
        else
            @compileError("add pointer fixture for " ++ @typeName(T)),
        .@"struct" => blk: {
            var value: T = undefined;
            for (std.meta.fields(T)) |f| {
                if (std.mem.eql(u8, f.name, "placeholder") or std.mem.eql(u8, f.name, "tab_group") or (@hasField(T, "tab_group") and (std.mem.eql(u8, f.name, "tag") or std.mem.eql(u8, f.name, "description") or std.mem.eql(u8, f.name, "content_type")))) {
                    @field(value, f.name) = null;
                } else {
                    @field(value, f.name) = sample(f.type, populated);
                }
            }
            break :blk value;
        },
        else => @compileError("add serializer fixture for " ++ @typeName(T)),
    };
}

/// STD
const std = @import("std");

pub fn getVersion() std.SemanticVersion {
    const zon = @embedFile("../build.zig.zon");
    const start_match = ".version = \"";

    blk: {
        var start_index = std.mem.indexOf(u8, zon, start_match) orelse
            break :blk;
        start_index += start_match.len;

        if (start_index >= zon.len)
            break :blk;

        const end_index = std.mem.indexOfScalarPos(u8, zon, start_index, '\"') orelse
            break :blk;

        return std.SemanticVersion.parse(zon[start_index..end_index]) catch
            break :blk;
    }

    return .{
        .major = 0,
        .minor = 0,
        .patch = 0,
    };
}

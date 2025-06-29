const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    });
    const jwt = b.dependency("jwt", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("core", .{
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = "src/core.zig",
            },
        },
        .imports = &[_]std.Build.Module.Import{
            .{ .name = "zap", .module = zap.module("zap") },
            .{ .name = "jwt", .module = jwt.module("jwt") },
        },
    });
}

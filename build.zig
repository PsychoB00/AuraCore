const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    });
    const jwt = b.dependency("jwt", .{
        .target = target,
        .optimize = optimize,
    });

    const core = b.addModule("core", .{
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = "src/core.zig",
            },
        },
        .imports = &[_]std.Build.Module.Import{
            .{ .name = "zeit", .module = zeit.module("zeit") },
            .{ .name = "zap", .module = zap.module("zap") },
            .{ .name = "jwt", .module = jwt.module("jwt") },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zeit", zeit.module("zeit"));
    exe_mod.addImport("zap", zap.module("zap"));
    exe_mod.addImport("jwt", jwt.module("jwt"));
    exe_mod.addImport("core", core);

    const exe = b.addExecutable(.{
        .name = "TestExe",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the TestExe");
    run_step.dependOn(&run_cmd.step);
}

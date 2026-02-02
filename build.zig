const std = @import("std");

const getVersion = @import("src/version.zig").getVersion;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "core_version", getVersion());

    // Dependencies
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = true,
    });
    const jwt = b.dependency("jwt", .{
        .target = target,
        .optimize = optimize,
    });

    // Core
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
        .target = target,
        .optimize = optimize,
    });
    core.addOptions("core_options", options);

    // Test exe
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
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
    exe.use_llvm = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the TestExe");
    run_step.dependOn(&run_cmd.step);

    // Copy resources
    const install_resources = b.addInstallDirectory(.{
        .source_dir = b.path("resources"),
        .install_dir = std.Build.InstallDir.prefix,
        .install_subdir = "resources",
    });

    b.getInstallStep().dependOn(&install_resources.step);

    if (std.mem.eql(u8, "", b.pkg_hash)) {
        // Docs
        const docs = b.addObject(.{
            .name = "core",
            .root_module = core,
        });

        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install docs");
        docs_step.dependOn(&install_docs.step);
    }
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for speech recognition logic
    const speech_mod = b.createModule(.{
        .root_source_file = b.path("src/speech.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target_os == .macos) {
        speech_mod.linkSystemLibrary("objc", .{});
        speech_mod.linkFramework("Foundation", .{});
        speech_mod.linkFramework("Speech", .{});
        speech_mod.linkFramework("AVFoundation", .{});
    }

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "stenographer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "speech", .module = speech_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the stenographer CLI");
    run_step.dependOn(&run_cmd.step);
}

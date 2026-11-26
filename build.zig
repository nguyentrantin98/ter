const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The app itself.
    const exe = b.addExecutable(.{
        .name = "ter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .windows;
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("res/ter.rc") });
    b.installArtifact(exe);

    // One-file installer: ter.exe is embedded into it at compile time.
    const setup = b.addExecutable(.{
        .name = "ter-setup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/setup.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    setup.subsystem = .windows;
    setup.root_module.addWin32ResourceFile(.{ .file = b.path("res/ter.rc") });
    setup.root_module.addAnonymousImport("ter_exe", .{ .root_source_file = exe.getEmittedBin() });
    b.installArtifact(setup);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run Ter").dependOn(&run_cmd.step);
}

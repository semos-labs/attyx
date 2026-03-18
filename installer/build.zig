const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "attyx-setup",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });

    exe.subsystem = .Windows;
    exe.addCSourceFile(.{ .file = b.path("installer.c"), .flags = &.{} });
    exe.addWin32ResourceFile(.{ .file = b.path("installer.rc") });
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("advapi32", .{});
    exe.root_module.linkSystemLibrary("shlwapi", .{});
    exe.root_module.linkSystemLibrary("uuid", .{});
    exe.root_module.linkSystemLibrary("c", .{});

    b.installArtifact(exe);
}

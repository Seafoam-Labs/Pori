const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gobject = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("Pori", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib2", gobject.module("glib2"));
    mod.addImport("gobject2", gobject.module("gobject2"));
    mod.addImport("gio2", gobject.module("gio2"));
    mod.addImport("gtk4", gobject.module("gtk4"));
    mod.addImport("gdk4", gobject.module("gdk4"));
    mod.addImport("pango1", gobject.module("pango1"));

    const exe = b.addExecutable(.{
        .name = "pori",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Pori", .module = mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("gtk4", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.root_module.link_libc = true;
    mod_tests.root_module.linkSystemLibrary("gtk4", .{});
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.root_module.linkSystemLibrary("gtk4", .{});

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coro_mod = b.addModule("coroutines", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "coro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "coroutine", .module = coro_mod },
            },
        }),
    });

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const test_step = b.step("run", "Run test executable");
    test_step.dependOn(&run_exe.step);
}
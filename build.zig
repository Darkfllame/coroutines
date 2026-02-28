const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .whitelist = &.{
            std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86_64 },
            std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86_64 },
            std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86_64 },
            std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86_64 },
            // std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86, .abi = .gnu },
            // std.Target.Query{ .os_tag = .linux, .cpu_arch = .x86, .abi = .musl },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const file_obj = compileASM(b, target, optimize);

    const coro_mod = b.addModule("coroutine", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    coro_mod.addObjectFile(file_obj);

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

fn compileASM(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const nasm_cmd = if (b.findProgram(&.{"nasm"}, &.{})) |path|
        b.addSystemCommand(&.{path})
    else |_| blk: {
        std.log.info("Nasm wasn't found, compiling from source.. Consider installing nasm for faster build times", .{});

        const nasm_dep = b.lazyDependency("nasm", .{
            .optimize = .ReleaseFast,
        }) orelse return b.path(".");

        const nasm_exe = nasm_dep.artifact("nasm");

        break :blk b.addRunArtifact(nasm_exe);
    };

    nasm_cmd.addArgs(&.{ "-f", switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86 => "elf32",
            .x86_64 => switch (target.result.abi) {
                .gnu, .musl => "elf64",
                .gnux32, .muslx32 => "elfx32",
                else => unreachable,
            },
            else => unreachable,
        },
        else => unreachable,
    } });
    nasm_cmd.addFileArg(b.path("src/asm/").path(b, switch (target.result.cpu.arch) {
        .x86 => "x86.s",
        .x86_64 => switch (target.result.abi) {
            .gnu, .musl => "x86_64.s",
            .gnux32, .muslx32 => "x86.s",
            else => unreachable,
        },
        else => unreachable,
    }));
    if (optimize == .Debug) {
        nasm_cmd.addArg("-g");
    }
    if (target.result.os.tag == .windows) {
        nasm_cmd.addArg("-DWINDOWS");
    }
    return nasm_cmd.addPrefixedOutputFileArg("-o", "gt-asm.o");
}

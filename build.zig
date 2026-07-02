const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});

    const libregex = buildLib(b, target, optimize);

    const trans_libregex: Translator = .init(translate_c, .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <regex/regex.h>
        ),
        .target = target,
        .optimize = optimize,
    });

    trans_libregex.linkLibrary(libregex);

    // zig fmt: off
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "regex",
                .module = trans_libregex.mod,
            },
        }
    });
    const main = b.addExecutable(.{
        .name = "zig-piler",
        .root_module = main_mod,
    });

    b.installArtifact(main);

    const run_step = b.step("run", "Build and run the executable");
    const run_cmd = b.addRunArtifact(main);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();
}

fn buildLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .root = b.path("lib/libregex"),
        .files = &.{"regex.c"},
    });
    const lib = b.addLibrary(.{
        .name = "regex",
        .root_module = mod,
    });
    // Install the headers, so that linking this library makes those headers available.
    lib.installHeader(b.path("lib/libregex/regex.h"), "regex/regex.h");
    return lib;
}

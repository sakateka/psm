const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "psm",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("clap", clap.module("clap"));

    const extras = b.createModule(.{
        .source_file = .{ .path = "vendor/zig-extras/lib.zig" },
    });
    exe.addModule("extras", extras);
    const range = b.createModule(.{
        .source_file = .{ .path = "vendor/zig-range/lib.zig" },
    });
    exe.addModule("range", range);
    const time = b.createModule(.{
        .source_file = .{ .path = "vendor/zig-time/time.zig" },
        .dependencies = &.{
            .{
                .name = "extras",
                .module = extras,
            },
        },
    });
    //try time.dependencies.put("extras", extras);
    exe.addModule("time", time);
    //exe.linkLibrary(clap.artifact("clap"));
    b.installArtifact(exe);
}

const Builder = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "llhttp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static
    });

    const module = b.addModule("llhttp", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addIncludePath(b.path("vendor"));

    lib.addCSourceFiles(.{
        .root = b.path("vendor"),
        .files = &base_sources
    });

    lib.linkLibC();

    lib.installHeadersDirectory(b.path("vendor/"), "", .{ .include_extensions = &.{".h"} });

    b.installArtifact(lib);
}

const base_sources = [_][]const u8{
    "api.c",
    "http.c",
    "llhttp.c",
};

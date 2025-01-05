const Builder = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bin = b.addExecutable(.{
        .name = "netserver",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libapenetwork = b.dependency("libapenetwork", .{ .target = target, .optimize = optimize });
    const libllhttp = b.dependency("llhttp", .{ .target = target, .optimize = optimize });

    const apenetwork = libapenetwork.artifact("apenetwork");
    const llhttp = libllhttp.artifact("llhttp");

    bin.linkLibrary(apenetwork);
    bin.linkLibrary(llhttp);
    bin.linkSystemLibrary("z");
    bin.linkSystemLibrary("resolv");
    bin.linkLibC();

    bin.root_module.addImport(
        "libapenetwork",
        libapenetwork.module("libapenetwork"),
    );

    bin.root_module.addImport(
        "llhttp",
        libllhttp.module("llhttp"),
    );

    b.installArtifact(bin);
}

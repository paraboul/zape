const Builder = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});


    const flags = [_][]const u8{"-DAPE_DISABLE_SSL"};

    const module = b.addModule("libapenetwork", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const upstream = b.dependency("libapenetwork", .{ .target = target, .optimize = optimize });
    const cares = b.dependency("c-ares", .{ .target = target, .optimize = optimize });

    const lib = b.addStaticLibrary(.{
        .name = "apenetwork",
        .target = target,
        .optimize = optimize,
    });

    // std.debug.print("Got {}", .{cares});

    lib.linkLibC();
    lib.addIncludePath(upstream.path(""));
    module.addIncludePath(upstream.path(""));

    lib.linkLibrary(cares.artifact("cares"));

    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &base_sources,
        .flags = &flags,
    });

    lib.installHeadersDirectory(b.path("src/"), "", .{ .include_extensions = &.{".h"} });

    // _ = b.addModule("libapenetwork", .{ .root_source_file = b.path("main.zig") });

    b.installArtifact(lib);
}

const base_sources = [_][]const u8{
    "ape_array.c",
    "ape_base64.c",
    "ape_buffer.c",
    "ape_dns.c",
    "ape_event_epoll.c",
    "ape_event_kqueue.c",
    "ape_event_select.c",
    "ape_events.c",
    "ape_events_loop.c",
    "ape_hash.c",
    "ape_log.c",
    "ape_lz4.c",
    "ape_netlib.c",
    "ape_pool.c",
    "ape_sha1.c",
    "ape_socket.c",
    "ape_ssl.c",
    "ape_timers_next.c",
    "ape_websocket.c",
};

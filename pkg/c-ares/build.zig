const Builder = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("c-ares", .{});

    const lib = b.addStaticLibrary(.{
        .name = "cares",
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addCMacro("HAVE_CONFIG_H", "1");

    switch(target.result.os.tag) {
        .linux => lib.addIncludePath(b.path("vendor/include/linux")),
        .macos => lib.addIncludePath(b.path("vendor/include/macos")),
        else => {}
    }

    lib.addIncludePath(upstream.path("include"));

    // lib.addConfigHeader(b.addConfigHeader(.{
    //     .style = .{
    //         .autoconf = cares.path("src/lib/ares_config.h.in")
    //     }
    // }, .{
    //     .AC_APPLE_UNIVERSAL_BUILD = false
    // }));
    //

    lib.addCSourceFiles(.{
        .root = upstream.path("src/lib"),
        .files = srcs,
        // .flags = &flags,
    });

    lib.linkLibC();

    lib.installHeadersDirectory(
        upstream.path("include"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);
}


const srcs = &.{
    "ares__close_sockets.c",
    "ares__get_hostent.c",
    "ares__parse_into_addrinfo.c",
    "ares__read_line.c",
    "ares__readaddrinfo.c",
    "ares__sortaddrinfo.c",
    "ares__timeval.c",
    "ares_android.c",
    "ares_cancel.c",
    "ares_create_query.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_expand_name.c",
    "ares_expand_string.c",
    "ares_fds.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_getsock.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_llist.c",
    "ares_mkquery.c",
    "ares_nowarn.c",
    "ares_options.c",
    "ares_parse_a_reply.c",
    "ares_parse_aaaa_reply.c",
    "ares_parse_caa_reply.c",
    "ares_parse_mx_reply.c",
    "ares_parse_naptr_reply.c",
    "ares_parse_ns_reply.c",
    "ares_parse_ptr_reply.c",
    "ares_parse_soa_reply.c",
    "ares_parse_srv_reply.c",
    "ares_parse_txt_reply.c",
    "ares_platform.c",
    "ares_process.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_strcasecmp.c",
    "ares_strdup.c",
    "ares_strerror.c",
    "ares_strsplit.c",
    "ares_timeout.c",
    "ares_version.c",
    "ares_writev.c",
    "bitncmp.c",
    "inet_net_pton.c",
    "inet_ntop.c"
};

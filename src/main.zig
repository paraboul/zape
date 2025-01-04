const std = @import("std");
const apenetwork = @import("libapenetwork");


fn testcall(_: ?[]const u8) void {
    std.debug.print("Async call\n", .{});
}

fn testcallbool(val: * const bool) u32 {
    std.debug.print("Async call for bool {}\n", .{val.*});

    return 10;
}

pub fn connected(_: *apenetwork.Server, client: *const apenetwork.Client) void {
    std.debug.print("New client connected", .{});

    client.write("Hello !");
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    apenetwork.init();

    std.debug.print("TYpe {}\n", .{@TypeOf(.{})});

    const testref : bool = true;

    apenetwork.callAsync(testcallbool, &testref);

    var server = try apenetwork.Server.init();
    try server.start(800, connected);

    apenetwork.startLoop();
}

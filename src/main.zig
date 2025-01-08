const std = @import("std");
const apenetwork = @import("libapenetwork");


fn testcall(_: ?[]const u8) void {
    std.debug.print("Async call\n", .{});
}

fn testcallbool(val: * const bool) u32 {
    std.debug.print("Async call for bool {}\n", .{val.*});

    return 10;
}

pub fn connected(_: *apenetwork.Server, _: *const apenetwork.Client) void {
    std.debug.print("New client connected", .{});

    // client.write("WELCOME 200\n", .static);
}

pub fn ondata(_: *apenetwork.Server, client: *const apenetwork.Client, data: []const u8) void {
    std.debug.print("New data received of len {s}\n", .{data});

    client.write("HTTP/1.1 200 OK\n\n", .static);
    client.write(payload, .static);
    client.close(.queue);
    // client.write(data, .copy);
}

pub fn main() !void {
    apenetwork.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    // const testref : bool = true;

    // apenetwork.callAsync(testcallbool, &testref);

    // var server = try apenetwork.Server.init();
    // try server.start(80, .{
    //     .onConnect = connected,
    // });

    var server = try http.HttpServer.init(gpa.allocator());

    try server.start(80, .{
        .onRequest = struct {
            fn onrequest(request: * const http.HttpParserState, _: apenetwork.Client) void {
                std.debug.print("Got a request {s}\n", .{request.getURL().?});
            }
        }.onrequest,

        .onWebSocketRequest = struct {
            fn onWebSocketRequest(request: * const http.HttpParserState, _: apenetwork.Client) bool {
                std.debug.print("Got websocket request {s}\n", .{request.getURL().?});

                return true;
            }
        }.onWebSocketRequest,

        .onWebSocketFrame = struct {
            fn onWebSocketFrame(_: * const http.HttpParserState, message: [] const u8) void {
                std.debug.print("WS FRAME -> {s}\n", .{message});
            }
        }.onWebSocketFrame

    });

    std.debug.print("Server http started at {*}\n", .{&server});

    apenetwork.startLoop();
}

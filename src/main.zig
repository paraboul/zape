const std = @import("std");
const apenetwork = @import("libapenetwork");
const http = @import("http.zig");
const websocket = @import("websocket.zig");

const UserCtx = struct {
    foo: u64 = 100
};


pub fn main() !void {
    apenetwork.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = false
    }){};

    var server = try http.HttpServer.init(gpa.allocator());

    try server.start(http.HttpServerConfig(UserCtx) {
        .port = 80,

        .onRequest = struct {
            fn onrequest(request: * const http.HttpParserState, _: apenetwork.Client, _: *UserCtx) void {
                std.debug.print("Got a request {s}\n", .{request.getURL().?});
            }
        }.onrequest,

        .onWebSocketRequest = struct {
            fn onwebsocketrequest(request: * const http.HttpParserState, _: apenetwork.Client, _: *UserCtx) bool {
                std.debug.print("Got websocket request {s}\n", .{request.getURL().?});

                return true;
            }
        }.onwebsocketrequest,

        .onWebSocketFrame = struct {
            fn onwebsocketframe(request: * const http.HttpParserState, _: *websocket.WebSocketClient(.server), message: [] const u8, ctx: *UserCtx) !void {
                std.debug.print("WS({d}) FRAME on {s} -> {s}\n", .{ctx.foo, request.getURL().?, message});

                // client.write(message, .copy);
            }
        }.onwebsocketframe

    });

    apenetwork.startLoop();
}

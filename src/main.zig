const std = @import("std");
const apenetwork = @import("libapenetwork");
const http = @import("http.zig");
const websocket = @import("websocket.zig");


const HttpRequestHandler = struct {

    const Self = @This();

    foo: u32 = 42,

    pub fn init(_: * const http.HttpRequestCtx, _: *http.HttpServer(Self)) HttpRequestHandler {
        return .{};
    }

    pub fn deinit(_: *HttpRequestHandler) void {

    }

    pub fn onRequest(_: * const HttpRequestHandler, _: * const http.HttpRequestCtx, _: apenetwork.Client) void {

    }

    pub fn onUpradeToWebSocket(_: * const HttpRequestHandler, _: * const http.HttpRequestCtx, _: apenetwork.Client) bool {
        return true;
    }

    pub fn onDisconnect(_: * const HttpRequestHandler) void {

    }

    pub fn onWebSocketMessage(_: * const HttpRequestHandler, client: *websocket.WebSocketClient(.server), message: [] const u8) !void {
        std.debug.print("Got ws frame {s}\n", .{message});

        // Echo back the same message
        client.write(message, .text, .copy);
    }
};

pub fn main() !void {

    // Init the event loop for the current thread
    apenetwork.init();



    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = false
    }){};

    var server = try http.HttpServer(HttpRequestHandler).init(gpa.allocator(), .{
        .port = 80,
    });

    try server.start();

    // Start the event loop
    apenetwork.startLoop();

}

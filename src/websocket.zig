const std = @import("std");
const apenetwork = @import("libapenetwork");
const http = @import("http.zig");

pub const WebSocketServer = struct {
    httpserver: http.HttpServer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !WebSocketServer {
        return WebSocketServer{
            .httpserver = try http.HttpServer.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn start(self: *WebSocketServer, port: u16) !void {
        return self.httpserver.start(port);
    }


};

const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");


const http_parser_settings : llhttp.c.llhttp_settings_t  = .{};


fn client_connected(server: *apenetwork.Server, _: *const apenetwork.Client) void {

    // Retrieve HttpServer address from the server address
    const httpserver : *HttpServer = @fieldParentPtr("server", server);

    std.debug.print("New client connected to http server at address {*} at base {*}\n", .{httpserver, server});
}

fn client_ondata(_: *apenetwork.Server, _: *const apenetwork.Client, data: []const u8) void {
    // const httpserver : *HttpServer = @fieldParentPtr("server", server);

    std.debug.print("=> {s}", .{data});
}


pub const HttpServer = struct {
    server: apenetwork.Server,
    parser: llhttp.c.llhttp_t,

    pub fn init() !HttpServer {
        return HttpServer{
            .server = try apenetwork.Server.init(),
            .parser = parser: {
                var parser : llhttp.c.llhttp_t = .{};
                llhttp.c.llhttp_init(&parser, llhttp.c.HTTP_BOTH, &http_parser_settings);

                break :parser parser;
            }
        };
    }

    pub fn start(self: *HttpServer, port: u16) !void {
        std.debug.print("Starting http server on port {d}\n", .{port});
        try self.server.start(port, .{
            .onConnect = client_connected,
            .onData = client_ondata
        });
    }
};

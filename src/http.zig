const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");


const http_parser_settings : llhttp.c.llhttp_settings_t  = .{
    .on_method_complete = http_on_method_complete
};


fn client_connected(server: *apenetwork.Server, _: *const apenetwork.Client) void {

    // Retrieve HttpServer address from the server address
    const httpserver : *HttpServer = @fieldParentPtr("server", server);

    std.debug.print("New client connected to http server at address {*} at base {*}\n", .{httpserver, server});
}

fn client_ondata(_: *apenetwork.Server, client: *const apenetwork.Client, data: []const u8) void {
    const parser : *llhttp.c.llhttp_t = @ptrCast(@alignCast(client.socket.*.ctx orelse return));
    const llhttp_errno = llhttp.c.llhttp_execute(parser, data.ptr, data.len);

    switch (llhttp_errno) {
        llhttp.c.HPE_OK => std.debug.print("Success parse", .{}),
        else => std.debug.print("Failed parse {s} {s}", .{llhttp.c.llhttp_errno_name(llhttp_errno), parser.reason})
    }
}

fn http_on_method_complete(_: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    std.debug.print("Method complete\n", .{});
    return 0;
}

pub const HttpServer = struct {
    server: apenetwork.Server,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HttpServer {
        return HttpServer{
            .server = try apenetwork.Server.init(),
            .allocator = allocator,
        };
    }

    pub fn start(self: *HttpServer, port: u16) !void {
        std.debug.print("Starting http server on port {d}\n", .{port});
        try self.server.start(port, .{
            .onConnect = struct {
                fn connect(server: *apenetwork.Server, client: *const apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);

                    client.socket.*.ctx = parser: {
                        const parser = httpserver.allocator.create(llhttp.c.llhttp_t) catch break :parser null;

                        llhttp.c.llhttp_init(parser, llhttp.c.HTTP_BOTH, &http_parser_settings);
                        llhttp.c.llhttp_set_lenient_optional_cr_before_lf(parser, 1);

                        break :parser parser;
                    };

                    client_connected(server, client);
                }
            }.connect,

            .onDisconnect = struct {
                fn disconnect(server: *apenetwork.Server, client: *const apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);
                    const parser : *llhttp.c.llhttp_t = @ptrCast(@alignCast(client.socket.*.ctx orelse return));

                    httpserver.allocator.destroy(parser);

                }
            }.disconnect,

            .onData = client_ondata
        });
    }
};

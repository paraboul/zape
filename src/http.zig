const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");


const http_parser_settings : llhttp.c.llhttp_settings_t  = .{
    .on_header_field = http_on_header_field,
    .on_header_value = http_on_header_value
};


fn http_on_header_field(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, size: usize) callconv(.C) c_int {
    const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    const allocator = parser.arena.allocator();
    const field = allocator.dupe(u8, data[0..size]) catch return 0;

    parser.headers.put(field, "") catch return 0;

    parser._lastHeaderKey = field;

    return 0;
}

fn http_on_header_value(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, size: usize) callconv(.C) c_int {
    const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    const allocator = parser.arena.allocator();
    const entry = parser.headers.getEntry(parser._lastHeaderKey.?);
    entry.?.value_ptr.* = allocator.dupe(u8, data[0..size]) catch return 0;

    return 0;
}

fn client_connected(server: *apenetwork.Server, _: *const apenetwork.Client) void {

    // Retrieve HttpServer address from the server address
    const httpserver : *HttpServer = @fieldParentPtr("server", server);

    std.debug.print("New client connected to http server at address {*} at base {*}\n", .{httpserver, server});
}

fn client_ondata(_: *apenetwork.Server, client: *const apenetwork.Client, data: []const u8) void {
    const parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx orelse return));
    const llhttp_errno = llhttp.c.llhttp_execute(&parser.state, data.ptr, data.len);

    switch (llhttp_errno) {
        llhttp.c.HPE_OK => std.debug.print("Success parse", .{}),
        else => std.debug.print("Failed parse {s} {s}", .{llhttp.c.llhttp_errno_name(llhttp_errno), parser.state.reason})
    }
}

const HttpParserState = struct {
    state: llhttp.c.llhttp_t,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    _lastHeaderKey: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) HttpParserState {

        return HttpParserState {
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .state = state: {
                var parser : llhttp.c.llhttp_t = .{};

                llhttp.c.llhttp_init(&parser, llhttp.c.HTTP_BOTH, &http_parser_settings);
                llhttp.c.llhttp_set_lenient_optional_cr_before_lf(&parser, 1);
                llhttp.c.llhttp_set_lenient_optional_lf_after_cr(&parser, 1);

                break :state parser;
            },
            .headers = std.StringHashMap([]const u8).init(allocator)
        };
    }

    pub fn deinit(self: *HttpParserState) void {
        self.headers.deinit();
        self.arena.deinit();
    }
};

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
        try self.server.start(port, .{
            .onConnect = struct {
                fn connect(server: *apenetwork.Server, client: *const apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);

                    client.socket.*.ctx = parser: {
                        const parser = httpserver.allocator.create(HttpParserState) catch break :parser null;
                        parser.* = HttpParserState.init(httpserver.allocator);

                        break :parser parser;
                    };

                    client_connected(server, client);
                }
            }.connect,

            .onDisconnect = struct {
                fn disconnect(server: *apenetwork.Server, client: *const apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);
                    var parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx orelse return));

                    parser.deinit();
                    httpserver.allocator.destroy(parser);

                }
            }.disconnect,

            .onData = client_ondata
        });
    }
};

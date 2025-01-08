const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");


const http_parser_settings : llhttp.c.llhttp_settings_t  = .{
    .on_url = http_on_parse_header_data("acc_url").func,
    .on_header_field = http_on_parse_header_data("acc_field").func,
    .on_header_value = http_on_parse_header_data("acc_value").func,
    .on_header_field_complete = http_on_header_field_complete,
    .on_header_value_complete = http_on_header_value_complete,
    .on_headers_complete = http_on_headers_complete,
    .on_message_complete = http_on_message_complete
};

fn http_on_parse_header_data(comptime field_name: []const u8) type {
    return struct {
        fn func(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, size: usize) callconv(.C) c_int {
            const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));
            const allocator = parser.arena.allocator();

            @field(parser.headers_state, field_name).appendSlice(allocator, data[0..size]) catch return -1;

            return 0;
        }
    };
}

fn http_on_header_field_complete(_: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    return 0;
}

fn http_on_header_value_complete(state: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    const allocator = parser.arena.allocator();

    const key = std.ascii.allocLowerString(allocator, parser.headers_state.acc_field.items) catch return 0;
    const value = allocator.dupe(u8, parser.headers_state.acc_value.items) catch return 0;

    parser.headers.put(key, value) catch return 0;

    parser.headers_state.acc_field.resize(allocator, 0) catch return 0;
    parser.headers_state.acc_value.resize(allocator, 0) catch return 0;

    return 0;
}

fn http_on_header_value(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, size: usize) callconv(.C) c_int {
    const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    const allocator = parser.arena.allocator();

    parser.headers_state.acc_value.appendSlice(allocator, data[0..size]) catch return 0;

    return 0;
}

fn http_on_headers_complete(_: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    return 1;
}

fn http_on_message_complete(state: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    // const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    if (llhttp.c.llhttp_get_upgrade(state) == 1) {
    }

    return 0;
}

fn client_connected(_: *apenetwork.Server, _: *const apenetwork.Client) void {}

const ParseReturnState = union(enum) {
    ok,
    websocket_upgrade,
    parse_error: llhttp.c.llhttp_errno_t
};

fn client_ondata(_: *apenetwork.Server, client: *const apenetwork.Client, data: []const u8) ParseReturnState {
    const parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx orelse return .ok));

    if (parser.upgraded) {
        // TODO: handle WS frame
        return .websocket_upgrade;
    }

    const llhttp_errno = llhttp.c.llhttp_execute(&parser.state, data.ptr, data.len);

    return switch (llhttp_errno) {
        llhttp.c.HPE_OK => return .ok,
        llhttp.c.HPE_PAUSED_UPGRADE => {
            parser.upgraded = true;
            return .websocket_upgrade;
        },
        // llhttp.c.HPE_CB_MESSAGE_COMPLETE => {
        //     std.debug.print("message complete\n", .{});
        //     if (llhttp.c.llhttp_get_upgrade(&parser.state) == 1) {
        //         if (parser.headers.get("sec-websocket-key")) |wskey| {

        //             var digest :[20]u8 = undefined;
        //             var b64key :[30]u8 = undefined;

        //             apenetwork.c.ape_ws_compute_sha1_key(wskey.ptr, @intCast(wskey.len), &digest);
        //             const b64key_slice = std.base64.standard.Encoder.encode(&b64key, &digest);

        //             client.tcpBufferStart();
        //             client.write(apenetwork.c.WEBSOCKET_HARDCODED_HEADERS, .static);
        //             client.write("Sec-WebSocket-Accept: ", .static);
        //             client.write(b64key_slice, .copy);
        //             client.write("\r\nSec-WebSocket-Origin: 127.0.0.1\r\n\r\n", .static);
        //             client.tcpBufferEnd();

        //             parser.upgraded = true;
        //         }
        //     }

        // },
        else => return .{.parse_error = llhttp_errno},
    };
}

const HttpParserState = struct {
    state: llhttp.c.llhttp_t,
    headers: std.StringHashMap([]const u8),
    upgraded: bool = false,

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    headers_state: struct {
        acc_field: std.ArrayListUnmanaged(u8) = .{},
        acc_value: std.ArrayListUnmanaged(u8) = .{},
        acc_url: std.ArrayListUnmanaged(u8) = .{}
    } = .{},

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

const HttpCallbacks =  struct {
    onConnect: ?fn () void = null,
    onDisconnect: ?fn () void = null,
    onRequest: ?fn () void = null
};


pub const HttpServer = struct {
    server: apenetwork.Server,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HttpServer {
        return HttpServer{
            .server = try apenetwork.Server.init(),
            .allocator = allocator
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

            .onData = struct {
                fn ondata(server: *apenetwork.Server, client: *const apenetwork.Client, data: []const u8) void {
                    switch(@call(.always_inline, client_ondata, .{server, client, data})) {
                        .parse_error => |_| {
                            client.write("HTTP/1.1 400 Bad Request\r\n\r\n", .static);
                            client.close(.queue);
                        },
                        .websocket_upgrade => std.debug.print("websocket uopgrade\n", .{}),
                        else => {}
                    }
                }
            }.ondata
        });
    }
};

const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");
const websocket = @import("websocket.zig");

const ParseReturnState = union(enum) {
    cont,
    done,
    websocket_upgrade,
    parse_error: llhttp.c.llhttp_errno_t
};

pub fn HttpServerConfig(comptime T: type) type {

    return struct {
        ctxType: type = T,
        port: u16 = 80,

        onConnect: ?fn () void = null,
        onDisconnect: ?fn (* const HttpParserState, apenetwork.Client, ?*T) void = null,
        onRequest: ?fn (* const HttpParserState, apenetwork.Client, *T) void = null,
        onWebSocketRequest: ?fn (* const HttpParserState, apenetwork.Client, *T) bool = null,
        onWebSocketFrame: ?fn (* const HttpParserState, *websocket.WebSocketClient(.server), [] const u8, *T) anyerror!void = null,
    };
}

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


            @field(parser.headers_state, field_name).ensureTotalCapacity(allocator, 32) catch return -1;
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
    const parser : *HttpParserState = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    parser.done = true;

    return 0;
}

fn client_connected(_: *apenetwork.Server, _: apenetwork.Client) void {}

fn client_onhttpdata(_: *apenetwork.Server, client: apenetwork.Client, data: []const u8) ParseReturnState {
    const parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx orelse return .cont));

    const llhttp_errno = llhttp.c.llhttp_execute(&parser.state, data.ptr, data.len);

    return switch (llhttp_errno) {
        llhttp.c.HPE_OK => return if (parser.done) .done else .cont,
        llhttp.c.HPE_PAUSED_UPGRADE => {
            // TODO: Check that upgrade is actually websocket
            return .websocket_upgrade;
        },
        else => return .{.parse_error = llhttp_errno},
    };
}

pub const HttpParserState = struct {

    server: *HttpServer,
    state: llhttp.c.llhttp_t,
    headers: std.StringHashMap([]const u8),
    done: bool = false,

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    headers_state: struct {
        acc_field: std.ArrayListUnmanaged(u8) = .{},
        acc_value: std.ArrayListUnmanaged(u8) = .{},
        acc_url: std.ArrayListUnmanaged(u8) = .{}
    } = .{},

    websocket_state: ?*websocket.WebSocketState(HttpParserState, .server) = null,

    user_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, server: *HttpServer) HttpParserState {

        return HttpParserState {
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .server = server,
            .state = state: {
                var parser : llhttp.c.llhttp_t = .{};

                llhttp.c.llhttp_init(&parser, llhttp.c.HTTP_BOTH, &http_parser_settings);
                llhttp.c.llhttp_set_lenient_optional_cr_before_lf(&parser, 1);
                llhttp.c.llhttp_set_lenient_optional_lf_after_cr(&parser, 1);

                break :state parser;
            },
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *HttpParserState) void {

        if (self.websocket_state) |wsstate| {
            wsstate.deinit();
        }
        self.headers.deinit();
        self.arena.deinit();
    }

    pub fn acceptWebSocket(self: *HttpParserState, client: apenetwork.Client, on_frame: anytype) bool {
        if (self.headers.get("sec-websocket-key")) |wskey| {

            var digest :[20]u8 = undefined;
            var b64key :[30]u8 = undefined;

            apenetwork.c.ape_ws_compute_sha1_key(wskey.ptr, @intCast(wskey.len), &digest);
            const b64key_slice = std.base64.standard.Encoder.encode(&b64key, &digest);

            client.tcpBufferStart();
            client.write(apenetwork.c.WEBSOCKET_HARDCODED_HEADERS, .static);
            client.write("Sec-WebSocket-Accept: ", .static);
            client.write(b64key_slice, .copy);
            client.write("\r\nSec-WebSocket-Origin: 127.0.0.1\r\n\r\n", .static);
            client.tcpBufferEnd();

            // Initialize WebSocket state and its callbacks
            self.websocket_state = brk: {
                const state = self.arena.allocator().create(websocket.WebSocketState(HttpParserState, .server)) catch @panic("OOM");
                state.* = websocket.WebSocketState(HttpParserState, .server).init(self.allocator, self, client, .{
                    .on_message = struct {
                        fn onwsmessage(wsclient: *websocket.WebSocketClient(.server), httpstate: *const HttpParserState, message: [] const u8, _: bool, _: websocket.FrameState) void {

                            on_frame(httpstate, wsclient, message, @alignCast(@ptrCast(httpstate.user_ctx.?))) catch |err| {

                                wsclient.close();
                                std.debug.print("on frame returned an error: {}\n", .{err});
                            };
                        }
                    }.onwsmessage
                });
                break :brk state;
            };

            return true;
        }

        return false;
    }

    pub fn getURL(self: *const HttpParserState) ?[] const u8 {
        if (!self.done) {
            return null;
        }

        return self.headers_state.acc_url.items;
    }
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

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
    }

    pub fn start(self: *HttpServer, comptime httpconfig: anytype) !void {
        try self.server.start(httpconfig.port, .{
            .onConnect = struct {
                fn connect(server: *apenetwork.Server, client: apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);

                    client.socket.*.ctx = parser: {
                        const parser = httpserver.allocator.create(HttpParserState) catch break :parser null;
                        parser.* = HttpParserState.init(httpserver.allocator, httpserver);

                        break :parser parser;
                    };

                    // TODO: callback?
                    client_connected(server, client);
                }
            }.connect,

            .onDisconnect = struct {
                fn disconnect(server: *apenetwork.Server, client: apenetwork.Client) void {
                    const httpserver : *HttpServer = @fieldParentPtr("server", server);
                    var parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx orelse return));

                    if (httpconfig.onDisconnect) |ondisconnect| {
                        ondisconnect(parser, client, @alignCast(@ptrCast(parser.user_ctx)));
                    }

                    parser.deinit();
                    httpserver.allocator.destroy(parser);
                }
            }.disconnect,

            .onData = struct {
                fn ondata(server: *apenetwork.Server, client: apenetwork.Client, data: []const u8) !void {
                    errdefer {
                        client.write("HTTP/1.1 400 Bad Request\r\n\r\n", .static);
                        client.close(.queue);
                    }

                    const parser : *HttpParserState = @ptrCast(@alignCast(client.socket.*.ctx));

                    if (parser.websocket_state) |wsnew| {
                        try wsnew.process_data(data);

                        return;
                    }

                    switch(@call(.always_inline, client_onhttpdata, .{server, client, data})) {
                        .parse_error => |_| {
                            return error.HttpParseError;
                        },

                        .websocket_upgrade => {

                            parser.user_ctx = blk: {
                                const ctx = try parser.arena.allocator().create(httpconfig.ctxType);
                                break :blk ctx;
                            };

                            if (httpconfig.onWebSocketRequest) |onwebsocketrequest| {

                                const result = onwebsocketrequest(parser, client, @alignCast(@ptrCast(parser.user_ctx.?)));

                                if (!result
                                    or httpconfig.onWebSocketFrame == null
                                    or !parser.acceptWebSocket(client, httpconfig.onWebSocketFrame.?)) {

                                    return error.HttpUnsupportedWebSocket;
                                }

                                // if (!result or !parser.acceptWebSocket(client, struct {
                                //     fn onframe(_: * const HttpParserState, _: websocket.WebSocketClient(.server), _: [] const u8, _: *anyopaque) !void {

                                //         if (httpconfig.onWebSocketFrame) |_| {

                                //             std.debug.print("Forward to original callbacl\n", .{});
                                //             // bench with inline
                                //             // try onwebsocketframe(frame_state, apenetwork.WebSocketClient{ .state = frame_state.websocket_state.? }, frame_data, @alignCast(@ptrCast(ctx)));
                                //         }
                                //     }
                                // }.onframe)) {
                                //     return error.HttpUnsupportedWebSocket;
                                // }
                            }
                        },

                        .done => {
                            parser.user_ctx = blk: {
                                const ctx = try parser.arena.allocator().create(httpconfig.ctxType);
                                // ctx.* = httpconfig.ctxType{};
                                break :blk ctx;
                            };

                            if (httpconfig.onRequest) |onrequest| {
                                onrequest(parser, client, @alignCast(@ptrCast(parser.user_ctx.?)));
                            }
                        },

                        else => {}
                    }
                }
            }.ondata
        });
    }
};

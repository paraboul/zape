const std = @import("std");
const llhttp = @import("llhttp");
const apenetwork = @import("libapenetwork");
const websocket = @import("websocket.zig");

const MAX_BODY_LEN = 1024 * 1024 * 4;

const ParseReturnState = union(enum) {
    cont,
    done,
    websocket_upgrade,
    parse_error: llhttp.c.llhttp_errno_t
};

const http_parser_settings : llhttp.c.llhttp_settings_t  = .{
    .on_url = http_on_parse_header_data("acc_url").func,
    .on_header_field = http_on_parse_header_data("acc_field").func,
    .on_header_value = http_on_parse_header_data("acc_value").func,
    .on_header_field_complete = http_on_header_field_complete,
    .on_header_value_complete = http_on_header_value_complete,
    .on_headers_complete = http_on_headers_complete,
    .on_message_complete = http_on_message_complete,
    .on_body = http_on_body
};


fn http_on_body(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, len: usize) callconv(.C) c_int {
    const http_request : *HttpRequestCtx = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));
    const allocator = http_request.arena.allocator();

    if (http_request.headers_state.acc_body.capacity == 0) {
        if (http_request.headers.get("content-length")) |cl| {
            const cl_int = std.fmt.parseInt(u32, cl, 10) catch return -1;

            if (cl_int > MAX_BODY_LEN) {
                return -1;
            }

            http_request.headers_state.acc_body.ensureTotalCapacity(allocator, cl_int) catch return -1;
        }
    }

    if (http_request.headers_state.acc_body.items.len + len > http_request.headers_state.acc_body.capacity) {
        return -1;
    }

    http_request.headers_state.acc_body.appendSliceAssumeCapacity(data[0..len]);

    return 0;
}

fn http_on_parse_header_data(comptime field_name: []const u8) type {
    return struct {
        fn func(state: [*c]llhttp.c.llhttp_t, data: [*c]const u8, size: usize) callconv(.C) c_int {
            const http_request : *HttpRequestCtx = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));
            const allocator = http_request.arena.allocator();

            // TODO: why not using size and ensureUnusedCapacity ?
            @field(http_request.headers_state, field_name).ensureTotalCapacity(allocator, 32) catch return -1;
            @field(http_request.headers_state, field_name).appendSlice(allocator, data[0..size]) catch return -1;

            return 0;
        }
    };
}

fn http_on_header_field_complete(_: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    return 0;
}

fn http_on_header_value_complete(state: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    const http_request : *HttpRequestCtx = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    const allocator = http_request.arena.allocator();

    const key = std.ascii.allocLowerString(allocator, http_request.headers_state.acc_field.items) catch return 0;
    const value = allocator.dupe(u8, http_request.headers_state.acc_value.items) catch return 0;

    http_request.headers.put(key, value) catch return 0;

    http_request.headers_state.acc_field.resize(allocator, 0) catch return 0;
    http_request.headers_state.acc_value.resize(allocator, 0) catch return 0;

    return 0;
}


fn http_on_headers_complete(_: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    return 0;
}

fn http_on_message_complete(state: [*c]llhttp.c.llhttp_t) callconv(.C) c_int {
    const http_request : *HttpRequestCtx = @fieldParentPtr("state", @as(*llhttp.c.llhttp_t, state));

    http_request.done = true;

    return 0;
}

fn client_connected(_: *apenetwork.Server, _: apenetwork.Client) void {}

fn client_onhttpdata(_: *apenetwork.Server, client: apenetwork.Client, data: []const u8) ParseReturnState {
    const http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.socket.*.ctx orelse return .cont));

    const llhttp_errno = llhttp.c.llhttp_execute(&http_request.state, data.ptr, data.len);

    return switch (llhttp_errno) {
        llhttp.c.HPE_OK => return if (http_request.done) .done else .cont,
        llhttp.c.HPE_PAUSED_UPGRADE => {
            // TODO: Check that upgrade is actually websocket
            return .websocket_upgrade;
        },
        else => return .{.parse_error = llhttp_errno},
    };
}

pub const HttpRequestCtx = struct {
    state: llhttp.c.llhttp_t,
    headers: std.StringHashMap([]const u8),
    done: bool = false,

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    headers_state: struct {
        acc_field: std.ArrayListUnmanaged(u8) = .empty,
        acc_value: std.ArrayListUnmanaged(u8) = .empty,
        acc_url: std.ArrayListUnmanaged(u8) = .empty,
        acc_body: std.ArrayListUnmanaged(u8) = .empty
    } = .{},

    websocket_state: ?*websocket.WebSocketState(HttpRequestCtx, .server) = null,

    user_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) HttpRequestCtx {

        return .{
            .allocator = allocator,
            .arena = .init(allocator),
            .state = state: {
                var parser : llhttp.c.llhttp_t = .{};

                llhttp.c.llhttp_init(&parser, llhttp.c.HTTP_REQUEST, &http_parser_settings);
                llhttp.c.llhttp_set_lenient_optional_cr_before_lf(&parser, 1);
                llhttp.c.llhttp_set_lenient_optional_lf_after_cr(&parser, 1);

                break :state parser;
            },
            .headers = .init(allocator),
        };
    }

    pub fn deinit(self: *HttpRequestCtx) void {

        if (self.websocket_state) |wsstate| {
            wsstate.deinit();
        }
        self.headers.deinit();
        self.arena.deinit();
    }

    pub fn acceptWebSocket(self: *HttpRequestCtx, client: apenetwork.Client, on_frame: anytype) bool {
        if (self.headers.get("sec-websocket-key")) |wskey| {

            var b64key : [30]u8 = undefined;

            const b64key_slice = websocket.get_b64_accept_key(wskey, &b64key) catch @panic("OOM");

            client.tcpBufferStart();
            client.write(apenetwork.c.WEBSOCKET_HARDCODED_HEADERS, .static);
            client.write("Sec-WebSocket-Accept: ", .static);
            client.write(b64key_slice, .copy);
            client.write("\r\nSec-WebSocket-Origin: 127.0.0.1\r\n\r\n", .static);
            client.tcpBufferEnd();

            // Initialize WebSocket state and its callbacks
            self.websocket_state = brk: {
                const state = self.arena.allocator().create(websocket.WebSocketState(HttpRequestCtx, .server)) catch @panic("OOM");
                state.* = .init(self.allocator, self, client, .{
                    .on_message = struct {
                        fn onwsmessage(wsclient: *websocket.WebSocketClient(.server), httpstate: *const HttpRequestCtx, message: [] const u8, _: bool, _: websocket.FrameState) void {

                            on_frame(@alignCast(@ptrCast(httpstate.user_ctx.?)), wsclient, message) catch |err| {

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

    pub fn getURL(self: *const HttpRequestCtx) ?[] const u8 {
        if (!self.done) {
            return null;
        }

        return self.headers_state.acc_url.items;
    }

    pub fn getBody(self: *const HttpRequestCtx) [] const u8 {
        return self.headers_state.acc_body.items;
    }
};


pub const HttpServerConfig = struct {
    port: u16,
    address: [] const u8 = "0.0.0.0"
};


pub fn HttpServer(T: type) type {

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: HttpServerConfig,
        server: apenetwork.Server,

        pub fn init(allocator: std.mem.Allocator, config: HttpServerConfig) !Self {
            return .{
                .allocator = allocator,
                .config = config,
                .server = try .init(.{
                    .port = config.port,
                    .address = config.address
                }),
            };
        }

        pub fn start(self: *Self) !void {

            try self.server.start(.{
                .onConnect = struct {
                    fn connect(server: *apenetwork.Server, client: apenetwork.Client) void {
                        const http_server : *Self = @fieldParentPtr("server", server);

                        client.socket.*.ctx = parser: {
                            const http_request = http_server.allocator.create(HttpRequestCtx) catch break :parser null;
                            http_request.* = HttpRequestCtx.init(http_server.allocator);

                            break :parser http_request;
                        };

                        // TODO: callback?
                    }
                }.connect,

                .onDisconnect = struct {
                    fn disconnect(server: *apenetwork.Server, client: apenetwork.Client) void {
                        const http_server : *Self = @fieldParentPtr("server", server);
                        var http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.socket.*.ctx orelse return));

                        if (http_request.user_ctx) |ctx| {

                            const handler : *T = @ptrCast(@alignCast(ctx));

                            if (std.meta.hasFn(T, "onDisconnect")) {
                                handler.onDisconnect();
                            }

                            handler.deinit();
                        }

                        http_request.deinit();
                        http_server.allocator.destroy(http_request);
                    }
                }.disconnect,

                .onData = struct {
                    fn ondata(server: *apenetwork.Server, client: apenetwork.Client, data: []const u8) !void {

                        errdefer {
                            client.write("HTTP/1.1 400 Bad Request\r\n\r\n", .static);
                            client.close(.queue);
                        }

                        const http_server : *Self = @fieldParentPtr("server", server);
                        const http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.socket.*.ctx));
                        // const http_server : *Self = @fieldParentPtr("server", server);

                        // We've switch to a websocket context
                        // Hand the data off directly to the websocket parser
                        if (http_request.websocket_state) |wsnew| {
                            try wsnew.process_data(data);

                            return;
                        }

                        switch(@call(.always_inline, client_onhttpdata, .{server, client, data})) {
                            .parse_error => |err| {
                                std.debug.print("Parser error, {s}\n", .{llhttp.c.llhttp_errno_name(err)});
                                return error.HttpParseError;
                            },

                            .websocket_upgrade => {

                                // These two functions must be implemented in order to accept WS upgrade
                                if (!std.meta.hasFn(T, "onUpradeToWebSocket") or !std.meta.hasFn(T, "onWebSocketMessage")) {
                                    return error.HttpUnsupportedWebSocket;
                                }

                                const userctx : *T = blk: {
                                    const ctx = try http_request.arena.allocator().create(T);
                                    ctx.* = T.init(http_request, http_server);
                                    break :blk ctx;
                                };

                                http_request.user_ctx = userctx;

                                if (!userctx.onUpradeToWebSocket(http_request, client)) {
                                    return error.HttpUnsupportedWebSocket;
                                }

                                if (!http_request.acceptWebSocket(client, T.onWebSocketMessage)) {
                                    return error.HttpUnsupportedWebSocket;
                                }

                                if (std.meta.hasFn(T, "onUpgradedToWebSocket")) {
                                    userctx.onUpgradedToWebSocket(&http_request.websocket_state.?.client);
                                }
                            },

                            .done => {

                                const userctx : *T = blk: {
                                    const ctx = try http_request.arena.allocator().create(T);
                                    ctx.* = T.init(http_request, http_server);
                                    break :blk ctx;
                                };

                                http_request.user_ctx = userctx;

                                if (std.meta.hasFn(T, "onRequest")) {
                                    userctx.onRequest(http_request, client);
                                }

                                client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", .static);
                                client.close(.queue);
                            },

                            else => {}
                        }
                    }
                }.ondata
            });
        }

    };
}

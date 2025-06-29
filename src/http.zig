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

fn client_connected(_: *apenetwork.Server, _: *apenetwork.Client) void {}

fn client_onhttpdata(_: *apenetwork.Server, client: *apenetwork.Client, data: []const u8) ParseReturnState {
    const http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.ctx() orelse return .cont));
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
    client: *apenetwork.Client,

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

    pub fn init(allocator: std.mem.Allocator, client: *apenetwork.Client) HttpRequestCtx {
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
            .client = client
        };
    }

    pub fn deinit(self: *HttpRequestCtx) void {
        if (self.websocket_state) |wsstate| {
            wsstate.deinit();
        }
        self.headers.deinit();
        self.arena.deinit();
    }

    pub fn acceptWebSocket(self: *HttpRequestCtx, client: *apenetwork.Client, on_frame: anytype) bool {
        if (self.headers.get("sec-websocket-key")) |wskey| {
            var b64key : [30]u8 = undefined;

            const b64key_slice = websocket.get_b64_accept_key(wskey, &b64key) catch @panic("OOM");

            client.tcpBufferStart();
            client.write(websocket.ws_hardcoded_header, .static);
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

    pub fn response(self: *HttpRequestCtx, code: u16, data: [] const u8, close: bool) void {
        var buffer: [256]u8 = undefined;

        self.client.tcpBufferStart();
        defer self.client.tcpBufferEnd();

        const http_response = switch(code) {
            100 => "Continue",
            101 => "Switching Protocols",
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            418 => "I'm a teapot",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown Status",
        };

        const ret = std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n", .{code, http_response, data.len}) catch return;

        self.client.write(ret, .copy);

        if (data.len > 0) {
            self.client.write(data, .copy);
        }

        if (close) {
            self.client.close(.queue);
        }
    }
};


pub const HttpServerConfig = struct {
    port: u16,
    address: [] const u8 = "0.0.0.0",
    preAllocatedRequest: usize = 64
};


pub fn HttpServer(T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        requests_pool: std.heap.MemoryPool(HttpRequestCtx),
        config: HttpServerConfig,
        server: apenetwork.Server,

        pub fn init(allocator: std.mem.Allocator, config: HttpServerConfig) !Self {
            return .{
                .allocator = allocator,
                .requests_pool = try .initPreheated(allocator, config.preAllocatedRequest),
                .config = config,
                .server = try .init(.{
                    .port = config.port,
                    .address = config.address
                }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.requests_pool.deinit();
        }

        pub fn start(self: *Self) !void {
            try self.server.start(.{
                .onConnect = struct {
                    fn connect(server: *apenetwork.Server, client: *apenetwork.Client) void {
                        const http_server : *Self = @fieldParentPtr("server", server);

                        const ctx = parser: {
                            const http_request = http_server.requests_pool.create() catch break :parser null;
                            http_request.* = HttpRequestCtx.init(http_server.allocator, client);

                            break :parser http_request;
                        };

                        client.setCtx(ctx);

                        // TODO: callback?
                    }
                }.connect,

                .onDisconnect = struct {
                    fn disconnect(server: *apenetwork.Server, client: *apenetwork.Client) void {
                        const http_server : *Self = @fieldParentPtr("server", server);
                        var http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.ctx() orelse return));

                        if (http_request.user_ctx) |ctx| {

                            const handler : *T = @ptrCast(@alignCast(ctx));

                            if (std.meta.hasFn(T, "onDisconnect")) {
                                handler.onDisconnect();
                            }

                            handler.deinit();
                        }

                        http_request.deinit();
                        http_server.requests_pool.destroy(http_request);
                    }
                }.disconnect,

                .onData = struct {
                    fn ondata(server: *apenetwork.Server, client: *apenetwork.Client, data: []const u8) !void {

                        const http_server : *Self = @fieldParentPtr("server", server);
                        const http_request : *HttpRequestCtx = @ptrCast(@alignCast(client.ctx() orelse {
                            client.close(.now);
                            return error.HttpContextError;
                        }));

                        errdefer {
                            http_request.response(400, "", true);
                        }

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
                                    try userctx.onRequest(http_request, client);
                                }
                            },

                            else => {}
                        }
                    }
                }.ondata
            });
        }

    };
}

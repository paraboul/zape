pub const c = @import("c.zig").c;
const std = @import("std");
const builtin = @import("builtin");

pub const ShutdownAction = enum {
    queue,
    now,
};

pub const DataLifetime = enum {
    static,
    own,
    copy
};

pub fn callAsync(comptime callback: anytype, args: anytype) ?*anyopaque {
    const gape = c.APE_get();

    const wrapper = struct {
        fn wrappedCallback(arg: ?*anyopaque) callconv(.C) c_int {
            return @call(.always_inline, callback, .{@as(@TypeOf(args), @ptrCast(@alignCast(arg)))});
        }
    };

    return c.APE_async(gape, wrapper.wrappedCallback, @constCast(args));
}

pub fn deleteAsync(ref: ?*anyopaque) void {
    const gape = c.APE_get();

    c.APE_async_destroy(gape, @ptrCast(ref));
}


// This is just an empty wrapper around c.ape_socket
// It's meant to be casted from a c.ape_socket pointer and never be allocated itself
pub const Client = struct {
    const Self = @This();

    pub fn write(self: *Self, data: []const u8, lifetime: DataLifetime) void {
        _ = c.APE_socket_write(@ptrCast(@alignCast(self)), @constCast(data.ptr), data.len, switch (lifetime) {
           .static => c.APE_DATA_STATIC,
           .own => c.APE_DATA_OWN,
           .copy => c.APE_DATA_COPY
        });
    }

    pub fn tcpBufferStart(self: *Self) void {
        switch (builtin.os.tag) {
            .linux => {
                const state : u8 = 1;
                const socket : [*c]c.ape_socket = @ptrCast(@alignCast(self));
                std.posix.setsockopt(socket.*.s.fd, std.posix.IPPROTO.TCP, std.posix.TCP.CORK, &std.mem.toBytes(@as(c_int, state))) catch return;
            },
            else => {}
        }
    }

    pub fn tcpBufferEnd(self: *Self) void {
        switch (builtin.os.tag) {
            .linux => {
                const state : u8 = 0;
                const socket : [*c]c.ape_socket = @ptrCast(@alignCast(self));
                std.posix.setsockopt(socket.*.s.fd, std.posix.IPPROTO.TCP, std.posix.TCP.CORK, &std.mem.toBytes(@as(c_int, state))) catch return;
            },
            else => {}
        }
    }

    pub fn close(self: *Self, action: ShutdownAction) void {
        switch (action) {
            .now => c.APE_socket_shutdown_now(@ptrCast(@alignCast(self))),
            .queue => c.APE_socket_shutdown(@ptrCast(@alignCast(self)))
        }
    }

    pub fn getAddr(self: *Self) [*:0]u8 {
        // XXX This is using inet_ntoa and so not thread safe
        // as it's using a globally shared buffer to store that string
        return c.APE_socket_ipv4(@ptrCast(@alignCast(self)));
    }

    pub fn ctx(self: *Self) ?*anyopaque {
        const socket : [*c]c.ape_socket = @ptrCast(@alignCast(self));
        return socket.*.ctx;
    }

    pub fn setCtx(self: *Self, ptr: ?*anyopaque) void {
        const socket : [*c]c.ape_socket = @ptrCast(@alignCast(self));
        socket.*.ctx = ptr;
    }
};

const ServerCallbacks = struct {
    onConnect: ?fn (*Server, *Client) void = null,
    onDisconnect: ?fn (*Server, *Client) void = null,
    onData: ?fn (*Server, *Client, []const u8) anyerror!void = null
};

const ServerConfig = struct {
    port: u16,
    address: [] const u8 = "0.0.0.0",
};

pub const Server = struct {
    const Self = @This();

    config: ServerConfig,

    socket : [*c]c.ape_socket = null,

    pub fn init(config: ServerConfig) !Server {
        return .{
            .socket = c.APE_socket_new(c.APE_SOCKET_PT_TCP, 0, c.APE_get()),
            .config = config
        };
    }

    pub fn deinit(self: *Server) void {
        c.APE_socket_shutdown(self.socket);
    }

    pub fn start(self: *Self, comptime callbacks: ServerCallbacks) !void {

        if (c.APE_socket_listen(self.socket, self.config.port, self.config.address.ptr, 0, 0) == -1) {
            return error.APE_socket_listen_error;
        }

        self.socket.*.callbacks.arg = self;

        self.socket.*.callbacks.on_connect = struct {
            fn callback(_: [*c]c.ape_socket, _client: [*c]c.ape_socket, _: [*c]c.ape_global, srv: ?*anyopaque) callconv(.C) void {

                const ctx : *Self = @ptrCast(@alignCast(srv));
                const client : *Client = @ptrCast(_client);

                if (callbacks.onConnect) |onconnect| {
                    @call(.always_inline, onconnect, .{ ctx, client });
                }
            }
        }.callback;

        self.socket.*.callbacks.on_disconnect = struct {
            fn callback(_client: [*c]c.ape_socket, _: [*c]c.ape_global, srv: ?*anyopaque) callconv(.C) void {

                const ctx : *Self = @ptrCast(@alignCast(srv));
                const client : *Client = @ptrCast(_client);

                if (callbacks.onDisconnect) |ondisconnect| {
                    @call(.always_inline, ondisconnect, .{ ctx, client });
                }
            }
        }.callback;

        self.socket.*.callbacks.on_read = struct {
            fn callback(_client: [*c]c.ape_socket, data: [*c]const u8, len: usize, _: [*c]c.ape_global, srv: ?*anyopaque) callconv(.C) void {

                const ctx : *Self = @ptrCast(@alignCast(srv));
                const client : *Client = @ptrCast(_client);

                if (callbacks.onData) |ondata| {
                    @call(.always_inline, ondata, .{ ctx, client, data[0..len] }) catch return;
                }
            }
        }.callback;

    }
};

pub fn startLoop() void {
    c.APE_loop_run(c.APE_get());
}

pub fn stopLoop() void {
    c.APE_loop_stop();
}

pub fn init() void {
    _ = c.APE_init();
}

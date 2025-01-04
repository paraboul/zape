pub const c = @import("c.zig").c;
const std = @import("std");

pub fn callAsync(comptime callback: anytype, args: anytype) void {
    const gape = c.APE_get();


    const wrapper = struct {
        fn wrappedCallback(arg: ?*anyopaque) callconv(.C) c_int {
            return @call(.always_inline, callback, .{@as(@TypeOf(args), @ptrCast(@alignCast(arg)))});
        }
    };

    _ = c.APE_async(gape, wrapper.wrappedCallback, @constCast(args));
}

pub const Client = struct {
    const Self = @This();
    socket : [*c]c.ape_socket,

    pub fn write(self: *const Self, data: []const u8) void {
        _ = c.APE_socket_write(self.socket, @constCast(data.ptr), data.len, c.APE_DATA_OWN);
    }
};

pub const Server = struct {
    const Self = @This();

    socket : [*c]c.ape_socket = null,


    pub fn init() !Server {
        return .{
            .socket = c.APE_socket_new(c.APE_SOCKET_PT_TCP, 0, c.APE_get())
        };
    }

    pub fn start(self: *Self, port: u16, comptime connected: anytype, comptime ondata: anytype) !void {

        if (c.APE_socket_listen(self.socket, port, "0.0.0.0", 0, 0) == -1) {
            return error.APE_socket_listen_error;
        }

        self.socket.*.callbacks.arg = self;
        self.socket.*.callbacks.on_connect = struct {
            fn callback(_: [*c]c.ape_socket, _client: [*c]c.ape_socket, _: [*c]c.ape_global, srv: ?*anyopaque) callconv(.C) void {

                const ctx : *Self = @ptrCast(@alignCast(srv));
                const client = Client{.socket = _client};

                @call(.always_inline, connected, .{ ctx, &client });
            }
        }.callback;

        self.socket.*.callbacks.on_read = struct {
            fn callback(_client: [*c]c.ape_socket, data: [*c]const u8, len: usize, _: [*c]c.ape_global, srv: ?*anyopaque) callconv(.C) void {

                const ctx : *Self = @ptrCast(@alignCast(srv));
                const client = Client{.socket = _client};

                @call(.always_inline, ondata, .{ ctx, &client, data[0..len] });
            }
        }.callback;
    }

    pub fn write(_: *Self, client: anytype, data: []u8) void {
        c.APE_socket_write(client, data.ptr, data.len, c.APE_DATA_COPY);
    }
};



pub fn startLoop() void {
    c.APE_loop_run(c.APE_get());
}

pub fn init() void {
    _ = c.APE_init();

    std.debug.print(("APE init"), .{});
}

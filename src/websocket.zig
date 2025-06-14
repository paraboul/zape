const std = @import("std");
const apenetwork = @import("libapenetwork");

const maximum_preallocated_bytes_per_frame = 1024*1024;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const WebSocketConnectionType = enum {
    client,
    server
};

const ParsingState = enum {
    step_key,
    step_start,
    step_length,
    step_short_length,
    step_extended_length,
    step_data
};

pub const FrameState = enum {
    frame_start,
    frame_continue,
    frame_finish
};

pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _ // This is needed so that if we can cast an arbitraty
      //integer to this enum and fallback to unknown value
};

fn get_masking_key() u32 {

    // This is how you define static in zig
    // Make prng static so it's only initialized the first time it's called
    const S = struct {
        var prng: ?std.Random.DefaultPrng = null;
    };

    if (S.prng == null) {
        S.prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch @panic("Failed to get rand value");
            break :blk seed;
        });
    }

    return S.prng.?.random().int(u32);
}

fn get_sha1_accept_key(key: [] const u8, out: *[20]u8) !void {

    if (key.len > 32) {
        return error.KeyTooLong;
    }

    var buffer = try std.BoundedArray(u8, 64).init(0);

    try buffer.appendSlice(key);
    try buffer.appendSlice(ws_guid);

    std.crypto.hash.Sha1.hash(buffer.constSlice(), out, .{});
}

pub fn get_b64_accept_key(key: [] const u8, out: *[30] u8) ![] const u8 {
    var sha_hash : [20]u8 = undefined;
    try get_sha1_accept_key(key, &sha_hash);

    return std.base64.standard.Encoder.encode(out, &sha_hash);
}

pub fn WebSocketCallbacks(T: type, comptime contype: WebSocketConnectionType) type {
    return struct {
        on_message: ?* const fn(client: *WebSocketClient(contype), context: * const T, data: [] const u8, is_binary: bool, frame: FrameState) void = null
    };
}

pub fn WebSocketClient(comptime contype: WebSocketConnectionType) type {

    return struct {

        const Self = @This();
        client: apenetwork.Client,
        closed: bool = false,
        comptime connection_type: WebSocketConnectionType = contype,

        pub fn write(self: *const Self, data: []const u8, comptime opcode: OpCode, lifetime: apenetwork.DataLifetime) void {
            if (self.closed) {
                return;
            }

            var payload_head = [_]u8{0} ** 32;
            payload_head[0] = @as(u8, 0x80) | @intFromEnum(opcode);

            // Masking flag
            if (self.connection_type == .client) {
                payload_head[1] = 0x80;
            }

            self.client.tcpBufferStart();
            defer {
                self.client.tcpBufferEnd();
            }

            if (data.len <= 125) {
                const len : u7 = @truncate(data.len);

                payload_head[1] |= len;

                self.client.write(payload_head[0..2], lifetime);

            } else if (data.len <= 65535) {
                const len : u16 = @truncate(data.len);

                payload_head[1] = 126;
                std.mem.writeInt(u16, @ptrCast(&payload_head[2]), len, .big);

                self.client.write(payload_head[0..4], lifetime);

            } else if (data.len <= 0xFFFFFFFF) {
                payload_head[1] = 127;
                std.mem.writeInt(u64, @ptrCast(&payload_head[2]), data.len, .big);

                self.client.write(payload_head[0..10], lifetime);
            }

            if (data.len != 0) {
                if (self.connection_type == .client) {
                    // TODO Masking
                }
                self.client.write(data, lifetime);
            }
        }

        pub fn close(self: *Self) void {
            if (self.closed) {
                return;
            }

            self.closed = true;
            self.write(&.{}, .close, .static);
            self.client.close(.queue);
        }

        pub fn ping(self: *const Self, data: [] const u8) void {
            if (self.closed) {
                return;
            }

            self.write(data, .ping, .copy);
        }

        pub fn pong(self: *const Self, data: [] const u8) void {
            if (self.closed) {
                return;
            }

            self.write(data, .pong, .copy);
        }
    };
}

pub fn WebSocketState(T: type, comptime contype: WebSocketConnectionType) type {
    return struct {
        const Self = @This();

        buffer: std.ArrayList(u8),

        client: WebSocketClient(contype),

        context: *T,

        frame: struct {
            length: u64 = 0,
            header: u8 = 0,
            prevheader: u8 = 0,
            length_pos: u3 = 0
        } = .{},

        cipher: struct {
            key: [4]u8 = .{0, 0, 0, 0},
            pos: u2 = 0
        } = .{},

        data_inkey: u2 = 0,
        masking: bool = false,
        close_sent: bool = false,

        step: ParsingState = .step_start,
        comptime connection_type: WebSocketConnectionType = contype,

        callbacks: WebSocketCallbacks(T, contype),

        pub fn init(allocator: std.mem.Allocator, context: *T, client: apenetwork.Client, callbacks: WebSocketCallbacks(T, contype)) Self {
            return Self {
                .buffer = .init(allocator),
                .callbacks = callbacks,
                .context = context,
                .client = .{ .client = client }
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn process_data(self: *Self, data: []const u8) !void {
            for (data) |byte| {
                switch (self.step) {

                    .step_start => {
                        self.frame.header = byte;
                        self.step = .step_length;
                        self.data_inkey = 0;
                        self.cipher.pos = 0;
                        self.frame.length_pos = 0;
                        self.frame.length = 0;
                        try self.buffer.resize(0);
                    },

                    .step_length => {
                        self.masking = (byte & 0x80) != 0;

                        switch (byte & 0x7f) {
                            126 => self.step = .step_short_length,
                            127 => self.step = .step_extended_length,
                            else => {
                                self.frame.length = byte & 0x7f;
                                self.step = if (self.masking) .step_key else .step_data;
                            }
                        }

                        if (!self.masking and self.frame.length == 0) {
                            try self.end_message();
                            continue;
                        }
                    },

                    .step_short_length, .step_extended_length => {
                        self.frame.length |= @as(u64, @intCast(byte)) << @as(u6, @intCast(self.frame.length_pos * @as(u6, 8)));
                        var done_reading_length = false;

                        switch (self.step) {
                            .step_short_length => {
                                if (self.frame.length_pos == 1) {
                                    self.frame.length = @byteSwap(@as(u16, @intCast(self.frame.length)));

                                    done_reading_length = true;
                                }
                            },
                            .step_extended_length => {
                                if (self.frame.length_pos == 7) {
                                    self.frame.length = @byteSwap(@as(u64, @intCast(self.frame.length)));

                                    done_reading_length = true;
                                }
                            },
                            else => unreachable
                        }

                        if (done_reading_length) {
                            self.step = if (self.masking) .step_key else .step_data;
                        } else {
                            self.frame.length_pos += 1;
                        }
                    },

                    .step_key => {
                        self.cipher.key[self.cipher.pos] = byte;

                        if (self.cipher.pos == 3) {
                            self.step = .step_data;

                            if (self.frame.length == 0) {
                                try self.end_message();
                            }

                            continue;
                        }

                        self.cipher.pos += 1;
                    },

                    .step_data => {
                        const decoded_byte : u8 = byte ^ self.cipher.key[self.data_inkey];

                        if (self.buffer.capacity == 0) {
                            self.buffer.ensureTotalCapacity(@min(self.frame.length, maximum_preallocated_bytes_per_frame)) catch @panic("OOM");
                        }

                        self.buffer.append(decoded_byte) catch @panic("OOM");

                        if (self.buffer.items.len == self.frame.length) {
                            try self.end_message();
                            continue;
                        }

                        self.data_inkey +%= 1;
                    }
                }
            }
        }

        fn reset_state(self: *Self) void {
            self.step = .step_start;
        }

        fn end_message(self: *Self) !void {
            const opcode : OpCode = @enumFromInt(self.frame.header & 0x0f);
            const is_binary = opcode == .binary or (opcode == .continuation and (self.frame.prevheader & 0x0F) == 0x2);

            switch (opcode) {
                .continuation, .text, .binary => {
                    const is_fin = (self.frame.header & 0xf0) == 0x80;

                    const frame_state : FrameState = state: {
                        if (is_fin) {
                            break :state .frame_finish;
                        } else if (opcode == .continuation) {
                            break :state .frame_continue;
                        } else {
                            break :state .frame_start;
                        }
                    };

                    if (self.callbacks.on_message) |on_message| {
                        on_message(&self.client, self.context, self.buffer.items, is_binary, frame_state);
                    }
                },

                .close => {
                    // Uncomment if we ever need to read the close reason
                    //
                    // const reason : u16 = brk: {
                    //     if (self.buffer.items.len < 2) break :brk 0;
                    //     break :brk self.buffer.items[1] | @as(u16, @intCast(self.buffer.items[0])) << 8;
                    // };

                    self.client.close();
                },

                .ping => {
                    // Send pong back with the same Application data
                    self.client.pong(self.buffer.items);
                },

                .pong => {},

                _ => {
                    std.debug.print("Unsupported opcode\n", .{});
                }
            }

            self.reset_state();
        }
    };

}

const std = @import("std");
const apenetwork = @import("libapenetwork");


const maximum_preallocated_bytes_per_frame = 1024*1024;

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

pub const WebSocketCallbacks = struct {
    on_message: ?* const fn(data: [] const u8, is_binary: bool, frame: FrameState) void = null
};

pub fn WebSocketState(T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8),

        context: ?*T,

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

        data_inkey: u2 = 0, // Increment with data_inkey +%= 1
        masking: bool = false,
        close_sent: bool = false,

        step: ParsingState = .step_start,
        connection_type: WebSocketConnectionType,

        callbacks: WebSocketCallbacks,

        pub fn init(allocator: std.mem.Allocator, connection_type: WebSocketConnectionType, callbacks: WebSocketCallbacks) Self {
            return Self {
                .buffer = std.ArrayList(u8).init(allocator),
                .connection_type = connection_type,
                .allocator = allocator,
                .callbacks = callbacks,
                .context = null
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn process_data(self: *Self, data: []const u8) !void {

            std.debug.print("[Process] {d}\n", .{data.len});

            for (data) |byte| {
                switch (self.step) {
                    .step_key => {
                        self.cipher.key[self.cipher.pos] = byte;

                        if (self.cipher.pos == 3) {

                            // TODO: no length ? end message
                            self.step = .step_data;

                            continue;
                        }

                        self.cipher.pos += 1;
                    },

                    .step_start => {
                        self.frame.header = byte;
                        self.step = .step_length;
                        self.data_inkey = 0;
                        self.cipher.pos = 0;
                        self.frame.length_pos = 0;
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
            const opcode : u8 = self.frame.header & 0x7f;
            const is_binary = opcode == 0x2 or (opcode == 0x0 and (self.frame.prevheader & 0x0F) == 0x2);

            switch (opcode) {

                // 0x0 = Continuation frame
                // 0x1 = ASCII frame
                // 0x2 = binary frame
                0x0, 0x1, 0x2 => {
                    const is_fin = (self.frame.header & 0xF0) == 0x80;

                    const frame_state : FrameState = state: {
                        if (is_fin) {
                            break :state .frame_finish;
                        } else if (opcode == 0) {
                            break :state .frame_continue;
                        } else {
                            break :state .frame_start;
                        }
                    };

                    if (self.callbacks.on_message) |on_message| {
                        on_message(self.buffer.items, is_binary, frame_state);
                    }
                },

                // Close frame
                0x8 => {
                    const reason : u16 = brk: {
                        if (self.buffer.items.len < 2) break :brk 0;
                        break :brk self.buffer.items[1] | @as(u16, @intCast(self.buffer.items[0])) << 8;
                    };
                    std.debug.print("[Close frame] {d}\n", .{reason});
                },

                // Ping frame
                0x9 => {
                    std.debug.print("[Ping frame]\n", .{});
                },

                // Pong frame
                0xA => {
                    std.debug.print("[Pong frame]\n", .{});
                },

                // Unknown value
                else => {
                    std.debug.print("[Unknown frame]\n", .{});
                }
            }

            self.reset_state();
        }

    };

}

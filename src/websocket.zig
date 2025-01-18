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
    step_data,
    step_end
};

const FrameState = enum {
    frame_start,
    frame_continue,
    frame_finish
};

pub const WebSocketState = struct {
    allocator: std.mem.Allocator,

    buffer: std.ArrayList(u8),

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

    pub fn init(allocator: std.mem.Allocator, connection_type: WebSocketConnectionType) WebSocketState {
        return WebSocketState {
            .buffer = std.ArrayList(u8).init(allocator),
            .connection_type = connection_type,
            .allocator = allocator
        };
    }

    pub fn Create(allocator: std.mem.Allocator, connection_type: WebSocketConnectionType) !*WebSocketState {
        const ret = try allocator.create(WebSocketState);
        ret.* = WebSocketState.init(allocator, connection_type);

        return ret;
    }

    pub fn destroy(self: *WebSocketState) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *WebSocketState) void {
        self.buffer.deinit();
    }

    pub fn process_data(self: *WebSocketState, data: []const u8) !void {

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
                        // end message;
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
                        self.buffer.ensureUnusedCapacity(@min(self.frame.length, maximum_preallocated_bytes_per_frame)) catch @panic("OOM");
                    }

                    self.buffer.append(decoded_byte) catch @panic("OOM");

                    self.data_inkey +%= 1;
                },

                else => {

                }
            }
        }
    }

    fn end_message(self: *WebSocketState) !void {
        const opcode : u8 = self.frame.header & 0x7f;
        // var is_binary = opcode == 0x2 or (opcode == 0x0 and (self.prevheader & 0x0F) == 0x2);

        switch (opcode) {

            // 0x0 = Continuation frame
            // 0x1 = ASCII frame
            // 0x2 = binary frame
            0x0, 0x1, 0x2 => {
                // bool isfin = (self.frame.header & 0xF0) == 0x80;

                // if (isfin) {
                //     fs = WS_FRAME_FINISH;
                // } else if (opcode == 0) {
                //     fs = WS_FRAME_CONTINUE;
                // } else {
                //     fs = WS_FRAME_START;
                // }

                // websocket->on_frame(websocket, websocket->data,
                //                     websocket->data_inkey, isBinary, fs);
            },

            // Close frame
            0x8 => {

            },

            // Ping frame
            0x9 => {

            },

            // Pong frame
            0xA => {

            },

            // Unknown value
            else => {

            }
        }
    }

};

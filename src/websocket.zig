const std = @import("std");
const apenetwork = @import("libapenetwork");


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
    buffer: std.ArrayList(u8),
    frame_pos: u64 = 0,

    frame: struct {
        length: u64 = 0,
        header: u8 = 0,
        prevheader: u8 = 0
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
            .connection_type = connection_type
        };
    }

    pub fn deinit(self: *WebSocketState) void {
        self.buffer.deinit();
    }


    pub fn process_data(self: *WebSocketState, data: []const u8) !void {
        for (data) |byte| {
            switch(self.step) {
                .step_key => {

                },

                .step_start => {
                    self.frame.header = byte;
                    self.step = .step_length;
                },

                .step_length => {
                    self.masking = (byte & 0x80) != 0;

                    switch(byte & 0x7f) {
                        127 => self.step = .step_short_length,
                        128 => self.step = .step_extended_length,
                        else => {
                            self.frame.length = byte & 0x7f;
                            self.step = if (self.masking) .step_key else .step_data;
                        }
                    }

                    if (!self.masking and self.frame.length == 0) {
                        // end message;
                    }
                },

                .step_short_length => {

                },

                .step_extended_length => {

                },

                .step_data => {

                },

                else => {

                }
            }
        }
    },

    fn end_message(self: *WebSocketState) !void {
        const opcode : u8 = self.frame.header & 0x7f;
        var is_binary = opcode == 0x2 or (opcode == 0x0 and (self.prevheader & 0x0F) == 0x2);

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

pub const apenetwork = @import("libapenetwork");
pub const http = @import("./http.zig");
pub const websocket = @import("./websocket.zig");

pub fn init() void {
    apenetwork.init();
}

pub fn loop() void {
    apenetwork.startLoop();
}

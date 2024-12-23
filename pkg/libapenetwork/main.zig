pub const c = @import("c.zig").c;

pub fn init() void {
    _ = c.APE_init();
}

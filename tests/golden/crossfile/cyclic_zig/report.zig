pub fn open() void {}

pub fn close() void {
    @import("walker.zig").step();
}

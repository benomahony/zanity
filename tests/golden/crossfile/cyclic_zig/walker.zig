const report = @import("report.zig");

pub fn step() void {
    report.open();
    report.close();
}

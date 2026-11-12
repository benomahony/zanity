const rules = @import("rules.zig");

pub const Limit = 64;

pub fn run() u32 {
    return rules.first() + rules.second() + rules.third();
}

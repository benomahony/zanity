const helpers = @import("helpers.zig");

pub fn first() u32 {
    return helpers.split(1) + helpers.join(2);
}

pub fn second() u32 {
    return 2;
}

pub fn third() u32 {
    return 3;
}

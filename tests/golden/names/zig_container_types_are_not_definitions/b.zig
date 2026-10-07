pub const Mode = struct { level: u8 };

pub fn third() Mode {
    return .{ .level = 1 };
}

pub const Limit = 9;

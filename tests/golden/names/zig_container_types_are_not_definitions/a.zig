pub const Mode = enum { fast, safe };

pub fn first(flag: bool) u8 {
    const state: enum { idle, busy } = if (flag) .busy else .idle;
    return @intFromEnum(state);
}

pub fn second(flag: bool) u8 {
    const state: enum { open, shut } = if (flag) .open else .shut;
    return @intFromEnum(state) + @intFromEnum(Mode.fast);
}

pub const Limit = // the most a reading can be
    8;

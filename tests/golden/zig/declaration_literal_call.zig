const Size = struct {
    bytes: u64,

    fn fromBytes(bytes: u64) Size {
        return .{ .bytes = bytes };
    }

    fn copyOf(bytes: u64) Size {
        return .fromBytes(bytes);
    }
};

pub fn sizeOf(bytes: u64) Size {
    return Size.copyOf(bytes);
}

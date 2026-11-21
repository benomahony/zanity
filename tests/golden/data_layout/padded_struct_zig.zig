const Padded = extern struct {
    ready: bool,
    count: u64,
    small: bool,
};

const Ordered = extern struct {
    count: u64,
    ready: bool,
    small: bool,
};

const Reordered = struct {
    ready: bool,
    count: u64,
    small: bool,
};

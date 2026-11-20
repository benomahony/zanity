#[repr(C)]
struct Padded {
    ready: bool,
    count: u64,
    small: bool,
}

#[repr(C)]
struct Ordered {
    count: u64,
    ready: bool,
    small: bool,
}

struct Reordered {
    ready: bool,
    count: u64,
    small: bool,
}

fn even(n: u32) bool {
    if (n == 0) return true;
    return odd(n - 1);
}

fn odd(n: u32) bool {
    if (n == 0) return false;
    return even(n - 1);
}

const Node = struct {
    next: ?*Node,

    fn depth(self: *const Node) u32 {
        return 1 + self.depth();
    }

    fn sibling(self: *const Node, other: *const Node) u32 {
        return other.sibling(self);
    }
};

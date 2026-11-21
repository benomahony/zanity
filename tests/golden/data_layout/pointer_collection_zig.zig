const std = @import("std");

const Node = struct { id: u32 };

const Scene = struct {
    nodes: []*Node,
    fixed: [4]*const Node,
    list: std.ArrayList(*Node),
    flat: []Node,
    bytes: []const u8,
    by_value: std.ArrayList(Node),
};

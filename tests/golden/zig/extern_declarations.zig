pub extern fn ts_parser_new() ?*anyopaque;
extern fn ts_node_type(node: u32) [*:0]const u8;

fn defined() void {}

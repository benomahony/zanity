const std = @import("std");
const unused = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const parse = json.parse;
const Writer = std.Io.Writer;
// Kept until reading moves here.
const Reader = std.Io.Reader;

pub fn flush(writer: *Writer) !void {
    try writer.flush();
}

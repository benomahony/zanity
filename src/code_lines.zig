//! Marks physical source lines that contain code after syntax comments are excluded.
const std = @import("std");
const assert = @import("assert.zig");
const captures = @import("captures.zig");
const ts = @import("ts.zig");

pub const Input = struct {
    source: []const u8,
    in_comment: []bool,
    code_lines: []bool,
    captures: []const captures.Triple,
    comment_id: ?captures.Id,
    path: []const u8,
};

pub fn mark(input: Input) []bool {
    const in_comment = input.in_comment[0..input.source.len];
    @memset(in_comment, false);
    if (input.comment_id) |comment| {
        for (input.captures) |t| {
            if (t.id != comment) continue;
            @memset(in_comment[ts.ts_node_start_byte(t.node)..ts.ts_node_end_byte(t.node)], true);
        }
    }
    const rows = std.mem.count(u8, input.source, "\n") + 1;
    const code = input.code_lines[0..rows];
    @memset(code, false);
    var row: usize = 0;
    for (input.source, in_comment) |c, commented| {
        if (c == '\n') {
            row += 1;
            continue;
        }
        if (!commented and !std.ascii.isWhitespace(c)) code[row] = true;
    }
    if (row + 1 != rows) assert.panic("{s}: marked code on {d} lines of a {d}-line file; codeLines() must advance one row per newline, so check its loop", .{ input.path, row + 1, rows });
    if (code.len != rows) assert.panic("{s}: {d} code-line flags for {d} lines; size code_lines from the file's row count, as initCheckScratch() does with file_bytes + 1", .{ input.path, code.len, rows });
    return code;
}

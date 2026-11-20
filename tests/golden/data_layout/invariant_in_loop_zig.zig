const std = @import("std");

fn count(lines: []const []const u8, word: []const u8) usize {
    var found: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, std.mem.trim(u8, word, " ")) != null) found += 1;
    }
    return found;
}

fn each(lines: []const []const u8) usize {
    var found: usize = 0;
    for (lines) |line| found += std.mem.trim(u8, line, " ").len;
    return found;
}

fn nested(tables: []const []const []const u8, target: []const u8) bool {
    for (tables) |table| for (table) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), target)) return true;
    };
    return false;
}

fn parent(buffer: []const u8, parts: []const []const u8) usize {
    var len = buffer.len;
    for (parts) |part| {
        if (part.len == 0) continue;
        len = std.mem.lastIndexOfScalar(u8, buffer[0..len], '/') orelse 0;
    }
    return len;
}

const Cursor = struct {
    at: usize,

    fn skip(self: *Cursor, b: []const u8, comment: []const u8) void {
        for (0..b.len + 1) |_| {
            while (self.at < b.len and b[self.at] == ' ') self.at += 1;
            if (self.at == b.len or !std.mem.startsWith(u8, b[self.at..], comment)) return;
            self.at += comment.len;
        }
    }
};

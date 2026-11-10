//! Splitting a name into words, on anything not a letter or digit and where its case changes,
//! with nothing but the standard library, so any module can split names without the naming checks.
const std = @import("std");
const assert = @import("assert.zig");

/// The words of a name, split on anything not a letter or digit and where its case changes, as
/// slices of the name: `parseHTTPRequest` gives parse, HTTP, Request.
pub const Words = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        if (self.at > self.text.len) assert.panic("reading words of '{s}' from byte {d}, past its end; next() must stop at the end", .{ self.text, self.at });
        while (self.at < self.text.len and !std.ascii.isAlphanumeric(self.text[self.at])) self.at += 1;
        if (self.at == self.text.len) return null;
        const start = self.at;
        self.at += 1;
        while (self.at < self.text.len and std.ascii.isAlphanumeric(self.text[self.at]) and !caseBoundary(self.text, self.at)) self.at += 1;
        if (self.at <= start) assert.panic("a word of '{s}' at byte {d} is empty; next() must take at least one byte", .{ self.text, start });
        return self.text[start..self.at];
    }
};

pub fn caseBoundary(name: []const u8, i: usize) bool {
    if (i == 0 or i >= name.len) assert.panic("checked for a word boundary at byte {d} of '{s}' ({d} bytes); only bytes 1..{d} can start a word", .{ i, name, name.len, name.len -| 1 });
    const previous = name[i - 1];
    const current = name[i];
    if (std.ascii.isUpper(current) and (std.ascii.isLower(previous) or std.ascii.isDigit(previous))) return true;
    const acronym_end = std.ascii.isUpper(previous) and std.ascii.isUpper(current) and i + 1 < name.len and std.ascii.isLower(name[i + 1]);
    if (acronym_end and i + 1 >= name.len) assert.panic("'{s}': an acronym ending at byte {d} needs a lowercase byte after it; caseBoundary() must end an acronym before its last capital", .{ name, i });
    return acronym_end;
}

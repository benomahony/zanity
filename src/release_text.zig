//! Reading the text of a workflow line: comments, quotes, block scalars, setting values and the
//! words in a reusable workflow's name.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");

/// How much of a command line is inspected for check and release commands.
pub const command_window_bytes = 512;
/// Words in the path of a reusable workflow zanity cannot read that say it runs the checks.
const check_workflow_words = [_][]const u8{ "test", "tests", "check", "checks", "ci", "lint", "verify" };

/// `text` lowercased without spaces, newlines or double quotes, so conditions compare by content.
pub fn squeeze(buffer: *[command_window_bytes]u8, text: []const u8) []const u8 {
    var len: usize = 0;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (len == buffer.len) break;
        buffer[len] = if (c == '"') '\'' else std.ascii.toLower(c);
        len += 1;
    }
    if (len > text.len) assert.panic("squeezed {d} bytes into {d}; squeezing only drops bytes", .{ text.len, len });
    if (std.mem.indexOfAny(u8, buffer[0..len], " \t\r\n\"") != null) assert.panic("squeezing '{s}' left whitespace or a double quote in '{s}'", .{ text, buffer[0..len] });
    return buffer[0..len];
}

/// `text` lowercased, with quoted strings and comments blanked, so words in messages don't count.
pub fn unquote(buffer: *[command_window_bytes]u8, text: []const u8) []const u8 {
    const kept = @min(text.len, buffer.len);
    var quote: ?u8 = null;
    for (text[0..kept], 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            buffer[i] = ' ';
            continue;
        }
        if (c == '#' and (i == 0 or text[i - 1] == ' ')) {
            @memset(buffer[i..kept], ' ');
            break;
        }
        if (c == '"' or c == '\'') quote = c;
        buffer[i] = if (quote != null) ' ' else std.ascii.toLower(c);
    }
    if (kept > text.len) assert.panic("kept {d} bytes of a {d}-byte command", .{ kept, text.len });
    if (std.mem.indexOfAny(u8, buffer[0..kept], "\"'") != null) assert.panic("unquoting '{s}' left a quote in '{s}'", .{ text, buffer[0..kept] });
    return buffer[0..kept];
}

fn hasWord(text: []const u8, words: []const []const u8) bool {
    if (words.len == 0) assert.panic("looking for none of no words in '{s}'; pass a word list", .{text});
    for (words) |word| if (word.len == 0) assert.panic("looking for an empty word in '{s}'; every listed word must have letters", .{text});
    var tokens = std.mem.tokenizeAny(u8, text, " \t-_./:;&|()=$,[]{}<>!");
    while (tokens.next()) |token| if (strings.contains(words, token)) return true;
    return false;
}

pub fn namesChecks(workflow: []const u8) bool {
    if (std.mem.indexOfScalar(u8, workflow, '\n') != null) assert.panic("'{s}' spans lines, but a job's uses: value is one line", .{workflow});
    if (workflow.len == 0) return false;
    var buffer: [command_window_bytes]u8 = undefined;
    const lowered = unquote(&buffer, std.fs.path.stem(workflow));
    if (lowered.len > workflow.len) assert.panic("lowercased '{s}' into more bytes", .{workflow});
    return hasWord(lowered, &check_workflow_words);
}

pub fn afterKey(content: []const u8) ?[]const u8 {
    if (content.len == 0) assert.panic("reading the value of an empty setting; line() skips blank lines", .{});
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return null;
    if (colon >= content.len) assert.panic("found a colon at {d} in a {d}-byte setting", .{ colon, content.len });
    return content[colon + 1 ..];
}

pub fn blockScalar(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but a setting's value is read one line at a time", .{value});
    const indicator = std.mem.trim(u8, value, " ");
    if (indicator.len > value.len) assert.panic("trimming '{s}' made it longer", .{value});
    if (indicator.len > 3) return false;
    return indicator.len > 0 and (indicator[0] == '|' or indicator[0] == '>');
}

pub fn withoutComment(value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but comments are stripped one line at a time", .{value});
    const comment = std.mem.indexOf(u8, value, " #") orelse value.len;
    if (comment > value.len) assert.panic("found a comment past the end of '{s}'", .{value});
    return std.mem.trimEnd(u8, value[0..comment], " ");
}

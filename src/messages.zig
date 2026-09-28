//! The mechanical checks of error messages: empty, a bare code, stock words, and for an
//! assertion, a message that only restates its condition or hides the values it reads.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;
const rewrite = @import("rewrite.zig");
const hazards = @import("hazards.zig");

/// The mechanical checks of an error message written as a plain string: empty, a bare code,
/// stock words, and for an assertion, whether it only restates its condition or hides its values.
/// Whether a message misleads or fails to guide is left to `check --infer`.
pub fn checkMessage(self: *File, node: ts.Node, condition: ?ts.Node) !void {
    if (ts.ts_node_end_byte(node) > self.source.len) std.debug.panic("{s}: the message {f} ends past the {d}-byte file", .{ self.work.facts.path, node.where(), self.source.len });
    if (self.enclosingFunction()) |function| function.has_message = true;
    if (!self.index.marks(node, self.v.literal_string)) return;
    const content = stringContent(node.text(self.source));
    var words: MessageWords = .{};
    words.split(content);
    const has_values = self.index.marks(node, self.v.string_format) or (words.placeholders > 0 and anyIn(content, self.tables.format_markers));
    const shown = content[0..@min(content.len, 80)];
    if (words.len == 0) {
        if (!has_values) _ = try self.report(node, "vague-error", try self.say("This error message is empty, so whoever hits it learns nothing about what failed.", .{}));
        return;
    }
    if (!has_values and looksLikeCode(content)) {
        _ = try self.report(node, "cryptic-error", try self.say("'{s}' is a code or an internal name, not an explanation, so whoever hits it can't tell what went wrong.", .{shown}));
        return;
    }
    if (!has_values and words.allIn(&rules.vague_words)) {
        _ = try self.report(node, "vague-error", try self.say("'{s}' doesn't say which input or value failed, or what was expected.", .{shown}));
        return;
    }
    const tested = condition orelse return;
    words.has_values = has_values;
    try checkAgainstCondition(self, node, tested, &words);
    if (words.len > MessageWords.max) std.debug.panic("{s}: kept {d} words of the message {f} in room for {d}", .{ self.work.facts.path, words.len, node.where(), MessageWords.max });
}

pub fn checkAgainstCondition(self: *File, node: ts.Node, condition: ts.Node, words: *const MessageWords) !void {
    if (words.len == 0) std.debug.panic("{s}: comparing the empty message {f} with its condition; checkMessage handles empty messages", .{ self.work.facts.path, node.where() });
    const has_values = words.has_values;
    const tested = condition.text(self.source);
    var condition_words: MessageWords = .{};
    condition_words.split(tested);
    if (words.restates(&condition_words)) {
        _ = try self.report(node, "unconstructive-error", try self.say("This message only restates the condition '{s}', so it says what broke but not why it must hold or what to change.", .{tested[0..@min(tested.len, 80)]}));
    }
    const null_check = self.index.marks(condition, self.v.compare_not_null);
    if (has_values or null_check or self.index.marks(condition, self.v.compare_equal) or settlesItsValues(tested)) return;
    var buffer: [4][]const u8 = undefined;
    const values = rewrite.conditionValues(self, condition, &buffer);
    if (values.len == 0) return;
    const start = self.work.text.used;
    for (values, 0..) |v, i| _ = try self.work.text.format("{s}'{s}'", .{ if (i == 0) "" else ", ", v });
    const listed = self.work.text.buffer[start..self.work.text.used];
    _ = try self.report(node, "vague-error", try self.say("This message shows none of the values its condition reads ({s}), so a failure can't be diagnosed from the message alone.", .{listed}));
    if (listed.len < values.len) std.debug.panic("{s}: listing {d} values wrote only {d} bytes", .{ self.work.facts.path, values.len, listed.len });
}

/// The words of a message or condition, lowercased on comparison, with placeholders such as
/// `{d}`, `${name}` or `%s` counted and left out.
pub const MessageWords = struct {
    const max = 48;
    list: [max][]const u8 = undefined,
    len: usize = 0,
    placeholders: usize = 0,
    has_values: bool = false,

    fn split(self: *MessageWords, text: []const u8) void {
        if (self.len != 0) std.debug.panic("splitting '{s}' into a word list that already holds {d} words", .{ text, self.len });
        var i: usize = 0;
        var start: ?usize = null;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            const word = std.ascii.isAlphanumeric(c) or c == '_' or c == '\'';
            if (word) {
                if (start == null) start = i;
                continue;
            }
            if (start) |from| self.keep(text[from..i]);
            start = null;
            if (placeholderEnd(text, i)) |last| {
                self.placeholders += 1;
                i = last;
            }
        }
        if (start) |from| self.keep(text[from..]);
        if (self.len > max) std.debug.panic("kept {d} words of '{s}' in room for {d}", .{ self.len, text, max });
    }

    /// The last byte of a placeholder starting at `i`, such as `{d}`, `${name}` or `%s`, or null.
    fn placeholderEnd(text: []const u8, i: usize) ?usize {
        if (i >= text.len) std.debug.panic("looked for a placeholder at byte {d} of the {d}-byte '{s}'", .{ i, text.len, text });
        const c = text[i];
        const next: u8 = if (i + 1 < text.len) text[i + 1] else 0;
        if (c == '{' or (c == '$' and next == '{')) return std.mem.indexOfScalarPos(u8, text, i, '}') orelse text.len;
        if (c != '%' or !(std.ascii.isAlphabetic(next) or next == '(')) return null;
        var end = i + 1;
        while (end + 1 < text.len and (std.ascii.isAlphanumeric(text[end + 1]) or text[end + 1] == ')')) end += 1;
        if (end <= i) std.debug.panic("the placeholder at byte {d} of '{s}' ended before it began", .{ i, text });
        return end;
    }

    fn keep(self: *MessageWords, word: []const u8) void {
        if (word.len == 0) std.debug.panic("splitting a message produced an empty word before {d} others", .{self.len});
        if (self.len == max) return;
        self.list[self.len] = word;
        self.len += 1;
        if (self.len > max) std.debug.panic("stored {d} words in room for {d}", .{ self.len, max });
    }

    fn allIn(self: *const MessageWords, vocabulary: []const []const u8) bool {
        if (self.len == 0) std.debug.panic("asked whether no words are all stock words; check for an empty message first", .{});
        const all = for (self.list[0..self.len]) |w| {
            if (!inVocabulary(vocabulary, w)) break false;
        } else true;
        if (vocabulary.len == 0) std.debug.panic("compared {d} words with an empty vocabulary", .{self.len});
        return all;
    }

    /// Whether every word that isn't framing, like "expected" or "got", also appears in `condition`.
    fn restates(self: *const MessageWords, condition: *const MessageWords) bool {
        if (self.len == 0) std.debug.panic("asked whether an empty message restates its condition", .{});
        var meaningful: usize = 0;
        for (self.list[0..self.len]) |w| {
            if (inVocabulary(&rules.filler_words, w)) continue;
            meaningful += 1;
            if (!inVocabulary(condition.list[0..condition.len], w)) return false;
        }
        if (meaningful > self.len) std.debug.panic("counted {d} meaningful words out of {d}", .{ meaningful, self.len });
        return meaningful > 0;
    }
};

pub fn inVocabulary(vocabulary: []const []const u8, word: []const u8) bool {
    if (word.len == 0) std.debug.panic("looked up an empty word among {d}", .{vocabulary.len});
    const singular = if (word.len > 3 and (word[word.len - 1] == 's' or word[word.len - 1] == 'S')) word[0 .. word.len - 1] else word;
    const found = for (vocabulary) |v| {
        if (std.ascii.eqlIgnoreCase(v, word) or std.ascii.eqlIgnoreCase(v, singular)) break true;
    } else false;
    if (found and vocabulary.len == 0) std.debug.panic("found '{s}' in an empty vocabulary", .{word});
    return found;
}

/// The text inside a string literal: prefixes such as `f` or `r#` and the quotes removed.
pub fn stringContent(literal: []const u8) []const u8 {
    if (literal.len == 0) std.debug.panic("asked for the content of an empty string literal; the capture matched no text", .{});
    const unprefixed = std.mem.trimStart(u8, literal, "rbufRBUF@#");
    const content = std.mem.trim(u8, std.mem.trim(u8, unprefixed, "#"), "\"'`");
    if (content.len > literal.len) std.debug.panic("the content of '{s}' came out longer than the literal", .{literal});
    return std.mem.trim(u8, content, " \t\n.");
}

/// A message that is one token shaped like an identifier or a code: `E1234`, `ERR_TIMEOUT`, `OutOfMemory`.
pub fn looksLikeCode(content: []const u8) bool {
    if (content.len == 0) std.debug.panic("asked whether an empty message is a code; check for an empty message first", .{});
    if (std.mem.indexOfAny(u8, content, " \t\n") != null) return false;
    var upper: usize = 0;
    var letters: usize = 0;
    var marks: usize = 0;
    for (content, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) letters += 1;
        if (std.ascii.isUpper(c)) upper += 1;
        if (c == '_' or c == '.' or c == ':' or std.ascii.isDigit(c) or (i > 0 and std.ascii.isUpper(c))) marks += 1;
    }
    if (upper > letters) std.debug.panic("counted {d} capitals among {d} letters of '{s}'", .{ upper, letters, content });
    return marks > 0 or (letters > 1 and upper == letters);
}

/// Whether a failing condition already fixes every value it reads: only equalities, booleans
/// and their combinations, with no ordering comparison, no `!=` and no call.
pub fn settlesItsValues(condition: []const u8) bool {
    if (condition.len == 0) std.debug.panic("asked whether an empty condition settles its values; the capture matched no text", .{});
    const open = std.mem.indexOfAny(u8, condition, "<>(") != null or std.mem.indexOf(u8, condition, "!=") != null;
    if (open and condition.len == 1) std.debug.panic("'{s}' is a lone operator, not a condition", .{condition});
    return !open;
}

pub fn anyIn(text: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (n.len == 0) std.debug.panic("a format marker in languages/tables.zon is empty; remove it", .{});
        if (std.mem.indexOf(u8, text, n) != null) return true;
    }
    if (needles.len > 16) std.debug.panic("{d} format markers is more than a language has; check languages/tables.zon", .{needles.len});
    return false;
}

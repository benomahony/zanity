//! `ddd.yaml`: the project's words for things, in the shape of a Contextive glossary, so one file
//! gives editors their hovers and zanity its checks. It lists bounded contexts, each with the
//! files it covers and its terms; a context with no paths holds the words of the whole project.
//! zanity reads the YAML that shape needs (mappings, block and flow lists, plain and quoted
//! strings) and skips what only Contextive uses, such as definitions and examples.
//!
//!     directional: [to, from]                  # words that give a name its direction
//!     contexts:
//!       - name: Shared                         # no paths, so its words apply everywhere
//!         forbidden: [util, manager]           # never in a name
//!         terms:
//!           - name: customer                   # the project's word
//!             aliases: [client, user]          # the words it replaces
//!       - name: Billing
//!         kind: context                        # or domain; a context's words win over a domain's
//!         paths: [src/billing/**]              # gitignore syntax, relative to this file
//!         forbidden: [discount]
//!         terms:
//!           - name: invoice
//!             definition: What a customer is asked to pay.
//!             aliases: [bill, statement]
const std = @import("std");
const assert = @import("assert.zig");
const config = @import("config.zig");
const Config = config.Config;
const Scope = config.Scope;
const Term = config.Term;
const Error = config.Error;

pub const glossary_file = "ddd.yaml";

/// Reads the glossary into `settings`, reporting the first problem in config.problem. Strings are
/// decoded in place, so `bytes` must outlive the config.
pub fn parseGlossary(bytes: []u8, settings: *Config) Error!void {
    if (bytes.len > config.max_file_bytes) assert.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ glossary_file, bytes.len, config.max_file_bytes });
    if (settings.terms_len != 0 or settings.scopes_len != 0) assert.panic("reading {s} into a config that already has {d} terms and {d} contexts; only the glossary adds them, so read it once", .{ glossary_file, settings.terms_len, settings.scopes_len });
    var reader: YamlReader = .{ .text = .{ .bytes = bytes, .file = glossary_file } };
    const text = &reader.text;
    text.skipBlank();
    if (text.at == bytes.len) return;
    if (reader.column() != 0) return text.fail("the first key is indented; start the file's keys at the left margin, such as contexts:.", .{});
    try reader.readTop(settings);
    text.skipBlank();
    if (text.at != bytes.len) return text.fail("this line is indented differently from the keys above it; line it up with the key it belongs beside.", .{});
}

const max_items = config.max_excludes;

/// The keys lined up at `indent`, read one at a time.
const Mapping = struct { indent: usize, started: bool = false };

/// The '- ' items of a list under a key at `indent`, read one at a time; `column` is where they
/// line up, once the first is found.
const List = struct { indent: usize, column: ?usize = null };

const YamlReader = struct {
    text: config.TomlReader,
    items: [max_items][]const u8 = undefined,
    /// The context being read, added once its paths are known.
    context: Scope = .{ .name = "", .context = true, .line = 1 },
    /// The term being read, and its aliases and their line until it ends.
    term: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    aliases_line: u32 = 1,

    /// How far the reading position is from the start of its line.
    fn column(self: *const YamlReader) usize {
        const text = &self.text;
        if (text.at > text.bytes.len) assert.panic("finding the column of byte {d} in a {d}-byte file; nothing may move the reader past the end", .{ text.at, text.bytes.len });
        const start = if (std.mem.lastIndexOfScalar(u8, text.bytes[0..text.at], '\n')) |i| i + 1 else 0;
        if (start > text.at) assert.panic("the line holding byte {d} starts after it, at {d}; column() must look only before the reading position", .{ text.at, start });
        return text.at - start;
    }

    /// Whether the line at the reading position belongs to the value of a key at `indent`: it is
    /// indented further, or is a list item lined up with the key.
    fn childOf(self: *const YamlReader, indent: usize) bool {
        const text = &self.text;
        if (text.at > text.bytes.len) assert.panic("checking indentation at byte {d} of a {d}-byte file; nothing may move the reader past the end", .{ text.at, text.bytes.len });
        if (text.at == text.bytes.len) return false;
        const at_column = self.column();
        if (at_column > text.at) assert.panic("column {d} at byte {d}; a column can't be past the bytes before it", .{ at_column, text.at });
        return at_column > indent or (at_column == indent and text.peek() == '-');
    }

    /// Moves past the mapping's next key and its colon, returning the key; null once a line is
    /// indented less than the keys, or starts the next item of a list.
    fn nextKey(self: *YamlReader, mapping: *Mapping) Error!?[]const u8 {
        const text = &self.text;
        if (mapping.started) {
            text.skipBlank();
            if (text.at == text.bytes.len or self.column() != mapping.indent or text.peek() == '-') return null;
        }
        mapping.started = true;
        const key = text.readKey() orelse return text.fail("expected a key such as 'name:'; write each setting as name: value.", .{});
        if (text.peek() != ':') return text.fail("expected ':' after '{s}'; write each setting as name: value.", .{key});
        text.at += 1;
        text.skipSpaces();
        if (key.len == 0) assert.panic("read an empty key at byte {d}; readKey() returns null when it reads nothing", .{text.at});
        if (text.at > text.bytes.len) assert.panic("reading the key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
        return key;
    }

    /// Moves to the content of the list's next item and returns the line its dash is on; null once
    /// a line is indented less, or isn't an item.
    fn nextItem(self: *YamlReader, list: *List) Error!?u32 {
        const text = &self.text;
        text.skipBlank();
        if (text.at == text.bytes.len) return null;
        const dash_column = self.column();
        if (list.column) |lined_up| {
            if (dash_column != lined_up or text.peek() != '-') return null;
        } else if (self.childOf(list.indent)) {
            list.column = dash_column;
        } else return null;
        if (text.peek() != '-') return text.fail("expected '- ' to start an item of the list; begin each item with a dash.", .{});
        const item_line = text.line();
        text.at += 1;
        text.skipBlank();
        if (dash_column < list.indent) assert.panic("an item's dash at column {d} is left of its key at {d}; childOf() accepts only lines at or past the key", .{ dash_column, list.indent });
        if (text.at == text.bytes.len or self.column() <= dash_column) return text.failAt(item_line, "an item of the list is empty; write it after the dash.", .{});
        if (item_line == 0) assert.panic("an item on line 0; line() counts from 1", .{});
        return item_line;
    }

    /// The list of mappings after `key:`, one '- name: ...' item per line below; null for `[]`.
    fn mappingList(self: *YamlReader, key: []const u8, indent: usize) Error!?List {
        const text = &self.text;
        if (key.len == 0) assert.panic("reading a list for a key with no name at byte {d}; nextKey() reads a key first", .{text.at});
        if (text.peek() == '[') {
            text.at += 1;
            text.skipSpaces();
            if (text.peek() != ']') return text.fail("write each item of '{s}' on its own line, starting with '- name:'.", .{key});
            text.at += 1;
            try text.endLine();
            return null;
        }
        try text.endLine();
        if (text.at > text.bytes.len) assert.panic("reading the list '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
        return .{ .indent = indent };
    }

    /// The top-level keys: the contexts, and the words that give names a direction.
    fn readTop(self: *YamlReader, settings: *Config) Error!void {
        const text = &self.text;
        const start = text.at;
        var mapping: Mapping = .{ .indent = 0 };
        for (0..text.bytes.len) |_| {
            const key = (try self.nextKey(&mapping)) orelse break;
            if (std.mem.eql(u8, key, "contexts")) {
                var list = (try self.mappingList(key, 0)) orelse continue;
                for (0..text.bytes.len) |_| try self.readContext(settings, (try self.nextItem(&list)) orelse break);
            } else if (std.mem.eql(u8, key, "directional")) {
                const items = try self.readStrings(key, 0);
                if (items.len > config.max_directional) return text.fail("'directional' has more than {d} words; keep the ones names use.", .{config.max_directional});
                @memcpy(settings.directional[0..items.len], items);
                settings.directional_len = items.len;
            } else if (std.mem.eql(u8, key, "imports")) {
                self.skipValue(0);
            } else return text.fail("'{s}' isn't a top-level key; the keys are contexts, directional and imports.", .{key});
        }
        if (text.at <= start) assert.panic("reading the top-level keys at byte {d} consumed nothing; parseGlossary() calls readTop() only at a key", .{start});
        if (settings.directional_len > config.max_directional) assert.panic("{d} directional words in room for {d}; readTop() must refuse more", .{ settings.directional_len, config.max_directional });
    }

    /// One context, and its words, which take its scope once its paths are known: a context
    /// with none holds the words of the whole project.
    fn readContext(self: *YamlReader, settings: *Config, item_line: u32) Error!void {
        const first_term = settings.terms_len;
        self.context = .{ .name = "", .context = true, .line = item_line };
        var mapping: Mapping = .{ .indent = self.column() };
        for (0..self.text.bytes.len) |_| try self.readContextValue(settings, (try self.nextKey(&mapping)) orelse break, mapping.indent);
        const scope: u8 = if (self.context.include_len == 0) 0 else try self.addScope(settings);
        for (settings.terms[first_term..settings.terms_len]) |*term| term.scope = scope;
        if (scope > settings.scopes_len) assert.panic("gave a context's words scope {d} of {d}; addScope() numbers scopes from 1", .{ scope, settings.scopes_len });
        if (first_term > settings.terms_len) assert.panic("a context's words start at {d} of {d}; reading it may only add words", .{ first_term, settings.terms_len });
    }

    /// A key of a context: what it is called, which files it covers, and its words.
    fn readContextValue(self: *YamlReader, settings: *Config, key: []const u8, indent: usize) Error!void {
        const text = &self.text;
        const start = text.at;
        if (std.mem.eql(u8, key, "name")) {
            self.context.name = try self.readScalar(key, false);
            try text.endLine();
        } else if (std.mem.eql(u8, key, "kind")) {
            try self.readKind(key);
        } else if (std.mem.eql(u8, key, "paths")) {
            try self.readPaths(key, indent);
        } else if (std.mem.eql(u8, key, "forbidden")) {
            const at_line = text.line();
            for (try self.readStrings(key, indent)) |word| try self.addTerm(settings, .{ .scope = 0, .word = word, .line = at_line });
        } else if (std.mem.eql(u8, key, "terms")) {
            var list = (try self.mappingList(key, indent)) orelse return;
            for (0..text.bytes.len) |_| try self.readTerm(settings, (try self.nextItem(&list)) orelse break);
        } else if (std.mem.eql(u8, key, "domainVisionStatement") or std.mem.eql(u8, key, "meta")) {
            self.skipValue(indent);
        } else return text.fail("'{s}' isn't a context key; a context takes name, kind, paths, forbidden and terms, and Contextive's domainVisionStatement and meta.", .{key});
        if (text.at < start) assert.panic("reading the context key '{s}' moved back from byte {d} to {d}; it must only move forward", .{ key, start, text.at });
        if (text.at > text.bytes.len) assert.panic("reading the context key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
    }

    /// Whether the context is a context, whose words win, or a domain.
    fn readKind(self: *YamlReader, key: []const u8) Error!void {
        const kind = try self.readScalar(key, false);
        const is_context = std.mem.eql(u8, kind, "context");
        if (!is_context and !std.mem.eql(u8, kind, "domain")) return self.text.fail("kind is '{s}'; it must be context or domain.", .{kind});
        self.context.context = is_context;
        try self.text.endLine();
        if (kind.len == 0) assert.panic("accepted an empty kind; only context and domain pass", .{});
        if (self.context.context != std.mem.eql(u8, kind, "context")) assert.panic("kind '{s}' left the context's kind unchanged; readKind() must store it", .{kind});
    }

    /// The files a context covers, as gitignore patterns.
    fn readPaths(self: *YamlReader, key: []const u8, indent: usize) Error!void {
        const at_line = self.text.line();
        const items = try self.readStrings(key, indent);
        if (items.len > config.max_scope_globs) return self.text.failAt(at_line, "a context has more than {d} paths; use broader ones.", .{config.max_scope_globs});
        for (items) |glob| if (glob.len == 0) return self.text.failAt(at_line, "a path of a context is empty; name the files it covers.", .{});
        @memcpy(self.context.include[0..items.len], items);
        self.context.include_len = items.len;
        if (self.context.include_len > config.max_scope_globs) assert.panic("kept {d} paths in room for {d}; readPaths() must refuse more", .{ self.context.include_len, config.max_scope_globs });
        if (at_line == 0) assert.panic("paths on line 0; line() counts from 1", .{});
    }

    /// Adds the context just read as a scope, returning its number.
    fn addScope(self: *YamlReader, settings: *Config) Error!u8 {
        const wanted = self.context;
        if (wanted.include_len == 0) assert.panic("adding the context '{s}', which has no paths, as a scope; its words belong to the whole project", .{wanted.name});
        if (wanted.name.len == 0) return self.text.failAt(wanted.line, "a context with paths has no name; give it one, such as name: Billing.", .{});
        for (settings.scopes[0..settings.scopes_len]) |scope| {
            if (std.ascii.eqlIgnoreCase(scope.name, wanted.name)) return self.text.failAt(wanted.line, "the context '{s}' is listed twice; merge the two into one.", .{wanted.name});
        }
        if (settings.scopes_len == config.max_scopes) return self.text.failAt(wanted.line, "there are more than {d} contexts with paths; merge the ones that share their words.", .{config.max_scopes});
        settings.scopes[settings.scopes_len] = wanted;
        settings.scopes_len += 1;
        if (settings.scopes_len > config.max_scopes) assert.panic("{d} scopes in room for {d}; addScope() must refuse more", .{ settings.scopes_len, config.max_scopes });
        return @intCast(settings.scopes_len);
    }

    /// One term: its name, and the aliases to replace with it.
    fn readTerm(self: *YamlReader, settings: *Config, item_line: u32) Error!void {
        const before = settings.terms_len;
        self.term = null;
        self.aliases = &.{};
        var mapping: Mapping = .{ .indent = self.column() };
        for (0..self.text.bytes.len) |_| try self.readTermValue((try self.nextKey(&mapping)) orelse break, mapping.indent);
        try self.addAliases(settings, item_line);
        if (settings.terms_len < before) assert.panic("reading a term dropped words from {d} to {d}; it may only add them", .{ before, settings.terms_len });
        if (settings.terms_len - before > self.aliases.len) assert.panic("a term added {d} words for {d} aliases; each alias adds at most one", .{ settings.terms_len - before, self.aliases.len });
    }

    fn readTermValue(self: *YamlReader, key: []const u8, indent: usize) Error!void {
        const text = &self.text;
        const start = text.at;
        if (std.mem.eql(u8, key, "name")) {
            self.term = try self.readScalar(key, false);
            try text.endLine();
        } else if (std.mem.eql(u8, key, "aliases")) {
            self.aliases_line = text.line();
            self.aliases = try self.readStrings(key, indent);
        } else if (std.mem.eql(u8, key, "definition") or std.mem.eql(u8, key, "examples") or std.mem.eql(u8, key, "meta")) {
            self.skipValue(indent);
        } else return text.fail("'{s}' isn't a term key; a term takes name and aliases, and Contextive's definition, examples and meta.", .{key});
        if (text.at < start) assert.panic("reading the term key '{s}' moved back from byte {d} to {d}; it must only move forward", .{ key, start, text.at });
        if (text.at > text.bytes.len) assert.panic("reading the term key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
    }

    /// Adds each alias of the term just read as a word to replace with its name, in lower case so
    /// a respelled name keeps its own case. A name of several words can't be one word of an
    /// identifier, so its aliases are left to the glossary.
    fn addAliases(self: *YamlReader, settings: *Config, item_line: u32) Error!void {
        const text = &self.text;
        const name = self.term orelse return text.failAt(item_line, "a term has no name; give it one, such as name: invoice.", .{});
        if (name.len == 0) return text.failAt(item_line, "a term has no name; give it one, such as name: invoice.", .{});
        if (std.mem.indexOfAny(u8, name, " \t") != null) return;
        const offset = @intFromPtr(name.ptr) - @intFromPtr(text.bytes.ptr);
        if (offset + name.len > text.bytes.len) assert.panic("the term '{s}' is not inside the file; readScalar() returns slices of it", .{name});
        const canonical = text.bytes[offset..][0..name.len];
        for (canonical) |*c| c.* = std.ascii.toLower(c.*);
        for (self.aliases) |alias| {
            if (std.mem.indexOfAny(u8, alias, " \t") == null) try self.addTerm(settings, .{ .scope = 0, .word = alias, .canonical = canonical, .line = self.aliases_line });
        }
        if (canonical.len != name.len) assert.panic("lowering '{s}' changed its length to {d}; it must change only case", .{ name, canonical.len });
    }

    fn addTerm(self: *YamlReader, settings: *Config, term: Term) Error!void {
        if (term.line == 0) assert.panic("the word '{s}' has no line; line() counts from 1", .{term.word});
        if (term.word.len == 0) return self.text.failAt(term.line, "a word is empty; remove it or write the word.", .{});
        if (settings.terms_len == config.max_terms) return self.text.failAt(term.line, "the glossary has more than {d} words; keep the ones that matter most.", .{config.max_terms});
        settings.terms[settings.terms_len] = term;
        settings.terms_len += 1;
        if (settings.terms_len > config.max_terms) assert.panic("{d} terms in room for {d}; addTerm() must refuse more", .{ settings.terms_len, config.max_terms });
    }

    /// Skips the value of a key at `indent` that only Contextive uses: the rest of its line, and
    /// every line below indented further or listed under it, which covers text blocks such as `|`.
    fn skipValue(self: *YamlReader, indent: usize) void {
        const text = &self.text;
        const start = text.at;
        text.at = std.mem.indexOfScalarPos(u8, text.bytes, text.at, '\n') orelse text.bytes.len;
        for (0..text.bytes.len) |_| {
            text.skipBlank();
            if (!self.childOf(indent)) break;
            text.at = std.mem.indexOfScalarPos(u8, text.bytes, text.at, '\n') orelse text.bytes.len;
        }
        if (text.at < start) assert.panic("skipping a value moved back from byte {d} to {d}; skipValue() must only move forward", .{ start, text.at });
        if (text.at > text.bytes.len) assert.panic("skipping a value ran to byte {d} of {d}; it must stop at the end of the file", .{ text.at, text.bytes.len });
    }

    /// A list of strings: `[a, b]`, or one '- item' per line below the key.
    fn readStrings(self: *YamlReader, key: []const u8, indent: usize) Error![]const []const u8 {
        const text = &self.text;
        if (text.peek() == '[') return self.readFlow(key);
        if (text.peek()) |c| if (c != '\n' and c != '\r' and c != '#') return text.fail("'{s}' needs a list, such as {s}: [a, b], or one '- item' per line below it.", .{ key, key });
        var list: List = .{ .indent = indent };
        var count: usize = 0;
        for (0..text.bytes.len) |_| {
            _ = (try self.nextItem(&list)) orelse break;
            if (count == max_items) return text.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
            self.items[count] = try self.readScalar(key, false);
            count += 1;
            try text.endLine();
        }
        if (count > max_items) assert.panic("read {d} items of '{s}' in room for {d}; readStrings() must refuse more", .{ count, key, max_items });
        if (text.at > text.bytes.len) assert.panic("reading '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
        return self.items[0..count];
    }

    /// A list written inline, `[a, b]`, which may span lines.
    fn readFlow(self: *YamlReader, key: []const u8) Error![]const []const u8 {
        const text = &self.text;
        if (text.peek() != '[') assert.panic("reading an inline list for '{s}' that doesn't start with '['; readStrings() checks first", .{key});
        text.at += 1;
        var count: usize = 0;
        for (0..text.bytes.len) |_| {
            text.skipBlank();
            if (text.at == text.bytes.len or text.peek() == ']') break;
            if (count == max_items) return text.fail("'{s}' has more than {d} items; use fewer, broader ones.", .{ key, max_items });
            self.items[count] = try self.readScalar(key, true);
            count += 1;
            text.skipBlank();
            if (text.peek() == ',') text.at += 1;
        }
        if (text.peek() != ']') return text.fail("'{s}' opens a list that is never closed with ']'; separate its items with commas and close it after the last.", .{key});
        text.at += 1;
        try text.endLine();
        if (count > max_items) assert.panic("read {d} items of '{s}' in room for {d}; readFlow() must refuse more", .{ count, key, max_items });
        return self.items[0..count];
    }

    /// A quoted string, or a plain one; inside `[]` a plain one also ends at a comma or bracket.
    fn readScalar(self: *YamlReader, key: []const u8, flow: bool) Error![]const u8 {
        const text = &self.text;
        const first = text.peek() orelse return text.fail("'{s}' has no value; write one after the colon.", .{key});
        if (first == '"' or first == '\'') return text.readString(key);
        const start = text.at;
        const end = self.skipPlain(flow);
        if (end == start) return text.fail("'{s}' has an empty value; write one, or remove it.", .{key});
        if (end > text.at) assert.panic("a plain value for '{s}' ends at byte {d}, past the reading position {d}; skipPlain() must end it at a byte it read", .{ key, end, text.at });
        if (end < start) assert.panic("a plain value for '{s}' ends at byte {d}, before it starts at {d}", .{ key, end, start });
        return text.bytes[start..end];
    }

    /// Moves past a plain value, to the end of the line or a comment, and returns where it ends
    /// without its trailing spaces.
    fn skipPlain(self: *YamlReader, flow: bool) usize {
        const text = &self.text;
        const start = text.at;
        var end = start;
        while (text.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            if (c == '#' and (text.at == start or text.bytes[text.at - 1] == ' ')) break;
            if (flow and (c == ',' or c == ']')) break;
            text.at += 1;
            if (c != ' ' and c != '\t') end = text.at;
        }
        if (end < start or end > text.at) assert.panic("a plain value from byte {d} ends at {d}, outside what was read up to {d}", .{ start, end, text.at });
        if (text.at > text.bytes.len) assert.panic("reading a plain value ran to byte {d} of {d}; it must stop at the end of the file", .{ text.at, text.bytes.len });
        return end;
    }
};

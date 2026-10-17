//! `ddd.yaml`: the project's words for things, in the shape of a Contextive glossary, so one file
//! gives editors their hovers and zanity its checks; the same keys may sit in zanity.yaml instead.
//! It lists bounded contexts, each with the files it covers and its terms; a context with no
//! paths holds the words of the whole project.
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
const yaml = @import("yaml.zig");
const Config = config.Config;
const Scope = config.Scope;
const Term = config.Term;
const Error = config.Error;

pub const glossary_file = "ddd.yaml";

/// Reads ddd.yaml into `settings`, reporting the first problem in config.problem. Strings are
/// decoded in place, so `bytes` must outlive the config.
pub fn parseGlossary(bytes: []u8, settings: *Config) Error!void {
    if (bytes.len > config.max_file_bytes) assert.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ glossary_file, bytes.len, config.max_file_bytes });
    var text: yaml.Reader = .{ .bytes = bytes, .file = glossary_file };
    var mapping = (try text.topKeys()) orelse return;
    for (0..bytes.len) |_| {
        const key = (try text.nextKey(&mapping)) orelse break;
        if (!try readGlossaryKey(&text, settings, key)) return text.fail("'{s}' isn't a glossary key; the keys are contexts, directional and imports, and zanity's own settings go in zanity.yaml.", .{key});
    }
    try text.finish();
    if (text.at != bytes.len) assert.panic("stopped reading {s} at byte {d} of {d}; finish() must refuse anything left", .{ glossary_file, text.at, bytes.len });
}

/// Reads the top-level glossary key `key`, from zanity.yaml or ddd.yaml; false when it isn't one,
/// leaving the reader where it was. The glossary must sit in one of the two files.
pub fn readGlossaryKey(text: *yaml.Reader, settings: *Config, key: []const u8) Error!bool {
    const Key = enum { contexts, directional, imports };
    const which = std.meta.stringToEnum(Key, key) orelse return false;
    if (settings.glossary_file.len > 0 and !std.mem.eql(u8, settings.glossary_file, text.file)) return text.fail("the glossary is already in {s}; keep contexts and directional in one of the two files.", .{settings.glossary_file});
    settings.glossary_file = text.file;
    var glossary: Glossary = .{ .text = text, .settings = settings };
    switch (which) {
        .contexts => {
            var list = (try text.mappingList(key, 0)) orelse return true;
            for (0..text.bytes.len) |_| try glossary.readContext((try text.nextItem(&list)) orelse break);
        },
        .directional => {
            const items = try text.readStrings(key, 0);
            if (items.len > config.max_directional) return text.fail("'directional' has more than {d} words; keep the ones names use.", .{config.max_directional});
            @memcpy(settings.directional[0..items.len], items);
            settings.directional_len = items.len;
        },
        .imports => text.skipValue(0),
    }
    if (settings.directional_len > config.max_directional) assert.panic("{d} directional words in room for {d}; readGlossaryKey() must refuse more", .{ settings.directional_len, config.max_directional });
    if (settings.glossary_file.len == 0) assert.panic("read the glossary key '{s}' without noting which file holds the glossary", .{key});
    return true;
}

/// The context or term being read, until it ends.
const Glossary = struct {
    text: *yaml.Reader,
    settings: *Config,
    /// The context being read, added once its paths are known.
    context: Scope = .{ .name = "", .context = true, .line = 1 },
    /// The term being read, and its aliases and their line until it ends.
    term: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    aliases_line: u32 = 1,

    /// One context, and its words, which take its scope once its paths are known: a context
    /// with none holds the words of the whole project.
    fn readContext(self: *Glossary, item_line: u32) Error!void {
        const text = self.text;
        const settings = self.settings;
        const first_term = settings.terms_len;
        self.context = .{ .name = "", .context = true, .line = item_line };
        var mapping: yaml.Mapping = .{ .indent = text.column() };
        for (0..text.bytes.len) |_| try self.readContextValue((try text.nextKey(&mapping)) orelse break, mapping.indent);
        const scope: u8 = if (self.context.include_len == 0) 0 else try self.addScope();
        for (settings.terms[first_term..settings.terms_len]) |*term| term.scope = scope;
        if (scope > settings.scopes_len) assert.panic("gave a context's words scope {d} of {d}; addScope() numbers scopes from 1", .{ scope, settings.scopes_len });
        if (first_term > settings.terms_len) assert.panic("a context's words start at {d} of {d}; reading it may only add words", .{ first_term, settings.terms_len });
    }

    /// A key of a context: what it is called, which files it covers, and its words.
    fn readContextValue(self: *Glossary, key: []const u8, indent: usize) Error!void {
        const text = self.text;
        const start = text.at;
        if (std.mem.eql(u8, key, "name")) {
            self.context.name = try text.readScalar(key, false);
            try text.endLine();
        } else if (std.mem.eql(u8, key, "kind")) {
            try self.readKind(key);
        } else if (std.mem.eql(u8, key, "paths")) {
            try self.readPaths(key, indent);
        } else if (std.mem.eql(u8, key, "forbidden")) {
            const at_line = text.line();
            for (try text.readStrings(key, indent)) |word| try self.addTerm(.{ .scope = 0, .word = word, .line = at_line });
        } else if (std.mem.eql(u8, key, "terms")) {
            var list = (try text.mappingList(key, indent)) orelse return;
            for (0..text.bytes.len) |_| try self.readTerm((try text.nextItem(&list)) orelse break);
        } else if (std.mem.eql(u8, key, "domainVisionStatement") or std.mem.eql(u8, key, "meta")) {
            text.skipValue(indent);
        } else return text.fail("'{s}' isn't a context key; a context takes name, kind, paths, forbidden and terms, and Contextive's domainVisionStatement and meta.", .{key});
        if (text.at < start) assert.panic("reading the context key '{s}' moved back from byte {d} to {d}; it must only move forward", .{ key, start, text.at });
        if (text.at > text.bytes.len) assert.panic("reading the context key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
    }

    /// Whether the context is a context, whose words win, or a domain.
    fn readKind(self: *Glossary, key: []const u8) Error!void {
        const kind = try self.text.readScalar(key, false);
        const is_context = std.mem.eql(u8, kind, "context");
        if (!is_context and !std.mem.eql(u8, kind, "domain")) return self.text.fail("kind is '{s}'; it must be context or domain.", .{kind});
        self.context.context = is_context;
        try self.text.endLine();
        if (kind.len == 0) assert.panic("accepted an empty kind; only context and domain pass", .{});
        if (self.context.context != std.mem.eql(u8, kind, "context")) assert.panic("kind '{s}' left the context's kind unchanged; readKind() must store it", .{kind});
    }

    /// The files a context covers, as gitignore patterns.
    fn readPaths(self: *Glossary, key: []const u8, indent: usize) Error!void {
        const at_line = self.text.line();
        const items = try self.text.readStrings(key, indent);
        if (items.len > config.max_scope_globs) return self.text.failAt(at_line, "a context has more than {d} paths; use broader ones.", .{config.max_scope_globs});
        for (items) |glob| if (glob.len == 0) return self.text.failAt(at_line, "a path of a context is empty; name the files it covers.", .{});
        @memcpy(self.context.include[0..items.len], items);
        self.context.include_len = items.len;
        if (self.context.include_len > config.max_scope_globs) assert.panic("kept {d} paths in room for {d}; readPaths() must refuse more", .{ self.context.include_len, config.max_scope_globs });
        if (at_line == 0) assert.panic("paths on line 0; line() counts from 1", .{});
    }

    /// Adds the context just read as a scope, returning its number.
    fn addScope(self: *Glossary) Error!u8 {
        const settings = self.settings;
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
    fn readTerm(self: *Glossary, item_line: u32) Error!void {
        const text = self.text;
        const before = self.settings.terms_len;
        self.term = null;
        self.aliases = &.{};
        var mapping: yaml.Mapping = .{ .indent = text.column() };
        for (0..text.bytes.len) |_| try self.readTermValue((try text.nextKey(&mapping)) orelse break, mapping.indent);
        try self.addAliases(item_line);
        if (self.settings.terms_len < before) assert.panic("reading a term dropped words from {d} to {d}; it may only add them", .{ before, self.settings.terms_len });
        if (self.settings.terms_len - before > self.aliases.len) assert.panic("a term added {d} words for {d} aliases; each alias adds at most one", .{ self.settings.terms_len - before, self.aliases.len });
    }

    fn readTermValue(self: *Glossary, key: []const u8, indent: usize) Error!void {
        const text = self.text;
        const start = text.at;
        if (std.mem.eql(u8, key, "name")) {
            self.term = try text.readScalar(key, false);
            try text.endLine();
        } else if (std.mem.eql(u8, key, "aliases")) {
            self.aliases_line = text.line();
            self.aliases = try text.readStrings(key, indent);
        } else if (std.mem.eql(u8, key, "definition") or std.mem.eql(u8, key, "examples") or std.mem.eql(u8, key, "meta")) {
            text.skipValue(indent);
        } else return text.fail("'{s}' isn't a term key; a term takes name and aliases, and Contextive's definition, examples and meta.", .{key});
        if (text.at < start) assert.panic("reading the term key '{s}' moved back from byte {d} to {d}; it must only move forward", .{ key, start, text.at });
        if (text.at > text.bytes.len) assert.panic("reading the term key '{s}' ran to byte {d} of {d}; it must stop at the end of the file", .{ key, text.at, text.bytes.len });
    }

    /// Adds each alias of the term just read as a word to replace with its name, in lower case so
    /// a respelled name keeps its own case. A name of several words can't be one word of an
    /// identifier, so its aliases are left to the glossary.
    fn addAliases(self: *Glossary, item_line: u32) Error!void {
        const text = self.text;
        const name = self.term orelse return text.failAt(item_line, "a term has no name; give it one, such as name: invoice.", .{});
        if (name.len == 0) return text.failAt(item_line, "a term has no name; give it one, such as name: invoice.", .{});
        if (std.mem.indexOfAny(u8, name, " \t") != null) return;
        const offset = @intFromPtr(name.ptr) - @intFromPtr(text.bytes.ptr);
        if (offset + name.len > text.bytes.len) assert.panic("the term '{s}' is not inside the file; readScalar() returns slices of it", .{name});
        const canonical = text.bytes[offset..][0..name.len];
        for (canonical) |*c| c.* = std.ascii.toLower(c.*);
        for (self.aliases) |alias| {
            if (std.mem.indexOfAny(u8, alias, " \t") == null) try self.addTerm(.{ .scope = 0, .word = alias, .canonical = canonical, .line = self.aliases_line });
        }
        if (canonical.len != name.len) assert.panic("lowering '{s}' changed its length to {d}; it must change only case", .{ name, canonical.len });
    }

    fn addTerm(self: *Glossary, term: Term) Error!void {
        const settings = self.settings;
        if (term.line == 0) assert.panic("the word '{s}' has no line; line() counts from 1", .{term.word});
        if (term.word.len == 0) return self.text.failAt(term.line, "a word is empty; remove it or write the word.", .{});
        if (settings.terms_len == config.max_terms) return self.text.failAt(term.line, "the glossary has more than {d} words; keep the ones that matter most.", .{config.max_terms});
        settings.terms[settings.terms_len] = term;
        settings.terms_len += 1;
        if (settings.terms_len > config.max_terms) assert.panic("{d} terms in room for {d}; addTerm() must refuse more", .{ settings.terms_len, config.max_terms });
    }
};

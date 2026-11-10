//! Reads `zanity.toml` into a Config: a reader for the TOML zanity understands, each table's
//! settings, and the checks on their values. The first thing it doesn't recognise is an error
//! naming the line, written to `config.problem`.
const std = @import("std");
const toml_values = @import("toml_values.zig");
const Cursor = toml_values.Cursor;
const assert = @import("assert.zig");
const rules = @import("rules.zig");
const config_module = @import("config.zig");
const Config = config_module.Config;
const Error = config_module.Error;
const Term = config_module.Term;
const Scope = config_module.Scope;
const file_name = config_module.file_name;
const max_excludes = config_module.max_excludes;
const max_concurrency = config_module.max_concurrency;
const max_questions = config_module.max_questions;
const max_path_sections = config_module.max_path_sections;
const max_file_bytes = config_module.max_file_bytes;
const max_terms = config_module.max_terms;
const max_scopes = config_module.max_scopes;
const max_scope_globs = config_module.max_scope_globs;
const max_directional = config_module.max_directional;

/// The [infer] settings that name the server, with the punctuation each may hold besides ASCII
/// letters and digits, and an example to show when a value holds anything else.
const ServerForm = struct { key: []const u8, target: enum { url, model, api_key_env }, allowed: []const u8, example: []const u8 };
const server_forms = [_]ServerForm{
    .{ .key = "url", .target = .url, .allowed = "-._~:/[]%", .example = "http://127.0.0.1:8009" },
    .{ .key = "model", .target = .model, .allowed = "-._:/", .example = "kev-latest" },
    .{ .key = "api_key_env", .target = .api_key_env, .allowed = "_", .example = "KEV_API_KEY" },
};

/// The first byte of `text` that is neither an ASCII letter or digit nor one of `extra`, or null.
/// Only ASCII passes, so no look-alike letter from another script can stand in for one.
fn firstOutside(text: []const u8, extra: []const u8) ?usize {
    if (extra.len == 0) assert.panic("server_forms allows no punctuation in one of its settings; give each entry the characters it allows besides letters and digits", .{});
    const found = for (text, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extra, c) == null) break i;
    } else null;
    const at = found orelse return null;
    if (at >= text.len) assert.panic("firstOutside() returned byte {d} of a {d}-byte value; it must return a byte inside the value", .{ at, text.len });
    if (std.ascii.isAlphanumeric(text[at])) assert.panic("firstOutside() returned byte {d}, the letter or digit '{c}'; it must return only a byte outside the allowed set", .{ at, text[at] });
    return at;
}

/// Parses the TOML zanity understands, reporting the first problem in `problem`. Strings are
/// decoded in place, so `bytes` must outlive the config.
pub fn parseConfig(bytes: []u8) Error!Config {
    if (bytes.len > max_file_bytes) assert.panic("{s} is {d} bytes; initConfig reads at most {d}", .{ file_name, bytes.len, max_file_bytes });
    var reader: TomlReader = .{ .cursor = .{ .bytes = bytes } };
    var config: Config = .{};
    for (0..bytes.len + 1) |_| {
        reader.cursor.skipBlank();
        if (reader.cursor.at == bytes.len) break;
        try reader.readEntry(&config);
    }
    if (reader.cursor.at != bytes.len) assert.panic("stopped parsing {s} at byte {d} of {d}; the loop in parseConfig() must read to the end of the file", .{ file_name, reader.cursor.at, bytes.len });
    try reader.finishQuestion(&config);
    return config;
}

const Table = enum { root, rules, infer, paths, vocabulary, synonyms, scope, questions };

pub const TomlReader = struct {
    /// Where the reader is in the file's text.
    cursor: Cursor,
    table: Table = .root,
    /// The pattern of a `[paths."<glob>"]` header, until its section is added.
    pending_glob: []const u8 = "",
    /// The vocabulary table being read: 0 for [vocabulary], else one more than a scope's index.
    scope: u8 = 0,
    /// Where the [questions] table being read starts, for saying which one is incomplete.
    question_line: u32 = 0,

    /// Skips spaces and tabs, then requires the rest of the line to be empty or a comment.
    fn endLine(self: *TomlReader) Error!void {
        const start = self.cursor.at;
        self.cursor.skipSpaces();
        if (self.cursor.peek() == '#') self.cursor.at = std.mem.indexOfScalarPos(u8, self.cursor.bytes, self.cursor.at, '\n') orelse self.cursor.bytes.len;
        if (self.cursor.peek()) |c| if (c != '\n' and c != '\r') {
            return self.cursor.fail("unexpected '{c}' after a value; put each setting on its own line.", .{c});
        };
        if (self.cursor.at < start) assert.panic("ending a line moved back from byte {d} to {d}; endLine() must only move self.cursor.at forward", .{ start, self.cursor.at });
        if (self.cursor.at > self.cursor.bytes.len) assert.panic("ending a line ran to byte {d} of {d}; endLine() must stop at the end of the file", .{ self.cursor.at, self.cursor.bytes.len });
    }

    fn readEntry(self: *TomlReader, config: *Config) Error!void {
        if (self.cursor.at >= self.cursor.bytes.len) assert.panic("reading an entry at byte {d} of a {d}-byte file; parseConfig() must stop before the end of the file", .{ self.cursor.at, self.cursor.bytes.len });
        const start = self.cursor.at;
        if (self.cursor.bytes[self.cursor.at] == '[') {
            try self.readHeader(config);
        } else {
            const key = toml_values.readKey(&self.cursor) orelse return self.cursor.fail("expected a setting such as 'rules = [...]' or a table such as '[infer]'.", .{});
            self.cursor.skipSpaces();
            if (self.cursor.peek() != '=') return self.cursor.fail("expected '=' after '{s}'; write each setting as name = value.", .{key});
            self.cursor.at += 1;
            self.cursor.skipSpaces();
            try self.readSetting(config, key);
        }
        try self.endLine();
        if (self.cursor.at <= start) assert.panic("reading an entry at byte {d} consumed nothing; readEntry() must consume at least the key or header it read", .{start});
    }

    /// Reads a table header: `[infer]`, or `[paths."<glob>"]`, which starts a new section.
    fn readHeader(self: *TomlReader, config: *Config) Error!void {
        if (self.cursor.bytes[self.cursor.at] != '[') assert.panic("reading a table header at byte {d}, which is not '['; call readHeader() only at a '['", .{self.cursor.at});
        const start = self.cursor.at;
        self.cursor.at += 1;
        const name = toml_values.readKey(&self.cursor) orelse return self.cursor.fail("expected a table name after '['; write [infer] or [paths.\"<pattern>\"].", .{});
        try self.finishQuestion(config);
        if (std.mem.eql(u8, name, "questions")) {
            try self.readQuestionHeader(config);
            if (self.cursor.at <= start) assert.panic("reading a [questions] header at byte {d} consumed nothing", .{start});
            return;
        }
        if (std.mem.eql(u8, name, "vocabulary") or std.mem.eql(u8, name, "domains") or std.mem.eql(u8, name, "contexts")) {
            try self.readVocabularyHeader(config, name);
            if (self.cursor.at <= start) assert.panic("reading a vocabulary header at byte {d} consumed nothing", .{start});
            return;
        }
        if (std.mem.eql(u8, name, "paths")) {
            if (self.cursor.peek() != '.') return self.cursor.fail("'[paths]' needs a pattern for the files it covers, such as [paths.\"tests/**\"].", .{});
            self.cursor.at += 1;
            if (self.cursor.at >= self.cursor.bytes.len) return self.cursor.fail("expected a quoted pattern after '[paths.'; write it as [paths.\"tests/**\"].", .{});
            self.pending_glob = try toml_values.readString(&self.cursor, "paths");
        }
        if (self.cursor.peek() != ']') return self.cursor.fail("expected ']' after '[{s}'; close the table name with ']'.", .{name});
        self.cursor.at += 1;
        self.table = std.meta.stringToEnum(Table, name) orelse .root;
        if (self.table == .root or self.table == .vocabulary or self.table == .questions) return self.cursor.fail("'[{s}]' isn't a table zanity knows; the tables are [rules], [infer], [paths.\"<pattern>\"], [questions.\"<name>\"], [vocabulary], [domains.<name>] and [contexts.<name>].", .{name});
        if (self.table == .paths) try self.readPathSection(config);
        if (self.cursor.at <= start) assert.panic("reading a table header at byte {d} consumed nothing; readHeader() must consume at least the '[' it starts at", .{start});
    }

    /// `[vocabulary]`, `[vocabulary.synonyms]`, `[domains.<name>]`, `[contexts.<name>]`, or either
    /// of those with `.synonyms`; a domain or context is added when its own table starts.
    fn readVocabularyHeader(self: *TomlReader, config: *Config, kind: []const u8) Error!void {
        if (kind.len == 0) assert.panic("reading a vocabulary table with no kind; readHeader() passes vocabulary, domains or contexts", .{});
        const start = self.cursor.at;
        self.scope = 0;
        if (!std.mem.eql(u8, kind, "vocabulary")) {
            const header_line = self.cursor.line();
            if (self.cursor.peek() != '.') return self.cursor.fail("'[{s}]' needs a name, such as [{s}.billing].", .{ kind, kind });
            self.cursor.at += 1;
            const name = (if (self.cursor.peek() == '"') try toml_values.readString(&self.cursor, kind) else toml_values.readKey(&self.cursor)) orelse return self.cursor.fail("expected a name after '[{s}.', such as [{s}.billing].", .{ kind, kind });
            self.scope = try self.scopeNamed(config, .{ .name = name, .context = std.mem.eql(u8, kind, "contexts"), .line = header_line });
        }
        self.table = if (self.scope == 0) .vocabulary else .scope;
        if (self.cursor.peek() == '.') {
            self.cursor.at += 1;
            const part = toml_values.readKey(&self.cursor) orelse "";
            if (!std.mem.eql(u8, part, "synonyms")) return self.cursor.fail("'[{s}.{s}]' isn't a table zanity knows; the only one inside [{s}] is synonyms.", .{ kind, part, kind });
            self.table = .synonyms;
        }
        if (self.cursor.peek() != ']') return self.cursor.fail("expected ']' after the [{s}] table's name; close it with ']'.", .{kind});
        self.cursor.at += 1;
        if (self.cursor.at <= start) assert.panic("reading the [{s}] header consumed nothing; it must consume at least the ']'", .{kind});
    }

    /// The scope number of the domain or context called `name`, adding it when it is new.
    fn scopeNamed(self: *TomlReader, config: *Config, wanted: Scope) Error!u8 {
        if (wanted.name.len == 0) return self.cursor.fail("a domain or context name is empty; give it a name, such as [contexts.billing].", .{});
        if (wanted.line == 0) assert.panic("the [{s}] table has no line; line() counts from 1", .{wanted.name});
        for (config.scopes[0..config.scopes_len], 0..) |scope, i| {
            if (std.mem.eql(u8, scope.name, wanted.name) and scope.context == wanted.context) return @intCast(i + 1);
        }
        if (config.scopes_len == max_scopes) return self.cursor.fail("there are more than {d} domains and contexts; merge the ones that share their words.", .{max_scopes});
        config.scopes[config.scopes_len] = wanted;
        config.scopes_len += 1;
        if (config.scopes_len > max_scopes) assert.panic("{d} scopes in room for {d}; scopeNamed() must refuse more", .{ config.scopes_len, max_scopes });
        return @intCast(config.scopes_len);
    }

    fn addTerm(self: *TomlReader, config: *Config, term: Term) Error!void {
        if (term.scope > config.scopes_len) assert.panic("a term for scope {d} of {d}; scopeNamed() numbers each scope before its terms", .{ term.scope, config.scopes_len });
        if (term.word.len == 0) return self.cursor.fail("a vocabulary word is empty; remove it or write the word.", .{});
        if (config.terms_len == max_terms) return self.cursor.fail("the vocabulary has more than {d} words; keep the ones that matter most.", .{max_terms});
        config.terms[config.terms_len] = term;
        config.terms_len += 1;
        if (config.terms_len > max_terms) assert.panic("{d} terms in room for {d}; addTerm() must refuse more", .{ config.terms_len, max_terms });
    }

    /// A setting in [vocabulary], a domain or context, or one of their synonyms tables.
    fn readVocabularySetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) assert.panic("a vocabulary setting with no name at byte {d}; readEntry() reads a key first", .{self.cursor.at});
        const at_line = self.cursor.line();
        if (self.table == .scope and self.scope == 0) assert.panic("reading '{s}' in a domain or context table without one; readVocabularyHeader() sets the scope", .{key});
        const items = try toml_values.readStrings(&self.cursor, key);
        if (self.table == .synonyms) {
            for (items) |alias| try self.addTerm(config, .{ .scope = self.scope, .word = alias, .canonical = key, .line = at_line });
            return;
        }
        if (std.mem.eql(u8, key, "forbidden")) {
            for (items) |word| try self.addTerm(config, .{ .scope = self.scope, .word = word, .line = at_line });
        } else if (self.table == .vocabulary and std.mem.eql(u8, key, "directional")) {
            if (items.len > max_directional) return self.cursor.fail("'directional' has more than {d} words; keep the ones names use.", .{max_directional});
            @memcpy(config.directional[0..items.len], items);
            config.directional_len = items.len;
        } else if (self.table == .scope and std.mem.eql(u8, key, "include")) {
            const scope = &config.scopes[self.scope - 1];
            if (items.len > max_scope_globs) return self.cursor.fail("[{s}] has more than {d} include patterns; use broader ones.", .{ scope.name, max_scope_globs });
            for (items) |glob| if (glob.len == 0) return self.cursor.fail("an include pattern of [{s}] is empty; name the files it covers.", .{scope.name});
            @memcpy(scope.include[0..items.len], items);
            scope.include_len = items.len;
        } else return self.cursor.fail("'{s}' isn't a setting here; [vocabulary] takes forbidden and directional, a domain or context takes include and forbidden, and a synonyms table takes canonical = [aliases].", .{key});
    }

    fn readPathSection(self: *TomlReader, config: *Config) Error!void {
        if (self.table != .paths) assert.panic("starting a [paths] section while reading [{t}]; readHeader() must set the table to paths before starting a section", .{self.table});
        const glob = self.pending_glob;
        if (glob.len == 0) return self.cursor.fail("a [paths] pattern is empty; name the files it covers, such as \"tests/**\".", .{});
        if (config.paths_len == max_path_sections) return self.cursor.fail("there are more than {d} [paths] sections; combine patterns that disable the same rules.", .{max_path_sections});
        config.paths[config.paths_len] = .{ .glob = glob };
        config.paths_len += 1;
        self.pending_glob = "";
        if (config.paths_len > max_path_sections) assert.panic("{d} [paths] sections in room for {d}; readPathSection() must refuse sections past max_path_sections", .{ config.paths_len, max_path_sections });
    }

    fn readPathSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (self.table != .paths or config.paths_len == 0) assert.panic("reading '{s}' as a [paths] setting outside a [paths] section; readSetting() must hand [paths] settings over only inside a section", .{key});
        if (!std.mem.eql(u8, key, "disable")) return self.cursor.fail("'{s}' isn't a [paths] setting; the only one is disable.", .{key});
        const section = &config.paths[config.paths_len - 1];
        for (try toml_values.readStrings(&self.cursor, key)) |name| section.disable.include((rules.find(name) orelse return self.cursor.fail("'{s}' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.", .{name})).name);
        if (section.disable.len > rules.all.len) assert.panic("[paths.\"{s}\"] disables {d} rules of {d}; Set.include() must add each rule once", .{ section.glob, section.disable.len, rules.all.len });
    }

    fn readInferSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (self.table != .infer) assert.panic("reading '{s}' as an [infer] setting outside [infer]; readSetting() must hand over only [infer] settings", .{key});
        const InferSetting = enum { enabled, url, model, api_key_env, concurrency, threshold };
        const setting = std.meta.stringToEnum(InferSetting, key) orelse return self.cursor.fail("'{s}' isn't an [infer] setting; the settings are enabled, url, model, api_key_env, concurrency and threshold.", .{key});
        switch (setting) {
            .enabled => config.infer = try toml_values.readBoolean(&self.cursor, key),
            .url, .model, .api_key_env => try self.readServerSetting(config, key),
            .concurrency => {
                const value = try toml_values.readInteger(&self.cursor, key);
                if (value < 1 or value > max_concurrency) return self.cursor.fail("concurrency is {d}; it must be between 1 and {d}.", .{ value, max_concurrency });
                config.concurrency = @intCast(value);
            },
            .threshold => {
                const value = try toml_values.readDecimal(&self.cursor, key);
                if (!(value > 0 and value <= 1)) return self.cursor.fail("threshold is {d}; it must be above 0 and at most 1, such as 0.9 to report only what the model is at least 90% sure of.", .{value});
                config.threshold = value;
            },
        }
        if (setting == .concurrency and config.concurrency == null) assert.panic("read [infer] concurrency but stored nothing; its branch of readInferSetting() must store it", .{});
        if (setting == .threshold and config.threshold == null) assert.panic("read [infer] threshold but stored nothing; its branch of readInferSetting() must store it", .{});
    }

    /// The [infer] settings naming the server: `url`, `model` and `api_key_env`, each held to the
    /// characters its kind of name uses.
    fn readServerSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        const text = try toml_values.readString(&self.cursor, key);
        const form = for (server_forms) |f| {
            if (std.mem.eql(u8, f.key, key)) break f;
        } else assert.panic("read '{s}' as a server setting; readInferSetting() must hand over only url, model and api_key_env", .{key});
        if (text.len == 0) return self.cursor.fail("'{s}' is empty; name one, or remove the line to use the default.", .{key});
        if (firstOutside(text, form.allowed)) |i| return self.cursor.fail("{s} is '{s}', which has '{c}' at byte {d}; use only letters, digits and '{s}', such as \"{s}\".", .{ key, text, text[i], i, form.allowed, form.example });
        if (form.target == .api_key_env and std.ascii.isDigit(text[0])) return self.cursor.fail("api_key_env is '{s}', which starts with a digit; name an environment variable, such as \"KEV_API_KEY\".", .{text});
        if (form.target == .url) try self.checkServerUrl(text);
        switch (form.target) {
            .url => config.url = text,
            .model => config.model = text,
            .api_key_env => config.api_key_env = text,
        }
        const stored = switch (form.target) {
            .url => config.url,
            .model => config.model,
            .api_key_env => config.api_key_env,
        };
        if (stored == null or stored.?.ptr != text.ptr) assert.panic("read [infer] {s} = '{s}' but stored something else; readServerSetting() must store the value it read", .{ key, text });
        if (text.len > self.cursor.bytes.len) assert.panic("read [infer] {s} as {d} bytes from a {d}-byte file; readString() must return part of the file", .{ key, text.len, self.cursor.bytes.len });
    }

    /// A url holds a server's address: http or https, a host, and optionally a port and path.
    fn checkServerUrl(self: *TomlReader, text: []const u8) Error!void {
        if (!(std.mem.startsWith(u8, text, "http://") or std.mem.startsWith(u8, text, "https://"))) return self.cursor.fail("url is '{s}'; it must start with http:// or https://, such as \"http://127.0.0.1:8009\".", .{text});
        const uri = std.Uri.parse(text) catch return self.cursor.fail("url is '{s}', which isn't a URL; write one such as \"http://127.0.0.1:8009\".", .{text});
        const host = uri.host orelse return self.cursor.fail("url is '{s}', which names no host; write one such as \"http://127.0.0.1:8009\".", .{text});
        if (host.isEmpty()) return self.cursor.fail("url is '{s}', which names no host; write one such as \"http://127.0.0.1:8009\".", .{text});
        if (firstOutside(text, server_forms[0].allowed) != null) assert.panic("checking url '{s}' before its characters; readServerSetting() must check them first", .{text});
        if (uri.query != null or uri.fragment != null) assert.panic("url '{s}' parsed with a query or fragment though '?' and '#' are refused; keep them out of the url's allowed characters", .{text});
    }

    /// `[questions."<name>"]`: starts a question of the file's own, or retunes one of zanity's,
    /// starting from what zanity asks.
    fn readQuestionHeader(self: *TomlReader, config: *Config) Error!void {
        const start = self.cursor.at;
        if (self.cursor.peek() != '.') return self.cursor.fail("'[questions]' needs the question's name, such as [questions.\"payment-without-key\"].", .{});
        self.cursor.at += 1;
        const name = (if (self.cursor.peek() == '"') try toml_values.readString(&self.cursor, "questions") else toml_values.readKey(&self.cursor)) orelse return self.cursor.fail("expected a name after '[questions.', such as [questions.\"payment-without-key\"].", .{});
        if (self.cursor.peek() != ']') return self.cursor.fail("expected ']' after the question's name; close the table with ']'.", .{});
        self.cursor.at += 1;
        if (name.len == 0) return self.cursor.fail("a question's name is empty; name it, such as [questions.\"payment-without-key\"].", .{});
        for (config.questionRules()) |q| if (std.mem.eql(u8, q.name, name)) return self.cursor.fail("[questions.\"{s}\"] appears twice; put its settings in one table.", .{name});
        if (config.questions_len == max_questions) return self.cursor.fail("there are more than {d} [questions] tables; keep the ones that matter most.", .{max_questions});
        const builtin = if (rules.ruleIndex(name)) |i| rules.all[i] else null;
        if (builtin) |b| if (b.question.len == 0) return self.cursor.fail("'{s}' is a deterministic rule, not a question, so there is nothing to retune; give your question a name of its own.", .{name});
        config.questions[config.questions_len] = builtin orelse .{ .name = name, .advice = "", .severity = .warning, .tier = .default, .question = "", .judgement = "", .asks = .function };
        config.questions[config.questions_len].name = name;
        config.questions_len += 1;
        self.table = .questions;
        self.question_line = self.cursor.line();
        if (self.cursor.at <= start) assert.panic("reading a [questions] header from byte {d} ended at {d}, having consumed nothing", .{ start, self.cursor.at });
        if (config.questions_len > max_questions) assert.panic("{d} questions in room for {d}; the check above refuses more", .{ config.questions_len, max_questions });
    }

    /// One setting of the question being read.
    fn readQuestionSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (config.questions_len == 0) assert.panic("reading '{s}' with no [questions] table open; readQuestionHeader() opens one first", .{key});
        const QuestionSetting = enum { question, finding, fix, severity, asks, threshold };
        const setting = std.meta.stringToEnum(QuestionSetting, key) orelse return self.cursor.fail("'{s}' isn't a question setting; the settings are question, finding, fix, severity, asks and threshold.", .{key});
        const q = &config.questions[config.questions_len - 1];
        if (setting == .threshold) {
            const value = try toml_values.readDecimal(&self.cursor, key);
            if (!(value > 0 and value <= 1)) return self.cursor.fail("threshold is {d}; it must be above 0 and at most 1, such as 0.9 to report only what the model is at least 90% sure of.", .{value});
            q.threshold = value;
            return;
        }
        const text = try toml_values.readString(&self.cursor, key);
        switch (setting) {
            .threshold => unreachable,
            .severity => q.severity = std.meta.stringToEnum(rules.Severity, text) orelse return self.cursor.fail("severity must be \"error\", \"warning\" or \"information\".", .{}),
            .asks => q.asks = std.meta.stringToEnum(rules.Asks, text) orelse return self.cursor.fail("asks must be \"function\", \"errors\", \"fixture\", \"test\", \"file\" or \"project\".", .{}),
            .question, .finding, .fix => {
                if (text.len == 0) return self.cursor.fail("'{s}' is empty; write it, or remove the line.", .{key});
                switch (setting) {
                    .question => q.question = text,
                    .finding => q.judgement = text,
                    else => q.advice = text,
                }
            },
        }
        if (setting == .question and q.question.len == 0) assert.panic("read a question for '{s}' but stored none", .{q.name});
    }

    /// Checks the question just read says everything a finding needs.
    fn finishQuestion(self: *TomlReader, config: *Config) Error!void {
        if (self.table != .questions) return;
        if (config.questions_len == 0) assert.panic("finishing a [questions] table that was never opened", .{});
        const q = config.questions[config.questions_len - 1];
        if (q.name.len == 0) assert.panic("the question table at line {d} has no name; readQuestionHeader() names it", .{self.question_line});
        const missing: []const u8 = if (q.question.len == 0) "question" else if (q.judgement.len == 0) "finding" else if (q.advice.len == 0) "fix" else return;
        const written = std.fmt.bufPrint(&config_module.problem, "{s}:{d}: [questions.\"{s}\"] has no {s}; a question of your own needs a question, a finding and a fix.", .{ file_name, self.question_line, q.name, missing }) catch config_module.problem[0..];
        config_module.problem_len = written.len;
        return error.InvalidConfig;
    }

    const Setting = enum { rules, select, disable, exclude };

    /// Which setting `key` is at the top of the file or in [rules]: `select` belongs in [rules],
    /// `exclude` at the top, and `disable` in either; `rules` at the top is the older `select`.
    fn settingNamed(self: *const TomlReader, key: []const u8) Error!Setting {
        if (self.table != .root and self.table != .rules) assert.panic("reading '{s}' as a top-level or [rules] setting inside [{t}]; readSetting() hands over the other tables' settings first", .{ key, self.table });
        const parsed = std.meta.stringToEnum(Setting, key);
        const in_rules = self.table == .rules;
        const fits = if (parsed) |s| switch (s) {
            .select => in_rules,
            .disable => true,
            .rules, .exclude => !in_rules,
        } else false;
        if (fits) {
            if (parsed.? == .select and !in_rules) assert.panic("accepted select outside [rules] at byte {d}; only [rules] takes select", .{self.cursor.at});
            return parsed.?;
        }
        if (in_rules) return self.cursor.fail("'{s}' isn't a [rules] setting; the settings are select and disable.", .{key});
        return self.cursor.fail("'{s}' isn't a setting; the settings are exclude and, under [rules], select and disable, and under [infer], enabled, url, model, api_key_env, concurrency and threshold.", .{key});
    }

    fn readSetting(self: *TomlReader, config: *Config, key: []const u8) Error!void {
        if (key.len == 0) assert.panic("setting a key with no name at byte {d}; readEntry() must read a key before calling readSetting()", .{self.cursor.at});
        if (self.table == .paths) return self.readPathSetting(config, key);
        if (self.table == .questions) return self.readQuestionSetting(config, key);
        if (self.table == .infer) return self.readInferSetting(config, key);
        if (self.table == .vocabulary or self.table == .synonyms or self.table == .scope) return self.readVocabularySetting(config, key);
        try self.storeSetting(config, try self.settingNamed(key), key);
        if (config.exclude_len > max_excludes) assert.panic("{d} exclude patterns in room for {d}; readStrings() must refuse lists longer than max_excludes", .{ config.exclude_len, max_excludes });
    }

    /// Reads and stores a top-level or [rules] setting: exclude, or a rule list.
    fn storeSetting(self: *TomlReader, config: *Config, which: Setting, key: []const u8) Error!void {
        const items = try toml_values.readStrings(&self.cursor, key);
        if (key.len == 0) assert.panic("storing a setting with no name; readEntry() reads its key first", .{});
        switch (which) {
            .exclude => {
                for (items) |glob| if (glob.len == 0) return self.cursor.fail("an 'exclude' pattern is empty; remove it or name a path.", .{});
                @memcpy(config.exclude[0..items.len], items);
                config.exclude_len = items.len;
            },
            .rules, .select, .disable => {
                var set: rules.Set = .{};
                for (items) |name| {
                    if (std.mem.eql(u8, name, "strict")) config.strict_line = self.cursor.line();
                    if (!set.includeNamed(if (config.strict_line == self.cursor.line()) "all" else name)) return self.cursor.fail("'{s}' isn't a rule; the rules are listed in the README, 'all' names every rule, and 'zanity check --rules' takes the same names.", .{name});
                }
                if (which != .disable and set.len == 0) return self.cursor.fail("'{s}' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.", .{key});
                if (which == .disable) config.disable = set else config.rules = set;
            },
        }
        if (which == .exclude and config.exclude_len != items.len) assert.panic("read {d} exclude patterns but stored {d}", .{ items.len, config.exclude_len });
    }
};

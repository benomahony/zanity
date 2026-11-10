//! A language's compiled queries and the rules selected for it, and checking one file with them:
//! parsing it, indexing its captures, walking its tree and returning its findings.
const std = @import("std");
const capture_ids = @import("capture_ids.zig");
const Vocabulary = capture_ids.Vocabulary;
const walk = @import("walk.zig");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");
const rules = @import("rules.zig");
const hazards = @import("hazards.zig");
const suppress = @import("suppress.zig");
const scope = @import("scope.zig");
const unread = @import("unread.zig");
const naming = @import("naming.zig");
const check = @import("check.zig");
const nameHash = @import("facts.zig").nameHash;
const Diagnostic = check.Diagnostic;
const File = check.File;
const Work = check.Work;

pub const Checker = struct {
    loaded: language.Loaded,
    compiled: captures.Compiled,
    vocabulary: Vocabulary,
    enabled: rules.Set,

    pub fn initChecker(gpa: Allocator, loaded: language.Loaded, requested: rules.Set) !Checker {
        if (requested.len == 0) assert.panic("building a {s} checker with no rules requested; runCheck always requests at least one", .{loaded.adapter.name});
        const compiled = try captures.Compiled.initCompiled(gpa, loaded.query);
        _ = unread.disableUnread(loaded.query, compiled);
        var checker: Checker = .{
            .loaded = loaded,
            .compiled = compiled,
            .vocabulary = Vocabulary.lookup(compiled),
            .enabled = .{},
        };
        checker.selectRules(requested);
        if (checker.enabled.len > requested.len) assert.panic("{s} enabled {d} rules from {d} requests; selectRules() must keep only supported requests", .{ loaded.adapter.name, checker.enabled.len, requested.len });
        return checker;
    }

    /// Changes selection without reallocating the language's immutable compiled query.
    pub fn selectRules(self: *Checker, requested: rules.Set) void {
        if (requested.len == 0) assert.panic("selecting no rules for {s}; settings must retain at least one requested rule", .{self.loaded.adapter.name});
        self.enabled = .{};
        for (requested.names()) |name| {
            if (language.applies(self.loaded.adapter, name)) self.enabled.include(name);
        }
        if (self.enabled.len > requested.len) assert.panic("{s} supports {d} of {d} requested rules; selection cannot introduce rules", .{ self.loaded.adapter.name, self.enabled.len, requested.len });
    }

    pub const Result = struct { diagnostics: []Diagnostic, parse_error: bool };

    pub fn check(self: *const Checker, work: Work, source: []const u8) !Result {
        if (source.len >= std.math.maxInt(u32)) assert.panic("{s}: {d} bytes is more than tree-sitter can parse; lower memory.Limits.file_bytes below 4 GiB", .{ work.facts.path, source.len });
        const room = work.scratch.in_comment;
        if (source.len > room.len) assert.panic("{s}: {d} bytes but the scratch has room for {d}; main.zig must reject files over memory.Limits.file_bytes", .{ work.facts.path, source.len, room.len });
        const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
        defer ts.ts_parser_delete(parser);
        _ = ts.ts_parser_set_language(parser, @ptrCast(self.loaded.adapter.grammar()));
        const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
        defer ts.ts_tree_delete(tree);
        const root = ts.ts_tree_root_node(tree);
        work.scratch.clearFile();
        var file: File = .{
            .work = work,
            .s = work.scratch,
            .checker = self,
            .v = self.vocabulary,
            .tables = self.loaded.adapter.tables,
            .source = source,
            .index = try captures.index(&work.scratch.captures, self.compiled, root, source),
        };
        try suppress.collectSuppressions(&file);
        try hazards.checkComments(&file);
        file.code_lines = file.codeLines();
        file.module = naming.usesModuleSyntax(self.compiled.id("module.syntax"), file.index.triples, source);
        if (ts.ts_node_has_error(root)) {
            _ = try file.report(root, "parse-error", "zanity couldn't fully parse this file, so some findings may be missing.");
        }
        try walk.walk(&file, root);
        try hazards.checkUnawaited(&file);
        try hazards.checkLength(&file, root);
        try scope.checkWideScope(&file);
        const scratch = work.scratch;
        const reflects = for (file.tables.reflective_calls) |call| {
            if (scratch.names.mentioned(nameHash(call))) break true;
        } else false;
        try scratch.names.drain(&work.facts.references, work.facts.path, reflects);
        const walked = file.s;
        if (walked.contexts.len != 0) assert.panic("{s}: the walk ended with {d} constructs still open; every node entered must be left", .{ work.facts.path, walked.contexts.len });
        if (walked.opened.len != 0) assert.panic("{s}: the walk ended with {d} nodes still open; every node entered must be left", .{ work.facts.path, walked.opened.len });
        return .{ .diagnostics = file.finish(), .parse_error = ts.ts_node_has_error(root) };
    }
};

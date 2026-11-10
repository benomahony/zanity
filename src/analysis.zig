//! Checking one file with a Checker: parsing it, indexing its captures, walking its tree and
//! returning its findings.
const std = @import("std");
const walk = @import("walk.zig");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const hazards = @import("hazards.zig");
const suppress = @import("suppress.zig");
const scope = @import("scope.zig");
const naming = @import("naming.zig");
const check = @import("check.zig");
const nameHash = @import("facts.zig").nameHash;
const Diagnostic = check.Diagnostic;
const File = check.File;
const Work = check.Work;
const Checker = checker.Checker;
const checker = @import("checker.zig");

pub const Result = struct { diagnostics: []Diagnostic, parse_error: bool };

pub fn checkFile(self: *const Checker, work: Work, source: []const u8) !Result {
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

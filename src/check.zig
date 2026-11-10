const std = @import("std");
const checker = @import("checker.zig");
pub const Checker = checker.Checker;
const file_scratch = @import("file_scratch.zig");
pub const FileScratch = file_scratch.FileScratch;
const capture_ids = @import("capture_ids.zig");
const Vocabulary = capture_ids.Vocabulary;
const source_lines = @import("code_lines.zig");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const strings = @import("strings.zig");
/// The most test file prefixes and suffixes one language's tables hold.
const max_test_file_affixes = 32;
/// The most test name prefixes one language's tables hold.
const max_test_prefixes = 16;

const constructs = @import("constructs.zig");
pub const Diagnostic = constructs.Diagnostic;
pub const Family = constructs.Family;
pub const Parameter = constructs.Parameter;
pub const Summary = constructs.Summary;
pub const Call = constructs.Call;
pub const Context = constructs.Context;
pub const Owned = constructs.Owned;
pub const Weak = constructs.Weak;
pub const Trail = constructs.Trail;
pub const Suppression = constructs.Suppression;
pub const Assertion = constructs.Assertion;
pub const Note = constructs.Note;

pub const Work = struct {
    scratch: *FileScratch,
    text: *memory.Text,
    facts: *Facts,
};

pub const File = struct {
    work: Work,
    s: *FileScratch,
    checker: *const Checker,
    v: Vocabulary,
    tables: *const language.Tables,
    source: []const u8,
    index: captures.Index,
    code_lines: []const bool = &.{},
    /// Whether the file uses `import` or `export`, so only what it exports leaves it.
    module: bool = false,
    serials: u32 = 0,
    /// Where the walk's capture lookups have reached in `index`.
    next_capture: usize = 0,

    /// `node`'s ancestors, root first. Climbing with parent() makes tree-sitter search down from
    /// the root again at every step; this finds the whole chain in one descent. The slice lasts
    /// until the next call.
    pub fn ancestorsOf(self: *File, node: ts.Node) error{LimitExceeded}![]const ts.Node {
        const chain = &self.s.ancestors;
        chain.clear();
        var current = ts.ts_tree_root_node(node.tree orelse assert.panic("{s}: looked for the ancestors of a node whose tree was deleted; look while the tree is alive", .{self.work.facts.path}));
        for (0..chain.buffer.len + 1) |_| {
            if (current.eql(node)) return chain.items();
            try chain.add(current);
            current = ts.ts_node_child_with_descendant(current, node);
            if (ts.ts_node_is_null(current)) assert.panic("{s}: {f} is not in the tree being checked; pass a node from this file's tree", .{ self.work.facts.path, node.where() });
            if (ts.ts_node_end_byte(current) < ts.ts_node_end_byte(node)) assert.panic("{s}: the step towards {f} landed on {f}, which ends before it; ts_node_child_with_descendant() returns the child holding the node", .{ self.work.facts.path, node.where(), current.where() });
        }
        assert.panic("{s}: {f} is deeper than the {d} nodes the chain has room for, yet adding past that did not fail; Bounded.add() must refuse to grow past its buffer", .{ self.work.facts.path, node.where(), chain.buffer.len });
    }

    /// `node`'s parent. tree-sitter finds a parent by searching down from the root, so for the
    /// nodes the walk is inside, which most lookups are about, it comes from the walk's path.
    pub fn parentOf(self: *const File, node: ts.Node) ?ts.Node {
        const path = self.s.path.items();
        var i = path.len;
        while (i > 1) {
            i -= 1;
            if (!path[i].eql(node)) continue;
            if (ts.ts_node_end_byte(path[i - 1]) < ts.ts_node_end_byte(node)) assert.panic("{s}: {f} ends after the node before it on the walk's path; enter() and leave() must keep the path to the nodes the walk is inside", .{ self.work.facts.path, node.where() });
            return path[i - 1];
        }
        if (path.len > 0 and path[0].eql(node)) return null;
        const parent = node.parent();
        if (parent) |p| if (ts.ts_node_start_byte(p) > ts.ts_node_start_byte(node)) assert.panic("{s}: {f}'s parent starts after it; tree-sitter returned a node from another tree", .{ self.work.facts.path, node.where() });
        return parent;
    }

    pub fn innermost(self: *File, family: Family) ?*Context {
        const items = self.s.contexts.items();
        if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
        var i = items.len;
        while (i > 0) {
            i -= 1;
            if (items[i].family == family) {
                if (i >= items.len) assert.panic("{s}: found a {t} at depth {d} of {d}; innermost() must index below the stack length, so check its bounds", .{ self.work.facts.path, family, i, items.len });
                return &items[i];
            }
        }
        return null;
    }

    /// The innermost named function or test, whose decisions a decision point adds to. A test is
    /// its own unit even where it is a call with an unnamed callback, like `it("works", () => {})`.
    pub fn enclosingUnit(self: *File) ?*Context {
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &items[i];
            switch (ctx.family) {
                .class => return null,
                .@"test" => return ctx,
                .function => if (ctx.name != null) return ctx,
                else => {},
            }
        }
        if (i != 0) assert.panic("{s}: the search for an enclosing unit stopped at depth {d} without returning; the loop in enclosingUnit() must return from inside, so check its exits", .{ self.work.facts.path, i });
        if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
        return null;
    }

    /// Lines of code from the first row of `span` to its last, not counting blank and comment lines.
    pub fn codeLinesIn(self: *File, span: ts.Node) u32 {
        const first = ts.ts_node_start_point(span).row;
        const last = ts.ts_node_end_point(span).row;
        if (last < first) assert.panic("{s}: {f} ends on row {d}, before it starts on row {d}; pass a node from the tree parsed from this source", .{ self.work.facts.path, span.where(), last, first });
        var lines: u32 = 0;
        for (self.code_lines[first .. last + 1]) |is_code| lines += @intFromBool(is_code);
        if (lines > last - first + 1) assert.panic("{s}: counted {d} code lines in {d} rows of {f}; codeLines() must give one flag per row, so check how it counts newlines", .{ self.work.facts.path, lines, last - first + 1, span.where() });
        return lines;
    }

    /// The name of the open function on `node` itself, as for a test that is a function marked
    /// `#[test]` or `@Test`; null for a test block or a test call.
    pub fn functionNameOf(self: *File, node: ts.Node) ?ts.Node {
        const items = self.s.contexts.items();
        if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = items[i];
            if (ctx.family == .function and ctx.node.eql(node)) return ctx.name;
            if (ts.ts_node_start_byte(ctx.node) < ts.ts_node_start_byte(node)) return null;
        }
        if (i != 0) assert.panic("{s}: the search for the function on {f} stopped at depth {d}; the loop in functionNameOf() must return from inside, so check its exits", .{ self.work.facts.path, node.where(), i });
        return null;
    }

    /// The innermost test: a test construct, or a function named as a test (`test_x`, `TestX`).
    /// Code in a callback or helper inside a test counts toward that test.
    pub fn enclosingTest(self: *File) ?*Context {
        const items = self.s.contexts.items();
        if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &items[i];
            switch (ctx.family) {
                .class => return null,
                .@"test" => return ctx,
                .function => if (ctx.is_test) return ctx,
                else => {},
            }
        }
        if (i != 0) assert.panic("{s}: the search for an enclosing test stopped at depth {d} without returning; the loop in enclosingTest() must return from inside, so check its exits", .{ self.work.facts.path, i });
        return null;
    }

    pub fn enclosingFunction(self: *File) ?*Context {
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &items[i];
            switch (ctx.family) {
                .class => return null,
                .function => if (ctx.name) |name| {
                    if (ts.ts_node_start_byte(name) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: @function.name captured {f}, before its function {f}; capture the name inside @function.outer", .{ self.work.facts.path, name.where(), ctx.node.where() });
                    if (ts.ts_node_end_byte(name) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: @function.name captured {f}, after its function {f} ends; capture the name inside @function.outer", .{ self.work.facts.path, name.where(), ctx.node.where() });
                    return ctx;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn statementOf(self: *File, node: ts.Node) ?*Context {
        const statement = self.innermost(.statement) orelse return null;
        if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(statement.node)) assert.panic("{s}: {f} starts before its statement {f}; call statementOf() only with a node inside the innermost open statement", .{ self.work.facts.path, node.where(), statement.node.where() });
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(statement.node)) assert.panic("{s}: {f} ends after its statement {f}; call statementOf() only with a node inside the innermost open statement", .{ self.work.facts.path, node.where(), statement.node.where() });
        if (statement.node.eql(node)) return statement;
        const parent = self.parentOf(node) orelse return null;
        return if (statement.node.eql(parent)) statement else null;
    }

    pub fn isTestName(self: *File, name: []const u8) bool {
        if (name.len == 0) assert.panic("{s}: asked whether an empty function name is a test name; @function.name matched an empty node", .{self.work.facts.path});
        if (self.tables.test_prefixes.len > max_test_prefixes) assert.panic("{s} lists {d} test prefixes in languages/tables.zon; more than 16 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_prefixes.len });
        for (self.tables.test_prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
        return false;
    }

    pub fn inTest(self: *File) bool {
        const items = self.s.contexts.items();
        if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
        for (items) |ctx| if (ctx.is_test) {
            if (ctx.family != .function and ctx.family != .@"test") assert.panic("{s}: the {t} {f} is marked as a test; only functions and test blocks can be", .{ self.work.facts.path, ctx.family, ctx.node.where() });
            return true;
        };
        return false;
    }

    /// Whether the file holds tests: its name has one of the language's test affixes, or it sits
    /// in a test directory.
    pub fn inTestFile(self: *File) bool {
        const path = self.work.facts.path;
        const base = std.fs.path.basename(path);
        if (base.len == 0) assert.panic("path '{s}' has no file name, so zanity can't tell whether it holds tests", .{path});
        for (self.tables.test_file_prefixes) |prefix| if (std.mem.startsWith(u8, base, prefix)) return true;
        for (self.tables.test_file_suffixes) |suffix| if (std.mem.endsWith(u8, base, suffix)) return true;
        if (self.tables.test_file_prefixes.len + self.tables.test_file_suffixes.len > max_test_file_affixes) assert.panic("{s} lists {d} test file prefixes and {d} suffixes in languages/tables.zon; more than 32 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_file_prefixes.len, self.tables.test_file_suffixes.len });
        return inTestDirectory(path);
    }

    pub fn calleeIn(self: *File, ctx: Context, name: []const u8, table: []const []const u8) ?[]const u8 {
        if (name.len == 0) assert.panic("{s}: looking up the call {f} in a name table with an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
        if (ctx.family != .call) assert.panic("{s}: looking up {f} in a call table, but it is a {t}; call calleeIn() only with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        for (table) |entry| {
            if (entry.len == 0) assert.panic("an entry in one of {s}'s name tables is empty; remove it from languages/tables.zon", .{self.tables.ecosystem});
            if (ctx.callee) |callee| {
                if (sameText(entry, callee.text(self.source))) return entry;
            }
            const dot = std.mem.lastIndexOfScalar(u8, entry, '.') orelse {
                if (std.mem.eql(u8, entry, name) and ctx.receiver == null) return entry;
                continue;
            };
            const receiver = ctx.receiver orelse continue;
            if (std.mem.eql(u8, entry[dot + 1 ..], name) and sameText(entry[0..dot], receiver.text(self.source))) return entry;
        }
        return null;
    }

    pub fn definedInClass(self: *File) bool {
        const items = self.s.contexts.items();
        var i = items.len;
        var seen_function = false;
        while (i > 0) {
            i -= 1;
            switch (items[i].family) {
                .class => if (seen_function) return true,
                .function => {
                    if (seen_function) return false;
                    seen_function = true;
                },
                else => {},
            }
        }
        if (i != 0) assert.panic("{s}: the search for an enclosing class stopped at depth {d} without returning; the loop in definedInClass() must return from inside, so check its exits", .{ self.work.facts.path, i });
        if (!seen_function) assert.panic("{s}: asked whether a function is defined in a class while no function is open; call it from a @function.name capture", .{self.work.facts.path});
        return false;
    }

    pub fn say(self: *File, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const message = try self.work.text.format(fmt, args);
        if (message.len == 0) assert.panic("{s}: a finding message came out empty from format '{s}'; give the report() call a message with text", .{ self.work.facts.path, fmt });
        if (!(std.ascii.isUpper(message[0]) or message[0] == '\'' or std.mem.startsWith(u8, message, "zanity"))) assert.panic("finding messages start with a capital, a quoted name or 'zanity'; this one does not: '{s}'", .{message});
        return message;
    }

    pub fn report(self: *File, node: ts.Node, rule: []const u8, message: []const u8) !bool {
        if (rules.find(rule) == null) assert.panic("{s}: reporting rule '{s}', which is not in rules.all; add it there or fix the name", .{ self.work.facts.path, rule });
        if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: reporting {s} on {f}, which ends past the {d}-byte file; pass a node from the tree parsed from this file", .{ self.work.facts.path, rule, node.where(), self.source.len });
        if (!self.checker.enabled.enabled(rule)) return false;
        const start = ts.ts_node_start_point(node);
        if (suppressed(self, start.row, rule)) return false;
        try self.s.diagnostics.add(.{
            .line = start.row,
            .column = start.column,
            .rule = rule,
            .message = message,
        });
        return true;
    }

    pub fn codeLines(self: *File) []const bool {
        if (self.s.in_comment.len < self.source.len) assert.panic("{s}: comment scratch has {d} bytes for {d} source bytes; initialize scratch from the file limit", .{ self.work.facts.path, self.s.in_comment.len, self.source.len });
        if (self.s.code_lines.len <= self.source.len) assert.panic("{s}: code-line scratch has {d} flags for {d} bytes; allow one flag per byte plus the final row", .{ self.work.facts.path, self.s.code_lines.len, self.source.len });
        return source_lines.mark(.{
            .source = self.source,
            .in_comment = self.s.in_comment,
            .code_lines = self.s.code_lines,
            .captures = self.index.triples,
            .comment_id = self.v.comment,
            .path = self.work.facts.path,
        });
    }

    pub fn finish(self: *File) []Diagnostic {
        if (self.s.contexts.len != 0) assert.panic("{s}: finishing with {d} constructs still open; every node entered must be left", .{ self.work.facts.path, self.s.contexts.len });
        const diagnostics = self.s.diagnostics.items();
        std.mem.sort(Diagnostic, diagnostics, {}, Diagnostic.reportedBefore);
        if (!std.sort.isSorted(Diagnostic, diagnostics, {}, Diagnostic.reportedBefore)) assert.panic("expected diagnostics in report order, got {d} diagnostics out of order; sort the diagnostics with Diagnostic.reportedBefore before checking them", .{diagnostics.len});
        return diagnostics;
    }
};

pub const contains = strings.contains;

pub const sameText = strings.sameText;
pub const header = strings.header;

/// Directories whose files are all tests or their helpers, in every language.
const test_directories = [_][]const u8{ "tests", "test", "__tests__", "acceptance" };

/// Whether a directory in `path`, as zanity was given it, is one of `test_directories`. The
/// directories of an absolute path are not read, since those above the project say nothing.
fn inTestDirectory(path: []const u8) bool {
    if (path.len == 0) assert.panic("asked whether an empty path is in a test directory; every checked file has a path", .{});
    if (std.fs.path.isAbsolute(path)) return false;
    const parent = std.fs.path.dirname(path) orelse return false;
    if (parent.len >= path.len) assert.panic("the directory '{s}' of '{s}' is no shorter than the path; read only the directories, not the file's own name", .{ parent, path });
    var dirs = std.mem.tokenizeAny(u8, parent, "/\\");
    while (dirs.next()) |dir| for (test_directories) |name| if (std.mem.eql(u8, dir, name)) return true;
    return false;
}

/// Whether a `zanity: ignore` comment on `line` suppresses `rule` there.
fn suppressed(self: *File, line: u32, rule: []const u8) bool {
    const found = rules.find(rule) orelse unreachable;
    if (!found.answers(rule)) assert.panic("rules.find('{s}') returned rule {s}, which does not answer to that name; rules.find() must return only a rule whose name or alias matches", .{ rule, found.name });
    if (line > std.mem.count(u8, self.source, "\n")) assert.panic("{s}: checking suppressions on line {d} of a {d}-line file; pass a line number from the tree parsed from this file", .{ self.work.facts.path, line + 1, std.mem.count(u8, self.source, "\n") + 1 });
    for (self.s.suppressions.items()) |s| {
        if (s.line != line) continue;
        if (s.len == 0) return true;
        for (self.s.codes.items()[s.start..][0..s.len]) |code| if (found.answers(code)) return true;
    }
    return false;
}

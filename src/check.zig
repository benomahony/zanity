const std = @import("std");
const capture_ids = @import("capture_ids.zig");
const Vocabulary = capture_ids.Vocabulary;
const walk = @import("walk.zig");
const closing = @import("closing.zig");
const source_lines = @import("code_lines.zig");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const messages = @import("messages.zig");
const rewrite = @import("rewrite.zig");
const hazards = @import("hazards.zig");
const tracing = @import("tracing.zig");
const secrets = @import("secrets.zig");
const weak = @import("weak.zig");
const suppress = @import("suppress.zig");
const types = @import("types.zig");
const scope = @import("scope.zig");
const test_quality = @import("test_quality.zig");
const isolation = @import("isolation.zig");
const unread = @import("unread.zig");
const strings = @import("strings.zig");
const parameters = @import("parameters.zig");
const repeats = @import("repeats.zig");
const shapes = @import("shapes.zig");
const notes = @import("notes.zig");
const extract = @import("extract.zig");
const loops = @import("loops.zig");
const naming = @import("naming.zig");
const passthrough = @import("passthrough.zig");
/// The most test file prefixes and suffixes one language's tables hold.
const max_test_file_affixes = 32;
/// The most test name prefixes one language's tables hold.
const max_test_prefixes = 16;

pub const Diagnostic = struct {
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    /// How to fix this particular finding; empty means the rule's general advice.
    fix: []const u8 = "",
    /// The change that makes `fix` happen, when zanity can make it.
    edit: ?facts_module.Edit = null,
    /// See `Finding.subject`.
    subject: u64 = 0,

    /// Whether `a` is reported before `b`: by line, then column, then rule name.
    pub fn reportedBefore(_: void, a: Diagnostic, b: Diagnostic) bool {
        if (a.rule.len == 0) assert.panic("a finding at {d}:{d} has no rule name; report() always passes one", .{ a.line + 1, a.column + 1 });
        if (b.rule.len == 0) assert.panic("a finding at {d}:{d} has no rule name; report() always passes one", .{ b.line + 1, b.column + 1 });
        if (a.line != b.line) return a.line < b.line;
        if (a.column != b.column) return a.column < b.column;
        return std.mem.order(u8, a.rule, b.rule) == .lt;
    }
};

pub const Family = enum { statement, function, class, call, loop, assertion, assignment, @"test", definition, control };

const Parameter = struct { name: ts.Node, type: ?ts.Node = null };

pub const Summary = union(enum) {
    none,
    assignment: struct { lhs: ts.Node, rhs: ts.Node },
    assertion: struct { node: ts.Node, condition: ts.Node },
};

pub const Call = struct {
    key: ts.Node.Key,
    name: ?ts.Node,
    receiver: bool,
    arguments: [4]?ts.Node,
    count: u32,
};

pub const Context = struct {
    family: Family,
    node: ts.Node,
    span: ts.Node,
    serial: u32,
    body: bool = false,
    /// Where this function's expressions start in the file's list, for duplicated-expression.
    repeat_mark: usize = 0,
    /// Where the body starts, from its @inner capture; parameters are declared before it.
    body_start: u32 = std.math.maxInt(u32),
    /// The first node of the body, from its @inner capture.
    inner: ?ts.Node = null,
    name: ?ts.Node = null,
    callee: ?ts.Node = null,
    receiver: ?ts.Node = null,
    condition: ?ts.Node = null,
    message: ?ts.Node = null,
    iterable: ?ts.Node = null,
    lhs: ?ts.Node = null,
    rhs: ?ts.Node = null,
    arguments: [4]?ts.Node = .{ null, null, null, null },
    argument_count: u32 = 0,
    parameter_start: usize = 0,
    parameter_count: u32 = 0,
    asserts: u32 = 0,
    formal_parameters: u32 = 0,
    owned_start: usize = 0,
    trail_mark: usize = 0,
    fact: ?u32 = null,
    is_test: bool = false,
    has_sleep: bool = false,
    /// Whether the function reports an error anywhere in its body.
    has_message: bool = false,
    /// A branch or loop that continues its parent at the same depth, like an `else if`.
    chained: bool = false,
    /// Checks a test makes: its assertions and its test framework's checks.
    checks: u32 = 0,
    /// Decision points in the function, for its cyclomatic complexity.
    decisions: u32 = 0,
    /// Whether the function's nesting was already reported, so it is reported once.
    nesting_reported: bool = false,
    kind: []const u8 = "",
    previous: Summary = .none,
    summary: Summary = .none,
};

/// Something a function owns, such as a local or an unqualified call and how many arguments it passes.
pub const Owned = struct { owner: u32, text: []const u8, arguments: u32 = 0, types: []const u8 = "" };
const Weak = struct { owner: u32, line: u32 };
const Trail = struct { parent: ts.Node.Key, summary: Summary };
const Suppression = struct { line: u32, start: usize, len: usize };
pub const Assertion = struct { function: *Context, node: ts.Node, condition: ts.Node };
pub const Note = struct { node: ts.Node, rule: []const u8, message: []const u8 };

pub const FileScratch = struct {
    contexts: memory.Bounded(Context),
    opened: memory.Bounded(u8),
    diagnostics: memory.Bounded(Diagnostic),
    suppressions: memory.Bounded(Suppression),
    codes: memory.Bounded([]const u8),
    trail: memory.Bounded(Trail),
    calls: memory.Bounded(Call),
    signature: memory.Bounded(Parameter),
    weak: memory.Bounded(Weak),
    locals: memory.Bounded(Owned),
    spans: tracing.Spans,
    declared: memory.Bounded(types.Declared),
    /// A declared type waiting for the name it declares, which comes after it.
    pending_type: ?ts.Node = null,
    bare_calls: memory.Bounded(Owned),
    async_names: memory.Bounded([]const u8),
    statement_calls: memory.Bounded(ts.Node),
    repeats: memory.Bounded(repeats.Repeat),
    writes: memory.Bounded(repeats.Write),
    names: notes.NameCounts,
    /// The nodes the walk is inside, outermost first, so their parents need no search.
    path: memory.Bounded(ts.Node),
    /// The chain from the root to a node, from ancestorsOf().
    ancestors: memory.Bounded(ts.Node),
    in_comment: []bool,
    code_lines: []bool,
    captures: captures.CaptureScratch,

    pub fn initCheckScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!FileScratch {
        if (limits.depth == 0 or limits.per_file == 0) assert.panic("memory.Limits.depth is {d} and per_file is {d}; both must be above 0 to check a file", .{ limits.depth, limits.per_file });
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so no file could be checked; set it above 0", .{});
        return .{
            .contexts = try .initBounded(gpa, limits.depth, "nested constructs in one file"),
            .opened = try .initBounded(gpa, limits.depth, "constructs opened per syntax node in one file"),
            .diagnostics = try .initBounded(gpa, limits.per_file, "findings in one file"),
            .suppressions = try .initBounded(gpa, limits.per_file, "suppression comments in one file"),
            .codes = try .initBounded(gpa, limits.per_file, "suppressed rule names in one file"),
            .trail = try .initBounded(gpa, limits.depth, "nested statements in one file"),
            .calls = try .initBounded(gpa, limits.captures, "calls in one file"),
            .signature = try .initBounded(gpa, limits.per_file, "parameters in one file"),
            .weak = try .initBounded(gpa, limits.per_file, "weak assertions in one file"),
            .locals = try .initBounded(gpa, limits.per_file, "local names in one file"),
            .spans = try .initSpans(gpa, limits.per_file),
            .declared = try .initBounded(gpa, limits.per_file, "declared names in one file"),
            .bare_calls = try .initBounded(gpa, limits.per_file, "unqualified calls in one file"),
            .async_names = try .initBounded(gpa, limits.per_file, "async functions in one file"),
            .statement_calls = try .initBounded(gpa, limits.per_file, "calls made as statements in one file"),
            .repeats = try .initBounded(gpa, limits.per_file, "repeatable expressions in one function"),
            .writes = try .initBounded(gpa, limits.per_file, "assignments in one file"),
            .names = try .initNameCounts(gpa, limits.per_file),
            .path = try .initBounded(gpa, limits.depth, "syntax nodes on the walk's path in one file"),
            .ancestors = try .initBounded(gpa, limits.depth, "ancestors of one syntax node"),
            .in_comment = try memory.reserveUninitialized(gpa, bool, limits.file_bytes),
            .code_lines = try memory.reserveUninitialized(gpa, bool, std.math.add(usize, limits.file_bytes, 1) catch return error.OutOfMemory),
            .captures = try .initCaptureScratch(gpa, limits),
        };
    }

    pub fn clearFile(self: *FileScratch) void {
        inline for (.{ "contexts", "opened", "diagnostics", "suppressions", "codes", "trail", "calls", "signature", "weak", "locals", "spans", "declared", "bare_calls", "async_names", "statement_calls", "repeats", "writes", "path", "ancestors" }) |field| {
            @field(self, field).clear();
        }
        self.names.reset();
        self.pending_type = null;
        if (self.contexts.len != 0) assert.panic("clearing the per-file scratch left {d} open constructs; clearFile() must clear contexts, so add it to the field list there", .{self.contexts.len});
        if (self.diagnostics.len != 0) assert.panic("clearing the per-file scratch left {d} findings; clearFile() must clear diagnostics, so add it to the field list there", .{self.diagnostics.len});
    }
};

pub const Work = struct {
    scratch: *FileScratch,
    text: *memory.Text,
    facts: *Facts,
};

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
        try scratch.names.drain(&work.facts.references);
        const walked = file.s;
        if (walked.contexts.len != 0) assert.panic("{s}: the walk ended with {d} constructs still open; every node entered must be left", .{ work.facts.path, walked.contexts.len });
        if (walked.opened.len != 0) assert.panic("{s}: the walk ended with {d} nodes still open; every node entered must be left", .{ work.facts.path, walked.opened.len });
        return .{ .diagnostics = file.finish(), .parse_error = ts.ts_node_has_error(root) };
    }
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
        return test_quality.inTestDirectory(path);
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
        if (suppress.suppressed(self, start.row, rule)) return false;
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

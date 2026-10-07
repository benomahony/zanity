const std = @import("std");
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
const weak = @import("weak.zig");
const suppress = @import("suppress.zig");
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
const passthrough = @import("passthrough.zig");

pub const Diagnostic = struct {
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    /// How to fix this particular finding; empty means the rule's general advice.
    fix: []const u8 = "",
    /// The change that makes `fix` happen, when zanity can make it.
    edit: ?facts_module.Edit = null,

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

const Summary = union(enum) {
    none,
    assignment: struct { lhs: ts.Node, rhs: ts.Node },
    assertion: struct { node: ts.Node, condition: ts.Node },
};

pub const Call = struct {
    key: ts.Node.Key,
    name: ?ts.Node,
    receiver: bool,
    arguments: [2]?ts.Node,
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
    arguments: [2]?ts.Node = .{ null, null },
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

const Owned = struct { owner: u32, text: []const u8 };
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
            .bare_calls = try .initBounded(gpa, limits.per_file, "unqualified calls in one file"),
            .async_names = try .initBounded(gpa, limits.per_file, "async functions in one file"),
            .statement_calls = try .initBounded(gpa, limits.per_file, "calls made as statements in one file"),
            .repeats = try .initBounded(gpa, limits.per_file, "repeatable expressions in one function"),
            .writes = try .initBounded(gpa, limits.per_file, "assignments in one file"),
            .names = try .initNameCounts(gpa, limits.per_file),
            .path = try .initBounded(gpa, limits.depth, "syntax nodes on the walk's path in one file"),
            .ancestors = try .initBounded(gpa, limits.depth, "ancestors of one syntax node"),
            .in_comment = try memory.reserve(gpa, bool, limits.file_bytes),
            .code_lines = try memory.reserve(gpa, bool, limits.file_bytes + 1),
            .captures = try .initCaptureScratch(gpa, limits),
        };
    }

    pub fn clearFile(self: *FileScratch) void {
        inline for (.{ "contexts", "opened", "diagnostics", "suppressions", "codes", "trail", "calls", "signature", "weak", "locals", "bare_calls", "async_names", "statement_calls", "repeats", "writes", "path", "ancestors" }) |field| {
            @field(self, field).clear();
        }
        self.names.reset();
        if (self.contexts.len != 0) assert.panic("clearing the per-file scratch left {d} open constructs; clearFile() must clear contexts, so add it to the field list there", .{self.contexts.len});
        if (self.diagnostics.len != 0) assert.panic("clearing the per-file scratch left {d} findings; clearFile() must clear diagnostics, so add it to the field list there", .{self.diagnostics.len});
    }
};

pub const Work = struct {
    scratch: *FileScratch,
    text: *memory.Text,
    facts: *Facts,
};

const Vocabulary = struct {
    comment: ?captures.Id,
    literal_true: ?captures.Id,
    literal_constant: ?captures.Id,
    literal_falsy: ?captures.Id,
    literal_none: ?captures.Id,
    literal_collection: ?captures.Id,
    literal_string: ?captures.Id,
    error_message: ?captures.Id,
    string_format: ?captures.Id,
    expression_path: ?captures.Id,
    expression_conditional: ?captures.Id,
    compare_not_null: ?captures.Id,
    compare_non_negative: ?captures.Id,
    compare_equal: ?captures.Id,
    compare_subject: ?captures.Id,
    compare_value: ?captures.Id,
    assignment_compound: ?captures.Id,
    function_passthrough: ?captures.Id,
    catch_swallowed: ?captures.Id,
    arith_difference: ?captures.Id,
    string_built: ?captures.Id,
    async_name: ?captures.Id,
    statement_call: ?captures.Id,
    control_chain: ?captures.Id,
    decision_point: ?captures.Id,
    test_outer: ?captures.Id,
    test_check: ?captures.Id,
    test_shared_state: ?captures.Id,
    chain_link: ?captures.Id,
    expression_repeatable: ?captures.Id,
    write_target: ?captures.Id,
    reference_name: ?captures.Id,
    abstraction_name: ?captures.Id,
    implementation_base: ?captures.Id,
    visibility_public: ?captures.Id,

    fn lookup(c: captures.Compiled) Vocabulary {
        if (c.names.len == 0) assert.panic("the query has no captures, so no rule could run; check the language's query files", .{});
        if (c.predicates.len == 0) assert.panic("the query has {d} captures but no patterns; check the language's query files listed in languages/manifest.zon", .{c.names.len});
        return .{
            .comment = c.id("comment.outer"),
            .literal_true = c.id("literal.true"),
            .literal_constant = c.id("literal.constant"),
            .literal_falsy = c.id("literal.falsy"),
            .literal_none = c.id("literal.none"),
            .literal_collection = c.id("literal.collection"),
            .literal_string = c.id("literal.string"),
            .error_message = c.id("error.message"),
            .string_format = c.id("string.format"),
            .expression_path = c.id("expression.path"),
            .expression_conditional = c.id("expression.conditional"),
            .compare_not_null = c.id("compare.not_null"),
            .compare_non_negative = c.id("compare.non_negative"),
            .compare_equal = c.id("compare.equal"),
            .compare_subject = c.id("compare.subject"),
            .compare_value = c.id("compare.value"),
            .assignment_compound = c.id("assignment.compound"),
            .function_passthrough = c.id("function.passthrough"),
            .catch_swallowed = c.id("catch.swallowed"),
            .arith_difference = c.id("arith.difference"),
            .string_built = c.id("string.built"),
            .async_name = c.id("async.name"),
            .statement_call = c.id("statement.call"),
            .control_chain = c.id("control.chain"),
            .decision_point = c.id("decision.point"),
            .test_outer = c.id("test.outer"),
            .test_check = c.id("test.check"),
            .test_shared_state = c.id("test.shared_state"),
            .chain_link = c.id("chain.link"),
            .expression_repeatable = c.id("expression.repeatable"),
            .write_target = c.id("write.target"),
            .reference_name = c.id("reference.name"),
            .abstraction_name = c.id("abstraction.name"),
            .implementation_base = c.id("implementation.base"),
            .visibility_public = c.id("visibility.public"),
        };
    }
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
        var supported: rules.Set = .{};
        for (requested.names()) |name| {
            if (language.applies(loaded.adapter, name)) supported.include(name);
        }
        if (supported.len > requested.len) assert.panic("{s} supports {d} of the {d} requested rules; it can't support more than were asked for", .{ loaded.adapter.name, supported.len, requested.len });
        return .{
            .loaded = loaded,
            .compiled = compiled,
            .vocabulary = Vocabulary.lookup(compiled),
            .enabled = supported,
        };
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
        file.code_lines = file.codeLines();
        if (ts.ts_node_has_error(root)) {
            _ = try file.report(root, "parse-error", "zanity couldn't fully parse this file, so some findings may be missing.");
        }
        try file.walk(root);
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
    serials: u32 = 0,
    /// Where the walk's capture lookups have reached in `index`.
    next_capture: usize = 0,

    pub fn walk(self: *File, root: ts.Node) !void {
        if (self.s.contexts.len != 0) assert.panic("{s}: starting a walk with {d} constructs already open; clear the scratch first", .{ self.work.facts.path, self.s.contexts.len });
        if (self.s.opened.len != 0) assert.panic("{s}: starting a walk with {d} nodes already open; clear the scratch first", .{ self.work.facts.path, self.s.opened.len });
        var cursor = ts.ts_tree_cursor_new(root);
        defer ts.ts_tree_cursor_delete(&cursor);
        try self.enter(ts.ts_tree_cursor_current_node(&cursor));
        const steps = 2 * @as(usize, ts.ts_node_descendant_count(root)) + 1;
        var descending = true;
        for (0..steps) |_| {
            if (descending and ts.ts_tree_cursor_goto_first_child(&cursor)) {
                try self.enter(ts.ts_tree_cursor_current_node(&cursor));
                continue;
            }
            try self.leave();
            if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) {
                try self.enter(ts.ts_tree_cursor_current_node(&cursor));
                descending = true;
                continue;
            }
            if (!ts.ts_tree_cursor_goto_parent(&cursor)) return;
            descending = false;
        }
        return error.TreeWalkExceededNodeCount;
    }

    pub fn enter(self: *File, node: ts.Node) !void {
        try self.s.path.add(node);
        const found = self.index.ofNext(&self.next_capture, node);
        const depth = self.s.contexts.len;
        for (found) |t| {
            if (t.id >= self.checker.compiled.captureCount()) assert.panic("{s}: {f} carries capture id {d}, but the query has {d} captures; build the capture index with this checker's compiled query", .{ self.work.facts.path, node.where(), t.id, self.checker.compiled.captureCount() });
            if (!try self.enterSignal(node, t.id, found)) try self.enterCapture(node, self.checker.compiled.names[t.id]);
        }
        const opened = try self.openFamilies(node, found);
        if (self.s.contexts.len != depth + opened) assert.panic("{s}: entering {f} opened {d} constructs but the stack grew from {d} to {d}; only openFamilies() may open constructs, so check enterSignal() and enterCapture()", .{ self.work.facts.path, node.where(), opened, depth, self.s.contexts.len });
        try self.s.opened.add(opened);
    }

    /// Captures that mark something about the node on their own, such as a decision point or an
    /// error message. Returns whether `id` was one of them.
    pub fn enterSignal(self: *File, node: ts.Node, id: captures.Id, found: []const captures.Triple) !bool {
        if (found.len == 0) assert.panic("{s}: {f} carries capture {d} but no captures were found on it; call enterSignal() only with captures found on this node", .{ self.work.facts.path, node.where(), id });
        if (try notes.note(self, node, id)) return true;
        const v = self.v;
        if (v.catch_swallowed == id) {
            _ = try self.report(node, "swallowed-error", try self.say("This error handler does nothing, so the failure disappears silently.", .{}));
            return false;
        }
        if (v.decision_point == id) {
            if (!self.hasOuter(found, .assertion)) if (self.enclosingUnit()) |unit| {
                unit.decisions += 1;
            };
        } else if (v.test_shared_state == id) {
            try isolation.checkSharedStatement(self, node);
        } else if (v.test_check == id) {
            if (test_quality.enclosingTest(self)) |unit| unit.checks += 1;
        } else if (v.async_name == id) {
            try self.s.async_names.add(node.text(self.source));
        } else if (v.statement_call == id) {
            try self.s.statement_calls.add(node);
        } else if (v.error_message == id) {
            if (self.innermost(.assertion) == null) try messages.checkMessage(self, node, null);
        } else return false;
        if (self.s.statement_calls.len > self.s.statement_calls.capacity()) assert.panic("{s}: {d} statement calls in room for {d}; raise memory.Limits.per_file, or split the file", .{ self.work.facts.path, self.s.statement_calls.len, self.s.statement_calls.capacity() });
        return true;
    }

    /// Captures that fill in part of an open construct: its name, a parameter, a local, a condition.
    pub fn enterCapture(self: *File, node: ts.Node, name: captures.Name) !void {
        if (name.full.len == 0) assert.panic("{s}: {f} carries a capture with no name; name every capture in the language's .scm files, such as @call.name", .{ self.work.facts.path, node.where() });
        if (std.mem.eql(u8, name.family, "finding")) return hazards.patternFinding(self, node, name.part);
        if (std.mem.eql(u8, name.full, "name")) {
            if (self.innermost(.definition)) |definition| {
                if (definition.name == null) definition.name = node;
            }
            return;
        }
        if (std.mem.eql(u8, name.part, "outer")) return;
        if (std.mem.eql(u8, name.family, "parameter")) return self.parameter(name.part, node);
        if (std.mem.eql(u8, name.family, "local.definition") and (std.mem.eql(u8, name.part, "var") or std.mem.eql(u8, name.part, "parameter"))) {
            if (self.innermost(.function)) |function| try self.s.locals.add(.{ .owner = function.serial, .text = node.text(self.source) });
            if (std.mem.eql(u8, name.part, "parameter")) try self.parameter("name", node);
            return;
        }
        const family = std.meta.stringToEnum(Family, name.family) orelse return;
        const ctx = self.innermost(family) orelse return;
        try self.assign(ctx, name.part, node);
        if (ctx.family != family) assert.panic("{s}: {f} was assigned to a {t} while looking for a {t}; innermost() must return a context of the family it was asked for", .{ self.work.facts.path, node.where(), ctx.family, family });
    }

    /// Opens a construct for each family the node is the outer node of; returns how many.
    pub fn openFamilies(self: *File, node: ts.Node, found: []const captures.Triple) !u8 {
        const before = self.s.contexts.len;
        if (before > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, before, self.s.contexts.capacity() });
        var opened: u8 = 0;
        for (std.enums.values(Family)) |family| {
            if (!self.hasOuter(found, family)) continue;
            if (self.refines(family, node, found)) |merged| {
                merged.span = node;
            } else {
                try self.open(family, node);
                opened += 1;
            }
        }
        if (self.definitionKind(found)) |kind| {
            try self.open(.definition, node);
            self.s.contexts.last().?.kind = kind;
            opened += 1;
        }
        if (self.s.contexts.len != before + opened) assert.panic("{s}: opened {d} constructs at {f} but the stack grew by {d}; openFamilies() must count each open(), and nothing else may add contexts", .{ self.work.facts.path, opened, node.where(), self.s.contexts.len - before });
        return opened;
    }

    pub fn definitionKind(self: *File, found: []const captures.Triple) ?[]const u8 {
        const names = self.checker.compiled.names;
        if (found.len > self.index.triples.len) assert.panic("{s}: {d} captures on one node, more than the {d} in the file; of() must slice within the recorded captures", .{ self.work.facts.path, found.len, self.index.triples.len });
        for (found) |t| {
            if (!std.mem.eql(u8, names[t.id].family, "definition")) continue;
            if (names[t.id].part.len == 0) assert.panic("capture @{s} has no kind after 'definition.'; write it as @definition.function, @definition.class and so on", .{names[t.id].full});
            return names[t.id].part;
        }
        return null;
    }

    pub fn hasOuter(self: *File, found: []const captures.Triple, family: Family) bool {
        const names = self.checker.compiled.names;
        if (found.len > self.index.triples.len) assert.panic("{s}: {d} captures on one node, more than the {d} in the file; of() must slice within the recorded captures", .{ self.work.facts.path, found.len, self.index.triples.len });
        for (found) |t| {
            if (t.id >= names.len) assert.panic("{s}: capture id {d} is out of range; the query has {d} captures", .{ self.work.facts.path, t.id, names.len });
            if (std.mem.eql(u8, names[t.id].part, "outer") and std.mem.eql(u8, names[t.id].family, @tagName(family))) return true;
        }
        return false;
    }

    pub fn leave(self: *File) !void {
        const opened = self.s.opened.drop() orelse return error.LeftMoreNodesThanEntered;
        if (opened > self.s.contexts.len) assert.panic("{s}: leaving a node that opened {d} constructs, but only {d} are open; only leave() may drop contexts, so check what closed them early", .{ self.work.facts.path, opened, self.s.contexts.len });
        const remaining = self.s.contexts.len - opened;
        for (0..opened) |_| {
            const ctx = self.s.contexts.drop().?;
            try self.close(ctx);
        }
        if (self.s.contexts.len != remaining) assert.panic("{s}: closing constructs left {d} open, expected {d}; close() must not open or drop contexts itself", .{ self.work.facts.path, self.s.contexts.len, remaining });
        if (self.s.path.drop() == null) assert.panic("{s}: left a node, but the walk's path is empty; enter() must add each node it enters to the path", .{self.work.facts.path});
    }

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

    pub fn parameter(self: *File, part: []const u8, node: ts.Node) !void {
        if (part.len == 0) assert.panic("{s}: {f} is captured as a parameter with no part; write @parameter.name or @parameter.type", .{ self.work.facts.path, node.where() });
        if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: parameter capture @parameter.{s} matched the empty {f}; capture a named node", .{ self.work.facts.path, part, node.where() });
        const function = self.innermost(.function) orelse return;
        if (std.mem.eql(u8, part, "name")) {
            const last = if (function.parameter_count > 0) self.s.signature.last() else null;
            if (last != null and last.?.name.eql(node)) return;
            try self.s.signature.add(.{ .name = node });
            function.parameter_count += 1;
        } else if (std.mem.eql(u8, part, "type")) {
            if (function.parameter_count > 0) self.s.signature.last().?.type = node;
        }
    }

    pub fn assign(self: *File, ctx: *Context, part: []const u8, node: ts.Node) !void {
        if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: @{t}.{s} captured {f}, which starts before its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: @{t}.{s} captured {f}, which ends after its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
        const slots = .{ "name", "callee", "receiver", "condition", "message", "iterable", "lhs", "rhs" };
        inline for (slots) |slot| {
            if (std.mem.eql(u8, part, slot)) {
                if (@field(ctx, slot) == null) @field(ctx, slot) = node;
                if (ctx.family == .function and std.mem.eql(u8, slot, "name")) {
                    ctx.is_test = self.isTestName(node.text(self.source));
                    const at = ts.ts_node_start_point(node);
                    ctx.fact = try self.work.facts.function(node.text(self.source), .{ at.row, at.column }, self.definedInClass());
                }
                return;
            }
        }
        if (std.mem.eql(u8, part, "inner")) {
            if (!ctx.body) {
                ctx.body_start = ts.ts_node_start_byte(node);
                ctx.inner = node;
            }
            ctx.body = true;
        } else if (std.mem.eql(u8, part, "argument")) {
            if (ctx.argument_count < ctx.arguments.len) ctx.arguments[ctx.argument_count] = node;
            ctx.argument_count += 1;
        } else if (std.mem.eql(u8, part, "parameter")) {
            ctx.formal_parameters += 1;
        }
    }

    pub fn refines(self: *File, family: Family, node: ts.Node, found: []const captures.Triple) ?*Context {
        if (found.len == 0) assert.panic("{s}: asked whether {f} refines a {t} with no captures on it; call refines() only from openFamilies(), with the node's captures", .{ self.work.facts.path, node.where(), family });
        for (found) |t| {
            const name = self.checker.compiled.names[t.id];
            if (!std.mem.eql(u8, name.family, @tagName(family))) continue;
            if (std.mem.eql(u8, name.part, "outer") or std.mem.eql(u8, name.part, "passthrough")) continue;
            return null;
        }
        const parent = self.parentOf(node) orelse return null;
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &items[i];
            if (!ctx.span.eql(parent) and !ctx.node.eql(parent)) return null;
            if (ctx.family != family) continue;
            if (ctx.body) return null;
            if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: {f} refines the {t} {f} but ends after it; capture the refining node inside the construct's @outer in the language's zanity.scm", .{ self.work.facts.path, node.where(), family, ctx.node.where() });
            return ctx;
        }
        if (i != 0) assert.panic("{s}: the search for a {t} to refine stopped at depth {d} without returning; the loop in refines() must return from inside, so check its exits", .{ self.work.facts.path, family, i });
        return null;
    }

    pub fn open(self: *File, family: Family, node: ts.Node) !void {
        if (self.s.contexts.last()) |top| {
            if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(top.node)) assert.panic("{s}: opening a {t} at {f}, which starts before the enclosing {t} {f}; the walk visits nodes in order", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
            if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(top.node)) assert.panic("{s}: opening a {t} at {f}, which ends after the enclosing {t} {f}; capture the inner construct inside the outer one's node in the language's zanity.scm", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
        }
        self.serials += 1;
        var ctx: Context = .{
            .family = family,
            .node = node,
            .span = node,
            .serial = self.serials,
            .is_test = family == .@"test",
            .parameter_start = self.s.signature.len,
            .owned_start = @min(self.s.locals.len, self.s.bare_calls.len),
            .trail_mark = self.s.trail.len,
            .repeat_mark = self.s.repeats.len,
        };
        switch (family) {
            .assertion => {
                if (self.enclosingFunction()) |function| function.asserts += 1;
                if (test_quality.enclosingTest(self)) |unit| unit.checks += 1;
            },
            .statement => if (self.parentOf(node)) |parent| {
                ctx.previous = self.trailFor(parent.key());
            },
            .control => {
                ctx.chained = self.index.marks(node, self.v.control_chain);
                try hazards.checkNesting(self, node, ctx.chained);
            },
            else => {},
        }
        try self.s.contexts.add(ctx);
    }

    pub fn trailFor(self: *File, parent: ts.Node.Key) Summary {
        const trail = self.s.trail.items();
        if (trail.len > self.s.trail.capacity()) assert.panic("{s}: {d} statement summaries in room for {d}; raise memory.Limits.depth, or check that remember() trims the trail", .{ self.work.facts.path, trail.len, self.s.trail.capacity() });
        var i = trail.len;
        while (i > 0) {
            i -= 1;
            const entry = trail[i];
            if (entry.parent.id == parent.id and entry.parent.start == parent.start) return entry.summary;
        }
        if (i != 0) assert.panic("{s}: the search for the previous statement stopped at {d} without returning; the loop in trailFor() must return from inside, so check its exits", .{ self.work.facts.path, i });
        return .none;
    }

    pub fn remember(self: *File, ctx: Context) !void {
        const parent = self.parentOf(ctx.node) orelse return;
        if (ctx.family != .statement) assert.panic("{s}: remembering a {t} ({f}) as the previous statement; only statements are remembered", .{ self.work.facts.path, ctx.family, ctx.node.where() });
        if (ctx.trail_mark > self.s.trail.len) assert.panic("{s}: the statement {f} marked {d} summaries, but only {d} remain; remember() must trim the trail back to the statement's mark, never below it", .{ self.work.facts.path, ctx.node.where(), ctx.trail_mark, self.s.trail.len });
        self.s.trail.len = ctx.trail_mark;
        const key = parent.key();
        for (self.s.trail.items()) |*entry| {
            if (entry.parent.id == key.id and entry.parent.start == key.start) {
                entry.summary = ctx.summary;
                return;
            }
        }
        try self.s.trail.add(.{ .parent = key, .summary = ctx.summary });
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

    pub fn close(self: *File, ctx: Context) !void {
        if (ts.ts_node_end_byte(ctx.span) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: the {t} {f} was widened to {f}, which ends after it; refines() may only widen a construct to a node inside it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
        if (ts.ts_node_start_byte(ctx.span) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: the {t} {f} was widened to {f}, which starts before it; refines() may only widen a construct to a node inside it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
        switch (ctx.family) {
            .call => try self.closeCall(ctx),
            .loop => try self.closeLoop(ctx),
            .assertion => try self.closeAssertion(ctx),
            .assignment => try self.closeAssignment(ctx),
            .function => try self.closeFunction(ctx),
            .statement => try self.remember(ctx),
            .@"test" => try test_quality.closeTest(self, ctx),
            .class, .control => {},
            .definition => try self.closeDefinition(ctx),
        }
    }

    pub fn closeCall(self: *File, ctx: Context) !void {
        if (ctx.family != .call) assert.panic("{s}: closing {f} as a call, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        try self.s.calls.add(.{
            .key = ctx.node.key(),
            .name = ctx.name,
            .receiver = ctx.receiver != null,
            .arguments = ctx.arguments,
            .count = ctx.argument_count,
        });
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (name.len == 0) assert.panic("{s}: @call.name matched the empty {f}; capture the callee's identifier", .{ self.work.facts.path, name_node.where() });
        try hazards.checkForbiddenCall(self, ctx, name);
        if (self.calleeIn(ctx, name, self.tables.debug_calls)) |matched| {
            _ = try self.report(ctx.callee orelse name_node, "debug-leftover", try self.say("'{s}' is debugging code: wherever it ships it stops the program or dumps its state.", .{matched}));
        }
        const reports_error = self.calleeIn(ctx, name, self.tables.error_calls) != null or (ctx.receiver != null and contains(self.tables.error_methods, name));
        if (reports_error and self.innermost(.assertion) == null) {
            if (ctx.arguments[0]) |message| try messages.checkMessage(self, message, null);
        }
        try hazards.checkRiskyCall(self, ctx, name);
        if (self.inTest()) {
            try test_quality.checkTestCall(self, ctx, name);
        } else if (self.inTestFile()) {
            try test_quality.checkTestDouble(self, ctx, name);
        }
        const allocating = self.calleeIn(ctx, name, self.tables.allocating_calls) orelse (if (contains(self.tables.allocating_calls, name)) name else null);
        if (allocating) |matched| try self.checkAllocation(ctx, matched);
        try repeats.noteCallWrites(self, ctx, name);
        if (contains(self.tables.mutating_calls, name) and self.inAssertionCondition(ctx.node)) {
            _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion calls '{s}', which changes state, so the program behaves differently when assertions are disabled.", .{name}));
        }
        const function = self.enclosingFunction() orelse return;
        const caller = function.fact orelse return;
        if (ctx.receiver) |receiver| {
            if (!contains(self.tables.self_receivers, receiver.text(self.source))) return;
            try self.work.facts.call(caller, name, .methods);
            return;
        }
        try self.s.bare_calls.add(.{ .owner = function.serial, .text = name });
    }

    pub fn closeDefinition(self: *File, ctx: Context) !void {
        if (ctx.family != .definition) assert.panic("{s}: closing {f} as a definition, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.kind.len == 0) assert.panic("{s}: the definition {f} has no kind; capture it as @definition.function, @definition.class and so on", .{ self.work.facts.path, ctx.node.where() });
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (self.checker.enabled.enabled("dead-symbol")) try self.s.names.tally(facts_module.nameHash(name), -1);
        if (std.mem.eql(u8, ctx.kind, "constant") and !std.ascii.isUpper(name[0])) return;
        if (contains(self.tables.protocol_names, name)) return;
        const at = ts.ts_node_start_point(name_node);
        const public = self.index.marks(ctx.node, self.v.visibility_public) or (self.tables.exported_by_case and std.ascii.isUpper(name[0]));
        const member = std.mem.eql(u8, ctx.kind, "method") or self.heldByFunctionOrClass(ctx.node);
        const prefix = self.tables.private_prefix;
        const importable = if (prefix.len > 0) !std.mem.startsWith(u8, name, prefix) else public;
        try self.work.facts.define(name, ctx.kind, .{ .at = .{ at.row, at.column }, .public = public, .member = member, .importable = importable });
    }

    /// Whether a function or class other than `node` itself holds it, so code reaches it only
    /// through that function or class.
    fn heldByFunctionOrClass(self: *File, node: ts.Node) bool {
        const start = ts.ts_node_start_byte(node);
        const end = ts.ts_node_end_byte(node);
        if (end <= start) assert.panic("{s}: the definition {f} covers no text; put @definition.<kind> on the whole declaration", .{ self.work.facts.path, node.where() });
        for (self.s.contexts.items()) |held| {
            if (held.family != .function and held.family != .class) continue;
            const from = ts.ts_node_start_byte(held.node);
            const to = ts.ts_node_end_byte(held.node);
            if (from == start and to == end) continue;
            if (from <= start and end <= to) return true;
        }
        if (self.s.contexts.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; leave() must pop what enter() opened", .{ self.work.facts.path, self.s.contexts.len, self.s.contexts.capacity() });
        return false;
    }

    pub fn inAssertionCondition(self: *File, node: ts.Node) bool {
        const assertion = self.innermost(.assertion) orelse return false;
        const condition = assertion.condition orelse return false;
        if (ts.ts_node_start_byte(condition) < ts.ts_node_start_byte(assertion.node)) assert.panic("{s}: @assertion.condition captured {f}, before its assertion {f}; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
        if (ts.ts_node_end_byte(condition) > ts.ts_node_end_byte(assertion.node)) assert.panic("{s}: @assertion.condition captured {f}, after its assertion {f} ends; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
        return ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(condition) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(condition);
    }

    pub fn isTestName(self: *File, name: []const u8) bool {
        if (name.len == 0) assert.panic("{s}: asked whether an empty function name is a test name; @function.name matched an empty node", .{self.work.facts.path});
        if (self.tables.test_prefixes.len > 16) assert.panic("{s} lists {d} test prefixes in languages/tables.zon; more than 16 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_prefixes.len });
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

    pub fn checkAllocation(self: *File, ctx: Context, callee: []const u8) !void {
        if (ctx.family != .call) assert.panic("{s}: checking the allocation in {f}, which is a {t}, not a call; call checkAllocation() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (callee.len == 0) assert.panic("{s}: the allocating call {f} has an empty callee; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
        if (self.inTest() or self.inTestFile()) return;
        const function = self.enclosingFunction() orelse return;
        const owner = function.name.?.text(self.source);
        for (self.tables.initializer_prefixes) |prefix| if (std.mem.startsWith(u8, owner, prefix)) return;
        const shown = if (ctx.callee) |c| c.text(self.source) else callee;
        _ = try self.report(ctx.node, "dynamic-allocation", try self.say("'{s}' allocates memory after initialization in '{s}', so memory use depends on input and can fail at any point.", .{ shown, owner }));
    }

    pub fn inTestFile(self: *File) bool {
        const base = std.fs.path.basename(self.work.facts.path);
        if (base.len == 0) assert.panic("path '{s}' has no file name, so zanity can't tell whether it holds tests", .{self.work.facts.path});
        for (self.tables.test_file_prefixes) |prefix| if (std.mem.startsWith(u8, base, prefix)) return true;
        for (self.tables.test_file_suffixes) |suffix| if (std.mem.endsWith(u8, base, suffix)) return true;
        if (self.tables.test_file_prefixes.len + self.tables.test_file_suffixes.len > 32) assert.panic("{s} lists {d} test file prefixes and {d} suffixes in languages/tables.zon; more than 32 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_file_prefixes.len, self.tables.test_file_suffixes.len });
        return false;
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

    pub fn closeLoop(self: *File, ctx: Context) !void {
        if (ctx.family != .loop) assert.panic("{s}: closing {f} as a loop, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.has_sleep) {
            _ = try self.report(ctx.node, "polling-loop", try self.say("This loop polls with a sleep, so the test's speed and outcome depend on timing.", .{}));
        }
        if (ctx.condition != null and ctx.iterable != null) assert.panic("{s}: the loop {f} has both @loop.condition and @loop.iterable; a loop is one or the other, so fix its query", .{ self.work.facts.path, ctx.node.where() });
        const unbounded = if (ctx.condition) |c| self.index.marks(c, self.v.literal_true) else ctx.iterable == null;
        if (!unbounded) return;
        if (try self.report(ctx.node, "unbounded-loop", try self.say("'{s}' has no bound, so it can run forever.", .{header(ctx.node.text(self.source))}))) {
            self.s.diagnostics.last().?.fix = try loops.unboundedFix(self, ctx.node);
        }
    }

    pub fn closeAssignment(self: *File, ctx: Context) !void {
        if (ctx.family != .assignment) assert.panic("{s}: closing {f} as an assignment, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (self.inAssertionCondition(ctx.node)) {
            _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion assigns a variable, so the program behaves differently when assertions are disabled.", .{}));
        }
        if (self.index.marks(ctx.node, self.v.assignment_compound)) return;
        const lhs = ctx.lhs orelse return;
        const rhs = ctx.rhs orelse return;
        try hazards.checkSecret(self, ctx.node, lhs, rhs);
        if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(rhs)) assert.panic("{s}: in the assignment {f}, @assignment.lhs {f} overlaps @assignment.rhs {f}; the query captured the wrong nodes", .{ self.work.facts.path, ctx.node.where(), lhs.where(), rhs.where() });
        const statement = self.statementOf(ctx.node) orelse return;
        statement.summary = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
    }

    pub fn closeAssertion(self: *File, ctx: Context) !void {
        if (ctx.family != .assertion) assert.panic("{s}: closing {f} as an assertion, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.message == null) {
            if (try self.report(ctx.node, "assertion-message", try self.say("This assertion has no message, so when it fails nobody will know which invariant broke or with what values.", .{}))) {
                if (ctx.condition) |condition| try rewrite.explainAssertion(self, ctx.node, condition);
            }
        }
        if (ctx.message) |message| try messages.checkMessage(self, message, ctx.condition);
        const condition = ctx.condition orelse return;
        if (ctx.message != null and ts.ts_node_start_byte(condition) > ts.ts_node_start_byte(ctx.message.?)) assert.panic("{s}: in the assertion {f}, @assertion.message {f} comes before @assertion.condition {f}; the query captured them the wrong way round", .{ self.work.facts.path, ctx.node.where(), ctx.message.?.where(), condition.where() });
        const function = self.enclosingFunction() orelse return;
        try weak.restatedType(self, function, ctx.node, condition);
        const statement = self.statementOf(ctx.node) orelse return;
        statement.summary = .{ .assertion = .{ .node = ctx.node, .condition = condition } };
        const here: Assertion = .{ .function = function, .node = ctx.node, .condition = condition };
        switch (statement.previous) {
            .assignment => |previous| try weak.afterAssignment(self, here, previous.lhs, previous.rhs),
            .assertion => |previous| try weak.afterAssertion(self, here, previous.node, previous.condition),
            .none => {},
        }
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

    pub fn resolveBareCalls(self: *File, ctx: Context) !void {
        const caller = ctx.fact orelse return;
        if (ctx.family != .function) assert.panic("{s}: resolving the calls of {f}, which is a {t}, not a function; call resolveBareCalls() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        const reach: facts_module.Reach = if (self.tables.methods_need_receiver) .functions else .any;
        const locals = self.s.locals.items();
        const calls = self.s.bare_calls.items();
        if (ctx.owned_start > calls.len or ctx.owned_start > locals.len) assert.panic("{s}: {f} owns calls and locals from {d}, but only {d} calls and {d} locals are recorded; open() must set owned_start from those lists' lengths when the function opens", .{ self.work.facts.path, ctx.node.where(), ctx.owned_start, calls.len, locals.len });
        outer: for (calls[ctx.owned_start..]) |call| {
            if (call.owner != ctx.serial) continue;
            for (locals[ctx.owned_start..]) |local| {
                if (local.owner == ctx.serial and sameText(local.text, call.text)) continue :outer;
            }
            try self.work.facts.call(caller, call.text, reach);
        }
    }

    pub fn closeFunction(self: *File, ctx: Context) !void {
        if (ctx.family != .function) assert.panic("{s}: closing {f} as a function, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        try self.resolveBareCalls(ctx);
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (name.len == 0) assert.panic("{s}: @function.name matched the empty {f}; capture the function's identifier", .{ self.work.facts.path, name_node.where() });
        const last = ts.ts_node_end_point(ctx.span).row;
        try self.checkFunctionLength(ctx, name_node, name);
        if (ctx.formal_parameters > rules.max_parameters) {
            _ = try self.report(name_node, "long-parameter-list", try self.say("'{s}' takes {d} parameters; functions should take at most {d}.", .{ name, ctx.formal_parameters, rules.max_parameters }));
        }
        try parameters.checkUnusedParameters(self, ctx, name);
        try repeats.checkRepeats(self, ctx, name);
        try shapes.recordShape(self, ctx);
        try extract.checkExtractable(self, ctx, name);
        if (self.index.marks(ctx.span, self.v.function_passthrough) or self.index.marks(ctx.node, self.v.function_passthrough)) try passthrough.checkPassthrough(self, ctx, name_node, name);
        const meaningful = ctx.asserts -| weak.weakLines(self, ctx);
        if (meaningful < rules.min_asserts_per_function) {
            const noun = if (meaningful == 1) "assertion" else "assertions";
            const message = try self.say("'{s}' has {d} {s} that can catch a bug; it needs at least {d}.", .{ name, meaningful, noun, rules.min_asserts_per_function });
            if (try self.report(name_node, "assertion-density", message)) {
                self.s.diagnostics.last().?.fix = try weak.assertionFix(self, ctx, name);
            }
        }
        if (ctx.decisions + 1 > rules.max_complexity) {
            _ = try self.report(name_node, "complex-function", try self.say("'{s}' makes {d} decisions (cyclomatic complexity {d}), past the {d} a reader can follow and a test suite can cover.", .{ name, ctx.decisions, ctx.decisions + 1, rules.max_complexity }));
        }
        if (self.work.facts.collect_units and !self.index.marks(ctx.node, self.v.test_outer)) {
            const at = ts.ts_node_start_point(name_node);
            try self.work.facts.unit(name, ctx.span.text(self.source), .{ .kind = if (ctx.is_test) .@"test" else .function, .reports_error = ctx.has_message, .at = .{ at.row, at.column, last } });
        }
    }

    /// A function against the function limit, or a test named as one (`test_x`, `TestX`) against the
    /// tighter test limit. A test marked by an attribute or annotation is also a test construct,
    /// and closeTest measures it.
    pub fn checkFunctionLength(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
        if (ctx.family != .function) assert.panic("{s}: measuring {f} as a function, but it is a {t}; call checkFunctionLength() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (!std.mem.eql(u8, name, name_node.text(self.source))) assert.panic("{s}: measuring '{s}' under the name of {f}; pass the function's own name node and its text", .{ self.work.facts.path, name, name_node.where() });
        if (self.index.marks(ctx.node, self.v.test_outer)) return;
        if (ctx.is_test) {
            try test_quality.checkEager(self, ctx, name_node, name);
            try test_quality.checkTestName(self, name_node, name);
        }
        const lines = self.codeLinesIn(ctx.span);
        if (ctx.is_test and lines >= rules.max_test_lines) {
            _ = try self.report(name_node, "long-test", try self.say("'{s}' has {d} lines of code; tests must have fewer than {d}.", .{ name, lines, rules.max_test_lines }));
        } else if (!ctx.is_test and lines >= rules.max_function_lines) {
            _ = try self.report(name_node, "long-function", try self.say("'{s}' has {d} lines of code; functions must have fewer than {d}.", .{ name, lines, rules.max_function_lines }));
        }
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
        const in_comment = self.s.in_comment[0..self.source.len];
        @memset(in_comment, false);
        if (self.v.comment) |comment| {
            for (self.index.triples) |t| {
                if (t.id != comment) continue;
                @memset(in_comment[ts.ts_node_start_byte(t.node)..ts.ts_node_end_byte(t.node)], true);
            }
        }
        const rows = std.mem.count(u8, self.source, "\n") + 1;
        const code = self.s.code_lines[0..rows];
        @memset(code, false);
        var row: usize = 0;
        for (self.source, in_comment) |c, commented| {
            if (c == '\n') {
                row += 1;
                continue;
            }
            if (!commented and !std.ascii.isWhitespace(c)) code[row] = true;
        }
        if (row + 1 != rows) assert.panic("{s}: marked code on {d} lines of a {d}-line file; codeLines() must advance one row per newline, so check its loop", .{ self.work.facts.path, row + 1, rows });
        if (code.len != rows) assert.panic("{s}: {d} code-line flags for {d} lines; size code_lines from the file's row count, as initCheckScratch() does with file_bytes + 1", .{ self.work.facts.path, code.len, rows });
        return code;
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

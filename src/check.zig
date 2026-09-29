const std = @import("std");
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

pub const Diagnostic = struct {
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    /// How to fix this particular finding; empty means the rule's general advice.
    fix: []const u8 = "",
    /// The change that makes `fix` happen, when zanity can make it.
    edit: ?facts_module.Edit = null,

    pub fn reportOrder(_: void, a: Diagnostic, b: Diagnostic) bool {
        if (a.rule.len == 0) std.debug.panic("a finding at {d}:{d} has no rule name; report() always passes one", .{ a.line + 1, a.column + 1 });
        if (b.rule.len == 0) std.debug.panic("a finding at {d}:{d} has no rule name; report() always passes one", .{ b.line + 1, b.column + 1 });
        if (a.line != b.line) return a.line < b.line;
        if (a.column != b.column) return a.column < b.column;
        return std.mem.order(u8, a.rule, b.rule) == .lt;
    }
};

const Family = enum { statement, function, class, call, loop, assertion, assignment, @"test", definition, control };

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
    in_comment: []bool,
    code_lines: []bool,
    captures: captures.CaptureScratch,

    pub fn initCheckScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!FileScratch {
        if (limits.depth == 0 or limits.per_file == 0) std.debug.panic("memory.Limits.depth is {d} and per_file is {d}; both must be above 0 to check a file", .{ limits.depth, limits.per_file });
        if (limits.file_bytes == 0) std.debug.panic("memory.Limits.file_bytes is 0, so no file could be checked; set it above 0", .{});
        return .{
            .contexts = try .initBounded(gpa, limits.depth, "nested constructs in one file"),
            .opened = try .initBounded(gpa, limits.depth, "nested syntax nodes in one file"),
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
            .in_comment = try gpa.alloc(bool, limits.file_bytes),
            .code_lines = try gpa.alloc(bool, limits.file_bytes + 1),
            .captures = try .initCaptureScratch(gpa, limits),
        };
    }

    pub fn clearFile(self: *FileScratch) void {
        inline for (.{ "contexts", "opened", "diagnostics", "suppressions", "codes", "trail", "calls", "signature", "weak", "locals", "bare_calls", "async_names", "statement_calls" }) |field| {
            @field(self, field).clear();
        }
        if (self.contexts.len != 0) std.debug.panic("clearing the per-file scratch left {d} open constructs", .{self.contexts.len});
        if (self.diagnostics.len != 0) std.debug.panic("clearing the per-file scratch left {d} findings", .{self.diagnostics.len});
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

    fn lookup(c: captures.Compiled) Vocabulary {
        if (c.names.len == 0) std.debug.panic("the query has no captures, so no rule could run; check the language's query files", .{});
        if (c.predicates.len == 0) std.debug.panic("the query has {d} captures but no patterns", .{c.names.len});
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
        };
    }
};

pub const Checker = struct {
    loaded: language.Loaded,
    compiled: captures.Compiled,
    vocabulary: Vocabulary,
    enabled: rules.Set,

    pub fn initChecker(gpa: Allocator, loaded: language.Loaded, requested: rules.Set) !Checker {
        if (requested.len == 0) std.debug.panic("building a {s} checker with no rules requested; runCheck always requests at least one", .{loaded.adapter.name});
        const compiled = try captures.Compiled.initCompiled(gpa, loaded.query);
        var supported: rules.Set = .{};
        for (requested.names()) |name| {
            if (language.applies(loaded.adapter, name)) supported.include(name);
        }
        if (supported.len > requested.len) std.debug.panic("{s} supports {d} of the {d} requested rules; it can't support more than were asked for", .{ loaded.adapter.name, supported.len, requested.len });
        return .{
            .loaded = loaded,
            .compiled = compiled,
            .vocabulary = Vocabulary.lookup(compiled),
            .enabled = supported,
        };
    }

    pub const Result = struct { diagnostics: []Diagnostic, parse_error: bool };

    pub fn check(self: *const Checker, work: Work, source: []const u8) !Result {
        if (source.len >= std.math.maxInt(u32)) std.debug.panic("{s}: {d} bytes is more than tree-sitter can parse; lower memory.Limits.file_bytes below 4 GiB", .{ work.facts.path, source.len });
        if (source.len > work.scratch.in_comment.len) std.debug.panic("{s}: {d} bytes but the scratch has room for {d}; main.zig must reject files over memory.Limits.file_bytes", .{ work.facts.path, source.len, work.scratch.in_comment.len });
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
        if (file.s.contexts.len != 0) std.debug.panic("{s}: the walk ended with {d} constructs still open; every node entered must be left", .{ work.facts.path, file.s.contexts.len });
        if (file.s.opened.len != 0) std.debug.panic("{s}: the walk ended with {d} nodes still open; every node entered must be left", .{ work.facts.path, file.s.opened.len });
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

    pub fn walk(self: *File, root: ts.Node) !void {
        if (self.s.contexts.len != 0) std.debug.panic("{s}: starting a walk with {d} constructs already open; clear the scratch first", .{ self.work.facts.path, self.s.contexts.len });
        if (self.s.opened.len != 0) std.debug.panic("{s}: starting a walk with {d} nodes already open; clear the scratch first", .{ self.work.facts.path, self.s.opened.len });
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
        const found = self.index.of(node);
        const depth = self.s.contexts.len;
        for (found) |t| {
            if (t.id >= self.checker.compiled.names.len) std.debug.panic("{s}: {f} carries capture id {d}, but the query has {d} captures", .{ self.work.facts.path, node.where(), t.id, self.checker.compiled.names.len });
            if (!try self.enterSignal(node, t.id, found)) try self.enterCapture(node, self.checker.compiled.names[t.id]);
        }
        const opened = try self.openFamilies(node, found);
        if (self.s.contexts.len != depth + opened) std.debug.panic("{s}: entering {f} opened {d} constructs but the stack grew from {d} to {d}", .{ self.work.facts.path, node.where(), opened, depth, self.s.contexts.len });
        try self.s.opened.add(opened);
    }

    /// Captures that mark something about the node on their own, such as a decision point or an
    /// error message. Returns whether `id` was one of them.
    pub fn enterSignal(self: *File, node: ts.Node, id: captures.Id, found: []const captures.Triple) !bool {
        if (found.len == 0) std.debug.panic("{s}: {f} carries capture {d} but no captures were found on it", .{ self.work.facts.path, node.where(), id });
        const v = self.v;
        if (v.catch_swallowed == id) {
            _ = try self.report(node, "swallowed-error", try self.say("This error handler does nothing, so the failure disappears silently.", .{}));
            return false;
        }
        if (v.decision_point == id) {
            if (!self.hasOuter(found, .assertion)) if (self.enclosingFunction()) |function| {
                function.decisions += 1;
            };
        } else if (v.async_name == id) {
            try self.s.async_names.add(node.text(self.source));
        } else if (v.statement_call == id) {
            try self.s.statement_calls.add(node);
        } else if (v.error_message == id) {
            if (self.innermost(.assertion) == null) try messages.checkMessage(self, node, null);
        } else return false;
        if (self.s.statement_calls.len > self.s.statement_calls.buffer.len) std.debug.panic("{s}: {d} statement calls in room for {d}", .{ self.work.facts.path, self.s.statement_calls.len, self.s.statement_calls.buffer.len });
        return true;
    }

    /// Captures that fill in part of an open construct: its name, a parameter, a local, a condition.
    pub fn enterCapture(self: *File, node: ts.Node, name: captures.Name) !void {
        if (name.full.len == 0) std.debug.panic("{s}: {f} carries a capture with no name", .{ self.work.facts.path, node.where() });
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
        if (ctx.family != family) std.debug.panic("{s}: {f} was assigned to a {t} while looking for a {t}", .{ self.work.facts.path, node.where(), ctx.family, family });
    }

    /// Opens a construct for each family the node is the outer node of; returns how many.
    pub fn openFamilies(self: *File, node: ts.Node, found: []const captures.Triple) !u8 {
        const before = self.s.contexts.len;
        if (before > self.s.contexts.buffer.len) std.debug.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, before, self.s.contexts.buffer.len });
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
        if (self.s.contexts.len != before + opened) std.debug.panic("{s}: opened {d} constructs at {f} but the stack grew by {d}", .{ self.work.facts.path, opened, node.where(), self.s.contexts.len - before });
        return opened;
    }

    pub fn definitionKind(self: *File, found: []const captures.Triple) ?[]const u8 {
        const names = self.checker.compiled.names;
        if (found.len > self.index.triples.len) std.debug.panic("{s}: {d} captures on one node, more than the {d} in the file", .{ self.work.facts.path, found.len, self.index.triples.len });
        for (found) |t| {
            if (!std.mem.eql(u8, names[t.id].family, "definition")) continue;
            if (names[t.id].part.len == 0) std.debug.panic("capture @{s} has no kind after 'definition.'; write it as @definition.function, @definition.class and so on", .{names[t.id].full});
            return names[t.id].part;
        }
        return null;
    }

    pub fn hasOuter(self: *File, found: []const captures.Triple, family: Family) bool {
        const names = self.checker.compiled.names;
        if (found.len > self.index.triples.len) std.debug.panic("{s}: {d} captures on one node, more than the {d} in the file", .{ self.work.facts.path, found.len, self.index.triples.len });
        for (found) |t| {
            if (t.id >= names.len) std.debug.panic("{s}: capture id {d} is out of range; the query has {d} captures", .{ self.work.facts.path, t.id, names.len });
            if (std.mem.eql(u8, names[t.id].part, "outer") and std.mem.eql(u8, names[t.id].family, @tagName(family))) return true;
        }
        return false;
    }

    pub fn leave(self: *File) !void {
        const opened = self.s.opened.drop() orelse return error.LeftMoreNodesThanEntered;
        if (opened > self.s.contexts.len) std.debug.panic("{s}: leaving a node that opened {d} constructs, but only {d} are open", .{ self.work.facts.path, opened, self.s.contexts.len });
        const remaining = self.s.contexts.len - opened;
        for (0..opened) |_| {
            const ctx = self.s.contexts.drop().?;
            try self.close(ctx);
        }
        if (self.s.contexts.len != remaining) std.debug.panic("{s}: closing constructs left {d} open, expected {d}", .{ self.work.facts.path, self.s.contexts.len, remaining });
    }

    pub fn parameter(self: *File, part: []const u8, node: ts.Node) !void {
        if (part.len == 0) std.debug.panic("{s}: {f} is captured as a parameter with no part; write @parameter.name or @parameter.type", .{ self.work.facts.path, node.where() });
        if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) std.debug.panic("{s}: parameter capture @parameter.{s} matched the empty {f}; capture a named node", .{ self.work.facts.path, part, node.where() });
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
        if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(ctx.node)) std.debug.panic("{s}: @{t}.{s} captured {f}, which starts before its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) std.debug.panic("{s}: @{t}.{s} captured {f}, which ends after its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
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
            ctx.body = true;
        } else if (std.mem.eql(u8, part, "argument")) {
            if (ctx.argument_count < ctx.arguments.len) ctx.arguments[ctx.argument_count] = node;
            ctx.argument_count += 1;
        } else if (std.mem.eql(u8, part, "parameter")) {
            ctx.formal_parameters += 1;
        }
    }

    pub fn refines(self: *File, family: Family, node: ts.Node, found: []const captures.Triple) ?*Context {
        if (found.len == 0) std.debug.panic("{s}: asked whether {f} refines a {t} with no captures on it", .{ self.work.facts.path, node.where(), family });
        for (found) |t| {
            const name = self.checker.compiled.names[t.id];
            if (!std.mem.eql(u8, name.family, @tagName(family))) continue;
            if (std.mem.eql(u8, name.part, "outer") or std.mem.eql(u8, name.part, "passthrough")) continue;
            return null;
        }
        const parent = node.parent() orelse return null;
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const ctx = &items[i];
            if (!ctx.span.eql(parent) and !ctx.node.eql(parent)) return null;
            if (ctx.family != family) continue;
            if (ctx.body) return null;
            if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) std.debug.panic("{s}: {f} refines the {t} {f} but ends after it", .{ self.work.facts.path, node.where(), family, ctx.node.where() });
            return ctx;
        }
        if (i != 0) std.debug.panic("{s}: the search for a {t} to refine stopped at depth {d} without returning", .{ self.work.facts.path, family, i });
        return null;
    }

    pub fn open(self: *File, family: Family, node: ts.Node) !void {
        if (self.s.contexts.last()) |top| {
            if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(top.node)) std.debug.panic("{s}: opening a {t} at {f}, which starts before the enclosing {t} {f}; the walk visits nodes in order", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
            if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(top.node)) std.debug.panic("{s}: opening a {t} at {f}, which ends after the enclosing {t} {f}", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
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
        };
        switch (family) {
            .assertion => if (self.enclosingFunction()) |function| {
                function.asserts += 1;
            },
            .statement => if (node.parent()) |parent| {
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
        if (trail.len > self.s.trail.buffer.len) std.debug.panic("{s}: {d} statement summaries in room for {d}", .{ self.work.facts.path, trail.len, self.s.trail.buffer.len });
        var i = trail.len;
        while (i > 0) {
            i -= 1;
            if (trail[i].parent.id == parent.id and trail[i].parent.start == parent.start) return trail[i].summary;
        }
        if (i != 0) std.debug.panic("{s}: the search for the previous statement stopped at {d} without returning", .{ self.work.facts.path, i });
        return .none;
    }

    pub fn remember(self: *File, ctx: Context) !void {
        const parent = ctx.node.parent() orelse return;
        if (ctx.family != .statement) std.debug.panic("{s}: remembering a {t} ({f}) as the previous statement; only statements are remembered", .{ self.work.facts.path, ctx.family, ctx.node.where() });
        if (ctx.trail_mark > self.s.trail.len) std.debug.panic("{s}: the statement {f} marked {d} summaries, but only {d} remain", .{ self.work.facts.path, ctx.node.where(), ctx.trail_mark, self.s.trail.len });
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
        if (items.len > self.s.contexts.buffer.len) std.debug.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, items.len, self.s.contexts.buffer.len });
        var i = items.len;
        while (i > 0) {
            i -= 1;
            if (items[i].family == family) {
                if (i >= items.len) std.debug.panic("{s}: found a {t} at depth {d} of {d}", .{ self.work.facts.path, family, i, items.len });
                return &items[i];
            }
        }
        return null;
    }

    pub fn enclosingFunction(self: *File) ?*Context {
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            switch (items[i].family) {
                .class => return null,
                .function => if (items[i].name) |name| {
                    if (ts.ts_node_start_byte(name) < ts.ts_node_start_byte(items[i].node)) std.debug.panic("{s}: @function.name captured {f}, before its function {f}; capture the name inside @function.outer", .{ self.work.facts.path, name.where(), items[i].node.where() });
                    if (ts.ts_node_end_byte(name) > ts.ts_node_end_byte(items[i].node)) std.debug.panic("{s}: @function.name captured {f}, after its function {f} ends; capture the name inside @function.outer", .{ self.work.facts.path, name.where(), items[i].node.where() });
                    return &items[i];
                },
                else => {},
            }
        }
        return null;
    }

    pub fn statementOf(self: *File, node: ts.Node) ?*Context {
        const statement = self.innermost(.statement) orelse return null;
        if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(statement.node)) std.debug.panic("{s}: {f} starts before its statement {f}", .{ self.work.facts.path, node.where(), statement.node.where() });
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(statement.node)) std.debug.panic("{s}: {f} ends after its statement {f}", .{ self.work.facts.path, node.where(), statement.node.where() });
        if (statement.node.eql(node)) return statement;
        const parent = node.parent() orelse return null;
        return if (statement.node.eql(parent)) statement else null;
    }

    pub fn close(self: *File, ctx: Context) !void {
        if (ts.ts_node_end_byte(ctx.span) > ts.ts_node_end_byte(ctx.node)) std.debug.panic("{s}: the {t} {f} was widened to {f}, which ends after it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
        if (ts.ts_node_start_byte(ctx.span) < ts.ts_node_start_byte(ctx.node)) std.debug.panic("{s}: the {t} {f} was widened to {f}, which starts before it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
        switch (ctx.family) {
            .call => try self.closeCall(ctx),
            .loop => try self.closeLoop(ctx),
            .assertion => try self.closeAssertion(ctx),
            .assignment => try self.closeAssignment(ctx),
            .function => try self.closeFunction(ctx),
            .statement => try self.remember(ctx),
            .class, .@"test", .control => {},
            .definition => try self.closeDefinition(ctx),
        }
    }

    pub fn closeCall(self: *File, ctx: Context) !void {
        if (ctx.family != .call) std.debug.panic("{s}: closing {f} as a call, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        try self.s.calls.add(.{
            .key = ctx.node.key(),
            .name = ctx.name,
            .receiver = ctx.receiver != null,
            .arguments = ctx.arguments,
            .count = ctx.argument_count,
        });
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (name.len == 0) std.debug.panic("{s}: @call.name matched the empty {f}; capture the callee's identifier", .{ self.work.facts.path, name_node.where() });
        if (contains(self.tables.forbidden_calls, name)) {
            _ = try self.report(ctx.callee orelse name_node, "forbidden-call", try self.say("Calling '{s}' runs code that can't be reviewed or checked before it runs.", .{name}));
        }
        if (self.calleeIn(ctx, name, self.tables.debug_calls)) |matched| {
            _ = try self.report(ctx.callee orelse name_node, "debug-leftover", try self.say("'{s}' is debugging code: wherever it ships it stops the program or dumps its state.", .{matched}));
        }
        const reports_error = self.calleeIn(ctx, name, self.tables.error_calls) != null or (ctx.receiver != null and contains(self.tables.error_methods, name));
        if (reports_error and self.innermost(.assertion) == null) {
            if (ctx.arguments[0]) |message| try messages.checkMessage(self, message, null);
        }
        try hazards.checkRiskyCall(self, ctx, name);
        if (self.inTest()) try self.checkTestCall(ctx, name);
        const allocating = self.calleeIn(ctx, name, self.tables.allocating_calls) orelse (if (contains(self.tables.allocating_calls, name)) name else null);
        if (allocating) |matched| try self.checkAllocation(ctx, matched);
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
        if (ctx.family != .definition) std.debug.panic("{s}: closing {f} as a definition, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.kind.len == 0) std.debug.panic("{s}: the definition {f} has no kind; capture it as @definition.function, @definition.class and so on", .{ self.work.facts.path, ctx.node.where() });
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (std.mem.eql(u8, ctx.kind, "constant") and !std.ascii.isUpper(name[0])) return;
        if (contains(self.tables.protocol_names, name)) return;
        const at = ts.ts_node_start_point(name_node);
        try self.work.facts.define(name, ctx.kind, .{ at.row, at.column });
    }

    pub fn inAssertionCondition(self: *File, node: ts.Node) bool {
        const assertion = self.innermost(.assertion) orelse return false;
        const condition = assertion.condition orelse return false;
        if (ts.ts_node_start_byte(condition) < ts.ts_node_start_byte(assertion.node)) std.debug.panic("{s}: @assertion.condition captured {f}, before its assertion {f}; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
        if (ts.ts_node_end_byte(condition) > ts.ts_node_end_byte(assertion.node)) std.debug.panic("{s}: @assertion.condition captured {f}, after its assertion {f} ends; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
        return ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(condition) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(condition);
    }

    pub fn isTestName(self: *File, name: []const u8) bool {
        if (name.len == 0) std.debug.panic("{s}: asked whether an empty function name is a test name; @function.name matched an empty node", .{self.work.facts.path});
        if (self.tables.test_prefixes.len > 16) std.debug.panic("{s} lists {d} test prefixes in languages/tables.zon; more than 16 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_prefixes.len });
        for (self.tables.test_prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
        return false;
    }

    pub fn inTest(self: *File) bool {
        const items = self.s.contexts.items();
        if (items.len > self.s.contexts.buffer.len) std.debug.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, items.len, self.s.contexts.buffer.len });
        for (items) |ctx| if (ctx.is_test) {
            if (ctx.family != .function and ctx.family != .@"test") std.debug.panic("{s}: the {t} {f} is marked as a test; only functions and test blocks can be", .{ self.work.facts.path, ctx.family, ctx.node.where() });
            return true;
        };
        return false;
    }

    pub fn checkAllocation(self: *File, ctx: Context, callee: []const u8) !void {
        if (ctx.family != .call) std.debug.panic("{s}: checking the allocation in {f}, which is a {t}, not a call", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (callee.len == 0) std.debug.panic("{s}: the allocating call {f} has an empty callee", .{ self.work.facts.path, ctx.node.where() });
        if (self.inTest() or self.inTestFile()) return;
        const function = self.enclosingFunction() orelse return;
        const owner = function.name.?.text(self.source);
        for (self.tables.initializer_prefixes) |prefix| if (std.mem.startsWith(u8, owner, prefix)) return;
        const shown = if (ctx.callee) |c| c.text(self.source) else callee;
        _ = try self.report(ctx.node, "dynamic-allocation", try self.say("'{s}' allocates memory after initialization in '{s}', so memory use depends on input and can fail at any point.", .{ shown, owner }));
    }

    pub fn inTestFile(self: *File) bool {
        const base = std.fs.path.basename(self.work.facts.path);
        if (base.len == 0) std.debug.panic("path '{s}' has no file name, so zanity can't tell whether it holds tests", .{self.work.facts.path});
        for (self.tables.test_file_prefixes) |prefix| if (std.mem.startsWith(u8, base, prefix)) return true;
        for (self.tables.test_file_suffixes) |suffix| if (std.mem.endsWith(u8, base, suffix)) return true;
        if (self.tables.test_file_prefixes.len + self.tables.test_file_suffixes.len > 32) std.debug.panic("{s} lists {d} test file prefixes and {d} suffixes in languages/tables.zon; more than 32 means the table is wrong", .{ self.tables.ecosystem, self.tables.test_file_prefixes.len, self.tables.test_file_suffixes.len });
        return false;
    }

    pub fn calleeIn(self: *File, ctx: Context, name: []const u8, table: []const []const u8) ?[]const u8 {
        if (name.len == 0) std.debug.panic("{s}: looking up the call {f} in a name table with an empty name", .{ self.work.facts.path, ctx.node.where() });
        if (ctx.family != .call) std.debug.panic("{s}: looking up {f} in a call table, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        for (table) |entry| {
            if (entry.len == 0) std.debug.panic("an entry in one of {s}'s name tables is empty; remove it from languages/tables.zon", .{self.tables.ecosystem});
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

    pub fn checkTestCall(self: *File, ctx: Context, name: []const u8) !void {
        if (ctx.family != .call) std.debug.panic("{s}: checking {f} as a test call, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (name.len == 0) std.debug.panic("{s}: the test call {f} has an empty name", .{ self.work.facts.path, ctx.node.where() });
        if (self.calleeIn(ctx, name, self.tables.sleeps)) |callee| {
            _ = try self.report(ctx.node, "sleep-in-test", try self.say("'{s}' makes this test wait on the clock, which slows the suite and hides timing bugs.", .{callee}));
            for (self.s.contexts.items()) |*open_ctx| if (open_ctx.family == .loop) {
                open_ctx.has_sleep = true;
            };
        }
        if (self.calleeIn(ctx, name, self.tables.nondeterministic)) |callee| {
            _ = try self.report(ctx.node, "nondeterministic-test", try self.say("'{s}' returns a different value on every run, so this test can pass or fail by chance.", .{callee}));
        }
        const double = self.calleeIn(ctx, name, self.tables.test_doubles) orelse (if (contains(self.tables.test_doubles, name)) name else null);
        if (double) |callee| {
            _ = try self.report(ctx.node, "test-double", try self.say("'{s}' replaces real behaviour with a stand-in, so the test can pass while the real code is broken.", .{callee}));
        }
    }

    pub fn closeLoop(self: *File, ctx: Context) !void {
        if (ctx.family != .loop) std.debug.panic("{s}: closing {f} as a loop, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.has_sleep) {
            _ = try self.report(ctx.node, "polling-loop", try self.say("This loop polls with a sleep, so the test's speed and outcome depend on timing.", .{}));
        }
        if (ctx.condition != null and ctx.iterable != null) std.debug.panic("{s}: the loop {f} has both @loop.condition and @loop.iterable; a loop is one or the other, so fix its query", .{ self.work.facts.path, ctx.node.where() });
        const unbounded = if (ctx.condition) |c| self.index.marks(c, self.v.literal_true) else ctx.iterable == null;
        if (!unbounded) return;
        _ = try self.report(ctx.node, "unbounded-loop", try self.say("'{s}' has no bound, so it can run forever.", .{header(ctx.node.text(self.source))}));
    }

    pub fn closeAssignment(self: *File, ctx: Context) !void {
        if (ctx.family != .assignment) std.debug.panic("{s}: closing {f} as an assignment, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (self.inAssertionCondition(ctx.node)) {
            _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion assigns a variable, so the program behaves differently when assertions are disabled.", .{}));
        }
        if (self.index.marks(ctx.node, self.v.assignment_compound)) return;
        const lhs = ctx.lhs orelse return;
        const rhs = ctx.rhs orelse return;
        try hazards.checkSecret(self, ctx.node, lhs, rhs);
        if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(rhs)) std.debug.panic("{s}: in the assignment {f}, @assignment.lhs {f} overlaps @assignment.rhs {f}; the query captured the wrong nodes", .{ self.work.facts.path, ctx.node.where(), lhs.where(), rhs.where() });
        const statement = self.statementOf(ctx.node) orelse return;
        statement.summary = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
    }

    pub fn closeAssertion(self: *File, ctx: Context) !void {
        if (ctx.family != .assertion) std.debug.panic("{s}: closing {f} as an assertion, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        if (ctx.message == null) {
            if (try self.report(ctx.node, "assertion-message", try self.say("This assertion has no message, so when it fails nobody will know which invariant broke or with what values.", .{}))) {
                if (ctx.condition) |condition| try rewrite.explainAssertion(self, ctx.node, condition);
            }
        }
        if (ctx.message) |message| try messages.checkMessage(self, message, ctx.condition);
        const condition = ctx.condition orelse return;
        if (ctx.message != null and ts.ts_node_start_byte(condition) > ts.ts_node_start_byte(ctx.message.?)) std.debug.panic("{s}: in the assertion {f}, @assertion.message {f} comes before @assertion.condition {f}; the query captured them the wrong way round", .{ self.work.facts.path, ctx.node.where(), ctx.message.?.where(), condition.where() });
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

    /// Points at what is worth asserting in this function, its inputs and its
    /// result, rather than asking for any assertion that makes up the count.
    pub fn assertionFix(self: *File, ctx: Context, name: []const u8) ![]const u8 {
        if (ctx.family != .function) std.debug.panic("{s}: advising assertions for {f}, which is a {t}, not a function", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        const params = self.s.signature.items()[ctx.parameter_start..][0..ctx.parameter_count];
        const start = self.work.text.used;
        if (params.len == 0) {
            _ = try self.work.text.format("Assert what state '{s}' relies on when it starts and what it guarantees before it returns", .{name});
        } else {
            _ = try self.work.text.format("Assert what '{s}' needs from ", .{name});
            const shown = @min(params.len, 3);
            for (params[0..shown], 0..) |p, i| {
                const separator = if (i == 0) "" else if (i + 1 == shown and shown == params.len) " and " else ", ";
                _ = try self.work.text.format("{s}'{s}'", .{ separator, p.name.text(self.source) });
            }
            if (shown < params.len) _ = try self.work.text.copy(" and the rest");
            _ = try self.work.text.copy(" (a range, a length, how they relate) and what it guarantees before it returns");
        }
        const discounted = self.weakLines(ctx);
        if (discounted > 0) {
            _ = try self.work.text.format("; {d} of its assertions can't fail, so they don't count", .{discounted});
        }
        _ = try self.work.text.copy(". An assertion that can't fail catches nothing.");
        const fix = self.work.text.buffer[start..self.work.text.used];
        if (fix.len <= name.len) std.debug.panic("{s}: the assertion advice for '{s}' came out as '{s}', shorter than the name", .{ self.work.facts.path, name, fix });
        if (!std.mem.endsWith(u8, fix, ".")) std.debug.panic("{s}: the assertion advice for '{s}' does not end with a full stop: '{s}'", .{ self.work.facts.path, name, fix });
        return fix;
    }

    pub fn weakLines(self: *File, ctx: Context) u32 {
        var lines: u32 = 0;
        for (self.s.weak.items()) |w| lines += @intFromBool(w.owner == ctx.serial);
        if (lines > self.s.weak.len) std.debug.panic("{s}: counted {d} weak assertion lines in {f} but only {d} are recorded", .{ self.work.facts.path, lines, ctx.node.where(), self.s.weak.len });
        if (ctx.family != .function) std.debug.panic("{s}: counting weak assertions of {f}, which is a {t}, not a function", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        return lines;
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
        if (i != 0) std.debug.panic("{s}: the search for an enclosing class stopped at depth {d} without returning", .{ self.work.facts.path, i });
        if (!seen_function) std.debug.panic("{s}: asked whether a function is defined in a class while no function is open; call it from a @function.name capture", .{self.work.facts.path});
        return false;
    }

    pub fn resolveBareCalls(self: *File, ctx: Context) !void {
        const caller = ctx.fact orelse return;
        if (ctx.family != .function) std.debug.panic("{s}: resolving the calls of {f}, which is a {t}, not a function", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        const reach: facts_module.Reach = if (self.tables.methods_need_receiver) .functions else .any;
        const locals = self.s.locals.items();
        const calls = self.s.bare_calls.items();
        if (ctx.owned_start > calls.len or ctx.owned_start > locals.len) std.debug.panic("{s}: {f} owns calls and locals from {d}, but only {d} calls and {d} locals are recorded", .{ self.work.facts.path, ctx.node.where(), ctx.owned_start, calls.len, locals.len });
        outer: for (calls[ctx.owned_start..]) |call| {
            if (call.owner != ctx.serial) continue;
            for (locals[ctx.owned_start..]) |local| {
                if (local.owner == ctx.serial and sameText(local.text, call.text)) continue :outer;
            }
            try self.work.facts.call(caller, call.text, reach);
        }
    }

    pub fn closeFunction(self: *File, ctx: Context) !void {
        if (ctx.family != .function) std.debug.panic("{s}: closing {f} as a function, but it is a {t}", .{ self.work.facts.path, ctx.node.where(), ctx.family });
        try self.resolveBareCalls(ctx);
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (name.len == 0) std.debug.panic("{s}: @function.name matched the empty {f}; capture the function's identifier", .{ self.work.facts.path, name_node.where() });
        const first = ts.ts_node_start_point(ctx.span).row;
        const last = ts.ts_node_end_point(ctx.span).row;
        var lines: u32 = 0;
        for (self.code_lines[first .. last + 1]) |is_code| lines += @intFromBool(is_code);
        if (lines >= rules.max_function_lines) {
            _ = try self.report(name_node, "long-function", try self.say("'{s}' has {d} lines of code; functions must have fewer than {d}.", .{ name, lines, rules.max_function_lines }));
        }
        if (ctx.formal_parameters > rules.max_parameters) {
            _ = try self.report(name_node, "long-parameter-list", try self.say("'{s}' takes {d} parameters; functions should take at most {d}.", .{ name, ctx.formal_parameters, rules.max_parameters }));
        }
        if (self.index.marks(ctx.span, self.v.function_passthrough) or self.index.marks(ctx.node, self.v.function_passthrough)) {
            _ = try self.report(name_node, "passthrough-wrapper", try self.say("'{s}' only forwards to another call, so it adds a name without adding behaviour.", .{name}));
        }
        const meaningful = ctx.asserts -| self.weakLines(ctx);
        if (meaningful < rules.min_asserts_per_function) {
            const noun = if (meaningful == 1) "assertion" else "assertions";
            const message = try self.say("'{s}' has {d} {s} that can catch a bug; it needs at least {d}.", .{ name, meaningful, noun, rules.min_asserts_per_function });
            if (try self.report(name_node, "assertion-density", message)) {
                self.s.diagnostics.last().?.fix = try self.assertionFix(ctx, name);
            }
        }
        if (ctx.decisions + 1 > rules.max_complexity) {
            _ = try self.report(name_node, "complex-function", try self.say("'{s}' makes {d} decisions (cyclomatic complexity {d}), past the {d} a reader can follow and a test suite can cover.", .{ name, ctx.decisions, ctx.decisions + 1, rules.max_complexity }));
        }
        if (ctx.has_message and self.work.facts.collect_units) {
            const at = ts.ts_node_start_point(name_node);
            try self.work.facts.unit(name, .{ at.row, at.column, last }, ctx.span.text(self.source));
        }
    }

    pub fn say(self: *File, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const message = try self.work.text.format(fmt, args);
        if (message.len == 0) std.debug.panic("{s}: a finding message came out empty from format '{s}'", .{ self.work.facts.path, fmt });
        if (!(std.ascii.isUpper(message[0]) or message[0] == '\'' or std.mem.startsWith(u8, message, "zanity"))) std.debug.panic("finding messages start with a capital, a quoted name or 'zanity'; this one does not: '{s}'", .{message});
        return message;
    }

    pub fn report(self: *File, node: ts.Node, rule: []const u8, message: []const u8) !bool {
        if (rules.find(rule) == null) std.debug.panic("{s}: reporting rule '{s}', which is not in rules.all; add it there or fix the name", .{ self.work.facts.path, rule });
        if (ts.ts_node_end_byte(node) > self.source.len) std.debug.panic("{s}: reporting {s} on {f}, which ends past the {d}-byte file", .{ self.work.facts.path, rule, node.where(), self.source.len });
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
        if (row + 1 != rows) std.debug.panic("{s}: marked code on {d} lines of a {d}-line file", .{ self.work.facts.path, row + 1, rows });
        if (code.len != rows) std.debug.panic("{s}: {d} code-line flags for {d} lines", .{ self.work.facts.path, code.len, rows });
        return code;
    }

    pub fn finish(self: *File) []Diagnostic {
        if (self.s.contexts.len != 0) std.debug.panic("{s}: finishing with {d} constructs still open; every node entered must be left", .{ self.work.facts.path, self.s.contexts.len });
        const diagnostics = self.s.diagnostics.items();
        std.mem.sort(Diagnostic, diagnostics, {}, Diagnostic.reportOrder);
        if (!std.sort.isSorted(Diagnostic, diagnostics, {}, Diagnostic.reportOrder)) std.debug.panic("expected diagnostics in report order, got {d} diagnostics out of order", .{diagnostics.len});
        return diagnostics;
    }
};

pub fn contains(haystack: []const []const u8, needle: []const u8) bool {
    if (needle.len == 0) std.debug.panic("looked up an empty name in a table of {d} names", .{haystack.len});
    for (haystack) |h| {
        if (h.len == 0) std.debug.panic("a name table holds an empty entry while looking up '{s}'; remove it from languages/tables.zon", .{needle});
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

pub fn sameText(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    for (0..a.len + b.len + 1) |_| {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
        if (i > a.len) std.debug.panic("comparing '{s}' with '{s}' ran past the first at byte {d}", .{ a, b, i });
        if (j > b.len) std.debug.panic("comparing '{s}' with '{s}' ran past the second at byte {d}", .{ a, b, j });
    }
    unreachable;
}

pub fn header(text: []const u8) []const u8 {
    if (text.len == 0) std.debug.panic("asked for the first line of an empty node; the capture matched no text", .{});
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..line_end], " \t\r");
    if (std.mem.indexOf(u8, line, " {")) |brace| {
        const before = line[0..brace];
        if (before.len > 0 and (before[before.len - 1] == ')' or std.ascii.isAlphanumeric(before[before.len - 1]))) line = before;
    }
    const result = std.mem.trimEnd(u8, line, " \t:{}");
    if (result.len > line_end) std.debug.panic("the first line of '{s}' came out longer than the line itself ({d} > {d})", .{ text[0..line_end], result.len, line_end });
    return result;
}

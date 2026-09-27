const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;

pub const Diagnostic = struct {
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    /// How to fix this particular finding; empty means the rule's general advice.
    fix: []const u8 = "",

    pub fn reportOrder(_: void, a: Diagnostic, b: Diagnostic) bool {
        assert(a.rule.len > 0);
        assert(b.rule.len > 0);
        if (a.line != b.line) return a.line < b.line;
        if (a.column != b.column) return a.column < b.column;
        return std.mem.order(u8, a.rule, b.rule) == .lt;
    }
};

const Family = enum { statement, function, class, call, loop, assertion, assignment, @"test", definition };

const Parameter = struct { name: ts.Node, type: ?ts.Node = null };

const Summary = union(enum) {
    none,
    assignment: struct { lhs: ts.Node, rhs: ts.Node },
    assertion: struct { node: ts.Node, condition: ts.Node },
};

const Call = struct {
    key: ts.Node.Key,
    name: ?ts.Node,
    receiver: bool,
    arguments: [2]?ts.Node,
    count: u32,
};

const Context = struct {
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
    kind: []const u8 = "",
    previous: Summary = .none,
    summary: Summary = .none,
};

const Owned = struct { owner: u32, text: []const u8 };
const Weak = struct { owner: u32, line: u32 };
const Trail = struct { parent: ts.Node.Key, summary: Summary };
const Suppression = struct { line: u32, start: usize, len: usize };
const Assertion = struct { function: *Context, node: ts.Node, condition: ts.Node };
const Note = struct { node: ts.Node, rule: []const u8, message: []const u8 };

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
    in_comment: []bool,
    code_lines: []bool,
    captures: captures.CaptureScratch,

    pub fn initCheckScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!FileScratch {
        assert(limits.depth > 0 and limits.per_file > 0);
        assert(limits.file_bytes > 0);
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
            .in_comment = try gpa.alloc(bool, limits.file_bytes),
            .code_lines = try gpa.alloc(bool, limits.file_bytes + 1),
            .captures = try .initCaptureScratch(gpa, limits),
        };
    }

    fn clearFile(self: *FileScratch) void {
        inline for (.{ "contexts", "opened", "diagnostics", "suppressions", "codes", "trail", "calls", "signature", "weak", "locals", "bare_calls" }) |field| {
            @field(self, field).clear();
        }
        assert(self.contexts.len == 0);
        assert(self.diagnostics.len == 0);
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

    fn lookup(c: captures.Compiled) Vocabulary {
        assert(c.names.len > 0);
        assert(c.predicates.len > 0);
        return .{
            .comment = c.id("comment.outer"),
            .literal_true = c.id("literal.true"),
            .literal_constant = c.id("literal.constant"),
            .literal_falsy = c.id("literal.falsy"),
            .literal_none = c.id("literal.none"),
            .literal_collection = c.id("literal.collection"),
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
        };
    }
};

pub const Checker = struct {
    loaded: language.Loaded,
    compiled: captures.Compiled,
    vocabulary: Vocabulary,
    enabled: rules.Set,

    pub fn initChecker(gpa: Allocator, loaded: language.Loaded, requested: rules.Set) !Checker {
        assert(requested.len > 0);
        const compiled = try captures.Compiled.initCompiled(gpa, loaded.query);
        var supported: rules.Set = .{};
        for (requested.names()) |name| {
            if (language.applies(loaded.adapter, name)) supported.include(name);
        }
        assert(supported.len <= requested.len);
        return .{
            .loaded = loaded,
            .compiled = compiled,
            .vocabulary = Vocabulary.lookup(compiled),
            .enabled = supported,
        };
    }

    pub const Result = struct { diagnostics: []Diagnostic, parse_error: bool };

    pub fn check(self: *const Checker, work: Work, source: []const u8) !Result {
        assert(source.len < std.math.maxInt(u32));
        assert(source.len <= work.scratch.in_comment.len);
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
        try file.collectSuppressions();
        file.code_lines = file.codeLines();
        if (ts.ts_node_has_error(root)) {
            _ = try file.report(root, "parse-error", "zanity couldn't fully parse this file, so some findings may be missing.");
        }
        try file.walk(root);
        assert(file.s.contexts.len == 0);
        assert(file.s.opened.len == 0);
        return .{ .diagnostics = file.finish(), .parse_error = ts.ts_node_has_error(root) };
    }
};

const File = struct {
    work: Work,
    s: *FileScratch,
    checker: *const Checker,
    v: Vocabulary,
    tables: *const language.Tables,
    source: []const u8,
    index: captures.Index,
    code_lines: []const bool = &.{},
    serials: u32 = 0,

    fn walk(self: *File, root: ts.Node) !void {
        assert(self.s.contexts.len == 0);
        assert(self.s.opened.len == 0);
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

    fn enter(self: *File, node: ts.Node) !void {
        const found = self.index.of(node);
        const depth = self.s.contexts.len;
        for (found) |t| {
            assert(t.id < self.checker.compiled.names.len);
            if (self.v.catch_swallowed == t.id) {
                _ = try self.report(node, "swallowed-error", try self.say("This error handler does nothing, so the failure disappears silently.", .{}));
            }
            const name = self.checker.compiled.names[t.id];
            if (std.mem.eql(u8, name.full, "name")) {
                if (self.innermost(.definition)) |definition| {
                    if (definition.name == null) definition.name = node;
                }
                continue;
            }
            if (std.mem.eql(u8, name.part, "outer")) continue;
            if (std.mem.eql(u8, name.family, "parameter")) {
                try self.parameter(name.part, node);
                continue;
            }
            if (std.mem.eql(u8, name.family, "local.definition") and (std.mem.eql(u8, name.part, "var") or std.mem.eql(u8, name.part, "parameter"))) {
                if (self.innermost(.function)) |function| try self.s.locals.add(.{ .owner = function.serial, .text = node.text(self.source) });
                if (std.mem.eql(u8, name.part, "parameter")) try self.parameter("name", node);
                continue;
            }
            const family = std.meta.stringToEnum(Family, name.family) orelse continue;
            const ctx = self.innermost(family) orelse continue;
            try self.assign(ctx, name.part, node);
        }
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
        assert(self.s.contexts.len == depth + opened);
        try self.s.opened.add(opened);
    }

    fn definitionKind(self: *File, found: []const captures.Triple) ?[]const u8 {
        const names = self.checker.compiled.names;
        assert(found.len <= self.index.triples.len);
        for (found) |t| {
            if (!std.mem.eql(u8, names[t.id].family, "definition")) continue;
            assert(names[t.id].part.len > 0);
            return names[t.id].part;
        }
        return null;
    }

    fn hasOuter(self: *File, found: []const captures.Triple, family: Family) bool {
        const names = self.checker.compiled.names;
        assert(found.len <= self.index.triples.len);
        for (found) |t| {
            assert(t.id < names.len);
            if (std.mem.eql(u8, names[t.id].part, "outer") and std.mem.eql(u8, names[t.id].family, @tagName(family))) return true;
        }
        return false;
    }

    fn leave(self: *File) !void {
        const opened = self.s.opened.drop() orelse return error.LeftMoreNodesThanEntered;
        assert(opened <= self.s.contexts.len);
        const remaining = self.s.contexts.len - opened;
        for (0..opened) |_| {
            const ctx = self.s.contexts.drop().?;
            try self.close(ctx);
        }
        assert(self.s.contexts.len == remaining);
    }

    fn parameter(self: *File, part: []const u8, node: ts.Node) !void {
        assert(part.len > 0);
        assert(ts.ts_node_end_byte(node) > ts.ts_node_start_byte(node));
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

    fn assign(self: *File, ctx: *Context, part: []const u8, node: ts.Node) !void {
        assert(ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(ctx.node));
        assert(ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(ctx.node));
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

    fn refines(self: *File, family: Family, node: ts.Node, found: []const captures.Triple) ?*Context {
        assert(found.len > 0);
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
            assert(ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(ctx.node));
            return ctx;
        }
        assert(i == 0);
        return null;
    }

    fn open(self: *File, family: Family, node: ts.Node) !void {
        if (self.s.contexts.last()) |top| {
            assert(ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(top.node));
            assert(ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(top.node));
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
            else => {},
        }
        try self.s.contexts.add(ctx);
    }

    fn trailFor(self: *File, parent: ts.Node.Key) Summary {
        const trail = self.s.trail.items();
        assert(trail.len <= self.s.trail.buffer.len);
        var i = trail.len;
        while (i > 0) {
            i -= 1;
            if (trail[i].parent.id == parent.id and trail[i].parent.start == parent.start) return trail[i].summary;
        }
        assert(i == 0);
        return .none;
    }

    fn remember(self: *File, ctx: Context) !void {
        const parent = ctx.node.parent() orelse return;
        assert(ctx.family == .statement);
        assert(ctx.trail_mark <= self.s.trail.len);
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

    fn innermost(self: *File, family: Family) ?*Context {
        const items = self.s.contexts.items();
        assert(items.len <= self.s.contexts.buffer.len);
        var i = items.len;
        while (i > 0) {
            i -= 1;
            if (items[i].family == family) {
                assert(i < items.len);
                return &items[i];
            }
        }
        return null;
    }

    fn enclosingFunction(self: *File) ?*Context {
        const items = self.s.contexts.items();
        var i = items.len;
        while (i > 0) {
            i -= 1;
            switch (items[i].family) {
                .class => return null,
                .function => if (items[i].name) |name| {
                    assert(ts.ts_node_start_byte(name) >= ts.ts_node_start_byte(items[i].node));
                    assert(ts.ts_node_end_byte(name) <= ts.ts_node_end_byte(items[i].node));
                    return &items[i];
                },
                else => {},
            }
        }
        return null;
    }

    fn statementOf(self: *File, node: ts.Node) ?*Context {
        const statement = self.innermost(.statement) orelse return null;
        assert(ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(statement.node));
        assert(ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(statement.node));
        if (statement.node.eql(node)) return statement;
        const parent = node.parent() orelse return null;
        return if (statement.node.eql(parent)) statement else null;
    }

    fn close(self: *File, ctx: Context) !void {
        assert(ts.ts_node_end_byte(ctx.span) <= ts.ts_node_end_byte(ctx.node));
        assert(ts.ts_node_start_byte(ctx.span) >= ts.ts_node_start_byte(ctx.node));
        switch (ctx.family) {
            .call => try self.closeCall(ctx),
            .loop => try self.closeLoop(ctx),
            .assertion => try self.closeAssertion(ctx),
            .assignment => try self.closeAssignment(ctx),
            .function => try self.closeFunction(ctx),
            .statement => try self.remember(ctx),
            .class, .@"test" => {},
            .definition => try self.closeDefinition(ctx),
        }
    }

    fn closeCall(self: *File, ctx: Context) !void {
        assert(ctx.family == .call);
        try self.s.calls.add(.{
            .key = ctx.node.key(),
            .name = ctx.name,
            .receiver = ctx.receiver != null,
            .arguments = ctx.arguments,
            .count = ctx.argument_count,
        });
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        assert(name.len > 0);
        if (contains(self.tables.forbidden_calls, name)) {
            _ = try self.report(ctx.callee orelse name_node, "forbidden-call", try self.say("Calling '{s}' runs code that can't be reviewed or checked before it runs.", .{name}));
        }
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

    fn closeDefinition(self: *File, ctx: Context) !void {
        assert(ctx.family == .definition);
        assert(ctx.kind.len > 0);
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        if (std.mem.eql(u8, ctx.kind, "constant") and !std.ascii.isUpper(name[0])) return;
        const at = ts.ts_node_start_point(name_node);
        try self.work.facts.define(name, ctx.kind, .{ at.row, at.column });
    }

    fn inAssertionCondition(self: *File, node: ts.Node) bool {
        const assertion = self.innermost(.assertion) orelse return false;
        const condition = assertion.condition orelse return false;
        assert(ts.ts_node_start_byte(condition) >= ts.ts_node_start_byte(assertion.node));
        assert(ts.ts_node_end_byte(condition) <= ts.ts_node_end_byte(assertion.node));
        return ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(condition) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(condition);
    }

    fn isTestName(self: *File, name: []const u8) bool {
        assert(name.len > 0);
        assert(self.tables.test_prefixes.len <= 16);
        for (self.tables.test_prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
        return false;
    }

    fn inTest(self: *File) bool {
        const items = self.s.contexts.items();
        assert(items.len <= self.s.contexts.buffer.len);
        for (items) |ctx| if (ctx.is_test) {
            assert(ctx.family == .function or ctx.family == .@"test");
            return true;
        };
        return false;
    }

    fn checkAllocation(self: *File, ctx: Context, callee: []const u8) !void {
        assert(ctx.family == .call);
        assert(callee.len > 0);
        if (self.inTest() or self.inTestFile()) return;
        const function = self.enclosingFunction() orelse return;
        const owner = function.name.?.text(self.source);
        for (self.tables.initializer_prefixes) |prefix| if (std.mem.startsWith(u8, owner, prefix)) return;
        const shown = if (ctx.callee) |c| c.text(self.source) else callee;
        _ = try self.report(ctx.node, "dynamic-allocation", try self.say("'{s}' allocates memory after initialization in '{s}', so memory use depends on input and can fail at any point.", .{ shown, owner }));
    }

    fn inTestFile(self: *File) bool {
        const base = std.fs.path.basename(self.work.facts.path);
        assert(base.len > 0);
        for (self.tables.test_file_prefixes) |prefix| if (std.mem.startsWith(u8, base, prefix)) return true;
        for (self.tables.test_file_suffixes) |suffix| if (std.mem.endsWith(u8, base, suffix)) return true;
        assert(self.tables.test_file_prefixes.len + self.tables.test_file_suffixes.len <= 32);
        return false;
    }

    fn calleeIn(self: *File, ctx: Context, name: []const u8, table: []const []const u8) ?[]const u8 {
        assert(name.len > 0);
        assert(ctx.family == .call);
        for (table) |entry| {
            assert(entry.len > 0);
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

    fn checkTestCall(self: *File, ctx: Context, name: []const u8) !void {
        assert(ctx.family == .call);
        assert(name.len > 0);
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

    fn closeLoop(self: *File, ctx: Context) !void {
        assert(ctx.family == .loop);
        if (ctx.has_sleep) {
            _ = try self.report(ctx.node, "polling-loop", try self.say("This loop polls with a sleep, so the test's speed and outcome depend on timing.", .{}));
        }
        assert(ctx.condition == null or ctx.iterable == null);
        const unbounded = if (ctx.condition) |c| self.index.marks(c, self.v.literal_true) else ctx.iterable == null;
        if (!unbounded) return;
        _ = try self.report(ctx.node, "unbounded-loop", try self.say("'{s}' has no bound, so it can run forever.", .{header(ctx.node.text(self.source))}));
    }

    fn closeAssignment(self: *File, ctx: Context) !void {
        assert(ctx.family == .assignment);
        if (self.inAssertionCondition(ctx.node)) {
            _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion assigns a variable, so the program behaves differently when assertions are disabled.", .{}));
        }
        if (self.index.marks(ctx.node, self.v.assignment_compound)) return;
        const lhs = ctx.lhs orelse return;
        const rhs = ctx.rhs orelse return;
        assert(ts.ts_node_end_byte(lhs) <= ts.ts_node_start_byte(rhs));
        const statement = self.statementOf(ctx.node) orelse return;
        statement.summary = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
    }

    fn closeAssertion(self: *File, ctx: Context) !void {
        assert(ctx.family == .assertion);
        if (ctx.message == null) {
            _ = try self.report(ctx.node, "assertion-message", try self.say("This assertion has no message, so when it fails nobody will know which invariant broke.", .{}));
        }
        const condition = ctx.condition orelse return;
        assert(ctx.message == null or ts.ts_node_start_byte(condition) <= ts.ts_node_start_byte(ctx.message.?));
        const function = self.enclosingFunction() orelse return;
        try self.restatedType(function, ctx.node, condition);
        const statement = self.statementOf(ctx.node) orelse return;
        statement.summary = .{ .assertion = .{ .node = ctx.node, .condition = condition } };
        const here: Assertion = .{ .function = function, .node = ctx.node, .condition = condition };
        switch (statement.previous) {
            .assignment => |previous| try self.afterAssignment(here, previous.lhs, previous.rhs),
            .assertion => |previous| try self.afterAssertion(here, previous.node, previous.condition),
            .none => {},
        }
    }

    fn restatedType(self: *File, function: *Context, node: ts.Node, condition: ts.Node) !void {
        assert(function.family == .function);
        assert(ts.ts_node_start_byte(condition) >= ts.ts_node_start_byte(node));
        const call = self.typeCheck(condition) orelse return;
        const subject = call.arguments[0].?.text(self.source);
        const type_text = call.arguments[1].?.text(self.source);
        const params = self.s.signature.items()[function.parameter_start..][0..function.parameter_count];
        for (params) |p| {
            if (!std.mem.eql(u8, p.name.text(self.source), subject)) continue;
            const annotation = p.type orelse return;
            if (!self.annotationIs(annotation.text(self.source), type_text)) return;
            try self.weak(function, .{ .node = node, .rule = "restated-type", .message = try self.say("This assertion only repeats that '{s}' is a {s}, which its annotation already guarantees.", .{ subject, type_text }) });
            return;
        }
    }

    fn annotationIs(self: *File, annotation: []const u8, type_text: []const u8) bool {
        assert(annotation.len > 0);
        assert(type_text.len > 0);
        var matched = false;
        var depth: usize = 0;
        var start: usize = 0;
        for (0..annotation.len + 1) |i| {
            if (i < annotation.len) {
                switch (annotation[i]) {
                    '[', '(', '{' => depth += 1,
                    ']', ')', '}' => depth -|= 1,
                    else => {},
                }
                if (annotation[i] != '|' or depth != 0) continue;
            }
            const part = std.mem.trim(u8, annotation[start..i], " \t");
            start = i + 1;
            if (contains(self.tables.null_types, part)) continue;
            if (matched or !sameText(part, type_text)) return false;
            matched = true;
        }
        return matched;
    }

    fn callFor(self: *File, node: ts.Node) ?Call {
        const key = node.key();
        const calls = self.s.calls.items();
        assert(calls.len <= self.s.calls.buffer.len);
        var i = calls.len;
        while (i > 0) {
            i -= 1;
            if (calls[i].key.id == key.id and calls[i].key.start == key.start) return calls[i];
        }
        assert(i == 0);
        return null;
    }

    fn typeCheck(self: *File, node: ts.Node) ?Call {
        const call = self.callFor(node) orelse return null;
        const name = call.name orelse return null;
        if (call.receiver or call.count != 2) return null;
        if (!contains(self.tables.type_checks, name.text(self.source))) return null;
        assert(call.arguments[0] != null and call.arguments[1] != null);
        assert(ts.ts_node_end_byte(call.arguments[0].?) <= ts.ts_node_start_byte(call.arguments[1].?));
        return call;
    }

    fn plainCall(self: *File, node: ts.Node, table: []const []const u8) ?[]const u8 {
        const call = self.callFor(node) orelse return null;
        const name = call.name orelse return null;
        if (call.receiver) return null;
        const text = name.text(self.source);
        assert(text.len > 0);
        assert(ts.ts_node_start_byte(name) >= ts.ts_node_start_byte(node));
        return if (contains(table, text)) text else null;
    }

    fn afterAssignment(self: *File, here: Assertion, lhs: ts.Node, rhs: ts.Node) !void {
        const function = here.function;
        const node = here.node;
        const condition = here.condition;
        assert(ts.ts_node_end_byte(rhs) <= ts.ts_node_start_byte(node));
        assert(ts.ts_node_end_byte(lhs) <= ts.ts_node_start_byte(rhs));
        const target = lhs.text(self.source);
        if (self.isLiteral(rhs) and self.alwaysHolds(condition, target, rhs)) {
            try self.weak(function, .{ .node = node, .rule = "constant-assertion", .message = try self.say("This assertion can never fail: '{s}' was just set to a constant.", .{target}) });
        }
        const total = self.index.marks(rhs, self.v.string_format) or self.plainCall(rhs, self.tables.total_conversions) != null;
        if (total and self.isPath(condition, target)) {
            try self.weak(function, .{ .node = node, .rule = "conversion-assertion", .message = try self.say("'{s}' comes from a conversion that always produces a value, so this assertion can't catch a bug.", .{target}) });
        }
        if (self.plainCall(rhs, self.tables.length_calls)) |length| {
            if (self.index.marks(condition, self.v.compare_non_negative) and self.subjectIs(condition, target)) {
                try self.weak(function, .{ .node = node, .rule = "guaranteed-length", .message = try self.say("'{s}' comes from {s}(), which is never negative, so this can't fail.", .{ target, length }) });
            }
        }
    }

    fn afterAssertion(self: *File, here: Assertion, previous: ts.Node, previous_condition: ts.Node) !void {
        const function = here.function;
        const condition = here.condition;
        assert(ts.ts_node_end_byte(previous) <= ts.ts_node_start_byte(condition));
        assert(ts.ts_node_start_byte(previous_condition) >= ts.ts_node_start_byte(previous));
        if (!self.index.marks(previous_condition, self.v.compare_not_null)) return;
        const subject = self.childWith(previous_condition, self.v.compare_subject) orelse return;
        const call = self.typeCheck(condition) orelse return;
        if (!sameText(call.arguments[0].?.text(self.source), subject.text(self.source))) return;
        const null_name = if (self.tables.null_types.len > 0) self.tables.null_types[0] else "missing";
        try self.weak(function, .{ .node = previous, .rule = "redundant-null-check", .message = try self.say("Checking that '{s}' is not {s} is redundant: the {s} on the next line already rules it out.", .{ subject.text(self.source), null_name, call.name.?.text(self.source) }) });
    }

    fn isPath(self: *File, node: ts.Node, target: []const u8) bool {
        assert(target.len > 0);
        assert(ts.ts_node_end_byte(node) <= self.source.len);
        return self.index.marks(node, self.v.expression_path) and sameText(node.text(self.source), target);
    }

    fn isLiteral(self: *File, node: ts.Node) bool {
        assert(ts.ts_node_end_byte(node) <= self.source.len);
        assert(ts.ts_node_start_byte(node) <= ts.ts_node_end_byte(node));
        if (self.index.marks(node, self.v.literal_collection)) return true;
        if (self.index.marks(node, self.v.literal_constant) and !self.index.marks(node, self.v.string_format)) return true;
        return self.plainCall(node, self.tables.constant_constructors) != null;
    }

    fn alwaysHolds(self: *File, condition: ts.Node, target: []const u8, value: ts.Node) bool {
        assert(target.len > 0);
        assert(ts.ts_node_end_byte(value) <= ts.ts_node_start_byte(condition));
        if (self.isPath(condition, target)) {
            return self.index.marks(value, self.v.literal_constant) and
                !self.index.marks(value, self.v.literal_falsy) and
                !self.index.marks(value, self.v.string_format);
        }
        if (self.index.marks(condition, self.v.compare_not_null) and self.subjectIs(condition, target)) {
            return !self.index.marks(value, self.v.literal_none);
        }
        if (self.index.marks(condition, self.v.compare_equal) and self.subjectIs(condition, target)) {
            const compared = self.childWith(condition, self.v.compare_value) orelse return false;
            return sameText(compared.text(self.source), value.text(self.source));
        }
        return false;
    }

    fn subjectIs(self: *File, condition: ts.Node, target: []const u8) bool {
        assert(target.len > 0);
        const subject = self.childWith(condition, self.v.compare_subject) orelse return false;
        assert(ts.ts_node_start_byte(subject) >= ts.ts_node_start_byte(condition));
        return sameText(subject.text(self.source), target);
    }

    fn childWith(self: *File, node: ts.Node, capture: ?captures.Id) ?ts.Node {
        const count = ts.ts_node_named_child_count(node);
        assert(count <= ts.ts_node_descendant_count(node));
        for (0..count) |i| {
            const child = ts.ts_node_named_child(node, @intCast(i));
            if (self.index.marks(child, capture)) {
                assert(ts.ts_node_end_byte(child) <= ts.ts_node_end_byte(node));
                return child;
            }
        }
        return null;
    }

    fn weak(self: *File, function: *Context, finding: Note) !void {
        assert(function.family == .function);
        assert(ts.ts_node_start_byte(finding.node) >= ts.ts_node_start_byte(function.node));
        if (!try self.report(finding.node, finding.rule, finding.message)) return;
        const line = ts.ts_node_start_point(finding.node).row;
        for (self.s.weak.items()) |w| if (w.owner == function.serial and w.line == line) return;
        try self.s.weak.add(.{ .owner = function.serial, .line = line });
    }

    /// Points at what is worth asserting in this function, its inputs and its
    /// result, rather than asking for any assertion that makes up the count.
    fn assertionFix(self: *File, ctx: Context, name: []const u8) ![]const u8 {
        assert(ctx.family == .function);
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
        assert(fix.len > name.len);
        assert(std.mem.endsWith(u8, fix, "."));
        return fix;
    }

    fn weakLines(self: *File, ctx: Context) u32 {
        var lines: u32 = 0;
        for (self.s.weak.items()) |w| lines += @intFromBool(w.owner == ctx.serial);
        assert(lines <= self.s.weak.len);
        assert(ctx.family == .function);
        return lines;
    }

    fn definedInClass(self: *File) bool {
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
        assert(i == 0);
        assert(seen_function);
        return false;
    }

    fn resolveBareCalls(self: *File, ctx: Context) !void {
        const caller = ctx.fact orelse return;
        assert(ctx.family == .function);
        const reach: facts_module.Reach = if (self.tables.methods_need_receiver) .functions else .any;
        const locals = self.s.locals.items();
        const calls = self.s.bare_calls.items();
        assert(ctx.owned_start <= calls.len and ctx.owned_start <= locals.len);
        outer: for (calls[ctx.owned_start..]) |call| {
            if (call.owner != ctx.serial) continue;
            for (locals[ctx.owned_start..]) |local| {
                if (local.owner == ctx.serial and sameText(local.text, call.text)) continue :outer;
            }
            try self.work.facts.call(caller, call.text, reach);
        }
    }

    fn closeFunction(self: *File, ctx: Context) !void {
        assert(ctx.family == .function);
        try self.resolveBareCalls(ctx);
        const name_node = ctx.name orelse return;
        const name = name_node.text(self.source);
        assert(name.len > 0);
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
    }

    fn say(self: *File, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const message = try self.work.text.format(fmt, args);
        assert(message.len > 0);
        assert(std.ascii.isUpper(message[0]) or message[0] == '\'' or std.mem.startsWith(u8, message, "zanity"));
        return message;
    }

    fn report(self: *File, node: ts.Node, rule: []const u8, message: []const u8) !bool {
        assert(rules.find(rule) != null);
        assert(ts.ts_node_end_byte(node) <= self.source.len);
        if (!self.checker.enabled.enabled(rule)) return false;
        const start = ts.ts_node_start_point(node);
        if (self.suppressed(start.row, rule)) return false;
        try self.s.diagnostics.add(.{
            .line = start.row,
            .column = start.column,
            .rule = rule,
            .message = message,
        });
        return true;
    }

    fn codeLines(self: *File) []const bool {
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
        assert(row + 1 == rows);
        assert(code.len == rows);
        return code;
    }

    fn collectSuppressions(self: *File) !void {
        assert(self.s.suppressions.len == 0);
        const comment = self.v.comment orelse return;
        for (self.index.triples) |t| {
            if (t.id != comment) continue;
            const start = self.s.codes.len;
            if (!try parseIgnore(&self.s.codes, t.node.text(self.source))) continue;
            try self.s.suppressions.add(.{ .line = ts.ts_node_start_point(t.node).row, .start = start, .len = self.s.codes.len - start });
        }
        assert(self.s.suppressions.len <= self.index.triples.len);
    }

    fn suppressed(self: *File, line: u32, rule: []const u8) bool {
        const found = rules.find(rule) orelse unreachable;
        assert(found.answers(rule));
        assert(line <= std.mem.count(u8, self.source, "\n"));
        for (self.s.suppressions.items()) |s| {
            if (s.line != line) continue;
            if (s.len == 0) return true;
            for (self.s.codes.items()[s.start..][0..s.len]) |code| if (found.answers(code)) return true;
        }
        return false;
    }

    fn finish(self: *File) []Diagnostic {
        assert(self.s.contexts.len == 0);
        const diagnostics = self.s.diagnostics.items();
        std.mem.sort(Diagnostic, diagnostics, {}, Diagnostic.reportOrder);
        assert(std.sort.isSorted(Diagnostic, diagnostics, {}, Diagnostic.reportOrder));
        return diagnostics;
    }
};

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    assert(needle.len > 0);
    for (haystack) |h| {
        assert(h.len > 0);
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

fn sameText(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    for (0..a.len + b.len + 1) |_| {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
        assert(i <= a.len);
        assert(j <= b.len);
    }
    unreachable;
}

fn header(text: []const u8) []const u8 {
    assert(text.len > 0);
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trim(u8, text[0..line_end], " \t\r");
    const result = std.mem.trimEnd(u8, line, " \t:{}");
    assert(result.len <= line_end);
    return result;
}

fn parseIgnore(codes: *memory.Bounded([]const u8), comment: []const u8) !bool {
    assert(comment.len > 0);
    var i: usize = 0;
    while (i < comment.len) : (i += 1) {
        if (!std.ascii.startsWithIgnoreCase(comment[i..], "nasa:")) continue;
        const before = std.mem.trimEnd(u8, comment[0..i], " \t");
        if (before.len > 0 and std.ascii.isAlphanumeric(before[before.len - 1])) continue;
        var j = i + 5;
        while (j < comment.len and std.ascii.isWhitespace(comment[j])) j += 1;
        if (!std.ascii.startsWithIgnoreCase(comment[j..], "ignore")) continue;
        j += 6;
        if (j < comment.len and (std.ascii.isAlphanumeric(comment[j]) or comment[j] == '_')) continue;
        while (j < comment.len and std.ascii.isWhitespace(comment[j])) j += 1;
        if (j >= comment.len or comment[j] != '[') return true;
        const close = std.mem.indexOfScalarPos(u8, comment, j, ']') orelse return true;
        var it = std.mem.splitScalar(u8, comment[j + 1 .. close], ',');
        while (it.next()) |raw| {
            const code = std.mem.trim(u8, raw, " \t");
            if (code.len > 0) try codes.add(code);
        }
        assert(close > j);
        return true;
    }
    return false;
}

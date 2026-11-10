//! The records the walk keeps while it checks one file: each construct open around it, the calls,
//! parameters and assertions it has seen, and the findings it reports.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const facts_module = @import("facts.zig");

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

pub const Family = captures.Family;

pub const Parameter = struct { name: ts.Node, type: ?ts.Node = null };

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
pub const Weak = struct { owner: u32, line: u32 };
pub const Trail = struct { parent: ts.Node.Key, summary: Summary };
pub const Suppression = struct { line: u32, start: usize, len: usize };
pub const Assertion = struct { function: *Context, node: ts.Node, condition: ts.Node };
pub const Note = struct { node: ts.Node, rule: []const u8, message: []const u8 };

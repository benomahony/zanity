const std = @import("std");
const assert = std.debug.assert;

pub const Severity = enum {
    @"error",
    warning,
    information,
};

pub const Rule = struct {
    name: []const u8,
    alias: []const u8 = "",
    advice: []const u8,
    severity: Severity,
    default: bool,
    needs: []const []const u8 = &.{},

    pub fn answers(rule: Rule, code: []const u8) bool {
        assert(rule.name.len > 0);
        assert(code.len > 0);
        return std.mem.eql(u8, rule.name, code) or (rule.alias.len > 0 and std.mem.eql(u8, rule.alias, code));
    }
};

pub const all = [_]Rule{
    .{ .name = "parse-error", .advice = "Fix the syntax error, or report the construct if the code is valid.", .severity = .warning, .default = true },
    .{ .name = "forbidden-call", .alias = "NASA01-A", .advice = "Call the code you need directly.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name" } },
    .{ .name = "recursion", .alias = "NASA01-B", .advice = "Rewrite it as a loop with a fixed bound.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "call.receiver", "function.outer", "function.name" } },
    .{ .name = "unbounded-loop", .alias = "NASA02", .advice = "Loop over a collection or cap the number of iterations.", .severity = .warning, .default = true, .needs = &.{ "loop.outer", "loop.condition", "loop.iterable", "literal.true" } },
    .{ .name = "long-function", .alias = "NASA04", .advice = "Move a self-contained step into its own function.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "assertion-density", .alias = "NASA05", .advice = "Assert conditions a bug could actually break: what it needs from its inputs and what it guarantees about its result.", .severity = .@"error", .default = true, .needs = &.{ "function.outer", "function.name", "assertion.outer" } },
    .{ .name = "assertion-message", .alias = "NASA05-A", .advice = "Add a message stating what must be true.", .severity = .warning, .default = true, .needs = &.{ "assertion.outer", "assertion.message" } },
    .{ .name = "dynamic-allocation", .advice = "Allocate what it needs up front in an init function and reuse it.", .severity = .@"error", .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "assertion-side-effect", .advice = "Do the work before the assertion and assert on its result.", .severity = .@"error", .default = true, .needs = &.{ "assertion.outer", "assertion.condition", "call.name" } },
    .{ .name = "long-parameter-list", .advice = "Group related parameters into a struct or split the function.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name", "function.parameter" } },
    .{ .name = "passthrough-wrapper", .advice = "Call the target directly, or give the wrapper work of its own.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name", "function.passthrough" } },
    .{ .name = "swallowed-error", .advice = "Handle the error, log it with context, or let it propagate.", .severity = .warning, .default = true, .needs = &.{"catch.swallowed"} },
    .{ .name = "sleep-in-test", .alias = "FST001", .advice = "Wait for the event itself, or use a fake clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "polling-loop", .alias = "FST002", .advice = "Wait on an event or callback, or inject a clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "loop.outer", "function.name" } },
    .{ .name = "nondeterministic-test", .advice = "Inject a seeded generator or a fixed value.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "test-double", .alias = "BHV001", .advice = "Use the real object, or a fake that behaves like it.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "name-drift", .alias = "drift", .advice = "Pick one spelling and use it everywhere.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "duplicate-name", .alias = "duplicate", .advice = "Give each a name that says how it differs.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "restated-type", .alias = "NASA05-M1", .advice = "Assert something about its value instead.", .severity = .warning, .default = false, .needs = &.{ "assertion.condition", "call.argument", "parameter.name", "parameter.type" } },
    .{ .name = "constant-assertion", .alias = "NASA05-M2", .advice = "Assert something that depends on the input.", .severity = .@"error", .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "literal.constant", "expression.path", "compare.not_null", "compare.equal" } },
    .{ .name = "redundant-null-check", .alias = "NASA05-M3", .advice = "Remove this check.", .severity = .warning, .default = false, .needs = &.{ "statement.outer", "compare.not_null", "compare.subject", "call.argument" } },
    .{ .name = "conversion-assertion", .alias = "NASA05-M4", .advice = "Assert the property you need it to have.", .severity = .information, .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "string.format", "expression.path" } },
    .{ .name = "guaranteed-length", .alias = "NASA05-M5", .advice = "Assert the length you actually require.", .severity = .information, .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "compare.non_negative", "compare.subject" } },
};

pub fn find(code: []const u8) ?Rule {
    assert(code.len > 0);
    assert(all.len > 0);
    for (all) |r| if (r.answers(code)) return r;
    return null;
}

pub const max_needs = 8;

pub fn missing(rule: Rule, has: anytype, out: *[max_needs][]const u8) []const []const u8 {
    assert(rule.name.len > 0);
    assert(rule.needs.len <= max_needs);
    var count: usize = 0;
    for (rule.needs) |capture| {
        if (has.has(capture)) continue;
        out[count] = capture;
        count += 1;
    }
    return out[0..count];
}

pub const Set = struct {
    buffer: [all.len][]const u8 = undefined,
    len: usize = 0,

    pub fn defaults() Set {
        var set: Set = .{};
        for (all) |r| if (r.default) set.include(r.name);
        assert(set.len > 0);
        assert(set.len <= all.len);
        return set;
    }

    pub fn include(self: *Set, name: []const u8) void {
        assert(find(name) != null);
        if (self.enabled(name)) return;
        assert(self.len < all.len);
        self.buffer[self.len] = name;
        self.len += 1;
    }

    pub fn names(self: *const Set) []const []const u8 {
        assert(self.len <= all.len);
        assert(self.len == 0 or self.buffer[0].len > 0);
        return self.buffer[0..self.len];
    }

    pub fn enabled(self: *const Set, name: []const u8) bool {
        assert(name.len > 0);
        assert(self.len <= all.len);
        for (self.buffer[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

pub const max_function_lines = 60;
pub const min_asserts_per_function = 2;
pub const max_parameters = 4;

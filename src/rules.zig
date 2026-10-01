const std = @import("std");

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
    /// Entries of the engineering error catalogue (catalogue/catalogue.json) this rule detects.
    catalogue: []const []const u8 = &.{},
    /// The message for findings a query captures as `@finding.<name>`; `$code` is the code's first line.
    pattern: []const u8 = "",
    /// The question `check --infer` asks a model about each function, for what no deterministic check can decide.
    question: []const u8 = "",
    /// How a finding from `question` describes the function, after its name.
    judgement: []const u8 = "",

    pub fn answers(rule: Rule, code: []const u8) bool {
        if (rule.name.len == 0) std.debug.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
        if (code.len == 0) std.debug.panic("asked whether rule {s} answers to an empty code; pass a rule name or alias", .{rule.name});
        return std.mem.eql(u8, rule.name, code) or (rule.alias.len > 0 and std.mem.eql(u8, rule.alias, code));
    }
};

pub const all = [_]Rule{
    .{ .name = "parse-error", .advice = "Fix the syntax error, or report the construct if the code is valid.", .severity = .warning, .default = true, .catalogue = &.{"EXT-BUILD-001"} },
    .{ .name = "forbidden-call", .alias = "NASA01-A", .advice = "Call the code you need directly.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name" }, .catalogue = &.{"CWE-94"} },
    .{ .name = "recursion", .alias = "NASA01-B", .advice = "Rewrite it as a loop with a fixed bound.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "call.receiver", "function.outer", "function.name" }, .catalogue = &.{"CWE-674"} },
    .{ .name = "unbounded-loop", .alias = "NASA02", .advice = "Loop over a collection or cap the number of iterations.", .severity = .warning, .default = true, .needs = &.{ "loop.outer", "loop.condition", "loop.iterable", "literal.true" }, .catalogue = &.{"CWE-835"} },
    .{ .name = "eager-test", .advice = "Split it into tests that each check one behaviour, named for that behaviour.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "long-test", .advice = "Split it into tests that each check one behaviour, or move the setup into a helper.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "long-function", .alias = "NASA04", .advice = "Move a self-contained step into its own function.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "assertion-density", .alias = "NASA05", .advice = "Assert conditions a bug could actually break: what it needs from its inputs and what it guarantees about its result.", .severity = .@"error", .default = true, .needs = &.{ "function.outer", "function.name", "assertion.outer" } },
    .{ .name = "assertion-message", .alias = "NASA05-A", .advice = "Add a message stating what must be true.", .severity = .warning, .default = true, .needs = &.{ "assertion.outer", "assertion.message" } },
    .{ .name = "dynamic-allocation", .advice = "Allocate what it needs up front in an init function and reuse it.", .severity = .@"error", .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "assertion-side-effect", .advice = "Do the work before the assertion and assert on its result.", .severity = .@"error", .default = true, .needs = &.{ "assertion.outer", "assertion.condition", "call.name" } },
    .{ .name = "long-parameter-list", .advice = "Group related parameters into a struct or split the function.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name", "function.parameter" }, .catalogue = &.{"CWE-1064"} },
    .{ .name = "passthrough-wrapper", .advice = "Call the target directly, or give the wrapper work of its own.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name", "function.passthrough" }, .catalogue = &.{"CWE-1041"} },
    .{ .name = "swallowed-error", .advice = "Handle the error, log it with context, or let it propagate.", .severity = .warning, .default = true, .needs = &.{"catch.swallowed"}, .catalogue = &.{ "CWE-390", "CWE-1069" } },
    .{ .name = "sleep-in-test", .advice = "Wait for the event itself, or use a fake clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "polling-loop", .advice = "Wait on an event or callback, or inject a clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "loop.outer", "function.name" } },
    .{ .name = "shared-state-in-test", .advice = "Set it for this test only and restore it after, with the framework's fixture (monkeypatch, t.Setenv, a try/finally), or pass the value in.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "filesystem-in-test", .advice = "Work in the test framework's temporary directory, or pass the code a reader and writer instead of a path.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "network-in-test", .advice = "Stub the service at its boundary with a fake that answers like it, or move this to an integration suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "database-in-test", .advice = "Use an in-memory database or a fake repository, or move this to an integration suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "unmanaged-temp-in-test", .advice = "Use the framework's temporary directory (tmp_path, t.TempDir(), @TempDir, std.testing.tmpDir), which it cleans up.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "process-in-test", .advice = "Call the code the process would run directly, or move this to an end-to-end suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "nondeterministic-test", .advice = "Inject a seeded generator or a fixed value.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "test-double", .advice = "Use the real object, or a fake that behaves like it.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" }, .catalogue = &.{"EXT-VERIFY-003"} },
    .{ .name = "name-drift", .advice = "Pick one spelling and use it everywhere.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "duplicate-name", .advice = "Give each a name that says how it differs.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "restated-type", .alias = "NASA05-M1", .advice = "Assert something about its value instead.", .severity = .warning, .default = false, .needs = &.{ "assertion.condition", "call.argument", "parameter.name", "parameter.type" }, .catalogue = &.{"EXT-VERIFY-002"} },
    .{ .name = "constant-assertion", .alias = "NASA05-M2", .advice = "Assert something that depends on the input.", .severity = .@"error", .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "literal.constant", "expression.path", "compare.not_null", "compare.equal" }, .catalogue = &.{"EXT-VERIFY-002"} },
    .{ .name = "redundant-null-check", .alias = "NASA05-M3", .advice = "Remove this check.", .severity = .warning, .default = false, .needs = &.{ "statement.outer", "compare.not_null", "compare.subject", "call.argument" }, .catalogue = &.{"EXT-VERIFY-002"} },
    .{ .name = "conversion-assertion", .alias = "NASA05-M4", .advice = "Assert the property you need it to have.", .severity = .information, .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "string.format", "expression.path" }, .catalogue = &.{"EXT-VERIFY-002"} },
    .{ .name = "guaranteed-length", .alias = "NASA05-M5", .advice = "Assert the length you actually require.", .severity = .information, .default = false, .needs = &.{ "statement.outer", "assignment.lhs", "assignment.rhs", "compare.non_negative", "compare.subject" }, .catalogue = &.{"EXT-VERIFY-002"} },
    .{ .name = "empty-block", .pattern = "'$code' has an empty body, so it does nothing; that is usually unfinished work or a lost statement.", .advice = "Fill in the body, delete the block, or leave a comment saying why nothing happens here.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1071"}, .needs = &.{"finding.empty-block"} },
    .{ .name = "constant-condition", .pattern = "'$code' tests a constant, so one branch always runs and the other never does.", .advice = "Delete the branch that can't run, or test the value that actually varies.", .severity = .warning, .default = true, .catalogue = &.{ "CWE-570", "CWE-571" }, .needs = &.{"finding.constant-condition"} },
    .{ .name = "float-equality", .pattern = "'$code' compares floating-point numbers exactly, which rounding error can make fail.", .advice = "Compare within a tolerance, such as abs(a - b) <= epsilon.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1077"}, .needs = &.{"finding.float-equality"} },
    .{ .name = "discarded-comparison", .pattern = "'$code' compares and throws the result away; an assignment or a check was probably meant.", .advice = "Assign with '=', or use the comparison in a condition or an assertion.", .severity = .@"error", .default = true, .catalogue = &.{ "CWE-480", "CWE-482" }, .needs = &.{"finding.discarded-comparison"} },
    .{ .name = "unreachable-code", .pattern = "'$code' follows a statement that always leaves the block, so it never runs.", .advice = "Delete it, or move it before the return, break, continue or throw.", .severity = .warning, .default = true, .catalogue = &.{"CWE-561"}, .needs = &.{"finding.unreachable-code"} },
    .{ .name = "generic-catch", .pattern = "'$code' catches every exception, including the ones this code can't handle.", .advice = "Catch the specific exceptions you expect and let the rest propagate.", .severity = .warning, .default = true, .catalogue = &.{"CWE-396"}, .needs = &.{"finding.generic-catch"} },
    .{ .name = "debug-leftover", .pattern = "'$code' is debugging code: wherever it ships it stops the program or dumps its state.", .advice = "Delete it; set breakpoints in the debugger instead of in the code.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-489"} },
    .{ .name = "hardcoded-secret", .advice = "Read it from the environment or a secret store at runtime.", .severity = .@"error", .default = true, .catalogue = &.{ "CWE-798", "CWE-259" }, .needs = &.{ "assignment.outer", "assignment.lhs", "assignment.rhs", "literal.string" } },
    .{ .name = "vague-error", .judgement = "has an error message too vague to find the problem: it doesn't name the input or value that failed, or what was expected", .advice = "Name the input or value that failed, show it, and say what was expected.", .severity = .warning, .default = true, .needs = &.{"literal.string"}, .question = "Does the function raise, assert, return or log an error message too vague to identify the problem, for example \"something went wrong\" or \"invalid input\" without saying which input, which value or what was expected?" },
    .{ .name = "cryptic-error", .judgement = "has an error message that isn't in plain language: a code, an internal name or jargon", .advice = "Say in plain words what went wrong and what to do; keep any code alongside if tools need it.", .severity = .warning, .default = true, .needs = &.{"literal.string"}, .question = "Does the function raise, assert, return or log an error message that is not in plain language, for example a bare error code, an internal identifier or jargon that the user, developer or agent reading it would not understand?" },
    .{ .name = "unconstructive-error", .judgement = "has an error message that says what failed but not what to do about it", .advice = "Add the next step for whoever reads it: the input, setting, file or code to change.", .severity = .warning, .default = true, .needs = &.{ "literal.string", "assertion.condition" }, .question = "Does the function raise, assert, return or log an error message that says what failed without suggesting what the user, developer or agent reading it should do to fix it, such as the input, setting, file or code to change?" },
    .{ .name = "misleading-error", .judgement = "has an error message that describes a different failure from the one that happened", .advice = "Reword the message to name the failure that actually occurred.", .severity = .warning, .default = false, .question = "Does the function raise or log an error message that misdescribes the failure that actually occurred?" },
    .{ .name = "return-in-finally", .pattern = "'$code' runs in a finally block, so it replaces any exception or return already under way.", .advice = "Move the return after the try statement, or let the finally block only clean up.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-584"}, .needs = &.{"finding.return-in-finally"} },
    .{ .name = "identity-comparison", .pattern = "'$code' compares identity, not value, so equal values can compare unequal.", .advice = "Compare values with == in Python or .equals() in Java.", .severity = .@"error", .default = true, .catalogue = &.{ "CWE-595", "CWE-597" }, .needs = &.{"finding.identity-comparison"} },
    .{ .name = "precedence-trap", .pattern = "'$code' does not group the way it reads: the operators bind in a different order.", .advice = "Add parentheses to say which operation happens first.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-783"}, .needs = &.{"finding.precedence-trap"} },
    .{ .name = "generic-throw", .pattern = "'$code' raises the most general exception type, so callers can't catch this failure without catching every other one.", .advice = "Raise a specific exception type, defined for this failure if none fits.", .severity = .warning, .default = true, .catalogue = &.{"CWE-397"}, .needs = &.{"finding.generic-throw"} },
    .{ .name = "switch-fallthrough", .pattern = "'$code' falls through into the next case because it doesn't end with break, return, throw or continue.", .advice = "End the case with break, or mark the fall-through as intended with a comment.", .severity = .warning, .default = true, .catalogue = &.{"CWE-484"}, .needs = &.{"finding.switch-fallthrough"} },
    .{ .name = "missing-default", .pattern = "'$code' has no default case, so a value no case expects passes through silently.", .advice = "Add a default case that handles or reports the unexpected value.", .severity = .warning, .default = true, .catalogue = &.{"CWE-478"}, .needs = &.{"finding.missing-default"} },
    .{ .name = "no-effect-statement", .pattern = "'$code' is a statement that does nothing: it evaluates a value and discards it.", .advice = "Delete it, or finish the statement it was meant to be, such as a call or an assignment.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1164"}, .needs = &.{"finding.no-effect-statement"} },
    .{ .name = "tls-verification-disabled", .pattern = "'$code' turns off certificate checks, so anyone on the network path can impersonate the server.", .advice = "Remove the override; to trust a private certificate, add it to the trusted certificates instead.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-295"}, .needs = &.{"finding.tls-verification-disabled"} },
    .{ .name = "weak-hash", .advice = "Use SHA-256 or better; for passwords, a password hash such as argon2, scrypt or bcrypt.", .severity = .warning, .default = true, .catalogue = &.{ "CWE-327", "CWE-328" }, .needs = &.{ "call.outer", "call.name" } },
    .{ .name = "unsafe-deserialization", .advice = "Parse a data-only format such as JSON, or use the library's safe loader.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-502"}, .needs = &.{ "call.outer", "call.name" } },
    .{ .name = "shell-command", .advice = "Pass the program and its arguments as a list, without a shell, so no value is parsed as shell syntax.", .severity = .warning, .default = true, .catalogue = &.{"CWE-78"}, .needs = &.{ "call.outer", "call.name", "call.argument", "literal.string" } },
    .{ .name = "sql-built-from-strings", .advice = "Pass values as query parameters, such as ? or %s placeholders, instead of building the SQL text.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-89"}, .needs = &.{ "call.outer", "call.name", "call.argument", "string.built" } },
    .{ .name = "secret-in-log", .advice = "Log that the secret was used, or a redacted form, never its value.", .severity = .@"error", .default = true, .catalogue = &.{"CWE-532"}, .needs = &.{ "call.outer", "call.name", "expression.path" } },
    .{ .name = "wall-clock-duration", .advice = "Measure durations with a monotonic clock, such as time.monotonic(), performance.now() or Instant::now().", .severity = .warning, .default = true, .catalogue = &.{"EXT-TIME-001"}, .needs = &.{ "call.outer", "call.name", "arith.difference" } },
    .{ .name = "unawaited-call", .advice = "Await it, or keep the task and await it later, so it runs and its errors are seen.", .severity = .@"error", .default = true, .catalogue = &.{"EXT-ASYNC-003"}, .needs = &.{ "async.name", "statement.call" } },
    .{ .name = "deep-nesting", .advice = "Return early for the edge cases, or move the inner block into its own function.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1124"}, .needs = &.{"control.outer"} },
    .{ .name = "complex-function", .advice = "Split the function so each part makes fewer decisions, or replace a chain of branches with a table.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1121"}, .needs = &.{ "function.outer", "function.name", "decision.point" } },
    .{ .name = "wide-scope", .alias = "NASA06", .advice = "Declare it inside that block, where it is used.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1126"}, .needs = &.{ "declaration.outer", "declaration.name", "declaration.block", "local.scope", "local.reference", "function.outer", "loop.outer" } },
    .{ .name = "long-file", .advice = "Split the file by responsibility into modules of a few hundred lines.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1080"} },
};

pub fn find(code: []const u8) ?Rule {
    if (code.len == 0) std.debug.panic("looked up a rule by an empty name; pass a rule name or alias such as 'unbounded-loop'", .{});
    if (all.len == 0) std.debug.panic("rules.all is empty, so '{s}' can't be found", .{code});
    for (all) |r| if (r.answers(code)) return r;
    return null;
}

pub const max_needs = 8;

pub fn missing(rule: Rule, has: anytype, out: *[max_needs][]const u8) []const []const u8 {
    if (rule.name.len == 0) std.debug.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
    if (rule.needs.len > max_needs) std.debug.panic("rule {s} needs {d} captures; raise rules.max_needs above {d}", .{ rule.name, rule.needs.len, max_needs });
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

    /// Adds the rule `name` or `alias` answers to, or every rule for `all`, including those off
    /// by default. Returns false when no rule answers to it, so the caller can say which names do.
    pub fn includeNamed(self: *Set, name: []const u8) bool {
        if (name.len == 0) std.debug.panic("including a rule by an empty name; trim and skip empty items before calling includeNamed()", .{});
        if (std.mem.eql(u8, name, "all")) {
            for (all) |r| self.include(r.name);
            if (self.len != all.len) std.debug.panic("'all' enabled {d} of the {d} rules; include() must add each rule once", .{ self.len, all.len });
            return true;
        }
        const rule = find(name) orelse return false;
        self.include(rule.name);
        return true;
    }

    pub fn defaults() Set {
        var set: Set = .{};
        for (all) |r| if (r.default) set.include(r.name);
        if (set.len == 0) std.debug.panic("no rule in rules.all is on by default; mark at least one with .default = true", .{});
        if (set.len > all.len) std.debug.panic("the default set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ set.len, all.len });
        return set;
    }

    pub fn include(self: *Set, name: []const u8) void {
        if (find(name) == null) std.debug.panic("tried to enable '{s}', which is not a rule; check rules.all", .{name});
        if (self.enabled(name)) return;
        if (self.len >= all.len) std.debug.panic("the rule set already holds all {d} rules, yet '{s}' was not among them; include() must check enabled() before adding", .{ all.len, name });
        self.buffer[self.len] = name;
        self.len += 1;
    }

    pub fn names(self: *const Set) []const []const u8 {
        if (self.len > all.len) std.debug.panic("the rule set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ self.len, all.len });
        if (self.len > 0 and self.buffer[0].len == 0) std.debug.panic("the first of {d} rules in the set has an empty name; include() only stores names from rules.all", .{self.len});
        return self.buffer[0..self.len];
    }

    pub fn enabled(self: *const Set, name: []const u8) bool {
        if (name.len == 0) std.debug.panic("asked whether an empty rule name is enabled; pass a rule name", .{});
        if (self.len > all.len) std.debug.panic("the rule set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ self.len, all.len });
        for (self.buffer[0..self.len]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

pub const max_function_lines = 60;
/// A test is read to learn one behaviour, so it gets less room than a function.
pub const max_test_lines = 50;
/// Past this many checks, a failing test no longer says which behaviour broke.
pub const max_test_checks = 10;
pub const min_asserts_per_function = 2;
pub const max_parameters = 4;
/// Deeper than this many nested branches and loops in one function is hard to follow.
pub const max_nesting = 4;
/// McCabe complexity: one plus the decisions a function makes.
pub const max_complexity = 15;
pub const max_file_lines = 1000;
/// Words an error message can be made of and still not say what failed, such as "invalid input".
/// Plurals match their singular, so only singulars are listed.
pub const vague_words = [_][]const u8{ "a", "an", "the", "error", "failed", "failure", "fail", "invalid", "bad", "wrong", "unexpected", "unknown", "something", "went", "occurred", "happened", "has", "have", "is", "was", "input", "value", "argument", "parameter", "data", "state", "request", "response", "operation", "result", "oops", "problem", "issue", "internal", "an", "unable", "could", "not", "cannot", "can't", "process", "please", "try", "again", "later", "assertion", "check", "condition", "violated", "error occurred" };
/// Words that frame a restated condition without adding meaning, such as "expected ... got".
pub const filler_words = [_][]const u8{ "expected", "expect", "expects", "got", "assert", "assertion", "failed", "fail", "fails", "check", "must", "should", "be", "is", "are", "was", "not", "to", "that", "the", "a", "an", "condition", "holds", "true", "but", "and", "or", "of", "with", "any", "d", "s" };
/// Name endings that mark a variable as holding a secret, lowercased without separators.
pub const secret_names = [_][]const u8{ "password", "passwd", "secret", "token", "apikey", "privatekey", "accesskey", "credentials" };
pub const secret_placeholders = [_][]const u8{ "not-set", "not_set", "dummy", "placeholder", "changeme", "change-me", "xxx" };

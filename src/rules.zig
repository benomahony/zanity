const std = @import("std");
const assert = @import("assert.zig");

pub const Severity = enum {
    @"error",
    warning,
    information,
};

/// What an inference question is asked about: functions that report errors, every function, every
/// test, each line of a project file, or the project files as a whole.
pub const Asks = enum { errors, function, @"test", setting, project };

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
    /// What `question` is asked about.
    asks: Asks = .errors,
    /// Deterministic rules whose finding inside a unit already answers `question` there.
    settled_by: []const []const u8 = &.{},

    pub fn answers(rule: Rule, code: []const u8) bool {
        if (rule.name.len == 0) assert.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
        if (code.len == 0) assert.panic("asked whether rule {s} answers to an empty code; pass a rule name or alias", .{rule.name});
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
    .{ .name = "dead-parameter", .advice = "Remove it and stop passing it, or name it with a leading underscore where the signature is fixed by an interface or a callback.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1164"}, .needs = &.{ "function.outer", "function.name", "local.reference" } },
    .{ .name = "passthrough-wrapper", .advice = "Call the target directly, or give the wrapper work of its own.", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name", "function.passthrough" }, .catalogue = &.{"CWE-1041"} },
    .{ .name = "message-chain", .advice = "Ask the nearest object for what you need, so only it knows how to find it, or pass that value in.", .severity = .warning, .default = true, .needs = &.{"chain.link"} },
    .{ .name = "duplicated-expression", .advice = "Compute it once into a variable named for what it is, and use that.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1041"}, .needs = &.{ "function.outer", "function.name", "expression.repeatable" } },
    .{ .name = "structural-twins", .advice = "Keep one, and make the other call it with what differs passed in.", .severity = .warning, .default = true, .catalogue = &.{"CWE-1041"}, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "dead-symbol", .advice = "Delete it; if something reaches it by name at runtime, such as a framework or a config file, say so in a comment where it is defined and suppress this finding there.", .severity = .warning, .default = true, .catalogue = &.{"CWE-561"}, .needs = &.{ "name", "reference.name" } },
    .{ .name = "single-impl-abstraction", .advice = "Use the one implementation directly until a second one is needed.", .severity = .information, .default = true, .needs = &.{ "abstraction.name", "implementation.base" } },
    .{ .name = "extractable-block", .advice = "Move them into a function named for what they do, taking the inputs and returning the output.", .severity = .information, .default = true, .needs = &.{ "function.outer", "function.name", "local.reference", "write.target", "flow.exit" } },
    .{ .name = "swallowed-error", .advice = "Handle the error, log it with context, or let it propagate.", .severity = .warning, .default = true, .needs = &.{"catch.swallowed"}, .catalogue = &.{ "CWE-390", "CWE-1069" } },
    .{ .name = "sleep-in-test", .advice = "Wait for the event itself, or use a fake clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "polling-loop", .advice = "Wait on an event or callback, or inject a clock.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "loop.outer", "function.name" } },
    .{ .name = "shared-state-in-test", .advice = "Set it for this test only and restore it after, with the framework's fixture (monkeypatch, t.Setenv, a try/finally), or pass the value in.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "filesystem-in-test", .advice = "Work in the test framework's temporary directory, or pass the code a reader and writer instead of a path.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "network-in-test", .advice = "Stub the service at its boundary with a fake that answers like it, or move this to an integration suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "database-in-test", .advice = "Use an in-memory database or a fake repository, or move this to an integration suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "unmanaged-temp-in-test", .advice = "Use the framework's temporary directory (tmp_path, t.TempDir(), @TempDir, std.testing.tmpDir), which it cleans up.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "stdin-in-test", .advice = "Pass the input in as a value, or as a reader the test controls.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "process-in-test", .advice = "Call the code the process would run directly, or move this to an end-to-end suite.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "nondeterministic-test", .advice = "Inject a seeded generator or a fixed value.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "test-double", .advice = "Use the real object, or a fake that behaves like it.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" }, .catalogue = &.{"EXT-VERIFY-003"} },
    .{ .name = "call-verification", .advice = "Assert on the result, or the state the code leaves behind; check a call only where the call is the behaviour, such as a message sent to another system.", .severity = .warning, .default = true, .needs = &.{ "call.outer", "call.name", "function.name" } },
    .{ .name = "broad-expected-error", .pattern = "'$code' accepts any error, so the test passes when the code fails for a reason nobody expected.", .advice = "Expect the specific error type, and match its message where the type is shared, such as pytest.raises(ValueError, match=...) or #[should_panic(expected = \"...\")].", .severity = .warning, .default = true, .needs = &.{"finding.broad-expected-error"} },
    .{ .name = "skipped-test", .pattern = "'$code' turns a test off, so it can't catch the failure it was written for, and nothing says when it comes back.", .advice = "Fix the test and turn it back on, or delete it; to skip only where it can't run, put the skip under a condition (skipif, an if around t.Skip), or use xfail(strict=True).", .severity = .warning, .default = true, .needs = &.{"finding.skipped-test"} },
    .{ .name = "vague-test-name", .advice = "Name the behaviour it expects, such as test_rejects_expired_token or it(\"returns 404 for an unknown id\").", .severity = .warning, .default = true, .needs = &.{ "function.outer", "function.name" } },
    .{ .name = "forbidden-term", .advice = "Rename it to say what it is or does, without the banned word.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "non-canonical-term", .advice = "Rename it with the project's word, as zanity.toml's synonyms give it.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "misplaced-test", .advice = "Move the test next to the code it tests, or move the code to the domain the test is in.", .severity = .warning, .default = true, .needs = &.{"name"} },
    .{ .name = "vocabulary-conflict", .advice = "Make the vocabulary in zanity.toml agree with itself: one word per meaning, and none both banned and canonical.", .severity = .@"error", .default = true },
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
    .{ .name = "name-behaviour-mismatch", .judgement = "is named for something materially different from what its body does", .advice = "Rename it to say what it does, or change the body to do what the name says.", .severity = .warning, .default = true, .asks = .function, .question = "Does the function's name describe something materially different from what its body actually does?" },
    .{ .name = "comment-drift", .judgement = "has a docstring or comment describing behaviour the code does not implement", .advice = "Update the comment to match the code, or fix the code if the comment is right.", .severity = .warning, .default = true, .asks = .function, .question = "Does the function's docstring or any comment inside it describe behaviour that the code does not implement?" },
    .{ .name = "query-with-side-effect", .judgement = "is named like a query but also changes state", .advice = "Rename it to say what it changes, or move the change into a separate function.", .severity = .warning, .default = true, .asks = .function, .question = "Is the function named like a query or predicate, such as get, is, has or find, while it also modifies state, writes to storage or sends messages?" },
    .{ .name = "partial-failure", .judgement = "makes several writes or external calls where a failure partway leaves data half updated", .advice = "Wrap the steps in a transaction, or undo the earlier steps when a later one fails.", .severity = .warning, .default = true, .asks = .function, .question = "Does the function make two or more changes to state that outlives the program, such as files, databases, remote services, message queues or other processes, in sequence, so that a failure between them would leave that state inconsistent, with no transaction, rollback or compensation? Changes to memory, buffers or values the function returns do not count, nor does writing one stream of output that a failure would simply cut short." },
    .{ .name = "check-then-act", .judgement = "checks shared state and then acts on it, though it can change in between", .advice = "Make the check and the action one atomic operation, for example with a lock or a conditional write.", .severity = .warning, .default = true, .asks = .function, .question = "Does the function check a condition on shared or external state and then act on it, where that state could change between the check and the action?" },
    .{ .name = "non-idempotent-retry", .judgement = "retries an operation that is not safe to repeat, so a retry can apply it twice", .advice = "Make the operation idempotent, for example with an idempotency key, or stop retrying it.", .severity = .@"error", .default = true, .asks = .function, .question = "Does the function retry an operation that is not idempotent, so that a retry could apply its effect twice?" },
    .{ .name = "unit-mismatch", .judgement = "combines quantities in different units without converting them", .advice = "Convert them to one unit first, and put the unit in the variable names.", .severity = .@"error", .default = true, .asks = .function, .question = "Does the function combine or compare quantities in different units, such as seconds and milliseconds or pence and pounds, without converting between them?" },
    .{ .name = "boundary-error", .judgement = "has a range limit or comparison that looks wrong for what it is trying to do", .advice = "Check the edge values and add a test for each boundary.", .severity = .@"error", .default = true, .asks = .function, .question = "Does the function contain a specific bound, index or comparison that gives the wrong result for its evident intent, such as an off by one range, an inclusive check that should be exclusive or a comparison in the wrong direction, so that you could name an input it mishandles? A comparison that is redundant or defensive but gives the right result does not count." },
    .{ .name = "missing-authorisation", .judgement = "performs a privileged or user-specific action without checking the caller may", .advice = "Check the caller's permission before acting.", .severity = .warning, .default = true, .asks = .function, .question = "Does the function perform a privileged or user specific action on behalf of a caller without checking that the caller is allowed to perform it?" },
    .{ .name = "mixed-abstraction", .judgement = "mixes high-level steps with low-level detail such as parsing or raw SQL", .advice = "Move the low-level detail into well-named helper functions.", .severity = .information, .default = true, .asks = .function, .question = "Does the function interleave steps at clearly different levels of abstraction, calling well-named high-level operations while also doing low-level detail such as index arithmetic, byte or string slicing, raw SQL or wire formatting inline, where that detail would read better as a named helper? A function that works at one level throughout, even a low one such as a parser, tokeniser or tree walker, does not." },
    .{ .name = "order-dependent-test", .judgement = "can pass or fail depending on which tests ran before it, because it shares state with them", .advice = "Give it its own state, or reset the shared state before it runs.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, whose result could change depending on which other tests ran before it, for example because it reads or mutates module level, class level, database or filesystem state that other tests also touch without resetting it?", .settled_by = &.{ "shared-state-in-test", "filesystem-in-test", "database-in-test", "unmanaged-temp-in-test" } },
    .{ .name = "combinatorial-test", .judgement = "varies several independent things at once, so they cannot be checked separately", .advice = "Split it into one test per dimension, or parametrise it.", .severity = .information, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that varies several independent dimensions of behaviour at once, so they cannot be checked separately and combined, for example one test covering every combination of inputs, formats and error modes?" },
    .{ .name = "flaky-test", .judgement = "can pass or fail with no code change, because it depends on time, randomness, the network, timing or ordering", .advice = "Inject a fixed clock, seed or fake, or sort before comparing.", .severity = .@"error", .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, whose result could change between runs with no code change, because it depends on the current time, unseeded randomness, real network calls, sleeps or timing, thread scheduling or unordered iteration?", .settled_by = &.{ "nondeterministic-test", "sleep-in-test", "network-in-test", "polling-loop" } },
    .{ .name = "slow-test", .judgement = "is likely to be slow, because it sleeps, waits, calls real services or processes more data than it needs", .advice = "Replace the wait or service with a fake, and shrink the data.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that would run slowly, because it sleeps, waits on timeouts, calls real external services or databases, or loops over far more data than the behaviour needs?", .settled_by = &.{ "sleep-in-test", "polling-loop", "network-in-test", "database-in-test", "process-in-test" } },
    .{ .name = "heavy-setup-test", .judgement = "needs a lot of setup for what it checks, which suggests the code is hard to use", .advice = "Simplify the code's dependencies, or move shared setup into a small builder.", .severity = .information, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, whose setup is large or elaborate relative to the behaviour it checks, such as many mocks, long object construction or copied fixtures, suggesting the code under test is expensive to test?" },
    .{ .name = "unreadable-test", .judgement = "does not let a reader tell what behaviour it checks or why", .advice = "Name it after the behaviour, name the magic values, and separate arrange, act and assert.", .severity = .information, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, where a reader could not tell from its name and body what behaviour it checks and why, for example a vague name, unexplained magic values or no clear arrange, act and assert steps?", .settled_by = &.{ "vague-test-name" } },
    .{ .name = "hollow-test", .judgement = "would still pass if the behaviour it names were broken", .advice = "Assert on the output or effect of that behaviour.", .severity = .@"error", .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that would still pass if the behaviour it claims to check were broken, for example because it asserts nothing, asserts only that no exception was raised when the behaviour is more than not failing, or asserts on values it set up itself? A test whose behaviour is that something compiles, loads or never breaks an invariant, such as a fuzz or smoke test, checks it through the error or assertion failure that would fail it." },
    .{ .name = "implementation-coupled-test", .judgement = "would fail after a refactor that keeps behaviour the same, because it checks internal details", .advice = "Assert on public results instead of private state or internal calls.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that would fail after a refactoring that keeps behaviour the same, because it asserts on private attributes, internal call order, mock call counts of internal collaborators or other implementation details?", .settled_by = &.{ "call-verification" } },
    .{ .name = "manual-test", .judgement = "needs a person to run or judge it", .advice = "Replace manual input, printing or setup with assertions and automated fixtures.", .severity = .@"error", .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that needs human intervention, for example reading input, printing output for someone to inspect instead of asserting, opening a browser or depending on manual setup steps?", .settled_by = &.{ "stdin-in-test", "debug-leftover" } },
    .{ .name = "unfocused-test", .judgement = "would not say why it failed, because it checks several things or one large opaque value", .advice = "Split it up, or assert only on the parts that matter.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, where a failure would not point to an obvious cause, because it checks several unrelated behaviours in one test or asserts on a large opaque value without saying what matters?", .settled_by = &.{ "eager-test" } },
    .{ .name = "self-mocking-test", .judgement = "mocks the behaviour it claims to check, so it can pass while the real code fails", .advice = "Exercise the real code, and mock only its external dependencies.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that could pass while the real code would fail in production, because it mocks or stubs out the very behaviour it claims to test or replaces it with a simplified fake?" },
    .{ .name = "trivial-test", .judgement = "checks something trivial or only the easy path, so passing it says little", .advice = "Test the risky behaviour and edge cases, and make the name match what is verified.", .severity = .warning, .default = true, .asks = .@"test", .question = "Is this a test case itself, not a fixture, setup or teardown hook or helper, that would give a reader little confidence the code works even when it passes, because it checks something trivial or incidental, exercises the framework or language rather than the code under test, covers only the easy path of risky behaviour, or claims in its name more than it actually verifies? A fuzz or property test over arbitrary input is not trivial." },
    .{ .name = "relaxed-check", .advice = "Remove it, or fix what the check reports and turn it back on at its strictest.", .severity = .warning, .default = true },
    .{ .name = "weakened-check", .judgement = "weakens a compiler, linter, type checker, test or coverage check", .advice = "Remove it, or turn the check back on at its strictest and fix what it reports.", .severity = .warning, .default = true, .asks = .setting, .settled_by = &.{"relaxed-check"}, .question = "Does this line of a project configuration file weaken a compiler, linter, type checker, static analyser, test or coverage check, for example by disabling or ignoring a rule, excluding or omitting files, choosing a mode below the strictest available, setting a confidence or severity threshold that hides findings, or letting a failing step or warning pass?" },
    .{ .name = "unscheduled-analysis", .judgement = "don't run a strict static analyser automatically on every change, or daily, and require it to pass with no warnings", .advice = "Run a strict type checker and a linter with every rule in CI on every change and on a daily schedule, and fail the build on any warning.", .severity = .warning, .default = true, .asks = .project, .question = "Is there no strict static analyser, such as a type checker in strict mode or a linter with all rules selected, that these project files run automatically at least daily or on every change and require to pass with zero warnings?" },
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
    if (code.len == 0) assert.panic("looked up a rule by an empty name; pass a rule name or alias such as 'unbounded-loop'", .{});
    if (all.len == 0) assert.panic("rules.all is empty, so '{s}' can't be found", .{code});
    for (all) |r| if (r.answers(code)) return r;
    return null;
}

pub const max_needs = 8;

pub fn missing(rule: Rule, has: anytype, out: *[max_needs][]const u8) []const []const u8 {
    if (rule.name.len == 0) assert.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
    if (rule.needs.len > max_needs) assert.panic("rule {s} needs {d} captures; raise rules.max_needs above {d}", .{ rule.name, rule.needs.len, max_needs });
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
        if (name.len == 0) assert.panic("including a rule by an empty name; trim and skip empty items before calling includeNamed()", .{});
        if (std.mem.eql(u8, name, "all")) {
            for (all) |r| self.include(r.name);
            if (self.len != all.len) assert.panic("'all' enabled {d} of the {d} rules; include() must add each rule once", .{ self.len, all.len });
            return true;
        }
        const rule = find(name) orelse return false;
        self.include(rule.name);
        return true;
    }

    pub fn defaults() Set {
        var set: Set = .{};
        for (all) |r| if (r.default) set.include(r.name);
        if (set.len == 0) assert.panic("no rule in rules.all is on by default; mark at least one with .default = true", .{});
        if (set.len > all.len) assert.panic("the default set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ set.len, all.len });
        return set;
    }

    pub fn include(self: *Set, name: []const u8) void {
        if (find(name) == null) assert.panic("tried to enable '{s}', which is not a rule; check rules.all", .{name});
        if (self.enabled(name)) return;
        if (self.len >= all.len) assert.panic("the rule set already holds all {d} rules, yet '{s}' was not among them; include() must check enabled() before adding", .{ all.len, name });
        self.buffer[self.len] = name;
        self.len += 1;
    }

    pub fn names(self: *const Set) []const []const u8 {
        if (self.len > all.len) assert.panic("the rule set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ self.len, all.len });
        if (self.len > 0 and self.buffer[0].len == 0) assert.panic("the first of {d} rules in the set has an empty name; include() only stores names from rules.all", .{self.len});
        return self.buffer[0..self.len];
    }

    pub fn enabled(self: *const Set, name: []const u8) bool {
        if (name.len == 0) assert.panic("asked whether an empty rule name is enabled; pass a rule name", .{});
        if (self.len > all.len) assert.panic("the rule set holds {d} rules but only {d} exist; Set.include() must refuse to add past rules.all.len, so check it", .{ self.len, all.len });
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
/// How alike two domain or context names can be before one looks like a misspelling of the other.
pub const min_scope_similarity = 0.85;
/// Member accesses in a row, as in `order.customer.address.city`, from which code reaches through
/// objects it shouldn't know about.
pub const min_chain_links = 3;
/// Copies of one expression in a function before it is duplication.
pub const min_repeats = 3;
/// Visible characters an expression needs before writing it again is duplication, not idiom.
pub const min_repeated_expression = 8;
/// Functions shorter than this many lines of code, or with fewer syntax nodes in their body, can
/// share a shape by chance, such as getters, so structural-twins leaves them out.
pub const min_twin_lines = 6;
pub const min_twin_nodes = 40;
/// Functions long-function reports are the ones worth splitting, so extractable-block looks inside them.
pub const min_extract_lines = max_function_lines;
/// Top-level statements a block needs before moving it out is worth a function of its own.
pub const min_extract_statements = 5;
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
/// Words a test's name can be made of and still not say what it checks, such as "it works".
/// Compared ignoring case; a trailing number is dropped first, so "test2" is "test".
pub const filler_test_words = [_][]const u8{ "test", "tests", "testing", "it", "works", "work", "working", "ok", "okay", "basic", "basics", "simple", "foo", "bar", "baz", "qux", "quux", "something", "stuff", "thing", "things", "case", "cases", "example", "examples", "sample", "demo", "dummy", "misc", "todo", "wip", "temp", "tmp", "new", "my", "the", "a", "an", "and", "x", "y", "z" };
/// Names a framework, a runner or the operating system calls without the code naming them.
pub const entry_points = [_][]const u8{ "main", "app", "cli", "setup", "teardown", "setUp", "tearDown", "setUpClass", "tearDownClass", "setUpModule", "tearDownModule", "conftest", "init", "deinit", "panic" };
/// Name endings that mark a variable as holding a secret, lowercased without separators.
pub const secret_names = [_][]const u8{ "password", "passwd", "secret", "token", "apikey", "privatekey", "accesskey", "credentials" };

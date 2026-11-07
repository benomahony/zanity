//! What counts as a job running the checks: a test runner, linter or type checker with its
//! checking subcommand, any command given a flag that fails on a problem, or a checking action.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const release = @import("release.zig");
const command_window_bytes = release.command_window_bytes;
const withoutComment = release.withoutComment;

/// Commands that run tests, a linter or a type checker, lowercased, matched as a whole command
/// or its start, so `cargo test` counts and `mkdir test-output` doesn't.
const check_commands = [_][]const u8{
    "cargo test",     "cargo nextest",  "cargo clippy",       "cargo check",   "go test",           "go vet",       "golangci-lint run", "staticcheck",
    "npm test",       "npm run test",   "npm run lint",       "npm run check", "npm run typecheck", "pnpm test",    "pnpm run test",     "pnpm lint",
    "pnpm run lint",  "yarn test",      "yarn lint",          "bun test",      "deno test",         "deno lint",    "deno check",        "jest",
    "vitest",         "mocha",          "eslint",             "biome check",   "biome ci",          "pytest",       "tox",               "nox",
    "mypy",           "pyright",        "ruff check",         "flake8",        "pylint",            "rspec",        "rake test",         "rake spec",
    "rubocop",        "phpunit",        "phpstan",            "ctest",         "make test",         "make check",   "make lint",         "just test",
    "zig build test", "dotnet test",    "mvn test",           "mvn verify",    "gradle test",       "gradle check", "./gradlew test",    "./gradlew check",
    "swift test",     "mix test",       "stack test",         "cabal test",    "shellcheck",        "actionlint",   "zizmor",            "hadolint",
    "zanity check",   "pre-commit run", "terraform validate", "helm lint",
};

/// Flags that make any command fail on a problem it finds, as a check does.
const check_flags = [_][]const u8{ "--check", "--noemit", "--exit-code" };

/// Prefixes that run the command after them, which is the one that counts.
const command_runners = [_][]const u8{ "uv run ", "poetry run ", "pipenv run ", "pdm run ", "hatch run ", "rye run ", "npx ", "pnpm exec ", "pnpm dlx ", "yarn dlx ", "bunx ", "bundle exec ", "python -m ", "python3 -m ", "time " };

/// Actions that run tests, a linter or a type checker, lowercased, without the version.
const check_actions = [_][]const u8{ "golangci/golangci-lint-action", "astral-sh/ruff-action", "chartboost/ruff-action", "pre-commit/action", "rhysd/actionlint", "ludeeus/action-shellcheck", "hadolint/hadolint-action", "zizmorcore/zizmor-action", "super-linter/super-linter", "github/super-linter", "jakebailey/pyright-action" };

/// Whether a step's `uses:` value is an action that runs tests, a linter or a type checker.
pub fn checkingAction(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("'{s}' spans lines, but a step's uses: value is one line", .{value});
    const trimmed = std.mem.trim(u8, withoutComment(value), " \"'");
    const action = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '@') orelse trimmed.len];
    var lower: [command_window_bytes]u8 = undefined;
    const kept = @min(action.len, lower.len);
    const lowered = std.ascii.lowerString(lower[0..kept], action[0..kept]);
    if (lowered.len > action.len) assert.panic("lowercased '{s}' into more bytes", .{action});
    return strings.contains(&check_actions, lowered);
}

/// Whether `text`, a command line lowercased with its quotes blanked, runs tests, a linter or a
/// type checker in any of the commands it chains with `&&`, `||`, `;` or `|`.
pub fn isCheck(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "\"'") != null) assert.panic("'{s}' still has quotes; unquote() a command before asking whether it checks", .{text});
    var commands = std.mem.tokenizeAny(u8, text, ";&|");
    var seen: usize = 0;
    while (commands.next()) |one| : (seen += 1) {
        if (checks(withoutRunners(std.mem.trim(u8, one, " \t")))) return true;
    }
    if (seen > text.len) assert.panic("split a {d}-byte command into {d} commands", .{ text.len, seen });
    return false;
}

/// `one` without the runners in front of it, such as `uv run` or `npx`, and its environment
/// assignments, such as `CI=1`, so what is left starts with the command that runs.
fn withoutRunners(one: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, one, ";&|") != null) assert.panic("'{s}' chains commands; isCheck() splits them first", .{one});
    var rest = one;
    for (0..command_runners.len + 16) |_| {
        const before = rest.len;
        for (command_runners) |runner| if (std.mem.startsWith(u8, rest, runner)) {
            rest = std.mem.trimStart(u8, rest[runner.len..], " \t");
        };
        const word_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        if (std.mem.indexOfScalar(u8, rest[0..word_end], '=')) |eq| if (eq > 0) {
            rest = std.mem.trimStart(u8, rest[word_end..], " \t");
        };
        if (rest.len != before) continue;
        if (@intFromPtr(rest.ptr) + rest.len != @intFromPtr(one.ptr) + one.len) assert.panic("'{s}' left '{s}', which is not its end; withoutRunners() may only drop words from the front", .{ one, rest });
        return rest;
    }
    assert.panic("'{s}' kept losing runners past any real command's count; each pass must shorten it or stop", .{one});
}

/// Whether one command, its runners removed, is a check: a listed command, or any command given a
/// flag that makes it fail on a problem.
fn checks(one: []const u8) bool {
    if (std.mem.indexOfAny(u8, one, ";&|") != null) assert.panic("'{s}' chains commands; isCheck() splits them first", .{one});
    if (one.len > command_window_bytes) assert.panic("checking a {d}-byte command, past the {d}-byte window unquote() keeps", .{ one.len, command_window_bytes });
    for (check_commands) |check| {
        if (!std.mem.startsWith(u8, one, check)) continue;
        if (one.len == check.len or one[check.len] == ' ' or one[check.len] == '\t') return true;
    }
    var words = std.mem.tokenizeAny(u8, one, " \t");
    while (words.next()) |word| {
        const flag = word[0 .. std.mem.indexOfScalar(u8, word, '=') orelse word.len];
        if (flag.len > 0 and strings.contains(&check_flags, flag)) return true;
    }
    return false;
}

test "a test runner, linter or type checker with its checking subcommand runs the checks" {
    for ([_][]const u8{ "cargo test --workspace", "go test ./...", "npm test", "zig build test", "ruff check .", "golangci-lint run", "make check", "mvn verify", "./gradlew check" }) |command| {
        if (!isCheck(command)) std.debug.print("'{s}' should count as running the checks\n", .{command});
        try std.testing.expect(isCheck(command));
    }
}

test "a command runs the checks behind a runner, after other commands, or with a failing flag" {
    for ([_][]const u8{ "uv run pytest", "npx tsc --noemit", "bundle exec rspec", "ci=1 npm test", "npm ci && npm test", "cd app; cargo clippy", "git diff --exit-code", "prettier --check src", "black --check=true ." }) |command| {
        if (!isCheck(command)) std.debug.print("'{s}' should count as running the checks\n", .{command});
        try std.testing.expect(isCheck(command));
    }
}

test "a check word inside an argument or another command's name doesn't run the checks" {
    for ([_][]const u8{ "mkdir test-output", "pytest-cov-report", "cargo build --tests-dir out", "echo test", "npm ci", "cargo build --locked", "cp checklist.md dist", "make" }) |command| {
        if (isCheck(command)) std.debug.print("'{s}' should not count as running the checks\n", .{command});
        try std.testing.expect(!isCheck(command));
    }
}

test "a checking action runs the checks whatever its version, and a release action doesn't" {
    try std.testing.expect(checkingAction(" golangci/golangci-lint-action@v6"));
    try std.testing.expect(checkingAction(" \"Astral-Sh/Ruff-Action@v3\" # lint"));
    try std.testing.expect(!checkingAction(" softprops/action-gh-release@v2"));
    try std.testing.expect(!checkingAction(" actions/checkout@v5"));
}

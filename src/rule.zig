//! What a rule is: its name, advice, severity, tier and the captures it needs.
const std = @import("std");
const assert = @import("assert.zig");

pub const Severity = enum {
    @"error",
    warning,
    information,
};

/// What an inference question is asked about: functions that report errors, every function,
/// fixtures and helpers in test files, every test, each line of a project file, the project files
/// as a whole, a cluster of functions or tests of one structure, or each source file whole.
pub const Asks = enum { errors, function, fixture, @"test", setting, project, cluster, file };

/// When a rule runs: by default, or with --production, which runs every rule, adding what
/// safety-critical code needs and most code doesn't, such as two assertions in every function.
pub const Tier = enum { default, production };

/// How `zanity init` and the schema describe when a rule in each tier runs.
pub const tier_descriptions = std.enums.EnumArray(Tier, []const u8).init(.{
    .default = "on by default",
    .production = "on with --production",
});

pub const Rule = struct {
    name: []const u8,
    alias: []const u8 = "",
    advice: []const u8,
    severity: Severity,
    tier: Tier,
    needs: []const []const u8 = &.{},
    /// Entries of the engineering error catalogue (catalogue/catalogue.json) this rule detects.
    catalogue: []const []const u8 = &.{},
    tests: bool = false,
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
    /// How sure the model must be for `question` to report; [infer] threshold when null.
    threshold: ?f64 = null,

    pub fn answers(rule: Rule, code: []const u8) bool {
        if (rule.name.len == 0) assert.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
        if (code.len == 0) assert.panic("asked whether rule {s} answers to an empty code; pass a rule name or alias", .{rule.name});
        return std.mem.eql(u8, rule.name, code) or (rule.alias.len > 0 and std.mem.eql(u8, rule.alias, code));
    }
};

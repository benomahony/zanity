const std = @import("std");
const Allocator = std.mem.Allocator;
const memory = @import("memory.zig");
const rules = @import("rules.zig");

pub const Definition = struct {
    path: []const u8,
    language: []const u8,
    name: []const u8,
    kind: []const u8,
    line: u32,
    column: u32,

    pub fn sourceOrder(_: void, a: Definition, b: Definition) bool {
        if (a.name.len == 0) std.debug.panic("a definition at {s}:{d} has no name; the @name capture matched an empty node", .{ a.path, a.line + 1 });
        if (b.name.len == 0) std.debug.panic("a definition at {s}:{d} has no name; the @name capture matched an empty node", .{ b.path, b.line + 1 });
        const by_path = std.mem.order(u8, a.path, b.path);
        if (by_path != .eq) return by_path == .lt;
        if (a.line != b.line) return a.line < b.line;
        return a.column < b.column;
    }
};

pub const Function = struct {
    path: []const u8,
    name: []const u8,
    method: bool,
    line: u32,
    column: u32,
};

/// A change that fixes a finding: bytes `start..end` of its file become `replacement`.
/// `check --fix` applies these; an editor can offer them as code actions.
pub const Edit = struct {
    start: u32,
    end: u32,
    replacement: []const u8,
};

pub const Finding = struct {
    path: []const u8,
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    fix: []const u8 = "",
    edit: ?Edit = null,
    /// Set once `--fix` has applied `edit`, so the finding is no longer reported.
    fixed: bool = false,

    pub fn advice(self: Finding) []const u8 {
        const rule = rules.find(self.rule) orelse unreachable;
        if (rule.advice.len == 0) std.debug.panic("rule {s} has no advice; add it in src/rules.zig", .{rule.name});
        if (self.message.len == 0) std.debug.panic("a {s} finding at {s}:{d} has no message; the check that reported it must say what is wrong", .{ self.rule, self.path, self.line + 1 });
        return if (self.fix.len > 0) self.fix else rule.advice;
    }
};

pub const Reach = enum { any, functions, methods };

pub const Edge = struct { caller: u32, callee: []const u8, reach: Reach };

/// A function that reports an error, kept whole so `check --infer` can ask about its messages.
pub const Unit = struct {
    path: []const u8,
    language: []const u8,
    name: []const u8,
    line: u32,
    column: u32,
    end_line: u32,
    source: []const u8,
};

pub const Facts = struct {
    text: *memory.Text,
    path: []const u8 = "",
    language: []const u8 = "",
    definitions: memory.Bounded(Definition),
    functions: memory.Bounded(Function),
    calls: memory.Bounded(Edge),
    units: memory.Bounded(Unit),
    /// Whether to keep `units`; only `check --infer` needs them.
    collect_units: bool = false,

    pub fn initFacts(gpa: Allocator, limits: memory.Limits, text: *memory.Text) Allocator.Error!Facts {
        if (limits.definitions == 0 or limits.functions == 0 or limits.calls == 0) std.debug.panic("memory.Limits allows {d} definitions, {d} functions and {d} calls; each must be above 0", .{ limits.definitions, limits.functions, limits.calls });
        if (text.buffer.len == 0) std.debug.panic("Facts was given an unallocated text buffer; call Text.initText first", .{});
        return .{
            .text = text,
            .definitions = try .initBounded(gpa, limits.definitions, "definitions across all files"),
            .functions = try .initBounded(gpa, limits.functions, "functions across all files"),
            .calls = try .initBounded(gpa, limits.calls, "calls across all files"),
            .units = try .initBounded(gpa, limits.functions, "functions with error messages across all files"),
        };
    }

    pub fn define(self: *Facts, name: []const u8, kind: []const u8, at: [2]u32) error{LimitExceeded}!void {
        if (self.path.len == 0 or self.language.len == 0) std.debug.panic("defining '{s}' before the file is known (path '{s}', language '{s}'); set facts.path and facts.language first", .{ name, self.path, self.language });
        if (name.len == 0) std.debug.panic("a {s} in {s} at {d}:{d} has an empty name; the query's @name capture matched an empty node", .{ kind, self.path, at[0] + 1, at[1] + 1 });
        try self.definitions.add(.{
            .path = self.path,
            .language = self.language,
            .name = try self.text.copy(name),
            .kind = kind,
            .line = at[0],
            .column = at[1],
        });
    }

    pub fn function(self: *Facts, name: []const u8, at: [2]u32, method: bool) error{LimitExceeded}!u32 {
        if (self.path.len == 0) std.debug.panic("recording function '{s}' before the file is known; set facts.path first", .{name});
        if (name.len == 0) std.debug.panic("a function in {s} at {d}:{d} has an empty name; check the @function.name capture", .{ self.path, at[0] + 1, at[1] + 1 });
        const id: u32 = @intCast(self.functions.len);
        try self.functions.add(.{ .path = self.path, .name = try self.text.copy(name), .method = method, .line = at[0], .column = at[1] });
        return id;
    }

    /// Keeps a function that reports an error; `at` is its name's line and column, `end_line` its last line.
    pub fn unit(self: *Facts, name: []const u8, at: [3]u32, source: []const u8) error{LimitExceeded}!void {
        if (self.path.len == 0 or self.language.len == 0) std.debug.panic("keeping function '{s}' before the file is known (path '{s}', language '{s}'); set facts.path and facts.language first", .{ name, self.path, self.language });
        if (at[2] < at[0]) std.debug.panic("{s}: function '{s}' ends on line {d}, before its name on line {d}; pass the function's name position and its last line from the same node", .{ self.path, name, at[2] + 1, at[0] + 1 });
        try self.units.add(.{
            .path = self.path,
            .language = self.language,
            .name = try self.text.copy(name),
            .line = at[0],
            .column = at[1],
            .end_line = at[2],
            .source = try self.text.copy(source),
        });
    }

    pub fn call(self: *Facts, caller: u32, callee: []const u8, reach: Reach) error{LimitExceeded}!void {
        if (caller >= self.functions.len) std.debug.panic("call to '{s}' names caller {d}, but only {d} functions are recorded; record the calling function before its calls", .{ callee, caller, self.functions.len });
        if (callee.len == 0) std.debug.panic("function {d} calls something with an empty name; check the @call.name capture", .{caller});
        try self.calls.add(.{ .caller = caller, .callee = try self.text.copy(callee), .reach = reach });
    }
};

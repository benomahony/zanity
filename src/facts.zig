const std = @import("std");
const assert = std.debug.assert;
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
        assert(a.name.len > 0);
        assert(b.name.len > 0);
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

pub const Finding = struct {
    path: []const u8,
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    fix: []const u8 = "",

    pub fn advice(self: Finding) []const u8 {
        const rule = rules.find(self.rule) orelse unreachable;
        assert(rule.advice.len > 0);
        assert(self.message.len > 0);
        return if (self.fix.len > 0) self.fix else rule.advice;
    }
};

pub const Reach = enum { any, functions, methods };

pub const Edge = struct { caller: u32, callee: []const u8, reach: Reach };

pub const Facts = struct {
    text: *memory.Text,
    path: []const u8 = "",
    language: []const u8 = "",
    definitions: memory.Bounded(Definition),
    functions: memory.Bounded(Function),
    calls: memory.Bounded(Edge),

    pub fn initFacts(gpa: Allocator, limits: memory.Limits, text: *memory.Text) Allocator.Error!Facts {
        assert(limits.definitions > 0 and limits.functions > 0 and limits.calls > 0);
        assert(text.buffer.len > 0);
        return .{
            .text = text,
            .definitions = try .initBounded(gpa, limits.definitions, "definitions across all files"),
            .functions = try .initBounded(gpa, limits.functions, "functions across all files"),
            .calls = try .initBounded(gpa, limits.calls, "calls across all files"),
        };
    }

    pub fn define(self: *Facts, name: []const u8, kind: []const u8, at: [2]u32) error{LimitExceeded}!void {
        assert(self.path.len > 0 and self.language.len > 0);
        assert(name.len > 0);
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
        assert(self.path.len > 0);
        assert(name.len > 0);
        const id: u32 = @intCast(self.functions.len);
        try self.functions.add(.{ .path = self.path, .name = try self.text.copy(name), .method = method, .line = at[0], .column = at[1] });
        return id;
    }

    pub fn call(self: *Facts, caller: u32, callee: []const u8, reach: Reach) error{LimitExceeded}!void {
        assert(caller < self.functions.len);
        assert(callee.len > 0);
        try self.calls.add(.{ .caller = caller, .callee = try self.text.copy(callee), .reach = reach });
    }
};

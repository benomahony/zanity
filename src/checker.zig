//! A language's compiled queries and the rules selected for it.
const std = @import("std");
const capture_ids = @import("capture_ids.zig");
const Vocabulary = capture_ids.Vocabulary;
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const captures = @import("captures.zig");
const language = @import("language.zig");
const rules = @import("rules.zig");
const unread = @import("unread.zig");

pub const Checker = struct {
    loaded: language.Loaded,
    compiled: captures.Compiled,
    vocabulary: Vocabulary,
    enabled: rules.Set,

    pub fn initChecker(gpa: Allocator, loaded: language.Loaded, requested: rules.Set) !Checker {
        if (requested.len == 0) assert.panic("building a {s} checker with no rules requested; runCheck always requests at least one", .{loaded.adapter.name});
        const compiled = try captures.Compiled.initCompiled(gpa, loaded.query);
        _ = unread.disableUnread(loaded.query, compiled);
        var checker: Checker = .{
            .loaded = loaded,
            .compiled = compiled,
            .vocabulary = Vocabulary.lookup(compiled),
            .enabled = .{},
        };
        checker.selectRules(requested);
        if (checker.enabled.len > requested.len) assert.panic("{s} enabled {d} rules from {d} requests; selectRules() must keep only supported requests", .{ loaded.adapter.name, checker.enabled.len, requested.len });
        return checker;
    }

    /// Changes selection without reallocating the language's immutable compiled query.
    pub fn selectRules(self: *Checker, requested: rules.Set) void {
        if (requested.len == 0) assert.panic("selecting no rules for {s}; settings must retain at least one requested rule", .{self.loaded.adapter.name});
        self.enabled = .{};
        for (requested.names()) |name| {
            if (language.applies(self.loaded.adapter, name)) self.enabled.include(name);
        }
        if (self.enabled.len > requested.len) assert.panic("{s} supports {d} of {d} requested rules; selection cannot introduce rules", .{ self.loaded.adapter.name, self.enabled.len, requested.len });
    }
};

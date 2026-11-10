//! The code actions and commands zanity offers an editor, and the keys and attributes they carry.
const std = @import("std");
const json = std.json;
const assert = @import("assert.zig");
const protocol = @import("lsp_protocol.zig");
const TextEdit = protocol.TextEdit;
const stringOf = protocol.stringOf;
const Target = @import("lsp_results.zig").Target;
const LspDiagnostic = @import("lsp_results.zig").LspDiagnostic;
/// The key a file's path is recorded under, as lsp.pathKey is.
const pathKey = @import("facts.zig").nameHash;
const Attribute = @import("telemetry.zig").Attribute;

/// The most actions offered for one finding.
pub const max_actions_per_finding = 4;

/// The commands the server's code actions run.
pub const flag_command = "zanity.flagFalsePositive";

pub const fixed_command = "zanity.fixApplied";

/// Mark a --infer finding real, or not a problem for its function, as `zanity mark` does.
pub const confirm_command = "zanity.confirmFinding";

pub const dismiss_command = "zanity.notAProblem";

/// The code action kind that applies every fix in a file.
pub const fix_all = "source.fixAll.zanity";

/// The edits of one file, written as LSP's `changes` map from its URI.
pub const Changes = struct {
    uri: []const u8,
    edits: []const TextEdit,

    pub fn jsonStringify(self: Changes, jw: anytype) !void {
        if (self.uri.len == 0) assert.panic("writing {d} edits under an empty URI", .{self.edits.len});
        if (self.edits.len == 0) assert.panic("writing no edits for {s}; an action with an edit has at least one", .{self.uri});
        try jw.beginObject();
        try jw.objectField(self.uri);
        try jw.write(self.edits);
        try jw.endObject();
    }
};

pub const Command = struct { title: []const u8, command: []const u8, arguments: []const Target };

pub const Action = struct {
    title: []const u8,
    kind: []const u8,
    diagnostics: []const LspDiagnostic,
    isPreferred: bool,
    edit: ?struct { changes: Changes } = null,
    /// Runs after the edit, if any, is applied.
    command: ?Command = null,
};

/// The span attributes that say which finding a command was about, and the code it was on.
pub fn attributesOf(target: Target, code: []const u8) [6]Attribute {
    if (target.line == 0) assert.panic("describing a finding on line 0 of {s}; lines count from 1", .{target.path});
    if (target.rule.len == 0) assert.panic("describing a finding with no rule at {s}:{d}", .{ target.path, target.line });
    return .{
        .{ .key = "code.filepath", .value = .{ .string = target.path } },
        .{ .key = "code.lineno", .value = .{ .int = target.line } },
        .{ .key = "code.column", .value = .{ .int = target.column } },
        .{ .key = "zanity.rule", .value = .{ .string = target.rule } },
        .{ .key = "zanity.message", .value = .{ .string = target.message } },
        .{ .key = "zanity.code", .value = .{ .string = code } },
    };
}

/// What identifies a flagged finding across checks: its file, rule and message, which names the
/// values it found, but not its line, which moves as the file is edited.
pub fn flagKey(path: []const u8, rule: []const u8, message: []const u8) u64 {
    if (path.len == 0 or rule.len == 0) assert.panic("keying a flag with path '{s}' and rule '{s}'; both are needed", .{ path, rule });
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ path, rule, message }) |part| {
        h.update(part);
        h.update("\x00");
    }
    const key = h.final();
    if (key == pathKey(path)) assert.panic("the flag of {s} in {s} hashed like the path alone", .{ rule, path });
    return key;
}

/// Whether a code action request's `only` list, when it has one, asks for `kind`. A listed kind
/// covers the kinds under it, so `source` covers `source.fixAll.zanity`.
pub fn wants(only: ?json.Value, kind: []const u8) bool {
    if (kind.len == 0) assert.panic("asked whether the editor wants an empty kind of code action; pass the requested action kind", .{});
    const list = switch (only orelse return true) {
        .array => |a| a.items,
        else => return true,
    };
    for (list) |item| {
        const asked = stringOf(item) orelse continue;
        if (std.mem.eql(u8, asked, kind)) return true;
        if (asked.len < kind.len and std.mem.startsWith(u8, kind, asked) and kind[asked.len] == '.') return true;
    }
    if (list.len > 1 << 10) assert.panic("the editor asked for {d} kinds of code action; cap or reject the request's only list", .{list.len});
    return false;
}

//! The language server's code actions and the commands they run: the fixes offered for a
//! finding or a whole file, and flagging a finding as a false positive or marking it real.
const results_module = @import("lsp_results.zig");
const protocol = @import("lsp_protocol.zig");
const std = @import("std");
const assert = @import("assert.zig");
const store = @import("store.zig");
const rules = @import("rules.zig");
const Attribute = @import("telemetry.zig").Attribute;
const Position = protocol.Position;
const TextEdit = protocol.TextEdit;
const no_value = protocol.no_value;
const member = protocol.member;
const stringOf = protocol.stringOf;
const integerOf = protocol.integerOf;
const LspDiagnostic = results_module.LspDiagnostic;
const DiagnosticEntry = results_module.DiagnosticEntry;
const Target = results_module.Target;
const CheckedFile = results_module.CheckedFile;
const editsFirst = results_module.editsFirst;
const isBefore = results_module.isBefore;
const lineOf = results_module.lineOf;
const Io = std.Io;
const json = std.json;
const lsp = @import("lsp.zig");
const LanguageServer = lsp.LanguageServer;
const invalid_params = lsp.invalid_params;
const pathKey = lsp.pathKey;

/// The most code action kinds one request may name.
pub const max_action_kinds = 1 << 10;
/// Keeps the unit of the first answer `eachObserved` reads.
fn firstUnit(found: *?store.Digest, observed: store.Observed) anyerror!bool {
    if (found.* != null) assert.panic("kept a second answer at {s}:{d}; firstUnit() stops after one", .{ observed.path, observed.line });
    if (observed.rule.len == 0) assert.panic("a kept answer at {s}:{d} has no rule; restore a good copy of the store or choose a new ZANITY_STORE", .{ observed.path, observed.line });
    found.* = observed.unit;
    return false;
}

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

/// Offers a quick fix and a false-positive flag for each finding on the requested lines, and
/// one action that makes every fix in the file. A file edited since the last check gets none
/// until it is saved, as its findings may have moved.
pub fn codeActions(self: *LanguageServer, id: json.Value, params: json.Value) !void {
    const actions = &self.scratch.actions;
    if (actions.len != 0) assert.panic("answering a code action request with {d} actions left from the last", .{actions.len});
    const none = [_]Action{};
    const file = try self.fileOf(params) orelse return self.respond(id, &none);
    if (self.isDirty(file.path)) return self.respond(id, &none);
    const only = member(member(params, "context"), "only");
    if (only) |value| if (value == .array) {
        const kinds = value.array.items;
        if (kinds.len > max_action_kinds) return self.sendError(id, invalid_params, "Request at most 1024 code action kinds in context.only.");
    };
    const range = member(params, "range");
    const first = integerOf(member(member(range, "start"), "line")) orelse 0;
    const last = integerOf(member(member(range, "end"), "line")) orelse first;
    const entries = self.current.entriesOf(file);
    if (wants(only, "quickfix")) for (entries) |*entry| {
        if (entry.line() < first or entry.line() > last) continue;
        offerFixes(self, file, entry) catch break;
    };
    if (wants(only, fix_all)) if (try fixAll(self, file)) |action| try actions.add(action);
    try self.respond(id, actions.items());
    if (actions.len > max_actions_per_finding * entries.len + 1) assert.panic("offered {d} actions for {d} findings; offer at most a fix, a flag and two marks per finding and one for the file", .{ actions.len, entries.len });
}

/// Adds the finding's own fix, when it has one, and the action that flags it.
pub fn offerFixes(self: *LanguageServer, file: *const CheckedFile, entry: *const DiagnosticEntry) !void {
    if (file.uri.len == 0) assert.panic("offering fixes in {s}, which has no URI; add() records each file's URI", .{file.path});
    const s = &self.scratch;
    const before = s.actions.len;
    try s.targets.add(self.current.bindTarget(entry.targets(file.path)));
    const target = s.targets.items()[s.targets.len - 1 ..];
    const diagnostics: []const LspDiagnostic = (&entry.diagnostic)[0..1];
    const rule = entry.record.rule;
    if (entry.edit) |*edit| {
        const title = try s.text.format("zanity: fix {s}", .{rule});
        try s.actions.add(.{ .title = title, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = true, .edit = .{ .changes = .{ .uri = file.uri, .edits = edit[0..1] } }, .command = .{ .title = title, .command = fixed_command, .arguments = target } });
    }
    // A judgement of the model is marked, so it stops being reported for that function.
    const judged = if (rules.find(rule)) |r| r.question.len > 0 else false;
    if (judged and self.services.store != null) {
        const dismiss = try s.text.format("zanity: {s} is not a problem here", .{rule});
        try s.actions.add(.{ .title = dismiss, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = false, .command = .{ .title = dismiss, .command = dismiss_command, .arguments = target } });
        const confirm = try s.text.format("zanity: confirm {s} here", .{rule});
        try s.actions.add(.{ .title = confirm, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = false, .command = .{ .title = confirm, .command = confirm_command, .arguments = target } });
    } else {
        const title = try s.text.format("zanity: flag {s} here as a false positive", .{rule});
        try s.actions.add(.{ .title = title, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = false, .command = .{ .title = title, .command = flag_command, .arguments = target } });
    }
    if (s.actions.len - before > 3) assert.panic("offered {d} actions for one {s} finding; offer at most a fix and a flag or two marks", .{ s.actions.len - before, rule });
}

/// One action with every fix in the file whose edit does not overlap an earlier one, as
/// `--fix` applies them; null when the file has none.
pub fn fixAll(self: *LanguageServer, file: *const CheckedFile) !?Action {
    const s = &self.scratch;
    if (s.fixes.len != 0 or s.edits.len != 0) assert.panic("fix-all started with {d} fixes and {d} edits left over; clear both lists before starting", .{ s.fixes.len, s.edits.len });
    for (self.current.entriesOf(file)) |entry| if (entry.edit != null) try s.fixes.add(entry);
    std.mem.sort(DiagnosticEntry, s.fixes.items(), {}, editsFirst);
    var end: ?Position = null;
    for (s.fixes.items()) |entry| {
        const edit = entry.edit orelse unreachable;
        if (end) |e| if (isBefore(edit.range.start, e)) continue;
        try s.edits.add(edit);
        try s.diagnostics.add(entry.diagnostic);
        end = edit.range.end;
    }
    if (s.edits.len == 0) return null;
    const title = try s.text.format("zanity: fix all {d} in this file", .{s.edits.len});
    if (s.edits.len > s.fixes.len) assert.panic("fix-all made {d} edits from {d} fixes; each fix has one edit", .{ s.edits.len, s.fixes.len });
    return .{ .title = title, .kind = fix_all, .diagnostics = s.diagnostics.items(), .isPreferred = false, .edit = .{ .changes = .{ .uri = file.uri, .edits = s.edits.items() } } };
}

/// Checks an action's finding coordinates and checked-view lifetime before changing labels
/// or diagnostics. Fix-applied acknowledgements describe an edit the editor already made.
pub fn acceptsCommandTarget(self: *LanguageServer, id: json.Value, command: []const u8, target: Target) !bool {
    const text = &self.scratch.text;
    if (self.outbox.len == 0) assert.panic("validating command {s} without reply storage; call initLanguageServer() first", .{command});
    if (text.buffer.len == 0) assert.panic("validating command {s} without message storage; initialize the request scratch first", .{command});
    if (target.path.len == 0 or target.rule.len == 0 or target.message.len == 0) {
        try self.sendError(id, invalid_params, "Use the nonempty path, rule and message from a finding offered by a code action.");
        return false;
    }
    if (target.line == 0 or target.column == 0) {
        try self.sendError(id, invalid_params, try text.format("The finding is at line {d} column {d}, but both count from 1.", .{ target.line, target.column }));
        return false;
    }
    // This acknowledgement only records telemetry for an edit already applied by the
    // editor; autosave may have advanced its check or left the document dirty meanwhile.
    if (std.mem.eql(u8, command, fixed_command)) return true;
    if (!self.current.isCurrentTarget(target) or self.isDirty(target.path)) {
        try self.sendError(id, invalid_params, try text.format("The code action for {s} no longer matches checked code; save the file and request fresh code actions before marking or dismissing a finding.", .{target.path}));
        return false;
    }
    return true;
}

/// Runs a command one of the server's code actions named.
pub fn execute(self: *LanguageServer, id: json.Value, params: json.Value) !void {
    if (self.services.version.len == 0) assert.panic("running a command with no version to record it under", .{});
    const Call = struct { command: []const u8, arguments: []const Target };
    const call = json.parseFromValueLeaky(Call, self.scratch.parse.allocator(), params, .{ .ignore_unknown_fields = true }) catch Call{ .command = "", .arguments = &.{} };
    if (call.arguments.len != 1) return self.sendError(id, invalid_params, try self.scratch.text.format("zanity's commands take one argument, the finding its code action named, not {d}.", .{call.arguments.len}));
    const target = call.arguments[0];
    if (!try acceptsCommandTarget(self, id, call.command, target)) return;
    if (std.mem.eql(u8, call.command, flag_command)) {
        try flag(self, target);
    } else if (std.mem.eql(u8, call.command, confirm_command) or std.mem.eql(u8, call.command, dismiss_command)) {
        try markFinding(self, target, std.mem.eql(u8, call.command, confirm_command));
    } else if (std.mem.eql(u8, call.command, fixed_command)) {
        const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
        try self.trace("fix applied", started, &attributesOf(target, ""));
    } else return self.sendError(id, -32601, try self.scratch.text.format("zanity has no command {s}; it has {s}, {s}, {s} and {s}.", .{ call.command, flag_command, fixed_command, confirm_command, dismiss_command }));
    try self.respond(id, no_value);
    if (target.line == 0 or target.column == 0) assert.panic("ran {s} for a finding at line {d} column {d}; such a target is refused above", .{ call.command, target.line, target.column });
}

/// Marks a --infer finding real or not a problem in the store, from the answer kept where it
/// was reported, and hides one that is not a problem.
pub fn markFinding(self: *LanguageServer, target: Target, real: bool) !void {
    if (target.rule.len == 0) assert.panic("marking a finding with no rule at {s}:{d}", .{ target.path, target.line });
    const kept = self.services.store orelse return self.show(1, "zanity: there is no store to keep the mark in; check ZANITY_STORE names a writable file.");
    var found: ?store.Digest = null;
    try kept.eachObserved(.{ .rule = target.rule, .path = target.path, .line = target.line }, &found, firstUnit);
    const unit = found orelse return self.show(2, try self.scratch.text.format("zanity: no answer is kept for {s} at {s}:{d}; check it again with --infer first.", .{ target.rule, target.path, target.line }));
    try kept.label(target.rule, unit, real);
    if (try kept.labelled(target.rule, unit) != real) assert.panic("marked {s} at {s}:{d}, but the store doesn't say so", .{ target.rule, target.path, target.line });
    if (!real) try refreshDiagnosticsAfterDismissal(self, target);
    try self.show(3, try self.scratch.text.format("zanity: marked {s} at {s}:{d} {s}.", .{ target.rule, target.path, target.line, if (real) "as real" else "not a problem; it won't be reported for this function again" }));
}

/// Republishes a current action's diagnostic view after an editor dismissal. Publication
/// replaces the editor's whole list, so retries in the same generation converge on that view.
pub fn refreshDiagnosticsAfterDismissal(self: *LanguageServer, target: Target) !void {
    if (self.outbox.len == 0) assert.panic("publishing a dismissal for {s} without reply storage; call initLanguageServer() first", .{target.path});
    const view = self.current.dismissDiagnostic(target) orelse return;
    if (view.uri.len == 0) assert.panic("dismissal of {s} produced no document URI; retain each checked file's URI when adding results", .{target.path});
    try self.publish(view.uri, view.entries);
}

/// Keeps a finding the editor flagged as a false positive, sends it as a span, and hides it.
pub fn flag(self: *LanguageServer, target: Target) !void {
    if (target.rule.len == 0) assert.panic("flagging a finding with no rule at {s}:{d}; take the rule from a published diagnostic", .{ target.path, target.line });
    const file = self.current.find(target.path) orelse return;
    const entries = self.current.entriesOf(file);
    const index = for (entries, 0..) |entry, i| {
        const r = entry.record;
        if (r.line == target.line and r.column == target.column and std.mem.eql(u8, r.rule, target.rule) and std.mem.eql(u8, r.message, target.message)) break i;
    } else return;
    const code = std.mem.trim(u8, lineOf(file.source, target.line - 1), " \t\r");
    const kept = keepFlag(self, target, code);
    const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
    try self.trace("false positive", started, &attributesOf(target, code));
    try self.flagged.add(flagKey(target.path, target.rule, target.message));
    std.mem.copyForwards(DiagnosticEntry, entries[index..], entries[index + 1 ..]);
    file.count -= 1;
    try self.publish(file.uri, entries[0 .. entries.len - 1]);
    try self.show(3, try self.scratch.text.format("zanity: flagged {s} as a false positive; {s}.", .{ target.rule, kept }));
    if (file.count + 1 != entries.len) assert.panic("{s} has {d} findings after hiding one of {d}; remove exactly the matching finding in hide()", .{ file.path, file.count, entries.len });
}

/// Keeps the flag in the store, and says where it went.
pub fn keepFlag(self: *LanguageServer, target: Target, code: []const u8) []const u8 {
    if (target.path.len == 0) assert.panic("keeping a flag of {s} with no path; pass the finding's file path", .{target.rule});
    const s = self.services.store orelse return "it is hidden for this session only, as zanity's store could not be opened";
    s.keepFalsePositive(.{ .path = target.path, .line = target.line, .column = target.column, .rule = target.rule, .message = target.message, .code = code, .version = self.services.version }) catch |e| {
        return self.scratch.text.format("it is hidden for this session only, as {s} would not keep it: {t}", .{ s.path, e }) catch "it is hidden for this session only";
    };
    if (s.path.len == 0) assert.panic("kept a flag in a store with no path; fix initStore() to retain its database path", .{});
    return self.scratch.text.format("kept in {s}'s false_positives table", .{s.path}) catch "kept in zanity's store";
}

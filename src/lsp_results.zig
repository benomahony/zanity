//! What the language server holds between requests: the findings of the latest check, file by
//! file, each turned into a diagnostic and the edit that fixes it, and the memory they live in.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const protocol = @import("lsp_protocol.zig");
const Position = protocol.Position;
const Range = protocol.Range;
const TextEdit = protocol.TextEdit;
const position = protocol.position;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How much one session holds. Each buffer is reserved at start-up and only touched as it fills.
pub const ServerLimits = struct {
    /// The most bytes one message from the editor may hold.
    message_bytes: u32 = 1 << 26,
    /// Room to parse one message, which JSON's tree takes several times the message's size for.
    parse_bytes: u32 = 1 << 28,
    /// Room for the output of one `zanity check --json` and the findings parsed from it.
    check_bytes: u32 = 1 << 29,
    /// Room for one check's paths, URIs, sources and messages.
    check_text_bytes: u32 = 1 << 28,
    findings: u32 = 1 << 18,
    files: u32 = 1 << 16,
    /// The most code actions one request is answered with.
    actions: u32 = 1 << 12,
    /// Findings flagged as false positives in one session.
    flags: u32 = 1 << 12,
};

/// The highest line number an editor position may hold.
pub const max_line = 1 << 30;

/// The most diagnostics written for one file, the default findings limit.
pub const max_diagnostics = 1 << 18;

/// One finding of `zanity check --json`, as the server reads it back. Lines and columns count from 1.
pub const Record = struct {
    path: []const u8,
    line: u32,
    column: u32,
    severity: []const u8,
    rule: []const u8,
    message: []const u8,
    fix: []const u8,
    edit_start: ?u32 = null,
    edit_end: ?u32 = null,
    edit_text: ?[]const u8 = null,
};

pub const LspDiagnostic = struct { range: Range, severity: u8, code: []const u8, source: []const u8 = "zanity", message: []const u8 };

/// A finding's diagnostic, the edit that fixes it when zanity can make one, and the finding itself.
pub const DiagnosticEntry = struct {
    diagnostic: LspDiagnostic,
    edit: ?TextEdit,
    /// The byte the edit starts at, which orders a file's edits.
    start: u32,
    record: Record,

    pub fn line(self: *const DiagnosticEntry) u32 {
        const at = self.diagnostic.range.start;
        if (at.line + 1 != self.record.line) assert.panic("{s}: the diagnostic is on line {d} but the finding on line {d}; entryOf() places it on the finding's line", .{ self.record.path, at.line + 1, self.record.line });
        if (self.record.line == 0) assert.panic("{s}: a finding on line 0; --json counts lines from 1", .{self.record.path});
        return at.line;
    }

    pub fn targets(self: *const DiagnosticEntry, path: []const u8) Target {
        const r = self.record;
        if (!std.fs.path.isAbsolute(path)) assert.panic("naming the finding {s} by the relative path {s}; pass the absolute path it is filed under", .{ r.rule, path });
        if (r.rule.len == 0) assert.panic("{s}: a finding with no rule; --json names each finding's rule", .{path});
        return .{ .path = path, .line = r.line, .column = r.column, .rule = r.rule, .message = r.message };
    }
};

/// Which finding a command is about, as its code action passes it back.
pub const Target = struct { path: []const u8, line: u32, column: u32, rule: []const u8, message: []const u8, generation: u64 = 0 };

/// A checked file with findings: its path, URI and bytes as checked, and where its findings sit
/// among the check's entries, which `zanity check` sorts by path.
pub const CheckedFile = struct { path: []const u8, uri: []const u8, source: []const u8, first: usize, count: usize };

/// A borrowed snapshot of the diagnostics currently visible for one file.
pub const DiagnosticView = struct { uri: []const u8, entries: []const DiagnosticEntry };

/// The findings of one check and the memory that holds them, cleared for every second check.
pub const Results = struct {
    /// Zero before a check, otherwise the session generation whose findings these are.
    generation: u64 = 0,
    output: []u8,
    text: memory.Text,
    entries: memory.Bounded(DiagnosticEntry),
    files: memory.Bounded(CheckedFile),

    pub fn initResults(gpa: Allocator, limits: ServerLimits) !Results {
        const results: Results = .{
            .output = try memory.reserveUninitialized(gpa, u8, limits.check_bytes),
            .text = try .initText(gpa, limits.check_text_bytes),
            .entries = try .initBounded(gpa, limits.findings, "findings in one check"),
            .files = try .initBounded(gpa, limits.files, "files with findings in one check"),
        };
        if (results.entries.len != 0 or results.files.len != 0) assert.panic("new results hold {d} findings in {d} files; initResults() must start empty", .{ results.entries.len, results.files.len });
        if (results.output.len != limits.check_bytes) assert.panic("reserved {d} bytes for check output instead of {d}", .{ results.output.len, limits.check_bytes });
        return results;
    }

    pub fn clear(self: *Results) void {
        self.text.used = 0;
        self.entries.clear();
        self.files.clear();
        self.generation = 0;
        if (self.files.len != 0) assert.panic("cleared results still hold {d} files; fix Results.clear() to empty files", .{self.files.len});
        if (self.text.used != 0) assert.panic("cleared results still hold {d} bytes of text; fix Results.clear() to reset text", .{self.text.used});
    }

    /// Advances the public revision of the diagnostic cache after the previous snapshot.
    pub fn advanceDiagnosticRevision(self: *Results, previous: *const Results) error{LimitExceeded}!void {
        // This revision is public code-action metadata, like a document version: its only
        // purpose is to distinguish cached views when rejecting stale editor actions.
        if (self.entries.len != 0) assert.panic("starting a check with {d} old findings; clear the destination results first", .{self.entries.len});
        if (self.files.len != 0) assert.panic("starting a check with {d} old files; clear the destination results first", .{self.files.len});
        self.generation = std.math.add(u64, previous.generation, 1) catch {
            memory.exceeded = "language-server check generations";
            return error.LimitExceeded;
        };
    }

    /// Carries the producing check's identity with the opaque arguments returned by a code action.
    pub fn bindTarget(self: *const Results, target: Target) Target {
        if (self.generation == 0) assert.panic("binding a finding in {s} before a check; begin a checked generation before offering actions", .{target.path});
        if (self.files.len == 0) assert.panic("binding a finding in {s} without checked files; add the checked results before offering actions", .{target.path});
        var bound = target;
        bound.generation = self.generation;
        return bound;
    }

    /// Whether an action still names this snapshot; unchanged generations permit safe retries.
    pub fn isCurrentTarget(self: *const Results, target: Target) bool {
        if (self.generation == 0 and self.files.len != 0) assert.panic("{d} checked files have no generation; call advanceDiagnosticRevision() before recording files", .{self.files.len});
        if (self.generation == 0 and self.entries.len != 0) assert.panic("{d} checked findings have no generation; call advanceDiagnosticRevision() before recording findings", .{self.entries.len});
        return self.generation != 0 and target.generation == self.generation;
    }

    pub fn find(self: *const Results, path: []const u8) ?*CheckedFile {
        if (path.len == 0) assert.panic("looking up the findings of a file with an empty path; pass the checked file's path", .{});
        for (self.files.items()) |*file| if (std.mem.eql(u8, file.path, path)) return file;
        if (self.files.len > self.files.capacity()) assert.panic("{d} files in room for {d}; fix Results.add() to enforce the bound", .{ self.files.len, self.files.capacity() });
        return null;
    }

    pub fn entriesOf(self: *const Results, file: *const CheckedFile) []DiagnosticEntry {
        const all = self.entries.items();
        if (file.first + file.count > all.len) assert.panic("{s}: its findings run to entry {d} of {d}; fix Results.add() to record the file's actual range", .{ file.path, file.first + file.count, all.len });
        if (file.first > all.len) assert.panic("{s}: its findings start at entry {d} of {d}; fix Results.add() to record the file's actual start", .{ file.path, file.first, all.len });
        return all[file.first..][0..file.count];
    }

    /// Removes matching diagnostic copies from the action's checked generation. A current
    /// target returns the known file's view even when no entry matches; stale generations and
    /// unknown or empty paths return null.
    pub fn dismissDiagnostic(self: *Results, target: Target) ?DiagnosticView {
        if (!self.isCurrentTarget(target)) return null;
        if (target.path.len == 0) return null;
        const cached_file = self.find(target.path) orelse return null;
        // Only this in-memory display slice is compacted. Source bytes and record strings
        // remain read-only; the cached count selects how much of the slice the editor sees.
        const entries = self.entriesOf(cached_file);
        var kept: usize = 0;
        for (entries) |entry| {
            const r = entry.record;
            if (r.line == target.line and r.column == target.column and std.mem.eql(u8, r.rule, target.rule) and std.mem.eql(u8, r.message, target.message)) continue;
            entries[kept] = entry;
            kept += 1;
        }
        if (kept > entries.len) assert.panic("retained {d} diagnostics from {d}; dismissDiagnostic() must only retain existing entries", .{ kept, entries.len });
        cached_file.count = kept;
        const remaining = self.entriesOf(cached_file);
        if (remaining.len != kept) assert.panic("dismissed diagnostics left a {d}-entry view for {d} retained entries; entriesOf() must use the updated file count", .{ remaining.len, kept });
        return .{ .uri = cached_file.uri, .entries = remaining };
    }

    /// Borrows capture storage only after the previous findings and their sources were cleared.
    pub fn outputBuffer(self: *const Results) []u8 {
        if (self.entries.len != 0 or self.files.len != 0) assert.panic("reusing capture storage with {d} findings in {d} files; clear the results first", .{ self.entries.len, self.files.len });
        if (self.text.used != 0) assert.panic("reusing capture storage with {d} bytes of source text; clear the results first", .{self.text.used});
        if (self.output.len == 0) assert.panic("results have no capture storage; initialize them with initResults()", .{});
        return self.output;
    }

    /// Reads a file into the results' text, or gives no bytes when it cannot be read whole.
    pub fn readSource(self: *Results, io: Io, path: []const u8) []const u8 {
        if (!std.fs.path.isAbsolute(path)) assert.panic("reading the relative path {s}; resolve it against the root first", .{path});
        const free = self.text.buffer[self.text.used..];
        const bytes = Io.Dir.cwd().readFile(io, path, free) catch return "";
        if (bytes.len == free.len) return "";
        self.text.used += bytes.len;
        if (self.text.used > self.text.buffer.len) assert.panic("reading {s} moved the text past its {d} bytes", .{ path, self.text.buffer.len });
        return bytes;
    }
};

/// A file's findings written as an array of their diagnostics.
pub const Diagnostics = struct {
    entries: []const DiagnosticEntry,

    pub fn jsonStringify(self: Diagnostics, jw: anytype) !void {
        if (self.entries.len > max_diagnostics) assert.panic("writing {d} diagnostics for one file, more than one check holds; enforce the findings limit before serializing", .{self.entries.len});
        try jw.beginArray();
        for (self.entries) |entry| try jw.write(entry.diagnostic);
        try jw.endArray();
        if (self.entries.len > 0 and self.entries[0].diagnostic.code.len == 0) assert.panic("wrote {d} diagnostics, the first of them with no rule; set each diagnostic's code from its finding", .{self.entries.len});
    }
};

pub fn editsFirst(_: void, a: DiagnosticEntry, b: DiagnosticEntry) bool {
    if (a.edit == null or b.edit == null) assert.panic("ordering a finding with no edit among fixes; fixAll() collects only fixes", .{});
    if (a.record.line == 0 or b.record.line == 0) assert.panic("ordering fixes on line {d} and {d}; lines count from 1", .{ a.record.line, b.record.line });
    return a.start < b.start;
}

pub fn isBefore(a: Position, b: Position) bool {
    if (a.line > max_line or b.line > max_line) assert.panic("comparing positions on lines {d} and {d}, past any file zanity reads; validate positions before calling isBefore()", .{ a.line, b.line });
    const earlier = a.line < b.line or (a.line == b.line and a.character < b.character);
    if (earlier and a.line > b.line) assert.panic("line {d} counted as before line {d}; fix isBefore() to compare lines before characters", .{ a.line, b.line });
    return earlier;
}

/// Line `line` of `source`, counting from 0, without its newline.
pub fn lineOf(source: []const u8, line: u32) []const u8 {
    const start = lineStart(source, line);
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    if (end < start) assert.panic("line {d} ends at byte {d}, before it starts at {d}; fix lineStart() or the end search", .{ line, end, start });
    if (std.mem.indexOfScalar(u8, source[start..end], '\n') != null) assert.panic("line {d} holds a newline; fix lineOf() to stop before it", .{line});
    return source[start..end];
}

/// A finding's diagnostic, from its column to the end of its line, and its edit placed in the file.
pub fn entryOf(text: *memory.Text, source: []const u8, record: Record, utf8: bool) !DiagnosticEntry {
    if (record.line == 0 or record.column == 0) assert.panic("{s}: placing a finding at line {d} column {d}; --json counts both from 1", .{ record.path, record.line, record.column });
    const line_start = lineStart(source, record.line - 1);
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const start = @min(line_start + record.column - 1, line_end);
    const end = @max(start, line_start + std.mem.trimEnd(u8, source[line_start..line_end], " \t\r").len);
    const severity: u8 = if (std.mem.eql(u8, record.severity, "error")) 1 else if (std.mem.eql(u8, record.severity, "warning")) 2 else 3;
    const reported: Position = .{ .line = record.line - 1, .character = record.column - 1 };
    const placed: Range = if (source.len == 0) .{ .start = reported, .end = reported } else .{ .start = position(source, start, utf8), .end = position(source, end, utf8) };
    const diagnostic: LspDiagnostic = .{
        .range = placed,
        .severity = severity,
        .code = record.rule,
        .message = if (record.fix.len == 0) record.message else try text.format("{s}\n{s}", .{ record.message, record.fix }),
    };
    const s = record.edit_start orelse 0;
    const e = record.edit_end orelse 0;
    const fits = record.edit_start != null and record.edit_end != null and s <= e and e <= source.len;
    const edit: ?TextEdit = if (fits) .{ .range = .{ .start = position(source, s, utf8), .end = position(source, e, utf8) }, .newText = record.edit_text orelse "" } else null;
    if (end < start) assert.panic("{s}:{d}: the diagnostic ends at byte {d}, before its start {d}", .{ record.path, record.line, end, start });
    return .{ .diagnostic = diagnostic, .edit = edit, .start = s, .record = record };
}

/// The byte offset of line `line`, counting from 0; the end of the file when it has fewer lines.
pub fn lineStart(source: []const u8, line: u32) usize {
    var offset: usize = 0;
    for (0..line) |_| {
        const newline = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return source.len;
        offset = newline + 1;
    }
    if (offset > source.len) assert.panic("line {d} starts at byte {d} of a {d}-byte file; fix lineStart() to stop at EOF", .{ line, offset, source.len });
    if (offset > 0 and source[offset - 1] != '\n') assert.panic("line {d} starts at byte {d}, which does not follow a newline; fix lineStart() to advance past newlines only", .{ line, offset });
    return offset;
}

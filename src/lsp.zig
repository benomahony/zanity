//! `zanity lsp`: a language server on stdin and stdout. It runs `zanity check --json` over the
//! workspace when the editor connects and on every save, publishes each finding as a diagnostic,
//! and offers the edits `--fix` would make as code actions. A finding can be flagged as a false
//! positive from the editor: it is kept in zanity's store and, with telemetry on, sent as a span,
//! so the rule can be made more precise, and it stays hidden for the rest of the session.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const nameHash = @import("facts.zig").nameHash;
const store = @import("store.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const Attribute = @import("telemetry.zig").Attribute;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

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

/// JSON's null, as a result and as what a missing member reads as.
const no_value: json.Value = .null;
/// The most header lines one message may start with; LSP defines two.
const max_header_lines = 16;
/// The most messages one session handles; an editor sends far fewer in a working lifetime.
const max_messages = 1 << 40;

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

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const TextEdit = struct { range: Range, newText: []const u8 };
pub const LspDiagnostic = struct { range: Range, severity: u8, code: []const u8, source: []const u8 = "zanity", message: []const u8 };

/// A finding's diagnostic, the edit that fixes it when zanity can make one, and the finding itself.
const Entry = struct {
    diagnostic: LspDiagnostic,
    edit: ?TextEdit,
    /// The byte the edit starts at, which orders a file's edits.
    start: u32,
    record: Record,

    fn line(self: *const Entry) u32 {
        const at = self.diagnostic.range.start;
        if (at.line + 1 != self.record.line) assert.panic("{s}: the diagnostic is on line {d} but the finding on line {d}; entryOf() places it on the finding's line", .{ self.record.path, at.line + 1, self.record.line });
        if (self.record.line == 0) assert.panic("{s}: a finding on line 0; --json counts lines from 1", .{self.record.path});
        return at.line;
    }

    fn targets(self: *const Entry, path: []const u8) Target {
        const r = self.record;
        if (!std.fs.path.isAbsolute(path)) assert.panic("naming the finding {s} by the relative path {s}; pass the absolute path it is filed under", .{ r.rule, path });
        if (r.rule.len == 0) assert.panic("{s}: a finding with no rule; --json names each finding's rule", .{path});
        return .{ .path = path, .line = r.line, .column = r.column, .rule = r.rule, .message = r.message };
    }
};

/// Which finding a command is about, as its code action passes it back.
const Target = struct { path: []const u8, line: u32, column: u32, rule: []const u8, message: []const u8 };

/// The commands the server's code actions run.
const flag_command = "zanity.flagFalsePositive";
const fixed_command = "zanity.fixApplied";
/// The code action kind that applies every fix in a file.
const fix_all = "source.fixAll.zanity";

/// A checked file with findings: its path, URI and bytes as checked, and where its findings sit
/// among the check's entries, which `zanity check` sorts by path.
const CheckedFile = struct { path: []const u8, uri: []const u8, source: []const u8, first: usize, count: usize };

/// The findings of one check and the memory that holds them, cleared for every second check.
const Results = struct {
    output: []u8,
    text: memory.Text,
    entries: memory.Bounded(Entry),
    files: memory.Bounded(CheckedFile),

    fn initResults(gpa: Allocator, limits: ServerLimits) !Results {
        const results: Results = .{
            .output = try memory.reserve(gpa, u8, limits.check_bytes),
            .text = try .initText(gpa, limits.check_text_bytes),
            .entries = try .initBounded(gpa, limits.findings, "findings in one check"),
            .files = try .initBounded(gpa, limits.files, "files with findings in one check"),
        };
        if (results.entries.len != 0 or results.files.len != 0) assert.panic("new results hold {d} findings in {d} files; initResults() must start empty", .{ results.entries.len, results.files.len });
        if (results.output.len != limits.check_bytes) assert.panic("reserved {d} bytes for check output instead of {d}", .{ results.output.len, limits.check_bytes });
        return results;
    }

    fn clear(self: *Results) void {
        self.text.used = 0;
        self.entries.clear();
        self.files.clear();
        if (self.files.len != 0) assert.panic("cleared results still hold {d} files", .{self.files.len});
        if (self.text.used != 0) assert.panic("cleared results still hold {d} bytes of text", .{self.text.used});
    }

    fn find(self: *const Results, path: []const u8) ?*CheckedFile {
        if (path.len == 0) assert.panic("looking up the findings of a file with an empty path", .{});
        for (self.files.items()) |*file| if (std.mem.eql(u8, file.path, path)) return file;
        if (self.files.len > self.files.capacity()) assert.panic("{d} files in room for {d}", .{ self.files.len, self.files.capacity() });
        return null;
    }

    fn entriesOf(self: *const Results, file: *const CheckedFile) []Entry {
        const all = self.entries.items();
        if (file.first + file.count > all.len) assert.panic("{s}: its findings run to entry {d} of {d}", .{ file.path, file.first + file.count, all.len });
        if (file.first > all.len) assert.panic("{s}: its findings start at entry {d} of {d}", .{ file.path, file.first, all.len });
        return all[file.first..][0..file.count];
    }

    /// Reads a file into the results' text, or gives no bytes when it cannot be read whole.
    fn readSource(self: *Results, io: Io, path: []const u8) []const u8 {
        if (!std.fs.path.isAbsolute(path)) assert.panic("reading the relative path {s}; resolve it against the root first", .{path});
        const free = self.text.buffer[self.text.used..];
        const bytes = Io.Dir.cwd().readFile(io, path, free) catch return "";
        if (bytes.len == free.len) return "";
        self.text.used += bytes.len;
        if (self.text.used > self.text.buffer.len) assert.panic("reading {s} moved the text past its {d} bytes", .{ path, self.text.buffer.len });
        return bytes;
    }
};

/// The memory a request is answered from, cleared after each message.
const Scratch = struct {
    parse: std.heap.FixedBufferAllocator,
    text: memory.Text,
    actions: memory.Bounded(Action),
    targets: memory.Bounded(Target),
    /// A file's fixes in the order fix-all applies them, and the edits and diagnostics it keeps.
    fixes: memory.Bounded(Entry),
    edits: memory.Bounded(TextEdit),
    diagnostics: memory.Bounded(LspDiagnostic),

    fn initScratch(gpa: Allocator, limits: ServerLimits) !Scratch {
        const scratch: Scratch = .{
            .parse = .init(try memory.reserve(gpa, u8, limits.parse_bytes)),
            .text = try .initText(gpa, limits.message_bytes),
            .actions = try .initBounded(gpa, limits.actions, "code actions in one answer"),
            .targets = try .initBounded(gpa, limits.actions, "code actions in one answer"),
            .fixes = try .initBounded(gpa, limits.findings, "fixes in one file"),
            .edits = try .initBounded(gpa, limits.findings, "edits fix-all makes in one file"),
            .diagnostics = try .initBounded(gpa, limits.findings, "findings fix-all fixes in one file"),
        };
        if (scratch.parse.end_index != 0) assert.panic("new scratch memory has {d} bytes in use", .{scratch.parse.end_index});
        if (scratch.text.used != 0) assert.panic("new scratch text has {d} bytes in use", .{scratch.text.used});
        return scratch;
    }

    fn clear(self: *Scratch) void {
        self.parse.reset();
        self.text.used = 0;
        inline for (.{ "actions", "targets", "fixes", "edits", "diagnostics" }) |name| @field(self, name).clear();
        if (self.parse.end_index != 0) assert.panic("scratch memory has {d} bytes in use after clear()", .{self.parse.end_index});
        if (self.actions.len != 0) assert.panic("scratch holds {d} code actions after clear()", .{self.actions.len});
    }
};

/// What the server needs besides the editor: this executable to run checks with, its version,
/// and where flags and spans go when they can.
pub const Services = struct {
    exe: []const u8,
    version: []const u8,
    store: ?*const store.Store = null,
    telemetry: ?*Telemetry = null,
};

pub const LanguageServer = struct {
    io: Io,
    out: *Io.Writer,
    services: Services,
    /// The workspace's root, where checks run and which their paths are relative to.
    root: []const u8 = ".",
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    /// Whether positions count bytes, as the editor agreed; otherwise they count UTF-16 code units.
    utf8: bool = false,
    inbox: []u8,
    outbox: []u8,
    scratch: Scratch,
    current: Results,
    /// The check before `current`, whose files are cleared when the next check no longer reports them.
    previous: Results,
    /// Files edited since the check, by `pathKey()`, whose edits would land in the wrong place.
    dirty: memory.Bounded(u64),
    /// Findings flagged as false positives this session, by `flagKey()`, which later checks hide.
    flagged: memory.Bounded(u64),
    shut_down: bool = false,

    pub fn initLanguageServer(gpa: Allocator, io: Io, out: *Io.Writer, services: Services) !LanguageServer {
        if (services.exe.len == 0) assert.panic("the language server was given no executable to run checks with; runLsp() passes this one's path", .{});
        if (services.version.len == 0) assert.panic("the language server was given an empty version; pass the app's version, which is dev or the release's", .{});
        const limits: ServerLimits = .{};
        return .{
            .io = io,
            .out = out,
            .services = services,
            .inbox = try memory.reserve(gpa, u8, limits.message_bytes),
            .outbox = try memory.reserve(gpa, u8, limits.message_bytes),
            .scratch = try .initScratch(gpa, limits),
            .current = try .initResults(gpa, limits),
            .previous = try .initResults(gpa, limits),
            .dirty = try .initBounded(gpa, limits.files, "files edited since the last check"),
            .flagged = try .initBounded(gpa, limits.flags, "findings flagged in one session"),
        };
    }

    /// Answers the editor until it says `exit` or closes stdin. Returns whether it shut down first,
    /// as the protocol asks of a clean exit.
    pub fn serve(self: *LanguageServer, in: *Io.Reader) !bool {
        if (self.inbox.len == 0) assert.panic("serving with no room for a message; initLanguageServer() reserves it", .{});
        if (self.outbox.len == 0) assert.panic("serving with no room to answer; initLanguageServer() reserves it", .{});
        for (0..max_messages) |_| {
            self.scratch.clear();
            const body = try readMessage(in, self.inbox) orelse return self.shut_down;
            const parsed = json.parseFromSliceLeaky(json.Value, self.scratch.parse.allocator(), body, .{}) catch {
                try self.sendError(.null, -32700, try self.scratch.text.format("The {d}-byte message is not JSON.", .{body.len}));
                continue;
            };
            const method = stringOf(member(parsed, "method")) orelse continue;
            if (std.mem.eql(u8, method, "exit")) return self.shut_down;
            const id = member(parsed, "id");
            self.handle(method, id, member(parsed, "params") orelse no_value) catch |e| try self.reportFailure(method, id, e);
            try self.flushTelemetry();
        }
        assert.panic("handled {d} messages without the editor exiting; no editor session sends that many", .{max_messages});
    }

    fn handle(self: *LanguageServer, method: []const u8, request: ?json.Value, params: json.Value) !void {
        if (method.len == 0) assert.panic("handling a message with an empty method; serve() passes the method the message names", .{});
        const id = request orelse no_value;
        const is = std.mem.eql;
        if (is(u8, method, "initialize")) return self.initialize(id, params);
        if (is(u8, method, "initialized")) return self.check("initialized");
        if (is(u8, method, "shutdown")) {
            self.shut_down = true;
            return self.respond(id, no_value);
        }
        if (is(u8, method, "textDocument/didOpen")) return self.republish(params);
        if (is(u8, method, "textDocument/didChange")) return self.markDirty(params);
        if (is(u8, method, "textDocument/didSave")) return self.check("save");
        if (is(u8, method, "textDocument/codeAction")) return self.codeActions(id, params);
        if (is(u8, method, "workspace/executeCommand")) return self.execute(id, params);
        if (request != null) try self.sendError(id, -32601, try self.scratch.text.format("zanity does not handle the request {s}.", .{method}));
        if (self.root.len == 0) assert.panic("the workspace root is empty after {s}; initialize() falls back to the working directory", .{method});
    }

    /// Tells the editor a message could not be handled, and goes on to the next.
    fn reportFailure(self: *LanguageServer, method: []const u8, id: ?json.Value, e: anyerror) !void {
        if (method.len == 0) assert.panic("reporting a failure of a message with no method", .{});
        const message = try self.scratch.text.format("zanity could not handle {s}: {t}{s}{s}.", .{ method, e, if (e == error.LimitExceeded) ", as it ran out of room for " else "", if (e == error.LimitExceeded) memory.exceeded else "" });
        if (id) |request| try self.sendError(request, -32603, message) else try self.show(1, message);
        if (message.len < method.len) assert.panic("the failure of {s} was reported as '{s}'", .{ method, message });
    }

    fn initialize(self: *LanguageServer, id: json.Value, params: json.Value) !void {
        if (self.current.files.len != 0) assert.panic("initialize arrived after a check of {d} files; the editor sends it first", .{self.current.files.len});
        self.root = try self.rootOf(params);
        self.utf8 = offersUtf8(params);
        try self.respond(id, .{
            .capabilities = .{
                .positionEncoding = if (self.utf8) "utf-8" else "utf-16",
                .textDocumentSync = .{ .openClose = true, .change = 2, .save = true },
                .codeActionProvider = .{ .codeActionKinds = &[_][]const u8{ "quickfix", fix_all } },
                .executeCommandProvider = .{ .commands = &[_][]const u8{ flag_command, fixed_command } },
            },
            .serverInfo = .{ .name = "zanity", .version = self.services.version },
        });
        if (!std.fs.path.isAbsolute(self.root)) assert.panic("the workspace root {s} is relative; rootOf() returns an absolute path", .{self.root});
    }

    /// The workspace root the editor names, as a path; the working directory when it names none.
    fn rootOf(self: *LanguageServer, params: json.Value) ![]const u8 {
        if (self.current.files.len != 0) assert.panic("choosing the workspace root after a check of {d} files", .{self.current.files.len});
        const folders = member(params, "workspaceFolders") orelse no_value;
        const listed: []const json.Value = if (folders == .array) folders.array.items else &.{};
        const first = if (listed.len > 0) listed[0] else no_value;
        const uri = stringOf(member(params, "rootUri")) orelse stringOf(member(first, "uri")) orelse "";
        const named = try pathOf(&self.scratch.text, uri) orelse stringOf(member(params, "rootPath"));
        const root = if (named) |path| path else self.root_buffer[0..try Io.Dir.cwd().realPath(self.io, &self.root_buffer)];
        if (root.len > self.root_buffer.len) return error.NameTooLong;
        @memmove(self.root_buffer[0..root.len], root);
        if (root.len == 0) assert.panic("the editor named an empty workspace root", .{});
        return self.root_buffer[0..root.len];
    }

    /// Runs `zanity check` over the workspace and publishes what changed since the last check.
    /// When the check fails, the last one's findings stay.
    fn check(self: *LanguageServer, trigger: []const u8) !void {
        if (trigger.len == 0) assert.panic("checking with no trigger; name what started the check", .{});
        const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
        self.previous.clear();
        const records = try self.runCheck(&self.previous) orelse return;
        std.mem.swap(Results, &self.current, &self.previous);
        self.dirty.clear();
        var fixable: usize = 0;
        for (records) |record| {
            if (self.isFlagged(record)) continue;
            try self.add(record);
            fixable += @intFromBool(record.edit_start != null);
        }
        for (self.current.files.items()) |*file| try self.publish(file.uri, self.current.entriesOf(file));
        for (self.previous.files.items()) |file| if (self.current.find(file.path) == null) try self.publish(file.uri, &.{});
        const shown = self.current.entries.len;
        try self.trace("check", started, &.{
            .{ .key = "zanity.trigger", .value = .{ .string = trigger } },
            .{ .key = "zanity.root", .value = .{ .string = self.root } },
            .{ .key = "zanity.findings", .value = .{ .int = @intCast(shown) } },
            .{ .key = "zanity.fixable", .value = .{ .int = @intCast(fixable) } },
            .{ .key = "zanity.flagged_hidden", .value = .{ .int = @intCast(records.len - shown) } },
            .{ .key = "zanity.files", .value = .{ .int = @intCast(self.current.files.len) } },
        });
        if (shown > records.len) assert.panic("{d} findings shown from {d} reported; add() files each finding once", .{ shown, records.len });
    }

    /// Runs this executable as `zanity check --json` in the root and reads its findings back into
    /// `into`; null, after telling the editor why, when the check fails.
    fn runCheck(self: *LanguageServer, into: *Results) !?[]const Record {
        if (into.entries.len != 0) assert.panic("checking into results that hold {d} findings; clear them first", .{into.entries.len});
        var output: std.heap.FixedBufferAllocator = .init(into.output);
        const result = std.process.run(output.allocator(), self.io, .{
            .argv = &.{ self.services.exe, "check", ".", "--json", "--quiet", "--no-color" },
            .cwd = .{ .path = self.root },
            .stdout_limit = .limited(into.output.len / 2),
            .stderr_limit = .limited(1 << 16),
        }) catch |e| {
            try self.show(1, try self.scratch.text.format("zanity could not run {s} check in {s}: {t}.", .{ self.services.exe, self.root, e }));
            return null;
        };
        const ok = switch (result.term) {
            .exited => |code| code <= 1,
            else => false,
        };
        if (!ok) {
            try self.show(1, try self.scratch.text.format("zanity check failed in {s}: {s}", .{ self.root, std.mem.trim(u8, result.stderr, " \n") }));
            return null;
        }
        const records = json.parseFromSliceLeaky([]const Record, output.allocator(), result.stdout, .{ .ignore_unknown_fields = true }) catch |e| {
            try self.show(1, try self.scratch.text.format("zanity could not read the findings of zanity check in {s}: {t}.", .{ self.root, e }));
            return null;
        };
        for (records) |r| if (r.line == 0 or r.column == 0) assert.panic("{s}: zanity check reported line {d} column {d}; --json counts both from 1", .{ r.path, r.line, r.column });
        return records;
    }

    /// Files one finding under its path, reading the file the first time to place it.
    fn add(self: *LanguageServer, record: Record) !void {
        if (record.path.len == 0) assert.panic("a {s} finding with no path; --json gives each finding its file's path", .{record.rule});
        const results = &self.current;
        const path = try results.text.format("{s}/{s}", .{ self.root, record.path });
        const last = results.files.last();
        const same = if (last) |file| std.mem.eql(u8, file.path, path) else false;
        if (!same) try results.files.add(.{
            .path = path,
            .uri = try uriOf(&results.text, path),
            .source = results.readSource(self.io, path),
            .first = results.entries.len,
            .count = 0,
        });
        const file = results.files.last() orelse unreachable;
        try results.entries.add(try entryOf(&results.text, file.source, record, self.utf8));
        file.count += 1;
        if (file.first + file.count != results.entries.len) assert.panic("{s}: its findings are not together; zanity check sorts findings by path", .{record.path});
    }

    fn isFlagged(self: *const LanguageServer, record: Record) bool {
        if (record.rule.len == 0) assert.panic("{s}: a finding with no rule; --json names each finding's rule", .{record.path});
        if (self.flagged.len == 0) return false;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.root, record.path }) catch return false;
        const key = flagKey(path, record.rule, record.message);
        for (self.flagged.items()) |flagged| if (flagged == key) return true;
        if (self.flagged.len > self.flagged.capacity()) assert.panic("{d} flags in room for {d}", .{ self.flagged.len, self.flagged.capacity() });
        return false;
    }

    /// The last check's findings in the file a message names, or null when it names none with any.
    fn fileOf(self: *LanguageServer, params: json.Value) !?*CheckedFile {
        if (self.root.len == 0) assert.panic("looking up a file with no workspace root; initialize() sets it", .{});
        const uri = stringOf(member(member(params, "textDocument"), "uri")) orelse return null;
        const path = try pathOf(&self.scratch.text, uri) orelse return null;
        const file = self.current.find(path) orelse return null;
        if (!std.mem.eql(u8, file.path, path)) assert.panic("looked up {s} and found {s}", .{ path, file.path });
        return file;
    }

    /// Publishes the last check's findings again for a file the editor just opened.
    fn republish(self: *LanguageServer, params: json.Value) !void {
        const file = try self.fileOf(params) orelse return;
        if (file.count == 0) assert.panic("{s} is filed with no findings; add() files a path only with a finding", .{file.path});
        try self.publish(file.uri, self.current.entriesOf(file));
        if (file.uri.len == 0) assert.panic("published findings for {s} under an empty URI; add() records each file's URI", .{file.path});
    }

    fn markDirty(self: *LanguageServer, params: json.Value) !void {
        const file = try self.fileOf(params) orelse return;
        if (file.count == 0) assert.panic("{s} is filed with no findings; add() files a path only with a finding", .{file.path});
        const key = pathKey(file.path);
        for (self.dirty.items()) |dirty| if (dirty == key) return;
        try self.dirty.add(key);
        if (self.dirty.len == 0) assert.panic("marked {s} edited but the edited set is empty", .{file.path});
    }

    fn isDirty(self: *const LanguageServer, path: []const u8) bool {
        if (path.len == 0) assert.panic("asked whether a file with an empty path is edited", .{});
        const key = pathKey(path);
        for (self.dirty.items()) |dirty| if (dirty == key) return true;
        if (self.dirty.len > self.dirty.capacity()) assert.panic("{d} edited files in room for {d}", .{ self.dirty.len, self.dirty.capacity() });
        return false;
    }

    fn publish(self: *LanguageServer, uri: []const u8, entries: []const Entry) !void {
        if (uri.len == 0) assert.panic("publishing {d} diagnostics under an empty URI", .{entries.len});
        try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = Diagnostics{ .entries = entries } });
        if (self.outbox.len == 0) assert.panic("published with no room to write messages", .{});
    }

    /// Offers a quick fix and a false-positive flag for each finding on the requested lines, and
    /// one action that makes every fix in the file. A file edited since the last check gets none
    /// until it is saved, as its findings may have moved.
    fn codeActions(self: *LanguageServer, id: json.Value, params: json.Value) !void {
        const actions = &self.scratch.actions;
        if (actions.len != 0) assert.panic("answering a code action request with {d} actions left from the last", .{actions.len});
        const none = [_]Action{};
        const file = try self.fileOf(params) orelse return self.respond(id, &none);
        if (self.isDirty(file.path)) return self.respond(id, &none);
        const only = member(member(params, "context"), "only");
        const range = member(params, "range");
        const first = integerOf(member(member(range, "start"), "line")) orelse 0;
        const last = integerOf(member(member(range, "end"), "line")) orelse first;
        const entries = self.current.entriesOf(file);
        if (wants(only, "quickfix")) for (entries) |*entry| {
            if (entry.line() < first or entry.line() > last) continue;
            self.offerFixes(file, entry) catch break;
        };
        if (wants(only, fix_all)) if (try self.fixAll(file)) |action| try actions.add(action);
        try self.respond(id, actions.items());
        if (actions.len > 2 * entries.len + 1) assert.panic("offered {d} actions for {d} findings; offer at most a fix and a flag per finding and one for the file", .{ actions.len, entries.len });
    }

    /// Adds the finding's own fix, when it has one, and the action that flags it.
    fn offerFixes(self: *LanguageServer, file: *const CheckedFile, entry: *const Entry) !void {
        if (file.uri.len == 0) assert.panic("offering fixes in {s}, which has no URI; add() records each file's URI", .{file.path});
        const s = &self.scratch;
        const before = s.actions.len;
        try s.targets.add(entry.targets(file.path));
        const target = s.targets.items()[s.targets.len - 1 ..];
        const diagnostics: []const LspDiagnostic = (&entry.diagnostic)[0..1];
        const rule = entry.record.rule;
        if (entry.edit) |*edit| {
            const title = try s.text.format("zanity: fix {s}", .{rule});
            try s.actions.add(.{ .title = title, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = true, .edit = .{ .changes = .{ .uri = file.uri, .edits = edit[0..1] } }, .command = .{ .title = title, .command = fixed_command, .arguments = target } });
        }
        const title = try s.text.format("zanity: flag {s} here as a false positive", .{rule});
        try s.actions.add(.{ .title = title, .kind = "quickfix", .diagnostics = diagnostics, .isPreferred = false, .command = .{ .title = title, .command = flag_command, .arguments = target } });
        if (s.actions.len - before > 2) assert.panic("offered {d} actions for one {s} finding; offer at most a fix and a flag", .{ s.actions.len - before, rule });
    }

    /// One action with every fix in the file whose edit does not overlap an earlier one, as
    /// `--fix` applies them; null when the file has none.
    fn fixAll(self: *LanguageServer, file: *const CheckedFile) !?Action {
        const s = &self.scratch;
        if (s.fixes.len != 0 or s.edits.len != 0) assert.panic("fix-all started with {d} fixes and {d} edits left over", .{ s.fixes.len, s.edits.len });
        for (self.current.entriesOf(file)) |entry| if (entry.edit != null) try s.fixes.add(entry);
        std.mem.sort(Entry, s.fixes.items(), {}, editsFirst);
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

    /// Runs a command one of the server's code actions named.
    fn execute(self: *LanguageServer, id: json.Value, params: json.Value) !void {
        if (self.services.version.len == 0) assert.panic("running a command with no version to record it under", .{});
        const Call = struct { command: []const u8, arguments: []const Target };
        const call = json.parseFromValueLeaky(Call, self.scratch.parse.allocator(), params, .{ .ignore_unknown_fields = true }) catch Call{ .command = "", .arguments = &.{} };
        if (call.arguments.len != 1) return self.sendError(id, -32602, try self.scratch.text.format("zanity's commands take one argument, the finding its code action named, not {d}.", .{call.arguments.len}));
        const target = call.arguments[0];
        if (target.line == 0 or target.column == 0) return self.sendError(id, -32602, try self.scratch.text.format("The finding is at line {d} column {d}, but both count from 1.", .{ target.line, target.column }));
        if (std.mem.eql(u8, call.command, flag_command)) {
            try self.flag(target);
        } else if (std.mem.eql(u8, call.command, fixed_command)) {
            const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
            try self.trace("fix applied", started, &attributesOf(target, ""));
        } else return self.sendError(id, -32601, try self.scratch.text.format("zanity has no command {s}; it has {s} and {s}.", .{ call.command, flag_command, fixed_command }));
        try self.respond(id, no_value);
        if (target.line == 0 or target.column == 0) assert.panic("ran {s} for a finding at line {d} column {d}; such a target is refused above", .{ call.command, target.line, target.column });
    }

    /// Keeps a finding the editor flagged as a false positive, sends it as a span, and hides it.
    fn flag(self: *LanguageServer, target: Target) !void {
        if (target.rule.len == 0) assert.panic("flagging a finding with no rule at {s}:{d}", .{ target.path, target.line });
        const file = self.current.find(target.path) orelse return;
        const entries = self.current.entriesOf(file);
        const index = for (entries, 0..) |entry, i| {
            const r = entry.record;
            if (r.line == target.line and r.column == target.column and std.mem.eql(u8, r.rule, target.rule) and std.mem.eql(u8, r.message, target.message)) break i;
        } else return;
        const code = std.mem.trim(u8, lineOf(file.source, target.line - 1), " \t\r");
        const kept = self.keepFlag(target, code);
        const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
        try self.trace("false positive", started, &attributesOf(target, code));
        try self.flagged.add(flagKey(target.path, target.rule, target.message));
        std.mem.copyForwards(Entry, entries[index..], entries[index + 1 ..]);
        file.count -= 1;
        try self.publish(file.uri, entries[0 .. entries.len - 1]);
        try self.show(3, try self.scratch.text.format("zanity: flagged {s} as a false positive; {s}.", .{ target.rule, kept }));
        if (file.count + 1 != entries.len) assert.panic("{s} has {d} findings after hiding one of {d}", .{ file.path, file.count, entries.len });
    }

    /// Keeps the flag in the store, and says where it went.
    fn keepFlag(self: *LanguageServer, target: Target, code: []const u8) []const u8 {
        if (target.path.len == 0) assert.panic("keeping a flag of {s} with no path", .{target.rule});
        const s = self.services.store orelse return "it is hidden for this session only, as zanity's store could not be opened";
        s.keepFalsePositive(.{ .path = target.path, .line = target.line, .column = target.column, .rule = target.rule, .message = target.message, .code = code, .version = self.services.version }) catch |e| {
            return self.scratch.text.format("it is hidden for this session only, as {s} would not keep it: {t}", .{ s.path, e }) catch "it is hidden for this session only";
        };
        if (s.path.len == 0) assert.panic("kept a flag in a store with no path", .{});
        return self.scratch.text.format("kept in {s}'s false_positives table", .{s.path}) catch "kept in zanity's store";
    }

    /// Records a span when telemetry is on, turning telemetry off if its memory runs out.
    fn trace(self: *LanguageServer, name: []const u8, started: Io.Timestamp, attributes: []const Attribute) !void {
        if (name.len == 0) assert.panic("tracing a span with no name", .{});
        const t = self.services.telemetry orelse return;
        t.record(name, started, attributes) catch |e| {
            self.services.telemetry = null;
            try self.show(2, try self.scratch.text.format("zanity could not record the span {s}: {t}. Telemetry is off for this session.", .{ name, e }));
        };
        if (self.services.telemetry) |on| if (!on.pending()) assert.panic("recorded the span {s} but none is pending", .{name});
    }

    /// Sends the pending spans, and says once if the collector cannot be reached.
    fn flushTelemetry(self: *LanguageServer) !void {
        const t = self.services.telemetry orelse return;
        if (t.url.len == 0) assert.panic("flushing telemetry with no URL; initTelemetry() returns null without one", .{});
        const was_failed = t.failed;
        t.flush() catch |e| if (!was_failed) {
            try self.show(2, try self.scratch.text.format("zanity could not send traces to {s}: {t}. Telemetry is off for this session.", .{ t.url, e }));
        };
        if (t.pending()) assert.panic("spans are still pending after a flush; flush() must clear them", .{});
    }

    fn respond(self: *LanguageServer, id: json.Value, result: anytype) !void {
        if (id == .object or id == .array) assert.panic("answering a request whose id is a {t}; JSON-RPC ids are numbers or strings", .{id});
        try self.send(.{ .jsonrpc = "2.0", .id = id, .result = result });
        if (self.outbox.len == 0) assert.panic("answered with no room to write messages", .{});
    }

    fn notify(self: *LanguageServer, method: []const u8, params: anytype) !void {
        if (method.len == 0) assert.panic("sending a notification with no method", .{});
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
        if (self.outbox.len == 0) assert.panic("sent {s} with no room to write messages", .{method});
    }

    fn sendError(self: *LanguageServer, id: json.Value, code: i32, message: []const u8) !void {
        if (code >= 0) assert.panic("sending the error code {d}; JSON-RPC error codes are negative", .{code});
        if (message.len == 0) assert.panic("sending the error {d} with no message", .{code});
        try self.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }

    /// Shows the editor a message: 1 an error, 2 a warning, 3 information.
    fn show(self: *LanguageServer, kind: u8, message: []const u8) !void {
        if (kind == 0 or kind > 4) assert.panic("showing a message of type {d}; LSP defines 1 to 4", .{kind});
        if (message.len == 0) assert.panic("showing an empty message of type {d}", .{kind});
        try self.notify("window/showMessage", .{ .type = kind, .message = message });
    }

    fn send(self: *LanguageServer, value: anytype) !void {
        var body: Io.Writer = .fixed(self.outbox);
        json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &body) catch {
            memory.exceeded = "bytes in one message to the editor";
            return error.LimitExceeded;
        };
        const bytes = body.buffered();
        try self.out.print("Content-Length: {d}\r\n\r\n", .{bytes.len});
        try self.out.writeAll(bytes);
        try self.out.flush();
        if (bytes.len < 2) assert.panic("sent a {d}-byte message; json.Stringify writes at least the braces of an object", .{bytes.len});
        if (bytes.len > self.outbox.len) assert.panic("sent {d} bytes from a {d}-byte outbox", .{ bytes.len, self.outbox.len });
    }
};

/// A file's findings written as an array of their diagnostics.
const Diagnostics = struct {
    entries: []const Entry,

    pub fn jsonStringify(self: Diagnostics, jw: anytype) !void {
        if (self.entries.len > 1 << 18) assert.panic("writing {d} diagnostics for one file, more than one check holds", .{self.entries.len});
        try jw.beginArray();
        for (self.entries) |entry| try jw.write(entry.diagnostic);
        try jw.endArray();
        if (self.entries.len > 0 and self.entries[0].diagnostic.code.len == 0) assert.panic("wrote {d} diagnostics, the first of them with no rule", .{self.entries.len});
    }
};

/// The edits of one file, written as LSP's `changes` map from its URI.
const Changes = struct {
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

const Command = struct { title: []const u8, command: []const u8, arguments: []const Target };

const Action = struct {
    title: []const u8,
    kind: []const u8,
    diagnostics: []const LspDiagnostic,
    isPreferred: bool,
    edit: ?struct { changes: Changes } = null,
    /// Runs after the edit, if any, is applied.
    command: ?Command = null,
};

fn editsFirst(_: void, a: Entry, b: Entry) bool {
    if (a.edit == null or b.edit == null) assert.panic("ordering a finding with no edit among fixes; fixAll() collects only fixes", .{});
    if (a.record.line == 0 or b.record.line == 0) assert.panic("ordering fixes on line {d} and {d}; lines count from 1", .{ a.record.line, b.record.line });
    return a.start < b.start;
}

fn isBefore(a: Position, b: Position) bool {
    if (a.line > 1 << 30 or b.line > 1 << 30) assert.panic("comparing positions on lines {d} and {d}, past any file zanity reads", .{ a.line, b.line });
    const earlier = a.line < b.line or (a.line == b.line and a.character < b.character);
    if (earlier and a.line > b.line) assert.panic("line {d} counted as before line {d}", .{ a.line, b.line });
    return earlier;
}

/// The span attributes that say which finding a command was about, and the code it was on.
fn attributesOf(target: Target, code: []const u8) [6]Attribute {
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
fn flagKey(path: []const u8, rule: []const u8, message: []const u8) u64 {
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

const pathKey = nameHash;

/// Line `line` of `source`, counting from 0, without its newline.
fn lineOf(source: []const u8, line: u32) []const u8 {
    const start = lineStart(source, line);
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    if (end < start) assert.panic("line {d} ends at byte {d}, before it starts at {d}", .{ line, end, start });
    if (std.mem.indexOfScalar(u8, source[start..end], '\n') != null) assert.panic("line {d} holds a newline", .{line});
    return source[start..end];
}

/// Whether a code action request's `only` list, when it has one, asks for `kind`. A listed kind
/// covers the kinds under it, so `source` covers `source.fixAll.zanity`.
fn wants(only: ?json.Value, kind: []const u8) bool {
    if (kind.len == 0) assert.panic("asked whether the editor wants an empty kind of code action", .{});
    const list = switch (only orelse return true) {
        .array => |a| a.items,
        else => return true,
    };
    for (list) |item| {
        const asked = stringOf(item) orelse continue;
        if (std.mem.eql(u8, asked, kind)) return true;
        if (asked.len < kind.len and std.mem.startsWith(u8, kind, asked) and kind[asked.len] == '.') return true;
    }
    if (list.len > 1 << 10) assert.panic("the editor asked for {d} kinds of code action", .{list.len});
    return false;
}

/// A finding's diagnostic, from its column to the end of its line, and its edit placed in the file.
fn entryOf(text: *memory.Text, source: []const u8, record: Record, utf8: bool) !Entry {
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
fn lineStart(source: []const u8, line: u32) usize {
    var offset: usize = 0;
    for (0..line) |_| {
        const newline = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return source.len;
        offset = newline + 1;
    }
    if (offset > source.len) assert.panic("line {d} starts at byte {d} of a {d}-byte file", .{ line, offset, source.len });
    if (offset > 0 and source[offset - 1] != '\n') assert.panic("line {d} starts at byte {d}, which does not follow a newline", .{ line, offset });
    return offset;
}

/// The LSP position of byte `offset`, counting characters in bytes or in UTF-16 code units.
pub fn position(source: []const u8, offset: usize, utf8: bool) Position {
    if (offset > source.len) assert.panic("byte {d} is past the end of a {d}-byte file", .{ offset, source.len });
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |n| n + 1 else 0;
    const line: u32 = @intCast(std.mem.count(u8, source[0..line_start], "\n"));
    const prefix = source[line_start..offset];
    const character = if (utf8) prefix.len else std.unicode.calcUtf16LeLen(prefix) catch prefix.len;
    if (character > prefix.len) assert.panic("{d} bytes counted as {d} characters; no encoding has more characters than bytes", .{ prefix.len, character });
    return .{ .line = line, .character = @intCast(character) };
}

/// Reads one message's JSON body into `inbox`, or null when the editor closed stdin between messages.
pub fn readMessage(in: *Io.Reader, inbox: []u8) !?[]u8 {
    if (inbox.len == 0) assert.panic("reading a message into no room", .{});
    var length: ?usize = null;
    for (0..max_header_lines) |i| {
        const raw = in.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => if (i == 0) return null else return error.EndOfStream,
            else => return e,
        };
        const header = std.mem.trimEnd(u8, raw, "\r\n");
        if (header.len == 0) break;
        const name = "content-length:";
        if (header.len > name.len and std.ascii.startsWithIgnoreCase(header, name)) length = try std.fmt.parseInt(usize, std.mem.trim(u8, header[name.len..], " "), 10);
    } else return error.TooManyHeaders;
    const n = length orelse return error.MissingContentLength;
    if (n > inbox.len) return error.MessageTooLong;
    try in.readSliceAll(inbox[0..n]);
    if (n > inbox.len) assert.panic("read a {d}-byte message into {d} bytes", .{ n, inbox.len });
    return inbox[0..n];
}

/// Whether the editor can count positions in bytes, which saves converting them.
fn offersUtf8(params: json.Value) bool {
    const encodings = member(member(member(params, "capabilities"), "general"), "positionEncodings") orelse return false;
    const offered: []const json.Value = if (encodings == .array) encodings.array.items else &.{};
    if (offered.len > 1 << 20) assert.panic("the editor offered {d} position encodings", .{offered.len});
    const utf8 = for (offered) |e| {
        if (std.mem.eql(u8, stringOf(e) orelse continue, "utf-8")) break true;
    } else false;
    if (utf8 and offered.len == 0) assert.panic("chose UTF-8 positions though the editor offered no encodings", .{});
    return utf8;
}

/// The path a `file://` URI names, decoded into `text`; null for any other scheme.
pub fn pathOf(text: *memory.Text, uri: []const u8) !?[]const u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return null;
    const start = text.used;
    _ = try text.copy(uri[scheme.len..]);
    const tail = std.Uri.percentDecodeInPlace(text.buffer[start..text.used]);
    std.mem.copyForwards(u8, text.buffer[start..][0..tail.len], tail);
    const decoded = text.buffer[start..][0..tail.len];
    text.used = start + decoded.len;
    if (decoded.len > uri.len) assert.panic("decoding {s} lengthened it to {d} bytes; percent-decoding only shortens", .{ uri, decoded.len });
    if (decoded.ptr != text.buffer[start..].ptr) assert.panic("decoded {s} outside the text it was copied to", .{uri});
    return decoded;
}

/// The `file://` URI of an absolute path, written into `text`, encoding what a URI path cannot hold.
pub fn uriOf(text: *memory.Text, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) assert.panic("making a URI of the relative path {s}; resolve it against the root first", .{path});
    var out: Io.Writer = .fixed(text.buffer[text.used..]);
    out.writeAll("file://") catch return error.LimitExceeded;
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        (if (plain) out.writeByte(c) else out.print("%{X:0>2}", .{c})) catch {
            memory.exceeded = "bytes of paths and URIs in one check";
            return error.LimitExceeded;
        };
    }
    const uri = out.buffered();
    text.used += uri.len;
    if (uri.len < path.len + "file://".len) assert.panic("the URI of {s} is shorter than the path", .{path});
    return uri;
}

fn member(value: ?json.Value, name: []const u8) ?json.Value {
    if (name.len == 0) assert.panic("looking up an empty member name", .{});
    const v = value orelse return null;
    if (v != .object) return null;
    const found = v.object.get(name);
    if (found != null and v.object.count() == 0) assert.panic("found {s} in an empty object", .{name});
    return found;
}

fn stringOf(value: ?json.Value) ?[]const u8 {
    const v = value orelse return null;
    if (v != .string) return null;
    const string = v.string;
    if (string.len > 1 << 28) assert.panic("a {d}-byte string in one message, past what a message holds", .{string.len});
    if (string.len > 0 and @intFromPtr(string.ptr) == 0) assert.panic("a {d}-byte string at address 0", .{string.len});
    return string;
}

fn integerOf(value: ?json.Value) ?u32 {
    const v = value orelse return null;
    if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) return null;
    const n: u32 = @intCast(v.integer);
    if (n != v.integer) assert.panic("{d} changed to {d} on narrowing", .{ v.integer, n });
    if (v.integer < 0) assert.panic("{d} passed as a line number; negative numbers are refused above", .{v.integer});
    return n;
}

test "positions count bytes or UTF-16 code units" {
    const source = "a = 1\nb = \"é𝄞\" + x\n";
    const x = std.mem.indexOfScalar(u8, source, 'x').?;
    try std.testing.expectEqual(Position{ .line = 1, .character = 15 }, position(source, x, true));
    try std.testing.expectEqual(Position{ .line = 1, .character = 12 }, position(source, x, false));
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, position(source, 0, false));
    try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, position(source, source.len, false));
}

test "a URI and its path convert both ways" {
    var text: memory.Text = try .initText(std.testing.allocator, 1024);
    defer std.testing.allocator.free(text.buffer);
    const uri = try uriOf(&text, "/tmp/my project/a#b.py");
    try std.testing.expectEqualStrings("file:///tmp/my%20project/a%23b.py", uri);
    try std.testing.expectEqualStrings("/tmp/my project/a#b.py", (try pathOf(&text, uri)).?);
    try std.testing.expectEqual(null, try pathOf(&text, "untitled:Untitled-1"));
}

test "a message is read by its Content-Length header" {
    var inbox: [64]u8 = undefined;
    var in: Io.Reader = .fixed("Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n{}Content-Length: 3\r\n\r\n[1]");
    try std.testing.expectEqualStrings("{}", (try readMessage(&in, &inbox)).?);
    try std.testing.expectEqualStrings("[1]", (try readMessage(&in, &inbox)).?);
    try std.testing.expectEqual(null, try readMessage(&in, &inbox));
}

test "a finding becomes a diagnostic to the end of its line, with its edit placed" {
    var text: memory.Text = try .initText(std.testing.allocator, 1024);
    defer std.testing.allocator.free(text.buffer);
    const source = "def f():\n    x = 1  \n";
    const record: Record = .{ .path = "a.py", .line = 2, .column = 5, .severity = "warning", .rule = "r", .message = "m", .fix = "do it", .edit_start = 13, .edit_end = 18, .edit_text = "y = 2" };
    const entry = try entryOf(&text, source, record, false);
    const line_two: Range = .{ .start = .{ .line = 1, .character = 4 }, .end = .{ .line = 1, .character = 9 } };
    try std.testing.expectEqual(line_two, entry.diagnostic.range);
    try std.testing.expectEqual(@as(u8, 2), entry.diagnostic.severity);
    try std.testing.expectEqualStrings("m\ndo it", entry.diagnostic.message);
    try std.testing.expectEqual(line_two, entry.edit.?.range);
}

test "a code action kind covers the kinds under it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const only = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), "[\"source\"]", .{});
    try std.testing.expect(wants(null, fix_all));
    try std.testing.expect(wants(only, fix_all));
    try std.testing.expect(!wants(only, "quickfix"));
    try std.testing.expect(isBefore(.{ .line = 0, .character = 4 }, .{ .line = 1, .character = 0 }));
    try std.testing.expect(!isBefore(.{ .line = 1, .character = 0 }, .{ .line = 1, .character = 0 }));
}

//! `zanity lsp`: a language server on stdin and stdout. It runs `zanity check --json` over the
//! workspace when the editor connects and on every save, publishes each finding as a diagnostic,
//! and offers the edits `--fix` would make as code actions. A finding can be flagged as a false
//! positive from the editor: it is kept in zanity's store and, with telemetry on, sent as a span,
//! so the rule can be made more precise, and it stays hidden for the rest of the session.
const std = @import("std");
const lsp_check = @import("lsp_check.zig");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const nameHash = @import("facts.zig").nameHash;
const store = @import("store.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const Attribute = @import("telemetry.zig").Attribute;
const protocol = @import("lsp_protocol.zig");
const Range = protocol.Range;
const TextEdit = protocol.TextEdit;
const no_value = protocol.no_value;
const readMessage = protocol.readMessage;
const offersUtf8 = protocol.offersUtf8;
const pathOf = protocol.pathOf;
const EditorRequest = protocol.EditorRequest;
const requestOf = protocol.requestOf;
const member = protocol.member;
const stringOf = protocol.stringOf;
const results_module = @import("lsp_results.zig");
const actions = @import("lsp_actions.zig");
const Action = actions.Action;
const fix_all = actions.fix_all;
const wants = actions.wants;
const flag_command = actions.flag_command;
const fixed_command = actions.fixed_command;
const confirm_command = actions.confirm_command;
const dismiss_command = actions.dismiss_command;
pub const ServerLimits = results_module.ServerLimits;
pub const Record = results_module.Record;
pub const LspDiagnostic = results_module.LspDiagnostic;
const DiagnosticEntry = results_module.DiagnosticEntry;
const Target = results_module.Target;
const CheckedFile = results_module.CheckedFile;
const Results = results_module.Results;
const Diagnostics = results_module.Diagnostics;
const isBefore = results_module.isBefore;
const entryOf = results_module.entryOf;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

/// The most messages one session handles; an editor sends far fewer in a working lifetime.
const max_messages = 1 << 40;
/// Bound the checker's diagnostic output independently of its JSON findings.
pub const check_stderr_bytes = 64 * 1024;
/// JSON-RPC 2.0's response code for an unsupported request method.
const method_not_found = -32601;
/// JSON-RPC's code for a request with bad parameters.
pub const invalid_params = -32602;
/// JSON-RPC's code for a request that is not a valid request.
const invalid_request = -32600;

/// The memory a request is answered from, cleared after each message.
const Scratch = struct {
    parse: std.heap.FixedBufferAllocator,
    text: memory.Text,
    actions: memory.Bounded(Action),
    targets: memory.Bounded(Target),
    /// A file's fixes in the order fix-all applies them, and the edits and diagnostics it keeps.
    fixes: memory.Bounded(DiagnosticEntry),
    edits: memory.Bounded(TextEdit),
    diagnostics: memory.Bounded(LspDiagnostic),

    fn initScratch(gpa: Allocator, limits: ServerLimits) !Scratch {
        const scratch: Scratch = .{
            .parse = .init(try memory.reserveUninitialized(gpa, u8, limits.parse_bytes)),
            .text = try .initText(gpa, limits.message_bytes),
            .actions = try .initBounded(gpa, limits.actions, "code actions in one answer"),
            .targets = try .initBounded(gpa, limits.actions, "code actions in one answer"),
            .fixes = try .initBounded(gpa, limits.findings, "fixes in one file"),
            .edits = try .initBounded(gpa, limits.findings, "edits fix-all makes in one file"),
            .diagnostics = try .initBounded(gpa, limits.findings, "findings fix-all fixes in one file"),
        };
        if (scratch.parse.end_index != 0) assert.panic("new scratch memory has {d} bytes in use; fix initScratch() to return unused parse memory", .{scratch.parse.end_index});
        if (scratch.text.used != 0) assert.panic("new scratch text has {d} bytes in use; fix initScratch() to return empty text", .{scratch.text.used});
        return scratch;
    }

    fn clear(self: *Scratch) void {
        self.parse.reset();
        self.text.used = 0;
        inline for (.{ "actions", "targets", "fixes", "edits", "diagnostics" }) |name| @field(self, name).clear();
        if (self.parse.end_index != 0) assert.panic("scratch memory has {d} bytes in use after clear(); fix Scratch.clear() to reset the parser", .{self.parse.end_index});
        if (self.actions.len != 0) assert.panic("scratch holds {d} code actions after clear(); fix Scratch.clear() to empty every bounded list", .{self.actions.len});
    }
};

/// What the server needs besides the editor: this executable to run checks with, its version,
/// and where flags and spans go when they can.
pub const Services = struct {
    exe: []const u8,
    version: []const u8,
    /// Whether each check also asks the model, as `zanity lsp --infer` says.
    infer: bool = false,
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
    initialized: bool = false,
    shut_down: bool = false,

    pub fn initLanguageServer(gpa: Allocator, io: Io, out: *Io.Writer, services: Services) !LanguageServer {
        if (services.exe.len == 0) assert.panic("the language server was given no executable to run checks with; runLsp() passes this one's path", .{});
        if (services.version.len == 0) assert.panic("the language server was given an empty version; pass the app's version, which is dev or the release's", .{});
        const limits: ServerLimits = .{};
        return .{
            .io = io,
            .out = out,
            .services = services,
            .inbox = try memory.reserveUninitialized(gpa, u8, limits.message_bytes),
            .outbox = try memory.reserveUninitialized(gpa, u8, limits.message_bytes),
            .scratch = try .initScratch(gpa, limits),
            .current = try .initResults(gpa, limits),
            .previous = try .initResults(gpa, limits),
            .dirty = try .initBounded(gpa, limits.files, "files edited since the last check"),
            .flagged = try .initBounded(gpa, limits.flags, "findings flagged in one session"),
        };
    }

    /// Answers the launching editor over inherited stdio until `exit` or EOF. Returns whether
    /// it shut down first, as the protocol asks of a clean exit.
    pub fn serveEditorStdio(self: *LanguageServer) !bool {
        // The launching editor owns this process's stdin/stdout descriptors. This session runs
        // with that editor's OS permissions; the transport is its local process pipe.
        var buffer: [64 * 1024]u8 = undefined;
        var parent_stdin = Io.File.stdin().readerStreaming(self.io, &buffer);
        if (self.inbox.len == 0) assert.panic("serving with no room for a message; initLanguageServer() reserves it", .{});
        if (self.outbox.len == 0) assert.panic("serving with no room to answer; initLanguageServer() reserves it", .{});
        for (0..max_messages) |_| {
            self.scratch.clear();
            const body = try readMessage(&parent_stdin.interface, self.inbox) orelse return self.shut_down;
            const parsed = json.parseFromSliceLeaky(json.Value, self.scratch.parse.allocator(), body, .{}) catch |e| {
                const exhausted = e == error.OutOfMemory;
                const message = if (exhausted)
                    try self.scratch.text.format("The {d}-byte message exceeds this server's JSON parsing memory; send a smaller message.", .{body.len})
                else
                    try self.scratch.text.format("The {d}-byte message is not valid JSON; send a JSON-RPC 2.0 object encoded as JSON.", .{body.len});
                try self.sendError(.null, if (exhausted) -32603 else -32700, message);
                continue;
            };
            if (member(parsed, "method") == null and (member(parsed, "result") != null or member(parsed, "error") != null)) continue;
            const message = requestOf(parsed) orelse {
                try self.sendError(.null, invalid_request, "Send a JSON-RPC 2.0 object with a nonempty method and a string or integer id.");
                continue;
            };
            if (std.mem.eql(u8, message.method, "exit")) return self.shut_down;
            self.dispatchEditorRequest(message) catch |e| try self.reportFailure(message.method, message.id, e);
            try self.flushTelemetry();
        }
        assert.panic("handled {d} messages without the editor exiting; raise max_messages if a real editor session needs more", .{max_messages});
    }

    /// Dispatches a shape-validated request from the launching editor's inherited stdio.
    fn dispatchEditorRequest(self: *LanguageServer, request: EditorRequest) !void {
        // requestOf() validated the envelope; each handler validates its method's arguments.
        // The stdio loop consumed this frame before dispatch. A failed command is reported,
        // not retried; dispatch never replays a command after writing its response.
        const method = request.method;
        const params = request.params;
        const id = request.id orelse no_value;
        if (self.outbox.len == 0) assert.panic("dispatching request {s} without reply storage; call initLanguageServer() before dispatch", .{method});
        if (method.len == 0) return self.sendError(id, invalid_request, "The editor's request has an empty method; send a supported nonempty request name.");
        if (!try self.accepts(method, request.id)) return;
        if (self.root.len == 0) assert.panic("dispatching request {s} without a workspace; retain the validated root in initialize() before accepting requests", .{method});
        const is = std.mem.eql;
        if (is(u8, method, "initialize")) return self.initialize(id, params);
        if (is(u8, method, "initialized")) return lsp_check.checkWorkspace(self, "initialized");
        if (is(u8, method, "shutdown")) {
            self.shut_down = true;
            return self.respond(id, no_value);
        }
        if (is(u8, method, "textDocument/didOpen")) return self.republish(params);
        if (is(u8, method, "textDocument/didChange")) return self.markDirty(params);
        if (is(u8, method, "textDocument/didSave")) return lsp_check.checkWorkspace(self, "save");
        if (is(u8, method, "textDocument/codeAction")) return actions.codeActions(self, id, params);
        if (is(u8, method, "workspace/executeCommand")) return actions.execute(self, id, params);
        if (request.id != null) try self.sendError(id, method_not_found, try self.scratch.text.format("zanity does not support the editor's request {s}. Send a request supported by the server's advertised capabilities.", .{method}));
    }

    /// Checks protocol ordering before requests reach handlers that require initialization.
    fn accepts(self: *LanguageServer, method: []const u8, request: ?json.Value) !bool {
        if (method.len == 0) assert.panic("checking protocol order with no method; requestOf() validates it before dispatch", .{});
        if (self.initialized and self.root.len == 0) assert.panic("initialized without a workspace root; initialize() must retain rootOf()'s validated path", .{});
        if (self.shut_down) {
            if (request) |id| try self.sendError(id, invalid_request, "The server has shut down; send exit and start a new session.");
            return false;
        }
        if (std.mem.eql(u8, method, "initialize")) {
            if (!self.initialized) return request != null;
            if (request) |id| try self.sendError(id, invalid_request, "The server is already initialized; start a new session to change its workspace.");
            return false;
        }
        if (self.initialized) return true;
        if (request) |id| try self.sendError(id, -32002, "Initialize the server before sending other requests.");
        return false;
    }

    /// Tells the editor a message could not be handled, and goes on to the next.
    fn reportFailure(self: *LanguageServer, method: []const u8, id: ?json.Value, e: anyerror) !void {
        if (method.len == 0) assert.panic("reporting a failure of a message with no method; pass the method from handle()", .{});
        const message = try self.scratch.text.format("zanity could not handle {s}: {t}{s}{s}.", .{ method, e, if (e == error.LimitExceeded) ", as it ran out of room for " else "", if (e == error.LimitExceeded) memory.exceeded else "" });
        if (id) |request| try self.sendError(request, -32603, message) else try self.show(1, message);
        if (message.len < method.len) assert.panic("the failure of {s} was reported as '{s}'; fix reportFailure() to include the method and error", .{ method, message });
    }

    fn initialize(self: *LanguageServer, id: json.Value, params: json.Value) !void {
        if (self.current.files.len != 0) assert.panic("initialize arrived after a check of {d} files; the editor sends it first", .{self.current.files.len});
        const root = self.rootOf(params) catch |e| switch (e) {
            error.InvalidWorkspaceRoot, error.InvalidFileUri, error.NameTooLong => return self.sendError(id, invalid_params, "Name the workspace with an absolute rootPath or a local file URI in rootUri."),
            else => return e,
        };
        const utf8 = offersUtf8(params) catch return self.sendError(id, invalid_params, "Offer at most 1048576 position encodings in capabilities.general.positionEncodings.");
        self.root = root;
        self.utf8 = utf8;
        try self.respond(id, .{
            .capabilities = .{
                .positionEncoding = if (self.utf8) "utf-8" else "utf-16",
                .textDocumentSync = .{ .openClose = true, .change = 2, .save = true },
                .codeActionProvider = .{ .codeActionKinds = &[_][]const u8{ "quickfix", fix_all } },
                .executeCommandProvider = .{ .commands = &[_][]const u8{ flag_command, fixed_command, confirm_command, dismiss_command } },
            },
            .serverInfo = .{ .name = "zanity", .version = self.services.version },
        });
        self.initialized = true;
        if (!std.fs.path.isAbsolute(self.root)) assert.panic("the workspace root {s} is relative; rootOf() returns an absolute path", .{self.root});
    }

    /// The workspace root the editor names, as a path; the working directory when it names none.
    fn rootOf(self: *LanguageServer, params: json.Value) ![]const u8 {
        if (self.current.files.len != 0) assert.panic("choosing the workspace root after a check of {d} files; call rootOf() only during initialize", .{self.current.files.len});
        const folders = member(params, "workspaceFolders") orelse no_value;
        const listed: []const json.Value = if (folders == .array) folders.array.items else &.{};
        const first = if (listed.len > 0) listed[0] else no_value;
        const uri = stringOf(member(params, "rootUri")) orelse stringOf(member(first, "uri"));
        const named: ?[]const u8 = if (uri) |value| try pathOf(&self.scratch.text, value) orelse return error.InvalidWorkspaceRoot else stringOf(member(params, "rootPath"));
        const root = if (named) |path| path else self.root_buffer[0..try Io.Dir.cwd().realPath(self.io, &self.root_buffer)];
        if (root.len > self.root_buffer.len) return error.NameTooLong;
        if (root.len == 0 or !std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidWorkspaceRoot;
        @memmove(self.root_buffer[0..root.len], root);
        if (root.len == 0) assert.panic("the editor named an empty workspace root; fall back to the working directory in rootOf()", .{});
        return self.root_buffer[0..root.len];
    }

    /// The last check's findings in the file a message names, or null when it names none with any.
    pub fn fileOf(self: *LanguageServer, params: json.Value) !?*CheckedFile {
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

    pub fn isDirty(self: *const LanguageServer, path: []const u8) bool {
        if (path.len == 0) assert.panic("asked whether a file with an empty path is edited; pass a CheckedFile.path", .{});
        const key = pathKey(path);
        for (self.dirty.items()) |dirty| if (dirty == key) return true;
        if (self.dirty.len > self.dirty.capacity()) assert.panic("{d} edited files in room for {d}; fix markDirty() to enforce the bound", .{ self.dirty.len, self.dirty.capacity() });
        return false;
    }

    pub fn publish(self: *LanguageServer, uri: []const u8, entries: []const DiagnosticEntry) !void {
        if (uri.len == 0) assert.panic("publishing {d} diagnostics under an empty URI; pass the CheckedFile.uri recorded by add()", .{entries.len});
        try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = Diagnostics{ .entries = entries } });
        if (self.outbox.len == 0) assert.panic("published with no room to write messages; reserve message_bytes in initLanguageServer()", .{});
    }

    /// Records a span when telemetry is on, turning telemetry off if its memory runs out.
    pub fn trace(self: *LanguageServer, name: []const u8, started: Io.Timestamp, attributes: []const Attribute) !void {
        if (name.len == 0) assert.panic("tracing a span with no name; pass the operation being traced", .{});
        const t = self.services.telemetry orelse return;
        t.record(name, started, attributes) catch |e| {
            self.services.telemetry = null;
            try self.show(2, try self.scratch.text.format("zanity could not record the span {s}: {t}. Telemetry is off for this session.", .{ name, e }));
        };
        if (self.services.telemetry) |on| if (!on.pending()) assert.panic("recorded the span {s} but none is pending; fix Telemetry.record() to queue it", .{name});
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

    pub fn respond(self: *LanguageServer, id: json.Value, result: anytype) !void {
        if (id == .object or id == .array) assert.panic("answering a request whose id is a {t}; JSON-RPC ids are numbers or strings", .{id});
        try self.send(.{ .jsonrpc = "2.0", .id = id, .result = result });
        if (self.outbox.len == 0) assert.panic("answered with no room to write messages", .{});
    }

    fn notify(self: *LanguageServer, method: []const u8, params: anytype) !void {
        if (method.len == 0) assert.panic("sending a notification with no method; pass the LSP method name", .{});
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
        if (self.outbox.len == 0) assert.panic("sent {s} with no room to write messages; reserve message_bytes in initLanguageServer()", .{method});
    }

    pub fn sendError(self: *LanguageServer, id: json.Value, code: i32, message: []const u8) !void {
        if (code >= 0) assert.panic("sending the error code {d}; pass a negative JSON-RPC error code", .{code});
        if (message.len == 0) assert.panic("sending the error {d} with no message; describe what the editor request must change", .{code});
        try self.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }

    /// Shows the editor a message: 1 an error, 2 a warning, 3 information.
    pub fn show(self: *LanguageServer, kind: u8, message: []const u8) !void {
        if (kind == 0 or kind > 4) assert.panic("showing a message of type {d}; pass an LSP message type from 1 to 4", .{kind});
        if (message.len == 0) assert.panic("showing an empty message of type {d}; pass the problem and its next step", .{kind});
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
        if (bytes.len < 2) assert.panic("sent a {d}-byte message; fix send() to serialize a JSON object", .{bytes.len});
        if (bytes.len > self.outbox.len) assert.panic("sent {d} bytes from a {d}-byte outbox; fix send() to keep serialization inside the outbox", .{ bytes.len, self.outbox.len });
    }
};

pub const pathKey = nameHash;

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

test "dismissal removes every matching copy and retains the same view on retry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limits: ServerLimits = .{ .check_bytes = 1024, .check_text_bytes = 1024, .findings = 4, .files = 4 };
    const previous = try Results.initResults(arena, limits);
    var results = try Results.initResults(arena, limits);
    try results.advanceDiagnosticRevision(&previous);
    const record: Record = .{ .path = "/tmp/a.py", .line = 1, .column = 1, .severity = "warning", .rule = "assertion-message", .message = "assertion needs context", .fix = "Add a message." };
    const entry = try entryOf(&results.text, "assert value\n", record, true);
    try results.entries.add(entry);
    try results.entries.add(entry);
    var other = record;
    other.line = 2;
    try results.entries.add(try entryOf(&results.text, "assert value\nassert other\n", other, true));
    try results.files.add(.{ .path = record.path, .uri = "file:///tmp/a.py", .source = "assert value\nassert other\n", .first = 0, .count = 3 });
    const target = results.bindTarget(entry.targets(record.path));
    var stale = target;
    stale.generation = 0;
    try std.testing.expectEqual(null, results.dismissDiagnostic(stale));
    const before = results.entriesOf(results.find(record.path).?);
    try std.testing.expectEqual(@as(usize, 3), before.len);
    const first = results.dismissDiagnostic(target).?;
    try std.testing.expectEqual(@as(usize, 1), first.entries.len);
    try std.testing.expectEqual(@as(u32, 2), first.entries[0].record.line);
    const retry = results.dismissDiagnostic(target).?;
    try std.testing.expectEqualStrings(first.uri, retry.uri);
    try std.testing.expectEqual(@as(usize, 1), retry.entries.len);
    for ([_][]const u8{ "", "/tmp/missing.py" }) |path| {
        var unknown = target;
        unknown.path = path;
        try std.testing.expectEqual(null, results.dismissDiagnostic(unknown));
    }
}

test "a newer check rejects old code actions even when the finding is unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limits: ServerLimits = .{ .check_bytes = 1024, .check_text_bytes = 1024, .findings = 4, .files = 4 };
    const empty = try Results.initResults(arena, limits);
    var previous = try Results.initResults(arena, limits);
    try previous.advanceDiagnosticRevision(&empty);
    const record: Record = .{ .path = "/tmp/a.py", .line = 1, .column = 1, .severity = "warning", .rule = "assertion-message", .message = "assertion needs context", .fix = "Add a message." };
    const entry = try entryOf(&previous.text, "assert value\n", record, true);
    const file: CheckedFile = .{ .path = record.path, .uri = "file:///tmp/a.py", .source = "assert value\n", .first = 0, .count = 1 };
    try previous.entries.add(entry);
    try previous.files.add(file);
    const old_action = previous.bindTarget(entry.targets(record.path));
    var current = try Results.initResults(arena, limits);
    try current.advanceDiagnosticRevision(&previous);
    try current.entries.add(entry);
    try current.files.add(file);
    try std.testing.expectEqual(null, current.dismissDiagnostic(old_action));
    const unchanged = current.entriesOf(current.find(record.path).?);
    try std.testing.expectEqual(@as(usize, 1), unchanged.len);
    const new_action = current.bindTarget(entry.targets(record.path));
    try std.testing.expectEqual(@as(usize, 0), current.dismissDiagnostic(new_action).?.entries.len);
}

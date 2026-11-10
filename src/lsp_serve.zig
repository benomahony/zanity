//! Serving an editor over stdio: reading each request and dispatching it to the server, the
//! checks it publishes and the code actions it offers.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const assert = @import("assert.zig");
const lsp = @import("lsp.zig");
const LanguageServer = lsp.LanguageServer;
const lsp_check = @import("lsp_check.zig");
const actions = @import("lsp_actions.zig");
const protocol = @import("lsp_protocol.zig");
const EditorRequest = protocol.EditorRequest;
const readMessage = protocol.readMessage;
const member = protocol.member;
const no_value = protocol.no_value;
const method_not_found = lsp.method_not_found;
const invalid_request = lsp.invalid_request;
const requestOf = lsp.requestOf;
const max_messages = lsp.max_messages;

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
        dispatchEditorRequest(self, message) catch |e| try self.reportFailure(message.method, message.id, e);
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

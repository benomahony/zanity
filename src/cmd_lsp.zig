//! `zanity lsp`: starts the language server on stdin and stdout.
const std = @import("std");
const assert = @import("assert.zig");
const zclig = @import("zclig");
const infer = @import("infer.zig");
const store = @import("store.zig");
const lsp = @import("lsp.zig");
const lsp_serve = @import("lsp_serve.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const workspace = @import("workspace.zig");
const workspaceOf = workspace.workspaceOf;
/// This build's version, as `zanity --version` prints it.
const build_version = @import("build_info").version;

pub const LspOptions = struct { infer: bool = false };

/// `zanity lsp` writes the protocol to stdout itself, so it has no rows.
pub const LspRow = struct { messages: usize };

pub fn runLsp(ctx: *zclig.Context, options: LspOptions) ![]const LspRow {
    const ws = workspaceOf(ctx);
    const environ = ws.environ orelse assert.panic("zanity lsp ran without the environment; main() passes it to the workspace", .{});
    const exe = std.process.executablePathAlloc(ws.io, ctx.allocator) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not find where this zanity is installed, to run its checks: {t}.", .{e}), "Reinstall it with install.sh, as the README describes.");
    };
    // SQLite's configured heap is process-wide and must outlive every cached statement.
    // Editor-session buffers and telemetry, by contrast, are released when stdio closes.
    var session_memory = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_memory.deinit();
    const session_allocator = session_memory.allocator();
    // Both are optional for an editor session: without the store, marking a finding from the
    // editor says there is nowhere to keep it, and without telemetry nothing is traced, so a
    // failure to open either must not stop the server.
    ws.source_cache = store.Store.initStore(std.heap.page_allocator, ws.io, environ, ws.limits.store_bytes) catch null;
    var telemetry = Telemetry.initTelemetry(session_allocator, ws.io, environ, build_version) catch null;
    const services: lsp.Services = .{
        .exe = exe,
        .version = build_version,
        .infer = options.infer,
        .store = if (ws.source_cache) |*s| s else null,
        .telemetry = if (telemetry) |*t| t else null,
    };
    const out = ctx.runtime.out;
    var server = try lsp.LanguageServer.initLanguageServer(session_allocator, ws.io, out.writer, services);
    if (!try lsp_serve.serveEditorStdio(&server)) ctx.status = .failure;
    ctx.format = .plain;
    if (exe.len == 0) assert.panic("found this zanity at an empty path; executablePathAlloc() returns a path or fails", .{});
    if (ctx.format != .plain) assert.panic("zanity lsp left the {t} format on, which would print an empty result after the protocol; clear the output format before runLsp() returns", .{ctx.format});
    return &.{};
}

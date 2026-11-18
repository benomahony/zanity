const std = @import("std");
const assert = @import("assert.zig");
const zclig = @import("zclig");
const rules = @import("rules.zig");
const embed = @import("embed.zig");
const vectors = @import("vectors.zig");
const store_vectors = @import("store_vectors.zig");
const check_paths = @import("check_paths.zig");
const cmd_check = @import("cmd_check.zig");
const workspace = @import("workspace.zig");
const console = workspace.console;

const max_hits = 200;

pub const SearchOptions = struct {
    query: []const []const u8,
    names: bool = false,
    docs: bool = false,
    bodies: bool = false,
    limit: u32 = 20,
};

pub const SearchRow = struct { path: []const u8, line: u32, column: u32, end: u32, text: []const u8, score: f64 };

var rows: [max_hits]SearchRow = undefined;

pub fn runSearch(ctx: *zclig.Context, options: SearchOptions) ![]const SearchRow {
    if (options.query.len == 0) return ctx.fail(.usage, "zanity search needs something to look for.", "Describe the code in words, such as zanity search \"retry a failed payment\".");
    if (options.limit == 0 or options.limit > max_hits) return ctx.fail(.usage, "zanity search lists between 1 and 200 matches.", "Pass a --limit from 1 to 200.");
    if (@as(u8, @intFromBool(options.names)) + @intFromBool(options.docs) + @intFromBool(options.bodies) > 1) return ctx.fail(.usage, "zanity search matches one kind of vector at a time.", "Pass one of --names, --docs or --bodies; bodies are the default.");
    const ws = workspace.workspaceOf(ctx);
    if (ws.embedding != null) assert.panic("zanity search connected to the embeddings server before it ran; it connects once", .{});
    const settings = try check_paths.loadSettings(ctx, ws, std.heap.page_allocator);
    ws.settings = &settings;
    defer ws.settings = null;
    var selected: rules.Set = .{};
    try cmd_check.connectEmbedding(ctx, ws, &selected, true);
    const e = &ws.embedding.?;
    e.judging = false;
    _ = try check_paths.checkPaths(ctx, ws, .{ .paths = &.{"."} }, selected);
    if (e.dimensions == 0) return &.{};
    const kind: embed.TextKind = if (options.names) .name else if (options.docs) .doc else .body;
    const start = ws.text.used;
    for (options.query, 0..) |word, i| _ = try ws.text.format("{s}{s}", .{ if (i == 0) "" else " ", word });
    const query = try embed.promptedText(&e.text, if (kind == .body) embed.search_prompt else embed.similarity_prompt, ws.text.buffer[start..ws.text.used]);
    var wanted: [store_vectors.max_vector]f32 = undefined;
    e.embedQuery(query, wanted[0..e.dimensions]) catch |err| switch (err) {
        error.EmbedFailed => return ctx.fail(.io, embed.failure, embed.advice),
        else => return err,
    };
    const found = try rank(ws, e, .{ .kind = kind, .wanted = wanted[0..e.dimensions], .limit = options.limit });
    if (found.len > options.limit) assert.panic("zanity search found {d} matches past --limit {d}", .{ found.len, options.limit });
    if (ws.chose_format) return found;
    try renderSearch(ctx, found);
    ctx.format = .plain;
    return &.{};
}

fn keep(hits: []SearchRow, count: *usize, limit: usize, hit: SearchRow) void {
    if (limit == 0 or limit > hits.len) assert.panic("keeping {d} matches in room for {d}", .{ limit, hits.len });
    var at = count.*;
    for (0..count.*) |_| {
        if (at == 0 or hits[at - 1].score >= hit.score) break;
        at -= 1;
    }
    if (at >= limit) return;
    const end = @min(count.* + 1, limit);
    std.mem.copyBackwards(SearchRow, hits[at + 1 .. end], hits[at .. end - 1]);
    hits[at] = hit;
    count.* = end;
    if (count.* > limit) assert.panic("kept {d} matches past the limit of {d}", .{ count.*, limit });
}

const Query = struct { kind: embed.TextKind, wanted: []const f32, limit: usize };

fn rank(ws: *workspace.Workspace, e: *const embed.Embedding, query: Query) ![]const SearchRow {
    const kind = query.kind;
    const wanted = query.wanted;
    const limit = query.limit;
    if (wanted.len != e.dimensions) assert.panic("ranking with a {d}-value query against {d}-value vectors", .{ wanted.len, e.dimensions });
    var count: usize = 0;
    if (kind == .name) {
        for (e.names.items()) |row| {
            const d = row.definition;
            keep(&rows, &count, limit, .{ .path = d.path, .line = d.line + 1, .column = d.column + 1, .end = d.line + 1, .text = try ws.text.format("{s} {s}", .{ d.kind, d.name }), .score = vectors.cosine(wanted, e.vector(row.name)) });
        }
    } else {
        for (e.units.items()) |row| {
            const entry = if (kind == .doc) row.doc orelse continue else row.body;
            const u = row.unit;
            keep(&rows, &count, limit, .{ .path = u.path, .line = u.line + 1, .column = u.column + 1, .end = u.end_line + 1, .text = preview(u.source, u.name), .score = vectors.cosine(wanted, e.vector(entry)) });
        }
    }
    if (count > limit) assert.panic("ranked {d} matches past the limit of {d}", .{ count, limit });
    return rows[0..count];
}

fn preview(source: []const u8, name: []const u8) []const u8 {
    if (source.len == 0 or name.len == 0) assert.panic("previewing '{s}' with no source; facts.unit() keeps both", .{name});
    if (std.mem.indexOfScalar(u8, name, '\n') != null) assert.panic("previewing the name '{s}', which spans lines", .{name});
    var lines = std.mem.splitScalar(u8, source, '\n');
    const first = std.mem.trim(u8, lines.first(), " \t\r");
    for (0..source.len) |_| {
        const line = lines.next() orelse break;
        if (std.mem.indexOf(u8, line, name) != null) return std.mem.trim(u8, line, " \t\r");
    }
    if (std.mem.indexOf(u8, first, name) == null and first.len == 0) return name;
    return if (std.mem.indexOf(u8, first, name) != null) first else name;
}

pub fn renderSearch(ctx: *zclig.Context, found: []const SearchRow) !void {
    const out = console(ctx, ctx.runtime.out);
    for (found) |row| try out.writer.print("{s}:{d}:{d}: {s}\n", .{ row.path, row.line, row.column, row.text });
    if (found.len > 0 and found[0].line == 0) assert.panic("{s}: a match at line 0; rank() adds 1 to the unit's line", .{found[0].path});
    if (found.len > max_hits) assert.panic("{d} matches past the {d} search keeps; keep() stops at the limit", .{ found.len, max_hits });
}

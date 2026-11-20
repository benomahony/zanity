//! A whole run's findings, cached by everything checking the collected files reads: this
//! zanity, the working directory, the paths and rules asked for, zanity.toml, and each file's
//! path and contents. When none of it changed, the run reports the findings it kept instead of
//! replaying every file's facts and recomputing the cross-file rules from them.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const assert = @import("assert.zig");
const config = @import("config.zig");
const facts_module = @import("facts.zig");
const Definition = facts_module.Definition;
const Finding = facts_module.Finding;
const Unit = facts_module.Unit;
const rules = @import("rules.zig");
const store = @import("store.zig");
const store_runs = @import("store_runs.zig");
const Workspace = @import("workspace.zig").Workspace;

const run_format = "run-analysis-1";

/// The scopes the store keeps a run for, so checking many folders doesn't grow it without end.
const kept_runs = 16;

/// Findings, and units and definitions when --infer or --semantic reads them, in each row of
/// run_findings, so no row outgrows the store's heap.
const chunk_items = 256;

pub const Key = store_runs.RunScope;

const Chunk = struct {
    format: []const u8,
    findings: []Finding,
    units: []Unit = &.{},
    definitions: []Definition = &.{},
};

/// The run's key, or null when something it depends on can't be read, so the run is checked.
pub fn runKey(ws: *Workspace, paths: []const []const u8, selected: rules.Set) !?Key {
    if (selected.len == 0) assert.panic("keying a run with no rules selected; runCheck always selects at least one", .{});
    if (paths.len == 0) assert.panic("keying a run with no paths; zclig supplies '.' when none are given", .{});
    if (ws.files.len == 0 or ws.source_cache == null) return null;
    var scope = Sha256.init(.{});
    part(&scope, run_format);
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buffer[0 .. std.process.executablePath(ws.io, &exe_buffer) catch return null];
    const built = Io.Dir.cwd().statFile(ws.io, exe, .{}) catch return null;
    part(&scope, exe);
    part(&scope, std.mem.asBytes(&built.size));
    part(&scope, std.mem.asBytes(&built.mtime.toNanoseconds()));
    const cwd = try Io.Dir.cwd().realPathFileAlloc(ws.io, ".", std.heap.page_allocator);
    defer std.heap.page_allocator.free(cwd);
    part(&scope, cwd);
    for (paths) |path| part(&scope, path);
    for (selected.names()) |name| part(&scope, name);
    part(&scope, if (ws.inference != null) "infer" else "");
    part(&scope, if (ws.embedding != null) "semantic" else "");
    if (ws.settings) |settings| if (settings.dir.len > 0) {
        var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buffer, "{s}/{s}", .{ settings.dir, config.file_name }) catch return null;
        part(&scope, Io.Dir.cwd().readFile(ws.io, file, ws.source) catch return null);
    };
    var state = Sha256.init(.{});
    part(&state, run_format);
    for (ws.files.items()) |path| {
        part(&state, path);
        part(&state, Io.Dir.cwd().readFile(ws.io, path, ws.source) catch return null);
    }
    return .{ .scope = finish(&scope), .state = finish(&state) };
}

/// Adds the findings kept for `run` to the workspace, as checking its files would have; false
/// when there are none, or they can't be read, so the run is checked instead.
pub fn replayRun(ws: *Workspace, run: Key) !bool {
    if (ws.findings.len != 0) assert.panic("{d} findings are left from an earlier run; replay a cached run into a fresh workspace", .{ws.findings.len});
    if (ws.analysis.len == 0) assert.panic("replaying a cached run into no memory; reserve memory.Limits.analysis_bytes at startup", .{});
    const source_cache = if (ws.source_cache) |*cache| cache else return false;
    const text_start = ws.text.used;
    const checked = store_runs.eachRunChunk(source_cache, run, ws, addChunk) catch |e| {
        forget(ws, text_start);
        return if (e == error.LimitExceeded) e else false;
    };
    const files = checked orelse return false;
    if (files > ws.files.len) {
        forget(ws, text_start);
        return false;
    }
    ws.checked = files;
    ws.cache_hits = files;
    return true;
}

fn addChunk(ws: *Workspace, json: []const u8) !void {
    if (json.len == 0) assert.panic("a run_findings row is empty; the table's JSON check rejects that", .{});
    if (ws.analysis.len == 0) assert.panic("parsing a cached run into no memory; reserve memory.Limits.analysis_bytes at startup", .{});
    var fixed = std.heap.FixedBufferAllocator.init(ws.analysis);
    const parsed = std.json.parseFromSlice(Chunk, fixed.allocator(), json, .{}) catch return error.InvalidCache;
    const chunk = parsed.value;
    if (!std.mem.eql(u8, chunk.format, run_format)) return error.InvalidCache;
    if (!ws.facts.collect_units and (chunk.units.len > 0 or chunk.definitions.len > 0)) return error.InvalidCache;
    for (chunk.findings) |f| {
        const rule = rules.find(f.rule) orelse return error.InvalidCache;
        if (f.message.len == 0) return error.InvalidCache;
        var kept = try copied(Finding, ws, f);
        kept.rule = rule.name;
        if (f.edit) |edit| kept.edit = try copied(facts_module.Edit, ws, edit);
        try ws.findings.add(kept);
    }
    const facts = &ws.facts;
    for (chunk.units) |unit| try facts.units.add(try copied(Unit, ws, unit));
    for (chunk.definitions) |definition| try facts.definitions.add(try copied(Definition, ws, definition));
}

/// `value` with each of its strings copied into the run's text, out of the memory it was parsed in.
fn copied(comptime T: type, ws: *Workspace, value: T) !T {
    const text = &ws.text;
    if (text.buffer.len == 0) assert.panic("copying a cached {s} into no text; reserve memory.Limits.text_bytes at startup", .{@typeName(T)});
    var kept = value;
    var strings: usize = 0;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| if (field_type == []const u8) {
        @field(kept, name) = try text.copy(@field(value, name));
        strings += 1;
    };
    if (strings == 0) assert.panic("{s} has no strings to copy; replay it without copied()", .{@typeName(T)});
    return kept;
}

/// Drops what a replay that failed part of the way added, so the files are checked from nothing.
fn forget(ws: *Workspace, text_start: usize) void {
    if (text_start > ws.text.used) assert.panic("forgetting a replay back to byte {d} of {d} used; pass the text mark taken before it", .{ text_start, ws.text.used });
    if (ws.checked != 0) assert.panic("forgetting a replay after {d} files were counted; count them only once it succeeds", .{ws.checked});
    const facts = &ws.facts;
    ws.findings.len = 0;
    facts.units.len = 0;
    facts.definitions.len = 0;
    ws.text.used = text_start;
}

/// Keeps the findings checking the files produced, for the next run with the same key. A store
/// that can't hold them only costs the next run its shortcut.
pub fn keep(ws: *Workspace, run: Key) void {
    if (ws.analysis.len == 0) assert.panic("keeping a run in no memory; reserve memory.Limits.analysis_bytes at startup", .{});
    if (ws.checked > ws.files.len) assert.panic("keeping a run that checked {d} of {d} files; count each file once", .{ ws.checked, ws.files.len });
    const source_cache = if (ws.source_cache) |*cache| cache else return;
    const checked = std.math.cast(u32, ws.checked) orelse return;
    store_runs.keepRunAnalysis(source_cache, .{ .run = run, .checked = checked, .keep = kept_runs }, ws, encodeChunk) catch return;
}

fn encodeChunk(ws: *Workspace, chunk: usize) !?[]const u8 {
    const findings = ws.findings.items();
    const facts = &ws.facts;
    const units: []Unit = if (facts.collect_units) facts.units.items() else &.{};
    const definitions: []Definition = if (ws.embedding != null) facts.definitions.items() else &.{};
    if (ws.analysis.len == 0) assert.panic("encoding a cached run into no memory; reserve memory.Limits.analysis_bytes at startup", .{});
    const start = std.math.mul(usize, chunk, chunk_items) catch return null;
    if (start >= @max(findings.len, units.len, definitions.len) and chunk > 0) return null;
    var out: Io.Writer = .fixed(ws.analysis);
    try std.json.Stringify.value(Chunk{
        .format = run_format,
        .findings = window(Finding, findings, start),
        .units = window(Unit, units, start),
        .definitions = window(Definition, definitions, start),
    }, .{}, &out);
    if (out.buffered().len == 0) assert.panic("chunk {d} of a run encoded as nothing; JSON always holds the chunk's fields", .{chunk});
    return out.buffered();
}

/// The items of chunk starting at `start`, which is past the end once a shorter list runs out.
fn window(comptime T: type, items: []T, start: usize) []T {
    if (start % chunk_items != 0) assert.panic("a chunk starts at item {d}, not a multiple of {d}", .{ start, chunk_items });
    const from = @min(items.len, start);
    const to = @min(items.len, start + chunk_items);
    if (to < from) assert.panic("chunk at {d} ends at {d}, before it starts at {d}", .{ start, to, from });
    return items[from..to];
}

/// Adds `bytes` with its length first, so no two lists of parts hash alike.
fn part(hash: *Sha256, bytes: []const u8) void {
    if (bytes.len > std.math.maxInt(u64)) assert.panic("hashing {d} bytes, more than a length prefix holds", .{bytes.len});
    const length: u64 = bytes.len;
    if (length != bytes.len) assert.panic("a length prefix of {d} for {d} bytes; it must count every byte", .{ length, bytes.len });
    hash.update(std.mem.asBytes(&length));
    hash.update(bytes);
}

fn finish(hash: *Sha256) store.Digest {
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    if (hex.len != 64) assert.panic("a SHA-256 printed as {d} hex characters, not 64", .{hex.len});
    if (std.mem.indexOfNone(u8, &hex, "0123456789abcdef") != null) assert.panic("a SHA-256 printed as '{s}', which is not lowercase hex", .{&hex});
    return hex[0..32].*;
}

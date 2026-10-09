//! Zanity's SQLite store, in WAL mode so several runs can use it at once. It keeps --infer
//! answers and deterministic source analyses; the latter are JSON so people and agents can query
//! the facts and findings zanity reused.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_config(op: c_int, ...) c_int;
extern fn sqlite3_initialize() c_int;
extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, i: c_int, text: [*]const u8, n: c_int, destructor: isize) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, value: i64) c_int;
extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, i: c_int, value: f64) c_int;
extern fn sqlite3_column_double(stmt: *sqlite3_stmt, i: c_int) f64;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;

const ok = 0;
const row = 100;
const done = 101;
const open_readwrite = 0x2;
const open_create = 0x4;
const config_heap = 8;
const transient: isize = -1;

pub const schema =
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS units (
    \\    unit_hash TEXT PRIMARY KEY,
    \\    language TEXT NOT NULL,
    \\    source TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS answers (
    \\    model TEXT NOT NULL,
    \\    question_hash TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    probability REAL NOT NULL,
    \\    asked_at TEXT NOT NULL,
    \\    PRIMARY KEY (model, question_hash, unit_hash)
    \\);
    \\CREATE TABLE IF NOT EXISTS observations (
    \\    path TEXT NOT NULL,
    \\    rule TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    unit_name TEXT NOT NULL,
    \\    line INTEGER NOT NULL,
    \\    language TEXT NOT NULL,
    \\    model TEXT NOT NULL,
    \\    question_hash TEXT NOT NULL,
    \\    probability REAL NOT NULL,
    \\    threshold REAL NOT NULL,
    \\    fired INTEGER NOT NULL,
    \\    seen_at TEXT NOT NULL,
    \\    PRIMARY KEY (path, rule, unit_hash, line)
    \\);
    \\CREATE TABLE IF NOT EXISTS labels (
    \\    rule TEXT NOT NULL,
    \\    unit_hash TEXT NOT NULL,
    \\    real INTEGER NOT NULL,
    \\    labelled_at TEXT NOT NULL,
    \\    PRIMARY KEY (rule, unit_hash)
    \\);
    \\CREATE TABLE IF NOT EXISTS runs (
    \\    at TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    units INTEGER NOT NULL,
    \\    asked INTEGER NOT NULL,
    \\    cached INTEGER NOT NULL,
    \\    input_tokens INTEGER NOT NULL,
    \\    output_tokens INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS false_positives (
    \\    path TEXT NOT NULL,
    \\    line INTEGER NOT NULL,
    \\    column INTEGER NOT NULL,
    \\    rule TEXT NOT NULL,
    \\    message TEXT NOT NULL,
    \\    code TEXT NOT NULL,
    \\    version TEXT NOT NULL,
    \\    flagged_at TEXT NOT NULL,
    \\    PRIMARY KEY (path, rule, message, code)
    \\);
    \\CREATE TABLE IF NOT EXISTS source_analyses (
    \\    analysis_hash TEXT PRIMARY KEY,
    \\    source_hash TEXT NOT NULL,
    \\    path TEXT NOT NULL,
    \\    language TEXT NOT NULL,
    \\    result TEXT NOT NULL CHECK (json_valid(result)),
    \\    created_at TEXT NOT NULL,
    \\    used_at TEXT NOT NULL,
    \\    hits INTEGER NOT NULL DEFAULT 0
    \\);
;

const find_answer = "SELECT probability FROM answers WHERE model = ?1 AND question_hash = ?2 AND unit_hash = ?3";
const save_unit = "INSERT OR IGNORE INTO units (unit_hash, language, source) VALUES (?1, ?2, ?3)";
const save_answer = "INSERT OR REPLACE INTO answers (model, question_hash, unit_hash, probability, asked_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";

const save_observation = "INSERT OR REPLACE INTO observations (path, rule, unit_hash, unit_name, line, language, model, question_hash, probability, threshold, fired, seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const save_run = "INSERT INTO runs (at, path, units, asked, cached, input_tokens, output_tokens) VALUES (strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), ?1, ?2, ?3, ?4, ?5, ?6)";
const save_false_positive = "INSERT OR REPLACE INTO false_positives (path, line, column, rule, message, code, version, flagged_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const find_analysis = "SELECT result FROM source_analyses WHERE analysis_hash = ?1 AND source_hash = ?2";
const touch_analysis = "UPDATE source_analyses SET used_at = strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), hits = hits + 1 WHERE analysis_hash = ?1";
const save_analysis = "INSERT OR REPLACE INTO source_analyses (analysis_hash, source_hash, path, language, result, created_at, used_at, hits) VALUES (?1, ?2, ?3, ?4, ?5, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), 0)";

/// A digest: the first 32 hex characters of the SHA-256 of the parts joined with NUL.
pub const Digest = [32]u8;

pub fn digest(parts: []const []const u8) Digest {
    if (parts.len == 0) assert.panic("digesting nothing; a digest names at least one part, so pass the language and source to digest()", .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts, 0..) |part, i| {
        if (i > 0) h.update("\x00");
        h.update(part);
    }
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    if (hex.len != 64) assert.panic("a SHA-256 printed as {d} hex characters, not 64; print each of the digest's 32 bytes as two hex digits", .{hex.len});
    return hex[0..32].*;
}

/// An answer to keep: what was asked, of which function, and how sure the model was.
pub const Answer = struct {
    model: []const u8,
    question: Digest,
    unit: Digest,
    language: []const u8,
    source: []const u8,
    probability: f64,
};

/// What the model said about one question of one unit in this run, kept whether or not it was
/// sure enough to report, so precision can be measured against `labels`.
pub const Observation = struct {
    path: []const u8,
    rule: []const u8,
    unit: Digest,
    unit_name: []const u8,
    /// The line a finding would be reported on, counting from 1.
    line: u32,
    language: []const u8,
    model: []const u8,
    question: Digest,
    probability: f64,
    threshold: f64,
    fired: bool,
};

/// One --infer run: where it ran, how many units it had questions about, how many of those it
/// asked TypeSafe about and how many the store answered, and the tokens the requests used.
pub const RunTotals = struct {
    path: []const u8,
    units: usize,
    asked: usize,
    cached: usize,
    input_tokens: u64,
    output_tokens: u64,
};

/// One deterministic source analysis. `result` is a JSON document containing the local findings
/// and every fact cross-file rules need, so `source_analyses` remains useful outside zanity.
pub const Analysis = struct {
    key: Digest,
    source: Digest,
    path: []const u8,
    language: []const u8,
    result: []const u8,
};

/// A finding someone flagged as wrong from their editor: where it was, what it said, the line of
/// code it was about, and the zanity that reported it, so the rule can be made more precise.
pub const FalsePositive = struct {
    path: []const u8,
    /// Counting from 1, as `--json` reports them.
    line: u32,
    column: u32,
    rule: []const u8,
    message: []const u8,
    code: []const u8,
    version: []const u8,
};

/// Why the last store operation failed, as SQLite put it.
pub var failure: [512]u8 = undefined;
pub var failure_len: usize = 0;

var configured = false;

pub const Store = struct {
    path: []const u8,
    db: *sqlite3,
    find: *sqlite3_stmt,
    unit: *sqlite3_stmt,
    answer: *sqlite3_stmt,
    observation: *sqlite3_stmt,
    run: *sqlite3_stmt,
    find_analysis: *sqlite3_stmt,
    touch_analysis: *sqlite3_stmt,
    save_analysis: *sqlite3_stmt,
    false_positive: *sqlite3_stmt,

    /// Gives SQLite one fixed heap, then opens the store and prepares every statement, so
    /// nothing allocates after start-up. SQLite keeps the first heap for the life of the process,
    /// so `gpa` must never free it. `ZANITY_STORE` overrides where the store lives.
    pub fn initStore(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, heap_bytes: usize) !Store {
        if (heap_bytes < 1 << 20) assert.panic("SQLite was given a {d}-byte heap; it needs at least 1 MiB", .{heap_bytes});
        if (!configured) {
            const heap = try gpa.alignedAlloc(u8, .@"64", heap_bytes);
            if (sqlite3_config(config_heap, heap.ptr, @as(c_int, @intCast(heap.len)), @as(c_int, 64)) != ok) return error.StoreUnavailable;
            if (sqlite3_initialize() != ok) return error.StoreUnavailable;
            configured = true;
        }
        const path = try initPath(gpa, io, environ);
        var handle: ?*sqlite3 = null;
        if (sqlite3_open_v2(path.ptr, &handle, open_readwrite | open_create, null) != ok) {
            return if (handle) |h| failed(h) else error.StoreUnavailable;
        }
        const db = handle orelse return error.StoreUnavailable;
        _ = sqlite3_busy_timeout(db, 5000);
        if (sqlite3_exec(db, schema, null, null, null) != ok) return failed(db);
        const opened: Store = .{
            .path = path,
            .db = db,
            .find = try prepare(db, find_answer),
            .unit = try prepare(db, save_unit),
            .answer = try prepare(db, save_answer),
            .observation = try prepare(db, save_observation),
            .run = try prepare(db, save_run),
            .find_analysis = try prepare(db, find_analysis),
            .touch_analysis = try prepare(db, touch_analysis),
            .save_analysis = try prepare(db, save_analysis),
            .false_positive = try prepare(db, save_false_positive),
        };
        if (!configured) assert.panic("opened {s} before SQLite was given its heap; install the heap with sqlite3_config before opening the store", .{path});
        return opened;
    }

    /// The model's cached answer to `question` about `unit`, if either tool has asked it.
    pub fn cached(self: *const Store, model: []const u8, question: Digest, unit: Digest) !?f64 {
        if (model.len == 0) assert.panic("looking up an answer with no model name; pass the model --infer asks, from the tai client", .{});
        if (std.mem.eql(u8, &question, &unit)) assert.panic("looking up an answer whose question and function have the same digest {s}; one was passed as the other", .{&question});
        defer _ = sqlite3_reset(self.find);
        try bind(self.find, 1, model);
        try bind(self.find, 2, &question);
        try bind(self.find, 3, &unit);
        return switch (sqlite3_step(self.find)) {
            row => sqlite3_column_double(self.find, 0),
            done => null,
            else => failed(self.db),
        };
    }

    /// Keeps an answer and the function it was about.
    pub fn keepAnswer(self: *const Store, a: Answer) !void {
        if (a.probability < 0 or a.probability > 1) assert.panic("keeping a probability of {d}; answers are between 0 and 1, so check how infer.zig reads TypeSafe's answer", .{a.probability});
        if (a.language.len == 0 or a.source.len == 0) assert.panic("keeping an answer about a function with no language or source; plan() must pass the unit's language and source", .{});
        defer _ = sqlite3_reset(self.unit);
        defer _ = sqlite3_reset(self.answer);
        try bind(self.unit, 1, &a.unit);
        try bind(self.unit, 2, a.language);
        try bind(self.unit, 3, a.source);
        if (sqlite3_step(self.unit) != done) return failed(self.db);
        try bind(self.answer, 1, a.model);
        try bind(self.answer, 2, &a.question);
        try bind(self.answer, 3, &a.unit);
        if (sqlite3_bind_double(self.answer, 4, a.probability) != ok) return failed(self.db);
        if (sqlite3_step(self.answer) != done) return failed(self.db);
    }

    /// Keeps what the model said about a unit, replacing what an earlier run said there.
    pub fn observe(self: *const Store, o: Observation) !void {
        if (o.line == 0) assert.panic("{s}: observing '{s}' on line 0; lines count from 1, so pass the unit's line plus 1", .{ o.path, o.unit_name });
        if (o.fired != (o.probability >= o.threshold)) assert.panic("{s}: '{s}' {s} at {d} against a threshold of {d}; fired must be whether the probability reaches the threshold", .{ o.path, o.rule, if (o.fired) "fired" else "did not fire", o.probability, o.threshold });
        defer _ = sqlite3_reset(self.observation);
        try bind(self.observation, 1, o.path);
        try bind(self.observation, 2, o.rule);
        try bind(self.observation, 3, &o.unit);
        try bind(self.observation, 4, o.unit_name);
        try bindInt(self.observation, 5, o.line);
        try bind(self.observation, 6, o.language);
        try bind(self.observation, 7, o.model);
        try bind(self.observation, 8, &o.question);
        if (sqlite3_bind_double(self.observation, 9, o.probability) != ok) return failed(self.db);
        if (sqlite3_bind_double(self.observation, 10, o.threshold) != ok) return failed(self.db);
        try bindInt(self.observation, 11, @intFromBool(o.fired));
        if (sqlite3_step(self.observation) != done) return failed(self.db);
    }

    /// Keeps a row for this run.
    pub fn keepRun(self: *const Store, r: RunTotals) !void {
        if (r.asked + r.cached != r.units) assert.panic("a run with {d} units, {d} asked and {d} answered from the store; each unit is either asked or fully cached", .{ r.units, r.asked, r.cached });
        if (r.path.len == 0) assert.panic("recording a run with no path; pass the directory zanity ran in", .{});
        defer _ = sqlite3_reset(self.run);
        try bind(self.run, 1, r.path);
        try bindInt(self.run, 2, r.units);
        try bindInt(self.run, 3, r.asked);
        try bindInt(self.run, 4, r.cached);
        try bindInt(self.run, 5, r.input_tokens);
        try bindInt(self.run, 6, r.output_tokens);
        if (sqlite3_step(self.run) != done) return failed(self.db);
    }

    /// Keeps a flagged finding, replacing an earlier flag of the same finding on the same code.
    pub fn keepFalsePositive(self: *const Store, f: FalsePositive) !void {
        if (f.line == 0 or f.column == 0) assert.panic("{s}: flagging '{s}' at line {d} column {d}; both count from 1", .{ f.path, f.rule, f.line, f.column });
        if (f.path.len == 0 or f.rule.len == 0) assert.panic("flagging a finding with no path or rule; pass the finding the editor flagged", .{});
        defer _ = sqlite3_reset(self.false_positive);
        try bind(self.false_positive, 1, f.path);
        try bindInt(self.false_positive, 2, f.line);
        try bindInt(self.false_positive, 3, f.column);
        try bind(self.false_positive, 4, f.rule);
        try bind(self.false_positive, 5, f.message);
        try bind(self.false_positive, 6, f.code);
        try bind(self.false_positive, 7, f.version);
        if (sqlite3_step(self.false_positive) != done) return failed(self.db);
    }

    /// Copies a cached JSON analysis into caller-owned memory, and records that it was reused.
    pub fn cachedAnalysis(self: *const Store, buffer: []u8, key: Digest, source: Digest) !?[]const u8 {
        if (buffer.len == 0) assert.panic("reading a cached analysis into no memory; reserve memory.Limits.analysis_bytes at startup", .{});
        if (std.mem.eql(u8, &key, &source)) assert.panic("an analysis context and its source have the same digest {s}; one was passed as the other", .{&key});
        defer _ = sqlite3_reset(self.find_analysis);
        try bind(self.find_analysis, 1, &key);
        try bind(self.find_analysis, 2, &source);
        switch (sqlite3_step(self.find_analysis)) {
            done => return null,
            row => {},
            else => return failed(self.db),
        }
        const length = sqlite3_column_bytes(self.find_analysis, 0);
        if (length <= 0) return error.StoreUnavailable;
        if (length > buffer.len) return null;
        const pointer = sqlite3_column_text(self.find_analysis, 0) orelse return error.StoreUnavailable;
        const result = buffer[0..@intCast(length)];
        @memcpy(result, pointer[0..@intCast(length)]);
        defer _ = sqlite3_reset(self.touch_analysis);
        try bind(self.touch_analysis, 1, &key);
        if (sqlite3_step(self.touch_analysis) != done) return failed(self.db);
        return result;
    }

    /// Keeps a deterministic analysis, replacing the same path/rules context after a source edit.
    pub fn keepAnalysis(self: *const Store, analysis: Analysis) !void {
        if (analysis.path.len == 0 or analysis.language.len == 0) assert.panic("keeping an analysis without a path or language; pass the file the checker analysed", .{});
        if (analysis.result.len == 0) assert.panic("keeping an empty analysis for {s}; encode its facts and findings as JSON first", .{analysis.path});
        defer _ = sqlite3_reset(self.save_analysis);
        try bind(self.save_analysis, 1, &analysis.key);
        try bind(self.save_analysis, 2, &analysis.source);
        try bind(self.save_analysis, 3, analysis.path);
        try bind(self.save_analysis, 4, analysis.language);
        try bind(self.save_analysis, 5, analysis.result);
        if (sqlite3_step(self.save_analysis) != done) return failed(self.db);
    }
};

const store_name = "zanity.db";

/// Where the store lives: `ZANITY_STORE`, or zanity.db in zanity's folder of the user's cache directory.
fn initPath(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map) ![:0]const u8 {
    if (environ.get("ZANITY_STORE")) |path| {
        if (path.len == 0) assert.panic("ZANITY_STORE is set but empty; unset it or name a file", .{});
        return gpa.dupeSentinel(u8, path, 0);
    }
    const cache = if (environ.get("XDG_CACHE_HOME")) |xdg| try gpa.dupe(u8, xdg) else blk: {
        const home = environ.get("HOME") orelse return error.StoreUnavailable;
        break :blk try std.fs.path.join(gpa, &.{ home, ".cache" });
    };
    const dir = try std.fs.path.join(gpa, &.{ cache, "zanity" });
    Io.Dir.cwd().createDirPath(io, dir) catch return error.StoreUnavailable;
    const path = try std.fs.path.joinZ(gpa, &.{ dir, store_name });
    if (!std.mem.endsWith(u8, path, store_name)) assert.panic("the store path {s} does not end in {s}; initPath() must join the cache directory with it", .{ path, store_name });
    return path;
}

fn prepare(db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
    if (sql.len == 0) assert.panic("preparing an empty statement; pass the SQL to prepare()", .{});
    if (std.mem.indexOfScalar(u8, sql, ';') != null) assert.panic("'{s}' holds more than one statement; prepare them one at a time", .{sql});
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != ok) return failed(db);
    return stmt orelse assert.panic("SQLite prepared '{s}' but returned no statement; check the SQL passed to prepare() is a single statement", .{sql});
}

fn bind(stmt: *sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (text.len > std.math.maxInt(c_int)) assert.panic("binding {d} bytes of text, more than SQLite takes in one parameter; shorten the function's source, or split the function", .{text.len});
    if (sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != ok) return error.StoreUnavailable;
}

fn bindInt(stmt: *sqlite3_stmt, index: c_int, value: u64) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (value > std.math.maxInt(i64)) assert.panic("binding {d}, past the largest integer SQLite stores; count something smaller", .{value});
    if (sqlite3_bind_int64(stmt, index, @intCast(value)) != ok) return error.StoreUnavailable;
}

/// Records SQLite's reason for the last failure, for the error message, and reports it.
fn failed(db: *sqlite3) error{StoreUnavailable} {
    const message = std.mem.span(sqlite3_errmsg(db));
    if (message.len == 0) assert.panic("SQLite reported a failure with no message; check the store file with the sqlite3 command-line tool", .{});
    failure_len = @min(message.len, failure.len);
    @memcpy(failure[0..failure_len], message[0..failure_len]);
    if (failure_len == 0) assert.panic("kept none of SQLite's {d}-byte failure message; failed() must copy at least part of SQLite's message", .{message.len});
    return error.StoreUnavailable;
}

test "digests stay the same, so answers already in a store keep matching" {
    const unit = digest(&.{ "lang-a", "def f():\n    return 1\n" });
    try std.testing.expectEqualStrings("307f739720f5a61cf9920d8646b0f444", &unit);
    const question = digest(&.{"Does the function raise, assert, return or log an error message too vague to identify the problem, for example \"something went wrong\" or \"invalid input\" without saying which input, which value or what was expected?"});
    try std.testing.expectEqualStrings("11cea346266196eca9ef54648779f8fb", &question);
}

test "an answer kept in the store is found again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const unit = digest(&.{ "lang-a", "fn f() void {}" });
    const question = digest(&.{"Is it fine?"});
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-1", question, unit));
    try store.keepAnswer(.{ .model = "jev-1", .question = question, .unit = unit, .language = "lang-a", .source = "fn f() void {}", .probability = 0.25 });
    try std.testing.expectEqual(@as(?f64, 0.25), try store.cached("jev-1", question, unit));
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-2", question, unit));
}

test "a source analysis is queryable JSON and records cache hits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const key = digest(&.{"analysis"});
    const source = digest(&.{"source"});
    try store.keepAnalysis(.{ .key = key, .source = source, .path = "src/a.py", .language = "lang-a", .result = "{\"findings\":[{\"rule\":\"unbounded-loop\"}]}" });
    var buffer: [1024]u8 = undefined;
    const result = (try store.cachedAnalysis(&buffer, key, source)).?;
    try std.testing.expectEqualStrings("{\"findings\":[{\"rule\":\"unbounded-loop\"}]}", result);
    try std.testing.expect((try store.cachedAnalysis(&buffer, key, digest(&.{"changed"}))) == null);
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT json_array_length(result, '$.findings') FROM source_analyses"));
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT hits FROM source_analyses"));
}

/// The first column of the first row `sql` returns, for reading back what a test kept.
fn scalar(db: *sqlite3, sql: []const u8) !f64 {
    if (!std.mem.startsWith(u8, sql, "SELECT ")) assert.panic("'{s}' is not a query; scalar() only reads back what a test kept", .{sql});
    const stmt = try prepare(db, sql);
    defer _ = sqlite3_reset(stmt);
    if (sqlite3_step(stmt) != row) return failed(db);
    const value = sqlite3_column_double(stmt, 0);
    if (std.math.isNan(value)) assert.panic("'{s}' read back NaN; SQLite reads NULL as 0, so check the column holds numbers", .{sql});
    return value;
}

test "every observation is kept, the latest per place, and each run adds a row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    const store = try Store.initStore(std.heap.page_allocator, std.testing.io, &environ, 8 << 20);
    const seen: Observation = .{ .path = "a.py", .rule = "hollow-test", .unit = digest(&.{"u"}), .unit_name = "test_a", .line = 3, .language = "lang-a", .model = "jev-1", .question = digest(&.{"q"}), .probability = 0.4, .threshold = 0.8, .fired = false };
    try store.observe(seen);
    var again = seen;
    again.probability = 0.9;
    again.fired = true;
    try store.observe(again);
    try store.keepRun(.{ .path = dir, .units = 2, .asked = 1, .cached = 1, .input_tokens = 300, .output_tokens = 30 });
    try store.keepRun(.{ .path = dir, .units = 2, .asked = 0, .cached = 2, .input_tokens = 0, .output_tokens = 0 });
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT count(*) FROM observations"));
    try std.testing.expectEqual(@as(f64, 0.9), try scalar(store.db, "SELECT probability FROM observations WHERE fired = 1"));
    try std.testing.expectEqual(@as(f64, 300), try scalar(store.db, "SELECT sum(input_tokens) FROM runs"));
}

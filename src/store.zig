//! Zanity's SQLite store, in WAL mode so several runs can use it at once. It keeps --infer
//! answers and deterministic source analyses; the latter are JSON so people and agents can query
//! the facts and findings zanity reused.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_config(op: c_int, ...) c_int;
extern fn sqlite3_initialize() c_int;
extern fn sqlite3_close_v2(db: *sqlite3) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern fn sqlite3_errcode(db: *sqlite3) c_int;
extern fn sqlite3_db_handle(stmt: *sqlite3_stmt) *sqlite3;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, i: c_int, text: [*]const u8, n: c_int, destructor: isize) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, value: i64) c_int;
extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, i: c_int, value: f64) c_int;
extern fn sqlite3_column_double(stmt: *sqlite3_stmt, i: c_int) f64;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, i: c_int) i64;
extern fn sqlite3_column_type(stmt: *sqlite3_stmt, i: c_int) c_int;
extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;

const ok = 0;
const row = 100;
const done = 101;
const open_readwrite = 0x2;
const open_create = 0x4;
const config_heap = 8;
const transient: isize = -1;
const column_null = 5;

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
const insert_unit_if_missing_sql = "INSERT OR IGNORE INTO units (unit_hash, language, source) VALUES (?1, ?2, ?3)";
const upsert_answer_sql = "INSERT OR REPLACE INTO answers (model, question_hash, unit_hash, probability, asked_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";

const save_observation = "INSERT OR REPLACE INTO observations (path, rule, unit_hash, unit_name, line, language, model, question_hash, probability, threshold, fired, seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const save_run = "INSERT INTO runs (at, path, units, asked, cached, input_tokens, output_tokens) VALUES (strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'), ?1, ?2, ?3, ?4, ?5, ?6)";
const save_false_positive = "INSERT OR REPLACE INTO false_positives (path, line, column, rule, message, code, version, flagged_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const find_analysis = "SELECT result FROM source_analyses WHERE analysis_hash = ?1 AND source_hash = ?2";
const save_label = "INSERT OR REPLACE INTO labels (rule, unit_hash, real, labelled_at) VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";
const find_label = "SELECT real FROM labels WHERE rule = ?1 AND unit_hash = ?2";
/// Every answer kept, newest first, with its label when it has one; ?1 narrows it to one rule,
/// ?2 and ?3 to one path and line.
const list_observed = "SELECT o.rule, o.path, o.line, o.unit_hash, o.unit_name, o.probability, o.threshold, l.real FROM observations o LEFT JOIN labels l ON l.rule = o.rule AND l.unit_hash = o.unit_hash WHERE (?1 = '' OR o.rule = ?1) AND (?2 = '' OR o.path = ?2) AND (?3 = 0 OR o.line = ?3) ORDER BY o.seen_at DESC";
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

/// One kept answer, as `list_observed` reads it: valid until the next row is read.
pub const Observed = struct {
    rule: []const u8,
    path: []const u8,
    line: u32,
    unit: Digest,
    unit_name: []const u8,
    probability: f64,
    threshold: f64,
    /// Whether someone confirmed the finding (true) or said it is not a problem (false).
    real: ?bool,
};

/// Which answers `eachObserved` reads: any empty field matches every answer.
pub const Narrow = struct { rule: []const u8 = "", path: []const u8 = "", line: u32 = 0 };

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

/// Why the calling thread's last store operation failed, as SQLite put it.
/// A worker using another connection cannot overwrite the caller's diagnostic.
pub threadlocal var failure: [512]u8 = undefined;
pub threadlocal var failure_len: usize = 0;

/// Process-lifetime ownership of SQLite's accepted heap and the lock guarding its initialization.
const ProcessHeap = struct { configured: bool = false, mutex: Io.Mutex = .init };
var process_heap: ProcessHeap = .{};
const minimum_heap_bytes = 1 << 20;
const sqlite_heap_alignment = 64;
/// Wait briefly for another local process holding a SQLite write lock.
const busy_timeout_ms = 5000;
/// Space left for cleanup context after retaining the original SQLite failure prefix.
const rollback_context_bytes = 128;

/// One connection and its prepared statements, used by one thread at a time.
/// Batch holds its mutex across complete operations when its workers share this connection.
pub const Store = struct {
    path: []const u8,
    db: *sqlite3,
    find: *sqlite3_stmt,
    insert_unit_if_missing: *sqlite3_stmt,
    upsert_answer_by_identity: *sqlite3_stmt,
    observation: *sqlite3_stmt,
    run: *sqlite3_stmt,
    find_analysis: *sqlite3_stmt,
    touch_analysis: *sqlite3_stmt,
    save_analysis: *sqlite3_stmt,
    false_positive: *sqlite3_stmt,
    save_label: *sqlite3_stmt,
    find_label: *sqlite3_stmt,
    list_observed: *sqlite3_stmt,

    /// Gives SQLite one fixed heap, then opens the store and prepares every statement, so
    /// nothing allocates after start-up. SQLite keeps the first heap for the life of the process,
    /// so `gpa` must never free it. `ZANITY_STORE` overrides where the store lives.
    pub fn initStore(gpa: Allocator, io: Io, operator_environ: *const std.process.Environ.Map, heap_bytes: usize) !Store {
        // This is the operator's local analysis cache, opened under their filesystem permissions.
        try initializeSqliteHeap(&process_heap, gpa, io, heap_bytes);
        const path = try initPath(gpa, io, operator_environ);
        errdefer gpa.free(path);
        const db = try openLocalCache(path);
        errdefer _ = sqlite3_close_v2(db);
        const opened = try prepareStoreStatements(path, db);
        if (opened.db != db) assert.panic("prepared local-cache connection 0x{x}, expected opened database 0x{x}; prepareStoreStatements() must retain initStore()'s connection", .{ @intFromPtr(opened.db), @intFromPtr(db) });
        if (opened.path.ptr != path.ptr) assert.panic("prepared cache path at 0x{x}, expected owned path at 0x{x}; prepareStoreStatements() must retain initStore()'s path", .{ @intFromPtr(opened.path.ptr), @intFromPtr(path.ptr) });
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
            else => captureDatabaseFailure(self.db),
        };
    }

    /// Idempotently caches a source unit and an answer identified by model, question and unit.
    /// Repeated delivery inserts no duplicate unit and replaces the same keyed answer row.
    pub fn keepAnswer(self: *const Store, a: Answer) !void {
        // This operator-owned local SQLite cache has a finite busy_timeout_ms lock wait.
        // No remote database or service is contacted; the keyed writes below are replay-safe.
        if (a.probability < 0 or a.probability > 1) assert.panic("keeping a probability of {d}; answers are between 0 and 1, so check how infer.zig reads TypeSafe's answer", .{a.probability});
        if (a.language.len == 0 or a.source.len == 0) assert.panic("keeping an answer about a function with no language or source; plan() must pass the unit's language and source", .{});
        if (sqlite3_exec(self.db, "SAVEPOINT zanity_answer", null, null, null) != ok) return captureDatabaseFailure(self.db);
        errdefer self.rollbackUncommittedAnswer();
        defer _ = sqlite3_reset(self.insert_unit_if_missing);
        defer _ = sqlite3_reset(self.upsert_answer_by_identity);
        // INSERT OR IGNORE uses the source-content hash as the units primary key.
        try bind(self.insert_unit_if_missing, 1, &a.unit);
        try bind(self.insert_unit_if_missing, 2, a.language);
        try bind(self.insert_unit_if_missing, 3, a.source);
        if (sqlite3_step(self.insert_unit_if_missing) != done) return captureDatabaseFailure(self.db);
        // INSERT OR REPLACE uses (model, question_hash, unit_hash), so retries update one identity.
        try bind(self.upsert_answer_by_identity, 1, a.model);
        try bind(self.upsert_answer_by_identity, 2, &a.question);
        try bind(self.upsert_answer_by_identity, 3, &a.unit);
        if (sqlite3_bind_double(self.upsert_answer_by_identity, 4, a.probability) != ok) return captureDatabaseFailure(self.db);
        if (sqlite3_step(self.upsert_answer_by_identity) != done) return captureDatabaseFailure(self.db);
        if (sqlite3_exec(self.db, "RELEASE zanity_answer", null, null, null) != ok) return captureDatabaseFailure(self.db);
    }

    /// Rolls back the source/answer pair after its original SQLite cause was copied to this thread.
    fn rollbackUncommittedAnswer(self: *const Store) void {
        if (failure_len == 0) assert.panic("rolling back an answer with {d} diagnostic bytes; retain the original failure before cleanup", .{failure_len});
        const statement_db = sqlite3_db_handle(self.upsert_answer_by_identity);
        if (self.db != statement_db) assert.panic("rolling back cache 0x{x} with an answer statement owned by 0x{x}; retain one connection for both answer writes", .{ @intFromPtr(self.db), @intFromPtr(statement_db) });
        // This Store method is the local SQLite data-access layer, not a caller bypassing it.
        const status = sqlite3_exec(self.db, "ROLLBACK TO zanity_answer; RELEASE zanity_answer", null, null, null);
        if (status != ok) appendAnswerRollbackFailure(status);
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
        if (sqlite3_bind_double(self.observation, 9, o.probability) != ok) return captureDatabaseFailure(self.db);
        if (sqlite3_bind_double(self.observation, 10, o.threshold) != ok) return captureDatabaseFailure(self.db);
        try bindInt(self.observation, 11, @intFromBool(o.fired));
        if (sqlite3_step(self.observation) != done) return captureDatabaseFailure(self.db);
    }

    /// Records whether the finding `rule` makes about `unit` is real: confirmed, or not a problem.
    pub fn label(self: *const Store, rule: []const u8, unit: Digest, real: bool) !void {
        if (rule.len == 0) assert.panic("labelling a finding with no rule; pass the rule it was reported under", .{});
        if (std.mem.indexOfNone(u8, &unit, "0123456789abcdef") != null) assert.panic("labelling '{s}' about '{s}', which is not a digest", .{ rule, &unit });
        defer _ = sqlite3_reset(self.save_label);
        try bind(self.save_label, 1, rule);
        try bind(self.save_label, 2, &unit);
        try bindInt(self.save_label, 3, @intFromBool(real));
        if (sqlite3_step(self.save_label) != done) return captureDatabaseFailure(self.db);
    }

    /// Whether someone said `rule`'s finding about `unit` is real, if anyone has.
    pub fn labelled(self: *const Store, rule: []const u8, unit: Digest) !?bool {
        if (rule.len == 0) assert.panic("looking up a label with no rule; pass the rule it was reported under", .{});
        if (std.mem.indexOfNone(u8, &unit, "0123456789abcdef") != null) assert.panic("looking up '{s}' about '{s}', which is not a digest", .{ rule, &unit });
        defer _ = sqlite3_reset(self.find_label);
        try bind(self.find_label, 1, rule);
        try bind(self.find_label, 2, &unit);
        return switch (sqlite3_step(self.find_label)) {
            row => sqlite3_column_int64(self.find_label, 0) != 0,
            done => null,
            else => captureDatabaseFailure(self.db),
        };
    }

    /// Runs the CLI's compile-time callback over the operator's filtered local-cache answers.
    /// Row text is borrowed until the next row; callbacks copy anything they retain.
    pub fn eachObserved(operator_cache: *const Store, operator_selection: Narrow, cli_context: anytype, comptime visit: fn (@TypeOf(cli_context), Observed) anyerror!bool) !void {
        // initStore() already opened this local file under the invoking OS user's permissions.
        // The operator chooses these CLI filters; no remote caller supplies the compile-time visitor.
        const stmt = operator_cache.list_observed;
        const statement_db = sqlite3_db_handle(stmt);
        if (statement_db != operator_cache.db) assert.panic("observation statement uses connection 0x{x}, expected operator cache 0x{x}; retain its owning local connection", .{ @intFromPtr(statement_db), @intFromPtr(operator_cache.db) });
        defer _ = sqlite3_reset(stmt);
        try bind(stmt, 1, operator_selection.rule);
        try bind(stmt, 2, operator_selection.path);
        try bindInt(stmt, 3, operator_selection.line);
        for (0..std.math.maxInt(u32)) |_| switch (sqlite3_step(stmt)) {
            row => {
                const observed = try readObservedRow(stmt);
                if (operator_selection.rule.len != 0 and !std.mem.eql(u8, observed.rule, operator_selection.rule)) assert.panic("observation query returned rule '{s}', expected selected rule '{s}'; retain the built-in SQL filter when decoding its rows", .{ observed.rule, operator_selection.rule });
                if (!try visit(cli_context, observed)) return;
            },
            done => return,
            else => return captureDatabaseFailure(operator_cache.db),
        };
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
        if (sqlite3_step(self.run) != done) return captureDatabaseFailure(self.db);
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
        if (sqlite3_step(self.false_positive) != done) return captureDatabaseFailure(self.db);
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
            else => return captureDatabaseFailure(self.db),
        }
        const length = sqlite3_column_bytes(self.find_analysis, 0);
        if (length <= 0) return error.StoreUnavailable;
        if (length > buffer.len) return null;
        const pointer = sqlite3_column_text(self.find_analysis, 0) orelse return error.StoreUnavailable;
        const result = buffer[0..@intCast(length)];
        @memcpy(result, pointer[0..@intCast(length)]);
        defer _ = sqlite3_reset(self.touch_analysis);
        try bind(self.touch_analysis, 1, &key);
        if (sqlite3_step(self.touch_analysis) != done) return captureDatabaseFailure(self.db);
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
        if (sqlite3_step(self.save_analysis) != done) return captureDatabaseFailure(self.db);
    }
};

/// Serializes SQLite's global heap setup. SQLite owns an accepted heap until process exit.
fn initializeSqliteHeap(owner: *ProcessHeap, gpa: Allocator, io: Io, heap_bytes: usize) !void {
    if (heap_bytes < minimum_heap_bytes) assert.panic("SQLite was given a {d}-byte heap; it needs at least {d} bytes", .{ heap_bytes, minimum_heap_bytes });
    if (heap_bytes > std.math.maxInt(c_int)) {
        describeStoreFailure("SQLite heap size {d} exceeds its {d}-byte limit; reduce memory.Limits.store_bytes", .{ heap_bytes, std.math.maxInt(c_int) });
        return error.StoreUnavailable;
    }
    owner.mutex.lockUncancelable(io);
    defer owner.mutex.unlock(io);
    if (!owner.configured) {
        const heap = gpa.alignedAlloc(u8, .@"64", heap_bytes) catch {
            describeStoreFailure("Could not allocate SQLite's {d}-byte heap; free memory or reduce memory.Limits.store_bytes", .{heap_bytes});
            return error.StoreUnavailable;
        };
        if (@intFromPtr(heap.ptr) % sqlite_heap_alignment != 0) assert.panic("SQLite's heap is not {d}-byte aligned; alignedAlloc() must honor its requested alignment", .{sqlite_heap_alignment});
        const configured = sqlite3_config(config_heap, heap.ptr, @as(c_int, @intCast(heap.len)), @as(c_int, sqlite_heap_alignment));
        if (configured != ok) {
            gpa.free(heap);
            describeStoreFailure("SQLite rejected its fixed heap with status {d}; initialize zanity's cache before any other SQLite user", .{configured});
            return error.StoreUnavailable;
        }
        // Even failed sqlite3_initialize() may retain this accepted heap; never free or replace it.
        owner.configured = true;
    }
    const initialized = sqlite3_initialize();
    if (initialized != ok) {
        describeStoreFailure("SQLite initialization failed with status {d}; increase memory.Limits.store_bytes and retry", .{initialized});
        return error.StoreUnavailable;
    }
}

/// Supplies an actionable local-cache diagnostic to the calling thread's store-error path.
fn describeStoreFailure(comptime template: []const u8, args: anytype) void {
    if (template.len == 0) assert.panic("store failure has no description; pass a message naming the failing configuration and recovery", .{});
    // failure/failure_len are threadlocal, so no other connection can replace this caller's cause.
    const shown = std.fmt.bufPrint(&failure, template, args) catch assert.panic("store diagnostic '{s}' exceeds the {d}-byte diagnostic buffer; shorten the template", .{ template, failure.len });
    failure_len = shown.len;
    if (failure_len == 0) assert.panic("the store diagnostic template '{s}' formatted to no diagnostic; retain its description for the caller", .{template});
}

/// Adds bounded cleanup context without overwriting the calling thread's original failure prefix.
fn appendAnswerRollbackFailure(status: c_int) void {
    if (status == ok) assert.panic("recording answer rollback failure with successful SQLite status {d}; only append cleanup context on failure", .{status});
    if (failure_len > failure.len) assert.panic("the original SQLite cause has {d} bytes in room for {d}; bound it before adding rollback context", .{ failure_len, failure.len });
    // Both diagnostics are threadlocal. The reserved suffix budget is independent of runtime text.
    var output: Io.Writer = .fixed(&failure);
    output.end = @min(failure_len, failure.len - rollback_context_bytes);
    output.print("; answer rollback failed with SQLite status {d}; restart zanity before reusing this cache", .{status}) catch assert.panic("answer rollback status {d} exceeds its {d}-byte context budget; shorten the fixed diagnostic", .{ status, rollback_context_bytes });
    failure_len = output.end;
}

/// Opens only the chosen local cache; every unsuccessful opening releases its connection.
fn openLocalCache(path: [:0]const u8) !*sqlite3 {
    if (path.len == 0) assert.panic("opening an empty local cache path; initPath() must reject empty operator overrides", .{});
    var handle: ?*sqlite3 = null;
    if (sqlite3_open_v2(path.ptr, &handle, open_readwrite | open_create, null) != ok) {
        const failed_db = handle orelse return error.StoreUnavailable;
        defer _ = sqlite3_close_v2(failed_db);
        return captureDatabaseFailure(failed_db);
    }
    const db = handle orelse return error.StoreUnavailable;
    errdefer _ = sqlite3_close_v2(db);
    if (sqlite3_busy_timeout(db, busy_timeout_ms) != ok) return captureDatabaseFailure(db);
    if (sqlite3_exec(db, schema, null, null, null) != ok) return captureDatabaseFailure(db);
    if (db != handle.?) assert.panic("opened local-cache connection 0x{x}, expected SQLite's handle 0x{x}; openLocalCache() must return that handle", .{ @intFromPtr(db), @intFromPtr(handle.?) });
    return db;
}

/// Built-in SQL for each prepared statement owned by Store, with matching field names.
const statement_sql = .{
    .find = find_answer,
    .insert_unit_if_missing = insert_unit_if_missing_sql,
    .upsert_answer_by_identity = upsert_answer_sql,
    .observation = save_observation,
    .run = save_run,
    .find_analysis = find_analysis,
    .touch_analysis = touch_analysis,
    .save_analysis = save_analysis,
    .false_positive = save_false_positive,
    .save_label = save_label,
    .find_label = find_label,
    .list_observed = list_observed,
};

/// Returns a complete statement owner, finalizing any partial preparation before an error escapes.
fn prepareStoreStatements(path: [:0]const u8, db: *sqlite3) !Store {
    var opened: Store = undefined;
    opened.path = path;
    opened.db = db;
    const names = @typeInfo(@TypeOf(statement_sql)).@"struct".field_names;
    comptime {
        for (@typeInfo(Store).@"struct".field_names) |name| {
            if (std.mem.eql(u8, name, "path") or std.mem.eql(u8, name, "db")) continue;
            if (!@hasField(@TypeOf(statement_sql), name)) @compileError("missing built-in SQL for Store." ++ name);
        }
    }
    var prepared: usize = 0;
    errdefer {
        inline for (names, 0..) |name, i| {
            if (i < prepared) _ = sqlite3_finalize(@field(opened, name));
        }
    }
    inline for (names) |name| {
        @field(opened, name) = try prepare(db, @field(statement_sql, name));
        prepared += 1;
    }
    if (prepared != names.len) assert.panic("prepared {d} of {d} local-cache statements; prepareStoreStatements() must fill every statement field", .{ prepared, names.len });
    if (opened.path.ptr != path.ptr) assert.panic("statement owner has cache path at 0x{x}, expected initStore()'s path at 0x{x}; retain the supplied path", .{ @intFromPtr(opened.path.ptr), @intFromPtr(path.ptr) });
    return opened;
}

const store_name = "zanity.db";

/// Where the store lives: `ZANITY_STORE`, or zanity.db in zanity's folder of the user's cache directory.
fn initPath(gpa: Allocator, io: Io, operator_environ: *const std.process.Environ.Map) ![:0]const u8 {
    // The person running zanity chooses this local cache path through their own environment.
    if (operator_environ.get("ZANITY_STORE")) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
            const reason = "ZANITY_STORE is empty or contains a NUL byte; unset it or name a writable SQLite file";
            failure_len = reason.len;
            @memcpy(failure[0..failure_len], reason);
            return error.StoreUnavailable;
        }
        const owned = try gpa.dupeSentinel(u8, path, 0);
        if (owned.len != path.len) assert.panic("copied {d} bytes of the {d}-byte store path; dupeSentinel() must retain the whole operator-supplied path", .{ owned.len, path.len });
        return owned;
    }
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.path.joinZ(gpa, &.{ try cacheDir(&dir_buffer, io, operator_environ), store_name });
    if (!std.mem.endsWith(u8, path, store_name)) assert.panic("the store path {s} does not end in {s}; initPath() must join the cache directory with it", .{ path, store_name });
    return path;
}

/// zanity's folder of the user's cache directory, written into `buffer` and created if it is missing.
pub fn cacheDir(buffer: []u8, io: Io, operator_environ: *const std.process.Environ.Map) ![]const u8 {
    if (buffer.len < std.fs.max_path_bytes) assert.panic("the cache directory gets {d} bytes, less than a path may need; pass a buffer of std.fs.max_path_bytes", .{buffer.len});
    // These are local filesystem preferences set by the operator, subject to OS permissions.
    // Keep an explicit XDG override first; otherwise use the target platform's cache root.
    const xdg = operator_environ.get("XDG_CACHE_HOME");
    const windows = builtin.os.tag == .windows;
    const root = xdg orelse if (windows)
        operator_environ.get("LOCALAPPDATA") orelse return error.StoreUnavailable
    else
        operator_environ.get("HOME") orelse return error.StoreUnavailable;
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.StoreUnavailable;
    const sep = std.fs.path.sep_str;
    const named = if (xdg != null or windows)
        std.fmt.bufPrint(buffer, "{s}" ++ sep ++ "zanity", .{root})
    else
        std.fmt.bufPrint(buffer, "{s}" ++ sep ++ ".cache" ++ sep ++ "zanity", .{root});
    const dir = named catch return error.StoreUnavailable;
    Io.Dir.cwd().createDirPath(io, dir) catch return error.StoreUnavailable;
    if (!std.mem.endsWith(u8, dir, "zanity")) assert.panic("the cache directory {s} is not zanity's folder; cacheDir() must join the cache directory with it", .{dir});
    return dir;
}

/// Prepares only SQL built into this executable; external values are bound as parameters later.
/// Validates persisted cache data before exposing a borrowed observation to a CLI callback.
fn readObservedRow(stmt: *sqlite3_stmt) !Observed {
    const columns = sqlite3_column_count(stmt);
    const expected_columns = @typeInfo(Observed).@"struct".field_names.len;
    if (columns != expected_columns) assert.panic("observation query has {d} columns, expected {d}; keep the built-in SELECT and Observed mapping aligned", .{ columns, expected_columns });
    var unit: Digest = undefined;
    const hash = columnText(stmt, 3);
    if (hash.len != unit.len or std.mem.indexOfNone(u8, hash, "0123456789abcdef") != null) {
        describeStoreFailure("Cached unit hash '{s}' has {d} bytes; expected {d} lowercase hex bytes. Restore a good copy of the store or choose a new ZANITY_STORE", .{ hash[0..@min(hash.len, unit.len)], hash.len, unit.len });
        return error.StoreUnavailable;
    }
    @memcpy(&unit, hash);
    const line = sqlite3_column_int64(stmt, 2);
    if (line < 1 or line > std.math.maxInt(u32)) {
        describeStoreFailure("Cached observation line {d} is outside 1..{d}. Restore a good copy of the store or choose a new ZANITY_STORE", .{ line, std.math.maxInt(u32) });
        return error.StoreUnavailable;
    }
    const real: ?bool = if (sqlite3_column_type(stmt, 7) == column_null) null else sqlite3_column_int64(stmt, 7) != 0;
    const observed: Observed = .{ .rule = columnText(stmt, 0), .path = columnText(stmt, 1), .line = @intCast(line), .unit = unit, .unit_name = columnText(stmt, 4), .probability = sqlite3_column_double(stmt, 5), .threshold = sqlite3_column_double(stmt, 6), .real = real };
    if (observed.line != line) assert.panic("decoded observation line {d}, expected cached line {d}; copy the validated line without changing it", .{ observed.line, line });
    return observed;
}

fn prepare(db: *sqlite3, comptime trusted_sql: []const u8) !*sqlite3_stmt {
    // comptime prevents runtime file contents, environment or request data becoming SQL here.
    if (trusted_sql.len == 0) assert.panic("preparing an empty built-in statement; pass a module SQL constant to prepare()", .{});
    if (std.mem.indexOfScalar(u8, trusted_sql, ';') != null) assert.panic("'{s}' holds more than one built-in statement; prepare them one at a time", .{trusted_sql});
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, trusted_sql.ptr, @intCast(trusted_sql.len), &stmt, null) != ok) return captureDatabaseFailure(db);
    return stmt orelse assert.panic("SQLite prepared '{s}' but returned no statement; check the built-in SQL passed to prepare() is a single statement", .{trusted_sql});
}

fn bind(stmt: *sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (text.len > std.math.maxInt(c_int)) assert.panic("binding {d} bytes of text, more than SQLite takes in one parameter; shorten the function's source, or split the function", .{text.len});
    if (sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != ok) return captureDatabaseFailure(sqlite3_db_handle(stmt));
}

/// The text of column `index` in the current row, valid until the next row is read.
fn columnText(stmt: *sqlite3_stmt, index: c_int) []const u8 {
    if (index < 0) assert.panic("reading column {d}; SQLite numbers columns from 0", .{index});
    const text = sqlite3_column_text(stmt, index) orelse return "";
    const length = sqlite3_column_bytes(stmt, index);
    if (length < 0) assert.panic("SQLite gave column {d} a length of {d}", .{ index, length });
    return text[0..@intCast(length)];
}

fn bindInt(stmt: *sqlite3_stmt, index: c_int, value: u64) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (value > std.math.maxInt(i64)) assert.panic("binding {d}, past the largest integer SQLite stores; count something smaller", .{value});
    if (sqlite3_bind_int64(stmt, index, @intCast(value)) != ok) return captureDatabaseFailure(sqlite3_db_handle(stmt));
}

/// Converts a failed SQLite operation into the store's stable error, retaining its detailed cause.
/// The diagnostic belongs to this calling thread, not to all connections in the process.
fn captureDatabaseFailure(db: *sqlite3) error{StoreUnavailable} {
    // failure and failure_len are threadlocal, so a different worker cannot replace this cause.
    // Callers still own the connection here, so its message is copied before any next operation.
    const code = sqlite3_errcode(db);
    if (code == ok or code == row or code == done) assert.panic("capturing SQLite failure after successful status {d}; call captureDatabaseFailure() only after an operation reports an error", .{code});
    const message = std.mem.span(sqlite3_errmsg(db));
    if (message.len == 0) assert.panic("SQLite reported a failure with no message; check the store file with the sqlite3 command-line tool", .{});
    failure_len = @min(message.len, failure.len);
    @memcpy(failure[0..failure_len], message[0..failure_len]);
    if (failure_len == 0) assert.panic("kept none of SQLite's {d}-byte failure message; captureDatabaseFailure() must copy at least part of SQLite's message", .{message.len});
    // SQLite error kinds deliberately share this public error; failure retains the specific cause.
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
    try std.testing.expectEqual(null, try store.cachedAnalysis(&buffer, key, digest(&.{"changed"})));
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT json_array_length(result, '$.findings') FROM source_analyses"));
    try std.testing.expectEqual(@as(f64, 1), try scalar(store.db, "SELECT hits FROM source_analyses"));
}

/// The first column of the first row `sql` returns, for reading back what a test kept.
fn scalar(db: *sqlite3, comptime sql: []const u8) !f64 {
    if (!std.mem.startsWith(u8, sql, "SELECT ")) assert.panic("'{s}' is not a query; scalar() only reads back what a test kept", .{sql});
    const stmt = try prepare(db, sql);
    defer _ = sqlite3_reset(stmt);
    if (sqlite3_step(stmt) != row) return captureDatabaseFailure(db);
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

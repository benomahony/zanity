//! Zanity's SQLite store, in WAL mode so several runs can use it at once. It keeps --infer
//! answers and deterministic source analyses; the latter are JSON so people and agents can query
//! the facts and findings zanity reused.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");
const store_sql = @import("store_sql.zig");
const sqlite = @import("sqlite.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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

/// Wait briefly for another local process holding a SQLite write lock.
const busy_timeout_ms = 5000;
/// Space left for cleanup context after retaining the original SQLite failure prefix.
const rollback_context_bytes = 128;

/// One connection and its prepared statements, used by one thread at a time.
/// Batch holds its mutex across complete operations when its workers share this connection.
pub const Store = struct {
    path: []const u8,
    db: *sqlite.sqlite3,
    find: *sqlite.sqlite3_stmt,
    insert_unit_if_missing: *sqlite.sqlite3_stmt,
    upsert_answer_by_identity: *sqlite.sqlite3_stmt,
    observation: *sqlite.sqlite3_stmt,
    run: *sqlite.sqlite3_stmt,
    find_analysis: *sqlite.sqlite3_stmt,
    touch_analysis: *sqlite.sqlite3_stmt,
    save_analysis: *sqlite.sqlite3_stmt,
    false_positive: *sqlite.sqlite3_stmt,
    save_label: *sqlite.sqlite3_stmt,
    find_label: *sqlite.sqlite3_stmt,
    list_observed: *sqlite.sqlite3_stmt,

    /// Gives SQLite one fixed heap, then opens the store and prepares every statement, so
    /// nothing allocates after start-up. SQLite keeps the first heap for the life of the process,
    /// so `gpa` must never free it. `ZANITY_STORE` overrides where the store lives.
    pub fn initStore(gpa: Allocator, io: Io, operator_environ: *const std.process.Environ.Map, heap_bytes: usize) !Store {
        // This is the operator's local analysis cache, opened under their filesystem permissions.
        try sqlite.initializeSqliteHeap(&sqlite.process_heap, gpa, io, heap_bytes);
        const path = try initPath(gpa, io, operator_environ);
        errdefer gpa.free(path);
        const db = try openLocalCache(path);
        errdefer _ = sqlite.sqlite3_close_v2(db);
        const opened = try prepareStoreStatements(path, db);
        if (opened.db != db) assert.panic("prepared local-cache connection 0x{x}, expected opened database 0x{x}; prepareStoreStatements() must retain initStore()'s connection", .{ @intFromPtr(opened.db), @intFromPtr(db) });
        if (opened.path.ptr != path.ptr) assert.panic("prepared cache path at 0x{x}, expected owned path at 0x{x}; prepareStoreStatements() must retain initStore()'s path", .{ @intFromPtr(opened.path.ptr), @intFromPtr(path.ptr) });
        return opened;
    }

    /// The model's cached answer to `question` about `unit`, if either tool has asked it.
    pub fn cached(self: *const Store, model: []const u8, question: Digest, unit: Digest) !?f64 {
        if (model.len == 0) assert.panic("looking up an answer with no model name; pass the model --infer asks, from the tai client", .{});
        if (std.mem.eql(u8, &question, &unit)) assert.panic("looking up an answer whose question and function have the same digest {s}; one was passed as the other", .{&question});
        defer _ = sqlite.sqlite3_reset(self.find);
        try sqlite.bind(self.find, 1, model);
        try sqlite.bind(self.find, 2, &question);
        try sqlite.bind(self.find, 3, &unit);
        return switch (sqlite.sqlite3_step(self.find)) {
            sqlite.row => sqlite.sqlite3_column_double(self.find, 0),
            sqlite.done => null,
            else => sqlite.captureDatabaseFailure(self.db),
        };
    }

    /// Idempotently caches a source unit and an answer identified by model, question and unit.
    /// Repeated delivery inserts no duplicate unit and replaces the same keyed answer row.
    pub fn keepAnswer(self: *const Store, a: Answer) !void {
        // This operator-owned local SQLite cache has a finite busy_timeout_ms lock wait.
        // No remote database or service is contacted; the keyed writes below are replay-safe.
        if (a.probability < 0 or a.probability > 1) assert.panic("keeping a probability of {d}; answers are between 0 and 1, so check how infer.zig reads TypeSafe's answer", .{a.probability});
        if (a.language.len == 0 or a.source.len == 0) assert.panic("keeping an answer about a function with no language or source; plan() must pass the unit's language and source", .{});
        if (sqlite.sqlite3_exec(self.db, "SAVEPOINT zanity_answer", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
        errdefer self.rollbackUncommittedAnswer();
        defer _ = sqlite.sqlite3_reset(self.insert_unit_if_missing);
        defer _ = sqlite.sqlite3_reset(self.upsert_answer_by_identity);
        // INSERT OR IGNORE uses the source-content hash as the units primary key.
        try sqlite.bind(self.insert_unit_if_missing, 1, &a.unit);
        try sqlite.bind(self.insert_unit_if_missing, 2, a.language);
        try sqlite.bind(self.insert_unit_if_missing, 3, a.source);
        if (sqlite.sqlite3_step(self.insert_unit_if_missing) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
        // INSERT OR REPLACE uses (model, question_hash, unit_hash), so retries update one identity.
        try sqlite.bind(self.upsert_answer_by_identity, 1, a.model);
        try sqlite.bind(self.upsert_answer_by_identity, 2, &a.question);
        try sqlite.bind(self.upsert_answer_by_identity, 3, &a.unit);
        if (sqlite.sqlite3_bind_double(self.upsert_answer_by_identity, 4, a.probability) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
        if (sqlite.sqlite3_step(self.upsert_answer_by_identity) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
        if (sqlite.sqlite3_exec(self.db, "RELEASE zanity_answer", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
    }

    /// Rolls back the source/answer pair after its original SQLite cause was copied to this thread.
    fn rollbackUncommittedAnswer(self: *const Store) void {
        if (sqlite.failure_len == 0) assert.panic("rolling back an answer with {d} diagnostic bytes; retain the original failure before cleanup", .{sqlite.failure_len});
        const statement_db = sqlite.sqlite3_db_handle(self.upsert_answer_by_identity);
        if (self.db != statement_db) assert.panic("rolling back cache 0x{x} with an answer statement owned by 0x{x}; retain one connection for both answer writes", .{ @intFromPtr(self.db), @intFromPtr(statement_db) });
        // This Store method is the local SQLite data-access layer, not a caller bypassing it.
        const status = sqlite.sqlite3_exec(self.db, "ROLLBACK TO zanity_answer; RELEASE zanity_answer", null, null, null);
        if (status != sqlite.ok) appendAnswerRollbackFailure(status);
    }

    /// Keeps what the model said about a unit, replacing what an earlier run said there.
    pub fn observe(self: *const Store, o: Observation) !void {
        if (o.line == 0) assert.panic("{s}: observing '{s}' on line 0; lines count from 1, so pass the unit's line plus 1", .{ o.path, o.unit_name });
        if (o.fired != (o.probability >= o.threshold)) assert.panic("{s}: '{s}' {s} at {d} against a threshold of {d}; fired must be whether the probability reaches the threshold", .{ o.path, o.rule, if (o.fired) "fired" else "did not fire", o.probability, o.threshold });
        defer _ = sqlite.sqlite3_reset(self.observation);
        try sqlite.bind(self.observation, 1, o.path);
        try sqlite.bind(self.observation, 2, o.rule);
        try sqlite.bind(self.observation, 3, &o.unit);
        try sqlite.bind(self.observation, 4, o.unit_name);
        try sqlite.bindInt(self.observation, 5, o.line);
        try sqlite.bind(self.observation, 6, o.language);
        try sqlite.bind(self.observation, 7, o.model);
        try sqlite.bind(self.observation, 8, &o.question);
        if (sqlite.sqlite3_bind_double(self.observation, 9, o.probability) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
        if (sqlite.sqlite3_bind_double(self.observation, 10, o.threshold) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
        try sqlite.bindInt(self.observation, 11, @intFromBool(o.fired));
        if (sqlite.sqlite3_step(self.observation) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }

    /// Records whether the finding `rule` makes about `unit` is real: confirmed, or not a problem.
    pub fn label(self: *const Store, rule: []const u8, unit: Digest, real: bool) !void {
        if (rule.len == 0) assert.panic("labelling a finding with no rule; pass the rule it was reported under", .{});
        if (std.mem.indexOfNone(u8, &unit, "0123456789abcdef") != null) assert.panic("labelling '{s}' about '{s}', which is not a digest", .{ rule, &unit });
        defer _ = sqlite.sqlite3_reset(self.save_label);
        try sqlite.bind(self.save_label, 1, rule);
        try sqlite.bind(self.save_label, 2, &unit);
        try sqlite.bindInt(self.save_label, 3, @intFromBool(real));
        if (sqlite.sqlite3_step(self.save_label) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }

    /// Whether someone said `rule`'s finding about `unit` is real, if anyone has.
    pub fn labelled(self: *const Store, rule: []const u8, unit: Digest) !?bool {
        if (rule.len == 0) assert.panic("looking up a label with no rule; pass the rule it was reported under", .{});
        if (std.mem.indexOfNone(u8, &unit, "0123456789abcdef") != null) assert.panic("looking up '{s}' about '{s}', which is not a digest", .{ rule, &unit });
        defer _ = sqlite.sqlite3_reset(self.find_label);
        try sqlite.bind(self.find_label, 1, rule);
        try sqlite.bind(self.find_label, 2, &unit);
        return switch (sqlite.sqlite3_step(self.find_label)) {
            sqlite.row => sqlite.sqlite3_column_int64(self.find_label, 0) != 0,
            sqlite.done => null,
            else => sqlite.captureDatabaseFailure(self.db),
        };
    }

    /// Runs the CLI's compile-time callback over the operator's filtered local-cache answers.
    /// Row text is borrowed until the next row; callbacks copy anything they retain.
    pub fn eachObserved(operator_cache: *const Store, operator_selection: Narrow, cli_context: anytype, comptime visit: fn (@TypeOf(cli_context), Observed) anyerror!bool) !void {
        // initStore() already opened this local file under the invoking OS user's permissions.
        // The operator chooses these CLI filters; no remote caller supplies the compile-time visitor.
        const stmt = operator_cache.list_observed;
        const statement_db = sqlite.sqlite3_db_handle(stmt);
        if (statement_db != operator_cache.db) assert.panic("observation statement uses connection 0x{x}, expected operator cache 0x{x}; retain its owning local connection", .{ @intFromPtr(statement_db), @intFromPtr(operator_cache.db) });
        defer _ = sqlite.sqlite3_reset(stmt);
        try sqlite.bind(stmt, 1, operator_selection.rule);
        try sqlite.bind(stmt, 2, operator_selection.path);
        try sqlite.bindInt(stmt, 3, operator_selection.line);
        for (0..std.math.maxInt(u32)) |_| switch (sqlite.sqlite3_step(stmt)) {
            sqlite.row => {
                const observed = try readObservedRow(stmt);
                if (operator_selection.rule.len != 0 and !std.mem.eql(u8, observed.rule, operator_selection.rule)) assert.panic("observation query returned rule '{s}', expected selected rule '{s}'; retain the built-in SQL filter when decoding its rows", .{ observed.rule, operator_selection.rule });
                if (!try visit(cli_context, observed)) return;
            },
            sqlite.done => return,
            else => return sqlite.captureDatabaseFailure(operator_cache.db),
        };
    }

    /// Keeps a row for this run.
    pub fn keepRun(self: *const Store, r: RunTotals) !void {
        if (r.asked + r.cached != r.units) assert.panic("a run with {d} units, {d} asked and {d} answered from the store; each unit is either asked or fully cached", .{ r.units, r.asked, r.cached });
        if (r.path.len == 0) assert.panic("recording a run with no path; pass the directory zanity ran in", .{});
        defer _ = sqlite.sqlite3_reset(self.run);
        try sqlite.bind(self.run, 1, r.path);
        try sqlite.bindInt(self.run, 2, r.units);
        try sqlite.bindInt(self.run, 3, r.asked);
        try sqlite.bindInt(self.run, 4, r.cached);
        try sqlite.bindInt(self.run, 5, r.input_tokens);
        try sqlite.bindInt(self.run, 6, r.output_tokens);
        if (sqlite.sqlite3_step(self.run) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }

    /// Keeps a flagged finding, replacing an earlier flag of the same finding on the same code.
    pub fn keepFalsePositive(self: *const Store, f: FalsePositive) !void {
        if (f.line == 0 or f.column == 0) assert.panic("{s}: flagging '{s}' at line {d} column {d}; both count from 1", .{ f.path, f.rule, f.line, f.column });
        if (f.path.len == 0 or f.rule.len == 0) assert.panic("flagging a finding with no path or rule; pass the finding the editor flagged", .{});
        defer _ = sqlite.sqlite3_reset(self.false_positive);
        try sqlite.bind(self.false_positive, 1, f.path);
        try sqlite.bindInt(self.false_positive, 2, f.line);
        try sqlite.bindInt(self.false_positive, 3, f.column);
        try sqlite.bind(self.false_positive, 4, f.rule);
        try sqlite.bind(self.false_positive, 5, f.message);
        try sqlite.bind(self.false_positive, 6, f.code);
        try sqlite.bind(self.false_positive, 7, f.version);
        if (sqlite.sqlite3_step(self.false_positive) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }

    /// Copies a cached JSON analysis into caller-owned memory, and records that it was reused.
    pub fn cachedAnalysis(self: *const Store, buffer: []u8, key: Digest, source: Digest) !?[]const u8 {
        if (buffer.len == 0) assert.panic("reading a cached analysis into no memory; reserve memory.Limits.analysis_bytes at startup", .{});
        if (std.mem.eql(u8, &key, &source)) assert.panic("an analysis context and its source have the same digest {s}; one was passed as the other", .{&key});
        defer _ = sqlite.sqlite3_reset(self.find_analysis);
        try sqlite.bind(self.find_analysis, 1, &key);
        try sqlite.bind(self.find_analysis, 2, &source);
        switch (sqlite.sqlite3_step(self.find_analysis)) {
            sqlite.done => return null,
            sqlite.row => {},
            else => return sqlite.captureDatabaseFailure(self.db),
        }
        const length = sqlite.sqlite3_column_bytes(self.find_analysis, 0);
        if (length <= 0) return error.StoreUnavailable;
        if (length > buffer.len) return null;
        const pointer = sqlite.sqlite3_column_text(self.find_analysis, 0) orelse return error.StoreUnavailable;
        const result = buffer[0..@intCast(length)];
        @memcpy(result, pointer[0..@intCast(length)]);
        defer _ = sqlite.sqlite3_reset(self.touch_analysis);
        try sqlite.bind(self.touch_analysis, 1, &key);
        if (sqlite.sqlite3_step(self.touch_analysis) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
        return result;
    }

    /// Keeps a deterministic analysis, replacing the same path/rules context after a source edit.
    pub fn keepAnalysis(self: *const Store, analysis: Analysis) !void {
        if (analysis.path.len == 0 or analysis.language.len == 0) assert.panic("keeping an analysis without a path or language; pass the file the checker analysed", .{});
        if (analysis.result.len == 0) assert.panic("keeping an empty analysis for {s}; encode its facts and findings as JSON first", .{analysis.path});
        defer _ = sqlite.sqlite3_reset(self.save_analysis);
        try sqlite.bind(self.save_analysis, 1, &analysis.key);
        try sqlite.bind(self.save_analysis, 2, &analysis.source);
        try sqlite.bind(self.save_analysis, 3, analysis.path);
        try sqlite.bind(self.save_analysis, 4, analysis.language);
        try sqlite.bind(self.save_analysis, 5, analysis.result);
        if (sqlite.sqlite3_step(self.save_analysis) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }
};

/// Appends the rollback status to the calling thread's failure, cutting the original cause short
/// when needed so the appended context always fits.
fn appendAnswerRollbackFailure(status: c_int) void {
    if (status == sqlite.ok) assert.panic("recording answer rollback failure with successful SQLite status {d}; only append cleanup context on failure", .{status});
    if (sqlite.failure_len > sqlite.failure.len) assert.panic("the original SQLite cause has {d} bytes in room for {d}; bound it before adding rollback context", .{ sqlite.failure_len, sqlite.failure.len });
    // Both diagnostics are threadlocal. The reserved suffix budget is independent of runtime text.
    var output: Io.Writer = .fixed(&sqlite.failure);
    output.end = @min(sqlite.failure_len, sqlite.failure.len - rollback_context_bytes);
    output.print("; answer rollback failed with SQLite status {d}; restart zanity before reusing this cache", .{status}) catch assert.panic("answer rollback status {d} exceeds its {d}-byte context budget; shorten the fixed diagnostic", .{ status, rollback_context_bytes });
    sqlite.failure_len = output.end;
}

/// Opens only the chosen local cache; every unsuccessful opening releases its connection.
fn openLocalCache(path: [:0]const u8) !*sqlite.sqlite3 {
    if (path.len == 0) assert.panic("opening an empty local cache path; initPath() must reject empty operator overrides", .{});
    var handle: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(path.ptr, &handle, sqlite.open_readwrite | sqlite.open_create, null) != sqlite.ok) {
        const failed_db = handle orelse return error.StoreUnavailable;
        defer _ = sqlite.sqlite3_close_v2(failed_db);
        return sqlite.captureDatabaseFailure(failed_db);
    }
    const db = handle orelse return error.StoreUnavailable;
    errdefer _ = sqlite.sqlite3_close_v2(db);
    if (sqlite.sqlite3_busy_timeout(db, busy_timeout_ms) != sqlite.ok) return sqlite.captureDatabaseFailure(db);
    if (sqlite.sqlite3_exec(db, store_sql.schema, null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(db);
    if (db != handle.?) assert.panic("opened local-cache connection 0x{x}, expected SQLite's handle 0x{x}; openLocalCache() must return that handle", .{ @intFromPtr(db), @intFromPtr(handle.?) });
    return db;
}

/// Returns a complete statement owner, finalizing any partial preparation before an error escapes.
fn prepareStoreStatements(path: [:0]const u8, db: *sqlite.sqlite3) !Store {
    var opened: Store = undefined;
    opened.path = path;
    opened.db = db;
    const names = @typeInfo(@TypeOf(store_sql.statements)).@"struct".field_names;
    comptime {
        for (@typeInfo(Store).@"struct".field_names) |name| {
            if (std.mem.eql(u8, name, "path") or std.mem.eql(u8, name, "db")) continue;
            if (!@hasField(@TypeOf(store_sql.statements), name)) @compileError("missing built-in SQL for Store." ++ name);
        }
    }
    var prepared: usize = 0;
    errdefer {
        inline for (names, 0..) |name, i| {
            if (i < prepared) _ = sqlite.sqlite3_finalize(@field(opened, name));
        }
    }
    inline for (names) |name| {
        @field(opened, name) = try sqlite.prepareStatement(db, @field(store_sql.statements, name));
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
            sqlite.failure_len = reason.len;
            @memcpy(sqlite.failure[0..sqlite.failure_len], reason);
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
fn readObservedRow(stmt: *sqlite.sqlite3_stmt) !Observed {
    const columns = sqlite.sqlite3_column_count(stmt);
    const expected_columns = @typeInfo(Observed).@"struct".field_names.len;
    if (columns != expected_columns) assert.panic("observation query has {d} columns, expected {d}; keep the built-in SELECT and Observed mapping aligned", .{ columns, expected_columns });
    var unit: Digest = undefined;
    const hash = sqlite.columnText(stmt, 3);
    if (hash.len != unit.len or std.mem.indexOfNone(u8, hash, "0123456789abcdef") != null) {
        sqlite.describeStoreFailure("Cached unit hash '{s}' has {d} bytes; expected {d} lowercase hex bytes. Restore a good copy of the store or choose a new ZANITY_STORE", .{ hash[0..@min(hash.len, unit.len)], hash.len, unit.len });
        return error.StoreUnavailable;
    }
    @memcpy(&unit, hash);
    const line = sqlite.sqlite3_column_int64(stmt, 2);
    if (line < 1 or line > std.math.maxInt(u32)) {
        sqlite.describeStoreFailure("Cached observation line {d} is outside 1..{d}. Restore a good copy of the store or choose a new ZANITY_STORE", .{ line, std.math.maxInt(u32) });
        return error.StoreUnavailable;
    }
    const real: ?bool = if (sqlite.sqlite3_column_type(stmt, 7) == sqlite.column_null) null else sqlite.sqlite3_column_int64(stmt, 7) != 0;
    const observed: Observed = .{ .rule = sqlite.columnText(stmt, 0), .path = sqlite.columnText(stmt, 1), .line = @intCast(line), .unit = unit, .unit_name = sqlite.columnText(stmt, 4), .probability = sqlite.sqlite3_column_double(stmt, 5), .threshold = sqlite.sqlite3_column_double(stmt, 6), .real = real };
    if (observed.line != line) assert.panic("decoded observation line {d}, expected cached line {d}; copy the validated line without changing it", .{ observed.line, line });
    return observed;
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
fn scalar(db: *sqlite.sqlite3, comptime sql: []const u8) !f64 {
    if (!std.mem.startsWith(u8, sql, "SELECT ")) assert.panic("'{s}' is not a query; scalar() only reads back what a test kept", .{sql});
    const stmt = try sqlite.prepareStatement(db, sql);
    defer _ = sqlite.sqlite3_reset(stmt);
    if (sqlite.sqlite3_step(stmt) != sqlite.row) return sqlite.captureDatabaseFailure(db);
    const value = sqlite.sqlite3_column_double(stmt, 0);
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

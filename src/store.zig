//! The SQLite store of --infer answers, keyed by model, question and function, in WAL mode so
//! several runs can use it at once. An answer paid for once is never asked for again.
const std = @import("std");
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
extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, i: c_int, value: f64) c_int;
extern fn sqlite3_column_double(stmt: *sqlite3_stmt, i: c_int) f64;

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
;

const find_answer = "SELECT probability FROM answers WHERE model = ?1 AND question_hash = ?2 AND unit_hash = ?3";
const save_unit = "INSERT OR IGNORE INTO units (unit_hash, language, source) VALUES (?1, ?2, ?3)";
const save_answer = "INSERT OR REPLACE INTO answers (model, question_hash, unit_hash, probability, asked_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now'))";

/// A digest: the first 32 hex characters of the SHA-256 of the parts joined with NUL.
pub const Digest = [32]u8;

pub fn digest(parts: []const []const u8) Digest {
    if (parts.len == 0) std.debug.panic("digesting nothing; a digest names at least one part, so pass the language and source to digest()", .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts, 0..) |part, i| {
        if (i > 0) h.update("\x00");
        h.update(part);
    }
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    if (hex.len != 64) std.debug.panic("a SHA-256 printed as {d} hex characters, not 64; print each of the digest's 32 bytes as two hex digits", .{hex.len});
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

/// Why the last store operation failed, as SQLite put it.
pub var failure: [512]u8 = undefined;
pub var failure_len: usize = 0;

var configured = false;

pub const Store = struct {
    db: *sqlite3,
    find: *sqlite3_stmt,
    unit: *sqlite3_stmt,
    answer: *sqlite3_stmt,

    /// Gives SQLite one fixed heap, then opens the store and prepares every statement, so
    /// nothing allocates after start-up. `ZANITY_STORE` overrides where the store lives.
    pub fn initStore(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, heap_bytes: usize) !Store {
        if (heap_bytes < 1 << 20) std.debug.panic("SQLite was given a {d}-byte heap; it needs at least 1 MiB", .{heap_bytes});
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
        const opened: Store = .{ .db = db, .find = try prepare(db, find_answer), .unit = try prepare(db, save_unit), .answer = try prepare(db, save_answer) };
        if (!configured) std.debug.panic("opened {s} before SQLite was given its heap", .{path});
        return opened;
    }

    /// The model's cached answer to `question` about `unit`, if either tool has asked it.
    pub fn cached(self: *const Store, model: []const u8, question: Digest, unit: Digest) !?f64 {
        if (model.len == 0) std.debug.panic("looking up an answer with no model name", .{});
        if (std.mem.eql(u8, &question, &unit)) std.debug.panic("looking up an answer whose question and function have the same digest {s}; one was passed as the other", .{&question});
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
        if (a.probability < 0 or a.probability > 1) std.debug.panic("keeping a probability of {d}; answers are between 0 and 1, so check how infer.zig reads TypeSafe's answer", .{a.probability});
        if (a.language.len == 0 or a.source.len == 0) std.debug.panic("keeping an answer about a function with no language or source; plan() must pass the unit's language and source", .{});
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
};

const store_name = "zanity.db";

/// Where the store lives: `ZANITY_STORE`, or zanity.db in zanity's folder of the user's cache directory.
fn initPath(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map) ![:0]const u8 {
    if (environ.get("ZANITY_STORE")) |path| {
        if (path.len == 0) std.debug.panic("ZANITY_STORE is set but empty; unset it or name a file", .{});
        return gpa.dupeSentinel(u8, path, 0);
    }
    const cache = if (environ.get("XDG_CACHE_HOME")) |xdg| try gpa.dupe(u8, xdg) else blk: {
        const home = environ.get("HOME") orelse return error.StoreUnavailable;
        break :blk try std.fs.path.join(gpa, &.{ home, ".cache" });
    };
    const dir = try std.fs.path.join(gpa, &.{ cache, "zanity" });
    Io.Dir.cwd().createDirPath(io, dir) catch return error.StoreUnavailable;
    const path = try std.fs.path.joinZ(gpa, &.{ dir, store_name });
    if (!std.mem.endsWith(u8, path, store_name)) std.debug.panic("the store path {s} does not end in {s}; initPath() must join the cache directory with it", .{ path, store_name });
    return path;
}

fn prepare(db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
    if (sql.len == 0) std.debug.panic("preparing an empty statement", .{});
    if (std.mem.indexOfScalar(u8, sql, ';') != null) std.debug.panic("'{s}' holds more than one statement; prepare them one at a time", .{sql});
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != ok) return failed(db);
    return stmt orelse std.debug.panic("SQLite prepared '{s}' but returned no statement", .{sql});
}

fn bind(stmt: *sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (index < 1) std.debug.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (text.len > std.math.maxInt(c_int)) std.debug.panic("binding {d} bytes of text, more than SQLite takes in one parameter", .{text.len});
    if (sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != ok) return error.StoreUnavailable;
}

/// Records SQLite's reason for the last failure, for the error message, and reports it.
fn failed(db: *sqlite3) error{StoreUnavailable} {
    const message = std.mem.span(sqlite3_errmsg(db));
    if (message.len == 0) std.debug.panic("SQLite reported a failure with no message", .{});
    failure_len = @min(message.len, failure.len);
    @memcpy(failure[0..failure_len], message[0..failure_len]);
    if (failure_len == 0) std.debug.panic("kept none of SQLite's {d}-byte failure message", .{message.len});
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
    const store = try Store.initStore(arena, std.testing.io, &environ, 8 << 20);
    const unit = digest(&.{ "lang-a", "fn f() void {}" });
    const question = digest(&.{"Is it fine?"});
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-1", question, unit));
    try store.keepAnswer(.{ .model = "jev-1", .question = question, .unit = unit, .language = "lang-a", .source = "fn f() void {}", .probability = 0.25 });
    try std.testing.expectEqual(@as(?f64, 0.25), try store.cached("jev-1", question, unit));
    try std.testing.expectEqual(@as(?f64, null), try store.cached("jev-2", question, unit));
}

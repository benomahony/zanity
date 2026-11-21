const std = @import("std");
const assert = @import("assert.zig");
const sqlite = @import("sqlite.zig");
const store = @import("store.zig");
const Store = store.Store;

/// The scope a whole run was checked in, and the state of the files it checked.
pub const RunScope = struct { scope: store.Digest, state: store.Digest };

/// A run to keep: its scope, how many files it checked, how many scopes the store keeps, and
/// room to list the digests of its chunks.
pub const KeptRun = struct { run: RunScope, checked: u32, keep: u32, chunks: []u8 };

/// How many files the run kept for its scope checked, when the files are still in its state,
/// after `visit` has seen each chunk of its findings in the order they were kept; null when no
/// run was kept for them, or the store has lost one of its chunks.
pub fn eachRunChunk(self: *const Store, run: RunScope, context: anytype, comptime visit: fn (@TypeOf(context), []const u8) anyerror!void) !?u32 {
    const stmt = self.list_run_chunks;
    if (std.mem.eql(u8, &run.scope, &run.state)) assert.panic("a run's scope and the state of its files have the same digest {s}; one was passed as the other", .{&run.scope});
    if (sqlite.sqlite3_db_handle(stmt) != self.db) assert.panic("the run chunks statement uses connection 0x{x}, not the store's 0x{x}; prepare it on the store's", .{ @intFromPtr(sqlite.sqlite3_db_handle(stmt)), @intFromPtr(self.db) });
    defer _ = sqlite.sqlite3_reset(stmt);
    try sqlite.bind(stmt, 1, &run.scope);
    try sqlite.bind(stmt, 2, &run.state);
    var checked: ?u32 = null;
    var seen: i64 = 0;
    for (0..std.math.maxInt(u32)) |_| switch (sqlite.sqlite3_step(stmt)) {
        sqlite.row => {
            checked = std.math.cast(u32, sqlite.sqlite3_column_int64(stmt, 0)) orelse return error.StoreUnavailable;
            const length = sqlite.sqlite3_column_bytes(stmt, 2);
            const pointer = sqlite.sqlite3_column_text(stmt, 2) orelse return null;
            if (length <= 0) return null;
            try visit(context, pointer[0..@intCast(length)]);
            seen += 1;
            if (seen == sqlite.sqlite3_column_int64(stmt, 1)) return checked;
        },
        sqlite.done => return if (checked == null) null else error.StoreUnavailable,
        else => return sqlite.captureDatabaseFailure(self.db),
    };
    return error.StoreUnavailable;
}

/// Keeps a run for its scope in place of the run before it, as the chunks `encode` returns until
/// it returns null. A chunk any kept run already has is not written again, so a check after an
/// edit writes only what changed. Only the most recent scopes are kept, with the chunks they name.
pub fn keepRunAnalysis(self: *const Store, kept: KeptRun, context: anytype, comptime encode: fn (@TypeOf(context)) anyerror!?[]const u8) !void {
    const run = kept.run;
    if (kept.keep == 0) assert.panic("keeping no cached runs would make every run a miss; keep at least one", .{});
    if (std.mem.eql(u8, &run.scope, &run.state)) assert.panic("a run's scope and the state of its files have the same digest {s}; one was passed as the other", .{&run.scope});
    if (sqlite.sqlite3_exec(self.db, "SAVEPOINT zanity_run", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
    errdefer _ = sqlite.sqlite3_exec(self.db, "ROLLBACK TO zanity_run; RELEASE zanity_run", null, null, null);
    var names: std.Io.Writer = .fixed(kept.chunks);
    try names.writeByte('[');
    for (0..std.math.maxInt(u32)) |chunk| {
        const result = try encode(context) orelse break;
        const name = store.digest(&.{result});
        try names.print("{s}\"{s}\"", .{ if (chunk == 0) "" else ",", &name });
        if (try hasChunk(self, name)) continue;
        defer _ = sqlite.sqlite3_reset(self.save_run_chunk);
        try sqlite.bind(self.save_run_chunk, 1, &name);
        try sqlite.bind(self.save_run_chunk, 2, result);
        if (sqlite.sqlite3_step(self.save_run_chunk) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }
    try names.writeByte(']');
    defer _ = sqlite.sqlite3_reset(self.save_run_analysis);
    try sqlite.bind(self.save_run_analysis, 1, &run.scope);
    try sqlite.bind(self.save_run_analysis, 2, &run.state);
    try sqlite.bindInt(self.save_run_analysis, 3, kept.checked);
    try sqlite.bind(self.save_run_analysis, 4, names.buffered());
    if (sqlite.sqlite3_step(self.save_run_analysis) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    defer _ = sqlite.sqlite3_reset(self.trim_run_analyses);
    try sqlite.bindInt(self.trim_run_analyses, 1, kept.keep);
    if (sqlite.sqlite3_step(self.trim_run_analyses) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    try stepOnce(self, self.trim_run_chunks, &.{});
    if (sqlite.sqlite3_exec(self.db, "RELEASE zanity_run", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
}

fn hasChunk(self: *const Store, name: store.Digest) !bool {
    const stmt = self.has_run_chunk;
    if (sqlite.sqlite3_db_handle(stmt) != self.db) assert.panic("the chunk lookup uses connection 0x{x}, not the store's 0x{x}; prepare it on the store's", .{ @intFromPtr(sqlite.sqlite3_db_handle(stmt)), @intFromPtr(self.db) });
    if (std.mem.indexOfNone(u8, &name, "0123456789abcdef") != null) assert.panic("looking up a chunk named '{s}', which is not a digest", .{&name});
    defer _ = sqlite.sqlite3_reset(stmt);
    try sqlite.bind(stmt, 1, &name);
    return switch (sqlite.sqlite3_step(stmt)) {
        sqlite.row => true,
        sqlite.done => false,
        else => sqlite.captureDatabaseFailure(self.db),
    };
}

fn stepOnce(self: *const Store, stmt: *sqlite.sqlite3_stmt, texts: []const []const u8) !void {
    if (sqlite.sqlite3_db_handle(stmt) != self.db) assert.panic("stepping a statement on connection 0x{x}, not the store's 0x{x}; prepare it on the store's", .{ @intFromPtr(sqlite.sqlite3_db_handle(stmt)), @intFromPtr(self.db) });
    if (texts.len > 1) assert.panic("binding {d} texts to a statement that takes at most one", .{texts.len});
    defer _ = sqlite.sqlite3_reset(stmt);
    for (texts, 1..) |text, i| try sqlite.bind(stmt, @intCast(i), text);
    if (sqlite.sqlite3_step(stmt) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
}

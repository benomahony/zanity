const std = @import("std");
const assert = @import("assert.zig");
const sqlite = @import("sqlite.zig");
const store = @import("store.zig");
const Store = store.Store;

/// The scope a whole run was checked in, and the state of the files it checked.
pub const RunScope = struct { scope: store.Digest, state: store.Digest };

/// A run to keep: its scope, how many files it checked, and how many scopes the store keeps.
pub const KeptRun = struct { run: RunScope, checked: u32, keep: u32 };

/// How many files the run kept for its scope checked, when the files are still in its state,
/// after `visit` has seen each chunk of its findings in the order they were kept; null when no
/// run was kept for them.
pub fn eachRunChunk(self: *const Store, run: RunScope, context: anytype, comptime visit: fn (@TypeOf(context), []const u8) anyerror!void) !?u32 {
    if (std.mem.eql(u8, &run.scope, &run.state)) assert.panic("a run's scope and the state of its files have the same digest {s}; one was passed as the other", .{&run.scope});
    if (sqlite.sqlite3_db_handle(self.list_run_findings) != self.db) assert.panic("the run findings statement uses connection 0x{x}, not the store's 0x{x}; prepare it on the store's", .{ @intFromPtr(sqlite.sqlite3_db_handle(self.list_run_findings)), @intFromPtr(self.db) });
    defer _ = sqlite.sqlite3_reset(self.find_run_analysis);
    try sqlite.bind(self.find_run_analysis, 1, &run.scope);
    try sqlite.bind(self.find_run_analysis, 2, &run.state);
    switch (sqlite.sqlite3_step(self.find_run_analysis)) {
        sqlite.done => return null,
        sqlite.row => {},
        else => return sqlite.captureDatabaseFailure(self.db),
    }
    const checked = std.math.cast(u32, sqlite.sqlite3_column_int64(self.find_run_analysis, 0)) orelse return error.StoreUnavailable;
    defer _ = sqlite.sqlite3_reset(self.list_run_findings);
    try sqlite.bind(self.list_run_findings, 1, &run.scope);
    for (0..std.math.maxInt(u32)) |_| switch (sqlite.sqlite3_step(self.list_run_findings)) {
        sqlite.row => {
            const length = sqlite.sqlite3_column_bytes(self.list_run_findings, 0);
            const pointer = sqlite.sqlite3_column_text(self.list_run_findings, 0) orelse return error.StoreUnavailable;
            if (length <= 0) return error.StoreUnavailable;
            try visit(context, pointer[0..@intCast(length)]);
        },
        sqlite.done => return checked,
        else => return sqlite.captureDatabaseFailure(self.db),
    };
    return error.StoreUnavailable;
}

/// Keeps a run's findings for its scope in place of the run before it, one chunk for each call
/// to `encode` until it returns null, and keeps only the most recent scopes.
pub fn keepRunAnalysis(self: *const Store, kept: KeptRun, context: anytype, comptime encode: fn (@TypeOf(context), usize) anyerror!?[]const u8) !void {
    const run = kept.run;
    if (kept.keep == 0) assert.panic("keeping no cached runs would make every run a miss; keep at least one", .{});
    if (std.mem.eql(u8, &run.scope, &run.state)) assert.panic("a run's scope and the state of its files have the same digest {s}; one was passed as the other", .{&run.scope});
    if (sqlite.sqlite3_exec(self.db, "SAVEPOINT zanity_run", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
    errdefer _ = sqlite.sqlite3_exec(self.db, "ROLLBACK TO zanity_run; RELEASE zanity_run", null, null, null);
    try stepOnce(self, self.clear_run_findings, &.{&run.scope});
    defer _ = sqlite.sqlite3_reset(self.save_run_analysis);
    try sqlite.bind(self.save_run_analysis, 1, &run.scope);
    try sqlite.bind(self.save_run_analysis, 2, &run.state);
    try sqlite.bindInt(self.save_run_analysis, 3, kept.checked);
    if (sqlite.sqlite3_step(self.save_run_analysis) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    for (0..std.math.maxInt(u32)) |chunk| {
        const result = try encode(context, chunk) orelse break;
        defer _ = sqlite.sqlite3_reset(self.save_run_findings);
        try sqlite.bind(self.save_run_findings, 1, &run.scope);
        try sqlite.bindInt(self.save_run_findings, 2, chunk);
        try sqlite.bind(self.save_run_findings, 3, result);
        if (sqlite.sqlite3_step(self.save_run_findings) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    }
    defer _ = sqlite.sqlite3_reset(self.trim_run_analyses);
    try sqlite.bindInt(self.trim_run_analyses, 1, kept.keep);
    if (sqlite.sqlite3_step(self.trim_run_analyses) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
    try stepOnce(self, self.trim_run_findings, &.{});
    if (sqlite.sqlite3_exec(self.db, "RELEASE zanity_run", null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
}

fn stepOnce(self: *const Store, stmt: *sqlite.sqlite3_stmt, texts: []const []const u8) !void {
    if (sqlite.sqlite3_db_handle(stmt) != self.db) assert.panic("stepping a statement on connection 0x{x}, not the store's 0x{x}; prepare it on the store's", .{ @intFromPtr(sqlite.sqlite3_db_handle(stmt)), @intFromPtr(self.db) });
    if (texts.len > 1) assert.panic("binding {d} texts to a statement that takes at most one", .{texts.len});
    defer _ = sqlite.sqlite3_reset(stmt);
    for (texts, 1..) |text, i| try sqlite.bind(stmt, @intCast(i), text);
    if (sqlite.sqlite3_step(stmt) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
}

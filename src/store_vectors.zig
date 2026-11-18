const std = @import("std");
const assert = @import("assert.zig");
const sqlite = @import("sqlite.zig");
const store = @import("store.zig");
const Store = store.Store;

pub const max_vector = 4096;

pub const Key = struct { model: []const u8, kind: []const u8, text: store.Digest };

fn bindKey(stmt: *sqlite.sqlite3_stmt, key: Key) !void {
    if (key.model.len == 0 or key.kind.len == 0) assert.panic("a vector keyed by model '{s}' and kind '{s}'; pass [semantic] model and name, doc or body", .{ key.model, key.kind });
    if (std.mem.indexOfNone(u8, &key.text, "0123456789abcdef") != null) assert.panic("a {s} vector keyed by '{s}', which is not a digest", .{ key.kind, &key.text });
    try sqlite.bind(stmt, 1, key.model);
    try sqlite.bind(stmt, 2, key.kind);
    try sqlite.bind(stmt, 3, &key.text);
}

pub fn cachedVector(self: *const Store, key: Key, out: []f32) !?usize {
    if (out.len == 0) assert.panic("reading a {s} vector into no room; pass a buffer of max_vector values", .{key.kind});
    defer _ = sqlite.sqlite3_reset(self.find_vector);
    try bindKey(self.find_vector, key);
    switch (sqlite.sqlite3_step(self.find_vector)) {
        sqlite.done => return null,
        sqlite.row => {},
        else => return sqlite.captureDatabaseFailure(self.db),
    }
    const bytes: usize = @intCast(sqlite.sqlite3_column_bytes(self.find_vector, 0));
    if (bytes == 0 or bytes % 2 != 0 or bytes / 2 > out.len) return null;
    const blob = sqlite.sqlite3_column_blob(self.find_vector, 0) orelse return error.StoreUnavailable;
    for (out[0 .. bytes / 2], 0..) |*value, i| value.* = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blob[2 * i ..][0..2], .little))));
    if (bytes / 2 > max_vector) assert.panic("read a {s} vector of {d} values, past the {d} kept", .{ key.kind, bytes / 2, max_vector });
    return bytes / 2;
}

pub fn keepVector(self: *const Store, key: Key, vector: []const f32) !void {
    if (vector.len == 0 or vector.len > max_vector) assert.panic("keeping a vector of {d} values; embed.zig must refuse a model that returns none or more than {d}", .{ vector.len, max_vector });
    if (std.math.isNan(vector[0])) assert.panic("keeping a {s} vector that starts with NaN; embed.zig normalises only valid vectors", .{key.kind});
    var blob: [2 * max_vector]u8 = undefined;
    for (vector, 0..) |value, i| std.mem.writeInt(u16, blob[2 * i ..][0..2], @bitCast(@as(f16, @floatCast(value))), .little);
    defer _ = sqlite.sqlite3_reset(self.save_vector);
    try bindKey(self.save_vector, key);
    if (sqlite.sqlite3_bind_blob(self.save_vector, 4, &blob, @intCast(2 * vector.len), sqlite.transient) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
    if (sqlite.sqlite3_step(self.save_vector) != sqlite.done) return sqlite.captureDatabaseFailure(self.db);
}

pub fn batched(self: *const Store, comptime statement: enum { begin, commit }) !void {
    const sql = switch (statement) {
        .begin => "BEGIN",
        .commit => "COMMIT",
    };
    if (sql.len == 0) assert.panic("batching the store with no statement", .{});
    if (sqlite.sqlite3_exec(self.db, sql, null, null, null) != sqlite.ok) return sqlite.captureDatabaseFailure(self.db);
    if (@intFromPtr(self.db) == 0) assert.panic("batched a store with no connection", .{});
}

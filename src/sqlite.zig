//! The parts of SQLite's C API the store uses: handles, status codes, statement helpers, the
//! fixed heap SQLite is given once per process, and why the calling thread's last call failed.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub extern fn sqlite3_config(op: c_int, ...) c_int;
pub extern fn sqlite3_initialize() c_int;
pub extern fn sqlite3_close_v2(db: *sqlite3) c_int;
pub extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
pub extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
pub extern fn sqlite3_errcode(db: *sqlite3) c_int;
pub extern fn sqlite3_db_handle(stmt: *sqlite3_stmt) *sqlite3;
pub extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, n: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
pub extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, i: c_int, text: [*]const u8, n: c_int, destructor: isize) c_int;
pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, i: c_int, value: f64) c_int;
pub extern fn sqlite3_column_double(stmt: *sqlite3_stmt, i: c_int) f64;
pub extern fn sqlite3_column_text(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, i: c_int) i64;
pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, i: c_int) c_int;
pub extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;

pub const ok = 0;
pub const row = 100;
pub const done = 101;
pub const open_readwrite = 0x2;
pub const open_create = 0x4;
pub const config_heap = 8;
const transient: isize = -1;
pub const column_null = 5;

/// Why the calling thread's last store operation failed, as SQLite put it.
/// A worker using another connection cannot overwrite the caller's diagnostic.
pub threadlocal var failure: [512]u8 = undefined;
pub threadlocal var failure_len: usize = 0;

/// Process-lifetime ownership of SQLite's accepted heap and the lock guarding its initialization.
pub const ProcessHeap = struct { configured: bool = false, mutex: Io.Mutex = .init };
pub var process_heap: ProcessHeap = .{};
pub const minimum_heap_bytes = 1 << 20;
pub const sqlite_heap_alignment = 64;

/// Serializes SQLite's global heap setup. SQLite owns an accepted heap until process exit.
pub fn initializeSqliteHeap(owner: *ProcessHeap, gpa: Allocator, io: Io, heap_bytes: usize) !void {
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
pub fn describeStoreFailure(comptime template: []const u8, args: anytype) void {
    if (template.len == 0) assert.panic("store failure has no description; pass a message naming the failing configuration and recovery", .{});
    // failure/failure_len are threadlocal, so no other connection can replace this caller's cause.
    const shown = std.fmt.bufPrint(&failure, template, args) catch assert.panic("store diagnostic '{s}' exceeds the {d}-byte diagnostic buffer; shorten the template", .{ template, failure.len });
    failure_len = shown.len;
    if (failure_len == 0) assert.panic("the store diagnostic template '{s}' formatted to no diagnostic; retain its description for the caller", .{template});
}

pub fn prepareStatement(db: *sqlite3, comptime trusted_sql: []const u8) !*sqlite3_stmt {
    // comptime prevents runtime file contents, environment or request data becoming SQL here.
    if (trusted_sql.len == 0) assert.panic("preparing an empty built-in statement; pass a module SQL constant to prepareStatement()", .{});
    if (std.mem.indexOfScalar(u8, trusted_sql, ';') != null) assert.panic("'{s}' holds more than one built-in statement; prepare them one at a time", .{trusted_sql});
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, trusted_sql.ptr, @intCast(trusted_sql.len), &stmt, null) != ok) return captureDatabaseFailure(db);
    return stmt orelse assert.panic("SQLite prepared '{s}' but returned no statement; check the built-in SQL passed to prepareStatement() is a single statement", .{trusted_sql});
}

pub fn bind(stmt: *sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (text.len > std.math.maxInt(c_int)) assert.panic("binding {d} bytes of text, more than SQLite takes in one parameter; shorten the function's source, or split the function", .{text.len});
    if (sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != ok) return captureDatabaseFailure(sqlite3_db_handle(stmt));
}

/// The text of column `index` in the current row, valid until the next row is read.
pub fn columnText(stmt: *sqlite3_stmt, index: c_int) []const u8 {
    if (index < 0) assert.panic("reading column {d}; SQLite numbers columns from 0", .{index});
    const text = sqlite3_column_text(stmt, index) orelse return "";
    const length = sqlite3_column_bytes(stmt, index);
    if (length < 0) assert.panic("SQLite gave column {d} a length of {d}", .{ index, length });
    return text[0..@intCast(length)];
}

pub fn bindInt(stmt: *sqlite3_stmt, index: c_int, value: u64) !void {
    if (index < 1) assert.panic("binding parameter {d}; SQLite numbers parameters from 1", .{index});
    if (value > std.math.maxInt(i64)) assert.panic("binding {d}, past the largest integer SQLite stores; count something smaller", .{value});
    if (sqlite3_bind_int64(stmt, index, @intCast(value)) != ok) return captureDatabaseFailure(sqlite3_db_handle(stmt));
}

/// Converts a failed SQLite operation into the store's stable error, retaining its detailed cause.
/// The diagnostic belongs to this calling thread, not to all connections in the process.
pub fn captureDatabaseFailure(db: *sqlite3) error{StoreUnavailable} {
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

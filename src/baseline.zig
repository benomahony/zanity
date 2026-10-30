const triage = @import("triage.zig");
const std = @import("std");
const assert = @import("assert.zig");

pub const Row = struct {
    path: []const u8,
    line: u32,
    column: u32,
    severity: []const u8,
    rule: []const u8,
    message: []const u8,
    fix: []const u8,
    matching_total: ?usize = null,
    next_offset: ?usize = null,
    edit_start: ?u32 = null,
    edit_end: ?u32 = null,
    edit_text: ?[]const u8 = null,
    id: []const u8 = "",
    classification: []const u8 = "unclassified",
};

pub const Review = struct {
    new: usize = 0,
    existing: usize = 0,
    resolved: usize = 0,
    matching: usize = 0,
    next: ?usize = null,
    new_counts: @import("report.zig").Counts = .{ .files = 0 },
};

const Snapshot = struct { schema_version: u32, identity_version: u32, findings: []const Row };
const max_baseline_bytes = 128 * 1024 * 1024;
const max_baseline_findings = 1 << 18;
const snapshot_schema_version = 1;
const snapshot_identity_version = 1;

/// Identity v1: path, rule, trimmed source line and duplicate ordinal.
/// Locations are deliberately excluded. Identical anchors are numbered in source order.
pub fn identity(text: *@import("memory.zig").Text, row: Row, anchor: []const u8, ordinal: usize) ![]const u8 {
    if (row.path.len == 0 or row.rule.len == 0) assert.panic("identity requires a file and rule", .{});
    if (ordinal == std.math.maxInt(usize)) assert.panic("identity ordinal overflow", .{});
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{
        row.path,
        row.rule,
        std.mem.trim(u8, anchor, " \t\r"),
    }) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, part.len, .little);
        hash.update(&length);
        hash.update(part);
    }
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, ordinal, .little);
    hash.update(&number);
    return text.format("{x}", .{hash.finalResult()});
}

/// Gives each row an identity from its rule, message and the text of its line. Rows must be in
/// report.sortFindings() order, by path and then line, since each file is read once, forwards.
pub fn identify(gpa: std.mem.Allocator, ws: anytype) !void {
    const rows = ws.rows.items();
    for (rows[0..rows.len -| 1], rows[@min(1, rows.len)..]) |a, b| {
        const by_path = std.mem.order(u8, a.path, b.path);
        if (by_path == .gt or (by_path == .eq and a.line > b.line)) assert.panic("identity rows are out of order: {s}:{d} before {s}:{d}; sort the findings with report.sortFindings() first", .{ a.path, a.line, b.path, b.line });
    }
    if (rows.len > ws.limits.findings) assert.panic("identity input {d} exceeds capacity {d}", .{ rows.len, ws.limits.findings });
    if (ws.source.len == 0) assert.panic("identity needs a source buffer", .{});
    var duplicates: std.StringHashMapUnmanaged(usize) = .empty;
    duplicates = try initIdentityIndex(gpa, rows.len);
    defer duplicates.deinit(gpa);
    var path: []const u8 = "";
    var source: []const u8 = "";
    var split = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 0;
    var anchor: []const u8 = "";
    for (rows) |*row| {
        if (!std.mem.eql(u8, path, row.path)) {
            path = row.path;
            source = try std.Io.Dir.cwd().readFile(ws.io, path, ws.source);
            split = std.mem.splitScalar(u8, source, '\n');
            line = 0;
        }
        while (line < row.line) : (line += 1) anchor = split.next() orelse "";
        const key = try identity(&ws.text, row.*, anchor, 0);
        const entry = duplicates.getOrPutAssumeCapacity(key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        row.id = try identity(&ws.text, row.*, anchor, entry.value_ptr.*);
        entry.value_ptr.* += 1;
    }
}

/// Reads an operator-selected baseline into a caller-owned bounded region. The returned rows
/// remain valid until that region is reset; missing, malformed and incompatible files return errors.
pub fn initSnapshot(region: *std.heap.FixedBufferAllocator, io: std.Io, operator_baseline_path: []const u8) !Snapshot {
    // The invoking user chooses this local baseline file; no remote caller selects it.
    // Source bytes and parsed rows belong to prepare()'s bounded region and are invalid after
    // that region is reset. Leaky JSON parsing deliberately shares that single lifetime.
    const gpa = region.allocator();
    const path = operator_baseline_path;
    if (path.len == 0) return error.EmptyBaselinePath;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_baseline_bytes));
    const versions = std.json.parseFromSliceLeaky(struct { schema_version: u32, identity_version: u32 }, gpa, data, .{ .ignore_unknown_fields = true }) catch return error.CorruptBaseline;
    if (versions.schema_version != snapshot_schema_version or versions.identity_version != snapshot_identity_version) return error.IncompatibleBaselineVersion;
    const snapshot = std.json.parseFromSliceLeaky(Snapshot, gpa, data, .{}) catch return error.CorruptBaseline;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(gpa);
    if (snapshot.findings.len > max_baseline_findings) return error.BaselineTooLarge;
    try ids.ensureTotalCapacity(gpa, @intCast(snapshot.findings.len));
    if (ids.count() != 0) assert.panic("baseline validation map must start empty", .{});
    for (snapshot.findings) |row| {
        try validateBaselineRow(row);
        const entry = ids.getOrPutAssumeCapacity(row.id);
        if (entry.found_existing) return error.DuplicateBaselineIdentity;
    }
    if (ids.count() != snapshot.findings.len) assert.panic("validated {d} identities among {d} rows", .{ ids.count(), snapshot.findings.len });
    return snapshot;
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, target: struct { path: []const u8, replace: bool }, rows: []const Row) !void {
    if (target.path.len == 0) return error.EmptyBaselinePath;
    if (rows.len > 1 << 18) return error.BaselineTooLarge;
    const data = try std.json.Stringify.valueAlloc(gpa, Snapshot{ .schema_version = 1, .identity_version = 1, .findings = rows }, .{ .whitespace = .indent_2 });
    defer gpa.free(data);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, target.path, .{ .replace = target.replace });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    if (rows.len > data.len) assert.panic("serialized {d} findings into only {d} bytes", .{ rows.len, data.len });
    if (data.len == 0) assert.panic("serialized baseline cannot be empty", .{});
    if (target.replace) try atomic.replace(io) else try atomic.link(io);
}

pub fn classifyFindings(gpa: std.mem.Allocator, rows: []Row, old: []const Row, resolved: *std.ArrayList(Row)) !Review {
    var prior: std.StringHashMapUnmanaged(Row) = .empty;
    defer prior.deinit(gpa);
    if (resolved.items.len != 0) assert.panic("comparison received {d} old resolutions", .{resolved.items.len});
    prior = try initComparisonIndex(gpa, old, resolved);

    var result: Review = .{};
    for (rows) |*row| {
        if (prior.fetchRemove(row.id) != null) {
            row.classification = "existing";
            result.existing += 1;
        } else {
            row.classification = "new";
            result.new += 1;
            if (std.mem.eql(u8, row.severity, "error")) result.new_counts.errors += 1 else result.new_counts.warnings += 1;
        }
    }
    var remaining = prior.valueIterator();
    while (remaining.next()) |value| {
        var row = value.*;
        row.classification = "resolved";
        resolved.appendAssumeCapacity(row);
    }
    result.resolved = resolved.items.len;
    if (result.new + result.existing != rows.len) assert.panic("comparison counted {d} new + {d} existing among {d} rows", .{ result.new, result.existing, rows.len });
    if (result.resolved + result.existing != old.len) assert.panic("comparison counted {d} resolved + {d} existing among {d} baseline rows", .{ result.resolved, result.existing, old.len });
    return result;
}

pub fn prepare(ctx: anytype, ws: anytype, options: anytype) !void {
    try validateOptions(ctx, ws, options);
    if (ws.rows.len > ws.limits.findings) assert.panic("review input {d} exceeds limit {d}", .{ ws.rows.len, ws.limits.findings });
    if (ws.baseline_buffer.len == 0) assert.panic("review requires its initialized buffer", .{});
    var arena = std.heap.FixedBufferAllocator.init(ws.baseline_buffer);
    const gpa = arena.allocator();
    try identify(gpa, ws);
    var resolved: std.ArrayList(Row) = .empty;
    defer resolved.deinit(gpa);
    ws.review = .{};
    if (options.baseline) |path| {
        if (!options.@"capture-baseline") {
            const snapshot = initSnapshot(&arena, ws.io, path) catch |e| return ctx.fail(.usage, try ws.text.format("Cannot load baseline {s}: {t}.", .{ path, e }), "No findings were accepted. Restore a compatible baseline or explicitly capture a new file.");
            ws.review = try classifyFindings(gpa, ws.rows.items(), snapshot.findings, &resolved);
        }
        if (options.@"capture-baseline") {
            ws.review.new = ws.rows.len;
            for (ws.rows.items()) |*row| row.classification = "new";
        }
        if (options.@"capture-baseline" or options.@"update-baseline") {
            save(gpa, ws.io, .{ .path = path, .replace = options.@"update-baseline" }, ws.rows.items()) catch |e| return ctx.fail(.io, try ws.text.format("Cannot write baseline {s}: {t}.", .{ path, e }), "Capture refuses to overwrite; use --update-baseline deliberately to accept current findings.");
            const err = ctx.runtime.err;
            try err.writer.print("Baseline recorded: {d} findings; {d} added, {d} retained, {d} resolved.\n", .{ ws.rows.len, ws.review.new, ws.review.existing, ws.review.resolved });
        }
    }
    if (options.baseline != null) try ws.history.describeChanges(&ws.text, ws.rows.items());
    try triage.selectRows(ws, options, resolved.items);
}

fn validateBaselineRow(row: Row) !void {
    if (row.id.len != 64 or row.path.len == 0 or row.rule.len == 0 or row.line == 0 or row.column == 0) return error.CorruptBaseline;
    for (row.id) |c| if (!std.ascii.isHex(c)) return error.CorruptBaseline;
    if (!std.mem.eql(u8, row.severity, "error") and !std.mem.eql(u8, row.severity, "warning") and !std.mem.eql(u8, row.severity, "information")) return error.CorruptBaseline;
    if (row.id.len != 64) assert.panic("validated identity has {d} characters", .{row.id.len});
    if (row.line == 0) assert.panic("validated row has line {d}", .{row.line});
}

fn initIdentityIndex(gpa: std.mem.Allocator, capacity: usize) !std.StringHashMapUnmanaged(usize) {
    if (capacity > 1 << 18) return error.TooManyFindings;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    try index.ensureTotalCapacity(gpa, @intCast(capacity));
    if (index.count() != 0) assert.panic("new identity index contains {d} entries", .{index.count()});
    if (index.capacity() < capacity) assert.panic("identity index capacity {d} is below {d}", .{ index.capacity(), capacity });
    return index;
}

fn initComparisonIndex(gpa: std.mem.Allocator, old: []const Row, resolved: *std.ArrayList(Row)) !std.StringHashMapUnmanaged(Row) {
    if (old.len > 1 << 18) return error.TooManyBaselineFindings;
    var index: std.StringHashMapUnmanaged(Row) = .empty;
    errdefer index.deinit(gpa);
    try index.ensureTotalCapacity(gpa, @intCast(old.len));
    try resolved.ensureTotalCapacity(gpa, old.len);
    for (old) |row| index.putAssumeCapacity(row.id, row);
    if (index.count() != old.len) assert.panic("baseline has {d} unique IDs among {d} findings", .{ index.count(), old.len });
    if (resolved.capacity < old.len) assert.panic("resolution capacity {d} is below {d}", .{ resolved.capacity, old.len });
    return index;
}

pub fn validateOptions(ctx: anytype, ws: anytype, options: anytype) !void {
    if (options.paths.len == 0) assert.panic("validation requires checked paths", .{});
    const text = &ws.text;
    if (text.used > text.buffer.len) assert.panic("validation text used {d} exceeds capacity", .{text.used});
    triage.validate(options) catch |e| return ctx.fail(.usage, try ws.text.format("Invalid baseline/triage options: {t}.", .{e}), "Use --baseline PATH; capture and update are explicit, separate actions without --watch.");
}

test "identifying duplicate findings releases its temporary index" {
    const memory = @import("memory.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "assert value\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "a.py", gpa);
    defer gpa.free(path);
    var source: [1024]u8 = undefined;
    var ws: struct {
        rows: memory.Bounded(Row),
        text: memory.Text,
        source: []u8,
        limits: memory.Limits,
        io: std.Io,
    } = .{
        .rows = try .initBounded(gpa, 2, "findings"),
        .text = try .initText(gpa, 4096),
        .source = &source,
        .limits = .{ .findings = 2 },
        .io = io,
    };
    defer gpa.free(ws.rows.buffer);
    defer gpa.free(ws.text.buffer);
    const row: Row = .{ .path = path, .line = 1, .column = 1, .severity = "warning", .rule = "assertion-message", .message = "assertion needs context", .fix = "Add a message." };
    try ws.rows.add(row);
    try ws.rows.add(row);
    try identify(gpa, &ws);
    try std.testing.expectEqual(@as(usize, 64), ws.rows.items()[0].id.len);
    try std.testing.expectEqualStrings(try identity(&ws.text, row, "assert value", 0), ws.rows.items()[0].id);
    try std.testing.expectEqualStrings(try identity(&ws.text, row, "assert value", 1), ws.rows.items()[1].id);
}

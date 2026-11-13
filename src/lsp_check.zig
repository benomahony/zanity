//! Running zanity check for the language server: the command it runs over the workspace, reading
//! its findings back, and leaving out those flagged as false positives this session.
const std = @import("std");
const assert = @import("assert.zig");
const protocol = @import("lsp_protocol.zig");
const uriOf = protocol.uriOf;
const results_module = @import("lsp_results.zig");
const flagKey = @import("lsp_commands.zig").flagKey;
const Record = results_module.Record;
const Results = results_module.Results;
const entryOf = results_module.entryOf;
const Io = std.Io;
const json = std.json;
const lsp = @import("lsp.zig");
pub const check_stderr_bytes = lsp.check_stderr_bytes;
const LanguageServer = lsp.LanguageServer;
const cmd_watch = @import("cmd_watch.zig");
const Resident = cmd_watch.Resident;
const Row = @import("baseline.zig").Row;
const memory = @import("memory.zig");

/// Runs `zanity check` over the workspace and publishes what changed since the last check.
/// When the check fails, the last one's findings stay.
pub fn checkWorkspace(self: *LanguageServer, trigger: []const u8) !void {
    if (trigger.len == 0) assert.panic("checking with no trigger; name what started the check", .{});
    const started = if (self.services.telemetry) |t| t.now() else Io.Timestamp.zero;
    self.previous.clear();
    const records = try runZanityCheck(self, &self.previous) orelse return;
    std.mem.swap(Results, &self.current, &self.previous);
    try self.current.advanceDiagnosticRevision(&self.previous);
    self.dirty.clear();
    var fixable: usize = 0;
    for (records) |record| {
        if (isFlagged(self, record)) continue;
        try add(self, record);
        fixable += @intFromBool(record.edit_start != null);
    }
    for (self.current.files.items()) |*file| try self.publish(file.uri, self.current.entriesOf(file));
    for (self.previous.files.items()) |file| if (self.current.find(file.path) == null) try self.publish(file.uri, &.{});
    const shown = self.current.entries.len;
    try self.trace("check", started, &.{
        .{ .key = "zanity.trigger", .value = .{ .string = trigger } },
        .{ .key = "zanity.root", .value = .{ .string = self.root } },
        .{ .key = "zanity.findings", .value = .{ .int = @intCast(shown) } },
        .{ .key = "zanity.fixable", .value = .{ .int = @intCast(fixable) } },
        .{ .key = "zanity.flagged_hidden", .value = .{ .int = @intCast(records.len - shown) } },
        .{ .key = "zanity.files", .value = .{ .int = @intCast(self.current.files.len) } },
    });
    if (shown > records.len) assert.panic("{d} findings shown from {d} reported; add() files each finding once", .{ shown, records.len });
}

/// Runs this executable as `zanity check --json` in the root and reads its findings back into
/// `into`; null, after telling the editor why, when the check fails.
pub fn runZanityCheck(self: *LanguageServer, into: *Results) !?[]const Record {
    if (!std.fs.path.isAbsolute(self.root)) assert.panic("checking the relative workspace {s}; initialize() must select an absolute workspace first", .{self.root});
    if (!self.services.infer) if (self.services.resident) |resident| return residentCheck(self, into, resident);
    const buffer = into.outputBuffer();
    var output: std.heap.FixedBufferAllocator = .init(buffer);
    const services = self.services;
    var argv: [8][]const u8 = .{ services.exe, "check", ".", "--json", "--quiet", "--no-color", "", "" };
    var argc: usize = 6;
    for ([_]struct { bool, []const u8 }{ .{ services.infer, "--infer" }, .{ services.production, "--production" } }) |flag| if (flag[0]) {
        argv[argc] = flag[1];
        argc += 1;
    };
    if (argc > argv.len) assert.panic("built {d} arguments for zanity check in room for {d}", .{ argc, argv.len });
    const result = std.process.run(output.allocator(), self.io, .{
        .argv = argv[0..argc],
        .cwd = .{ .path = self.root },
        .stdout_limit = .limited(buffer.len / 2),
        .stderr_limit = .limited(check_stderr_bytes),
    }) catch |e| {
        try self.show(1, try self.scratch.text.format("zanity could not run {s} check in {s}: {t}. Check that this executable can run and the workspace is readable, then save a file to retry.", .{ self.services.exe, self.root, e }));
        return null;
    };
    const ok = switch (result.term) {
        .exited => |code| code <= 1,
        else => false,
    };
    if (!ok) {
        try self.show(1, try self.scratch.text.format("zanity check failed in {s}: {s} Run zanity check --json in this workspace to diagnose the failure, then save a file to retry.", .{ self.root, std.mem.trim(u8, result.stderr, " \n") }));
        return null;
    }
    const records = json.parseFromSliceLeaky([]const Record, output.allocator(), result.stdout, .{ .ignore_unknown_fields = true }) catch |e| {
        try self.show(1, try self.scratch.text.format("zanity could not read the findings of zanity check in {s}: {t}. Rebuild or reinstall zanity and restart the language server; if the workspace has too many findings, open a smaller workspace.", .{ self.root, e }));
        return null;
    };
    for (records) |r| if (r.line == 0 or r.column == 0) assert.panic("{s}: zanity check reported line {d} column {d}; --json counts both from 1", .{ r.path, r.line, r.column });
    return records;
}

/// Checks the workspace in this process, on the workspace kept between checks, so a save analyses
/// only the files that changed; null, after telling the editor why, when the check fails.
fn residentCheck(self: *LanguageServer, into: *Results, resident: *Resident) !?[]const Record {
    if (into.records.len != 0) assert.panic("checking {s} into results that still hold {d} findings; checkWorkspace() clears them first", .{ self.root, into.records.len });
    if (!self.initialized) assert.panic("checking {s} before the editor initialized the session; accepts() admits only initialize first", .{self.root});
    const ctx = self.services.ctx orelse assert.panic("checking {s} in this process without the command's context; runLsp() passes both", .{self.root});
    var root = Io.Dir.cwd().openDir(self.io, self.root, .{}) catch |e| {
        try self.show(1, try self.scratch.text.format("zanity could not open the workspace {s}: {t}. Check that it exists and is readable, then save a file to retry.", .{ self.root, e }));
        return null;
    };
    defer root.close(self.io);
    try std.process.setCurrentDir(self.io, root);
    _ = cmd_watch.checkAgain(ctx, resident, .{ .paths = &.{"."}, .production = self.services.production }) catch |e| switch (e) {
        error.UserFailure => {
            const failure = ctx.failure orelse assert.panic("zanity check failed in {s} without saying why; ctx.fail() records the failure", .{self.root});
            try self.show(1, try self.scratch.text.format("zanity check failed in {s}: {s} {s}", .{ self.root, failure.message, failure.hint }));
            return null;
        },
        else => return e,
    };
    const rows = resident.rows();
    copyRecords(into, rows) catch {
        try self.show(1, try self.scratch.text.format("zanity found {d} findings in {s}, more than the language server holds. Open a smaller workspace.", .{ rows.len, self.root }));
        return null;
    };
    return into.records.items();
}

/// Copies each row into the results' own reserved memory, since the next check reuses the workspace's.
fn copyRecords(into: *Results, rows: []const Row) error{LimitExceeded}!void {
    if (into.records.len != 0) assert.panic("copying {d} findings into results that hold {d}; checkWorkspace() clears them first", .{ rows.len, into.records.len });
    var text: memory.Text = .{ .buffer = into.outputBuffer() };
    for (rows) |row| {
        if (row.line == 0 or row.column == 0) assert.panic("{s}: the check reported line {d} column {d}; rows count both from 1", .{ row.path, row.line, row.column });
        try into.records.add(.{
            .path = try text.copy(row.path),
            .line = row.line,
            .column = row.column,
            .severity = try text.copy(row.severity),
            .rule = try text.copy(row.rule),
            .message = try text.copy(row.message),
            .fix = try text.copy(row.fix),
            .edit_start = row.edit_start,
            .edit_end = row.edit_end,
            .edit_text = if (row.edit_text) |edit| try text.copy(edit) else null,
        });
    }
    if (into.records.len != rows.len) assert.panic("copied {d} of {d} findings; copyRecords() copies every row", .{ into.records.len, rows.len });
}

/// Files one finding under its path, reading the file the first time to place it.
pub fn add(self: *LanguageServer, record: Record) !void {
    if (record.path.len == 0) assert.panic("a {s} finding with no path; --json gives each finding its file's path", .{record.rule});
    const results = &self.current;
    const path = try results.text.format("{s}/{s}", .{ self.root, record.path });
    const last = results.files.last();
    const same = if (last) |file| std.mem.eql(u8, file.path, path) else false;
    if (!same) try results.files.add(.{
        .path = path,
        .uri = try uriOf(&results.text, path),
        .source = results.readSource(self.io, path),
        .first = results.entries.len,
        .count = 0,
    });
    const file = results.files.last() orelse unreachable;
    try results.entries.add(try entryOf(&results.text, file.source, record, self.utf8));
    file.count += 1;
    if (file.first + file.count != results.entries.len) assert.panic("{s}: its findings are not together; zanity check sorts findings by path", .{record.path});
}

pub fn isFlagged(self: *const LanguageServer, record: Record) bool {
    if (record.rule.len == 0) assert.panic("{s}: a finding with no rule; --json names each finding's rule", .{record.path});
    if (self.flagged.len == 0) return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.root, record.path }) catch return false;
    const key = flagKey(path, record.rule, record.message);
    for (self.flagged.items()) |flagged| if (flagged == key) return true;
    if (self.flagged.len > self.flagged.capacity()) assert.panic("{d} flags in room for {d}", .{ self.flagged.len, self.flagged.capacity() });
    return false;
}

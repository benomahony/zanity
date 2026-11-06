//! Running zanity check for the language server: the command it runs over the workspace, reading
//! its findings back, and leaving out those flagged as false positives this session.
const std = @import("std");
const assert = @import("assert.zig");
const protocol = @import("lsp_protocol.zig");
const uriOf = protocol.uriOf;
const results_module = @import("lsp_results.zig");
const actions = @import("lsp_actions.zig");
const flagKey = actions.flagKey;
const Record = results_module.Record;
const Results = results_module.Results;
const entryOf = results_module.entryOf;
const Io = std.Io;
const json = std.json;
const lsp = @import("lsp.zig");
pub const check_stderr_bytes = lsp.check_stderr_bytes;
const LanguageServer = lsp.LanguageServer;

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
    const buffer = into.outputBuffer();
    var output: std.heap.FixedBufferAllocator = .init(buffer);
    const services = self.services;
    const argv = [_][]const u8{ services.exe, "check", ".", "--json", "--quiet", "--no-color", "--infer" };
    const result = std.process.run(output.allocator(), self.io, .{
        .argv = argv[0..if (services.infer) argv.len else argv.len - 1],
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

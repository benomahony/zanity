//! `zanity init`: writes a zanity.toml and reports what it wrote.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const zclig = @import("zclig");
const adapters = @import("adapters");
const language = @import("language.zig");
const rules = @import("rules.zig");
const config = @import("config.zig");
const starter = @import("init.zig");
const workspace = @import("workspace.zig");
const workspaceOf = workspace.workspaceOf;
const console = workspace.console;
const collect = @import("collect.zig").collect;

pub const InitOptions = struct {
    paths: []const []const u8,
    force: bool = false,
    minimal: bool = false,
};

pub const InitRow = @import("rows.zig").InitRow;

pub fn runInit(ctx: *zclig.Context, options: InitOptions) ![]const InitRow {
    const ws = workspaceOf(ctx);
    if (options.paths.len != 1) return ctx.fail(.usage, "zanity init takes one directory.", "Run it in the project's root, or pass that directory, such as zanity init path/to/project.");
    const dir = options.paths[0];
    const target = if (std.mem.eql(u8, dir, ".")) config.file_name else try ws.text.format("{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), config.file_name });
    const cwd = Io.Dir.cwd();
    try collect(ctx, ws, dir);
    var counts: [language.count]starter.Project.Count = undefined;
    for (adapters.all, &counts) |*adapter, *count| count.* = .{ .name = adapter.name, .files = 0 };
    for (ws.files.items()) |path| if (language.forPath(path)) |adapter| {
        counts[language.indexOf(adapter)].files += 1;
    };
    var present: [starter.usual_excludes.len][]const u8 = undefined;
    var found: usize = 0;
    for (starter.usual_excludes) |candidate| {
        const path = if (std.mem.eql(u8, dir, ".")) candidate else try ws.text.format("{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), candidate });
        cwd.access(ws.io, path, .{}) catch continue;
        present[found] = candidate;
        found += 1;
    }
    var buffer: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try starter.renderConfig(&w, .{ .languages = &counts, .present = present[0..found], .minimal = options.minimal });
    cwd.writeFile(ws.io, .{ .sub_path = target, .data = w.buffered(), .flags = .{ .exclusive = !options.force } }) catch |e| switch (e) {
        error.PathAlreadyExists => return ctx.fail(.usage, try ws.text.format("{s} already exists.", .{target}), "Edit it, or pass --force to replace it with a fresh one."),
        else => return ctx.fail(.io, try ws.text.format("Could not write {s}: {t}.", .{ target, e }), "Check that the directory exists and is writable."),
    };
    if (w.buffered().len == 0) assert.panic("zanity init wrote an empty {s}; renderConfig() in src/init.zig must write the whole file", .{target});
    if (found > starter.usual_excludes.len) assert.panic("found {d} of the {d} usual excludes; the loop in runInit() must add each at most once", .{ found, starter.usual_excludes.len });
    ws.init_row[0] = .{ .path = target, .rules = rules.all.len, .excluded = found, .minimal = options.minimal };
    return &ws.init_row;
}

pub fn renderInit(ctx: *zclig.Context, rows: []const InitRow) !void {
    if (rows.len != 1) assert.panic("zanity init reported {d} files written; runInit() writes exactly one", .{rows.len});
    const row = rows[0];
    const out = console(ctx, ctx.runtime.out);
    if (row.minimal) {
        try out.writer.print("Wrote {s}: every rule on, with nothing explained; `zanity init --force` writes the full file with notes and the list of all {d} rules.\n", .{ row.path, row.rules });
    } else try out.writer.print("Wrote {s}: every setting explained, and all {d} rules listed with how to fix what they find.\n", .{ row.path, row.rules });
    if (row.excluded > 0) try out.writer.print("It excludes the {d} fixture or vendored {s} it found; check that list.\n", .{ row.excluded, if (row.excluded == 1) "directory" else "directories" });
    try out.writer.writeAll("Next: run `zanity check .`, then delete or change what you don't need.\n");
    if (row.path.len == 0) assert.panic("zanity init reported writing a file with no path; runInit() must pass the path it wrote", .{});
}

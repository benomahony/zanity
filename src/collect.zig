//! The walk that finds the files `zanity check` checks, honouring git's ignore files and
//! zanity.toml's `exclude`, and counting the checkable files an exclude leaves out.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const zclig = @import("zclig");
const language = @import("language.zig");
const project = @import("project.zig");
const memory = @import("memory.zig");
const watch = @import("watch.zig");
const Workspace = @import("workspace.zig").Workspace;

const Entry = Io.Dir.Walker.Entry;

/// Where the walk is: the path it was asked for, and the excluded directory it is inside, if any.
const Walk = struct {
    ws: *Workspace,
    walker: *Io.Dir.SelectiveWalker,
    path: []const u8,
    excluded_dir: ?[]const u8 = null,
};

/// Adds the checkable files under `path`, skipping what git ignores. A file named directly is always checked.
pub fn collect(ctx: *zclig.Context, ws: *Workspace, path: []const u8) !void {
    if (path.len == 0) assert.panic("asked to collect files from an empty path; zclig supplies '.' when none are given", .{});
    const before = ws.files.len;
    var dir = Io.Dir.cwd().openDir(ws.io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            const relative = if (std.mem.startsWith(u8, path, "./") and path.len > 2) path[2..] else path;
            const configures = language.forPath(std.fs.path.basename(path)) == null and project.isProjectFile(relative);
            try if (configures) ws.project_files.add(path) else ws.files.add(path);
            return;
        },
        error.FileNotFound => return ctx.fail(.usage, try ws.text.format("{s} does not exist.", .{path}), "Pass a file or directory to check."),
        else => return e,
    };
    defer dir.close(ws.io);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try dir.realPath(ws.io, &root_buffer)];
    ws.ignore.loadAncestors(ws.io, root) catch |e| switch (e) {
        error.LimitExceeded => return e,
        else => return ctx.fail(.io, try ws.text.format("Could not read the git ignore files that apply to {s}: {t}.", .{ root, e }), "Check that the repository's .git, and the git directory a .git file names, are readable."),
    };
    try ws.ignore.loadFile(ws.io, root, ".gitignore");
    try ws.dirs.add(try ws.text.copy(root));
    var walker = try dir.walkSelectively(std.heap.page_allocator);
    defer walker.deinit();
    var walk: Walk = .{ .ws = ws, .walker = &walker, .path = path };
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..ws.limits.files * 2) |_| {
        const entry = try walker.next(ws.io) orelse break;
        const absolute = std.fmt.bufPrint(&absolute_buffer, "{s}/{s}", .{ root, entry.path }) catch return ctx.fail(.io, try ws.text.format("Cannot check {s}/{s}: its absolute path is too long.", .{ root, entry.path }), "Move the project to a shorter path, or shorten the nested directory names.");
        try visit(&walk, entry, absolute);
    } else {
        memory.exceeded = "directory entries";
        return error.LimitExceeded;
    }
    if (ws.files.len < before) assert.panic("collecting {s} dropped files: {d} before, {d} after; collect() must only add files", .{ path, before, ws.files.len });
}

/// Handles one entry of the walk at absolute path `absolute`, leaving any excluded directory it has walked out of.
fn visit(walk: *Walk, entry: Entry, absolute: []const u8) !void {
    if (!std.fs.path.isAbsolute(absolute)) assert.panic("visiting '{s}', which is relative; join the entry to the walk's real root", .{absolute});
    if (walk.excluded_dir) |dir_path| if (!watch.within(absolute, dir_path)) {
        walk.excluded_dir = null;
    };
    switch (entry.kind) {
        .directory => try visitDirectory(walk, entry, absolute),
        .file => try visitFile(walk, entry, absolute),
        else => {},
    }
    if (walk.excluded_dir) |dir_path| if (!watch.within(absolute, dir_path)) assert.panic("'{s}' is outside the excluded directory '{s}' the walk is in; visit() must leave it first", .{ absolute, dir_path });
}

/// Enters a directory the walk keeps, or one zanity.toml excludes so its checkable files can be counted.
fn visitDirectory(walk: *Walk, entry: Entry, absolute: []const u8) !void {
    if (entry.kind != .directory) assert.panic("'{s}' is a {t}; visitDirectory() takes directories", .{ entry.path, entry.kind });
    if (!std.mem.endsWith(u8, absolute, entry.path)) assert.panic("'{s}' does not end with the entry's path '{s}'; join the entry to the walk's root", .{ absolute, entry.path });
    const ws = walk.ws;
    if (project.skippedDir(entry.basename)) return;
    const kept = !ws.ignore.ignored(absolute, .directory);
    if (!kept and (walk.excluded_dir != null or !ws.ignore.excluded(absolute, .directory))) return;
    if (!kept) walk.excluded_dir = try ws.text.copy(absolute);
    try ws.ignore.loadFile(ws.io, absolute, ".gitignore");
    if (walk.excluded_dir == null) try ws.dirs.add(try ws.text.copy(absolute));
    try walk.walker.enter(ws.io, entry);
    if (walk.excluded_dir) |dir_path| if (!watch.within(absolute, dir_path)) assert.panic("entered '{s}' outside the excluded directory '{s}'; an excluded walk only goes deeper", .{ absolute, dir_path });
}

/// Adds a file the walk keeps, or counts it as skipped when zanity.toml excludes it or its directory.
fn visitFile(walk: *Walk, entry: Entry, absolute: []const u8) !void {
    if (entry.kind != .file) assert.panic("'{s}' is a {t}; visitFile() takes files", .{ entry.path, entry.kind });
    if (!std.mem.endsWith(u8, absolute, entry.path)) assert.panic("'{s}' does not end with the entry's path '{s}'; join the entry to the walk's root", .{ absolute, entry.path });
    const ws = walk.ws;
    const skipped_before = ws.skipped;
    const ignored = ws.ignore.ignored(absolute, .file);
    if (walk.excluded_dir == null and !ignored) return addFile(ws, walk.path, entry);
    const excluded = if (walk.excluded_dir == null) ws.ignore.excluded(absolute, .file) else !ignored;
    if (excluded and checkable(entry)) ws.skipped += 1;
    if (ws.skipped > skipped_before + 1) assert.panic("counted {d} skipped files for '{s}'; a file is skipped at most once", .{ ws.skipped - skipped_before, entry.path });
}

/// Whether zanity checks the file the walk found: source in a language it knows, or project configuration.
fn checkable(entry: Entry) bool {
    if (entry.basename.len == 0) assert.panic("the walk found a file with no name at '{s}'; Walker names every entry", .{entry.path});
    const result = language.forPath(entry.basename) != null or project.isProjectFile(entry.path);
    if (result and entry.kind != .file) assert.panic("'{s}' is a {t}, not a file; only files are checkable", .{ entry.path, entry.kind });
    return result;
}

/// Adds a file the walk found under `path` to the source files or the project files, or neither.
fn addFile(ws: *Workspace, path: []const u8, entry: Entry) !void {
    if (entry.path.len == 0) assert.panic("the walk under {s} found a file with no path; Walker gives each entry its path", .{path});
    const source = language.forPath(entry.basename) != null;
    if (!checkable(entry)) return;
    const joined = if (std.mem.eql(u8, path, "."))
        try ws.text.copy(entry.path)
    else
        try ws.text.format("{s}{s}{s}", .{ path, if (std.mem.endsWith(u8, path, "/")) "" else "/", entry.path });
    if (joined.len < entry.path.len) assert.panic("joined '{s}' under '{s}' into the shorter '{s}'; addFile() must keep the whole path", .{ entry.path, path, joined });
    if (source) try ws.files.add(joined) else try ws.project_files.add(joined);
}

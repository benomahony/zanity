//! `zanity check --watch`: waits for the operating system to report that a file `check` reads has
//! changed, then runs the check again. macOS reports changes through FSEvents, which watches a whole
//! tree and is loaded when --watch starts, so building zanity needs no framework; Linux through
//! inotify, one watch on each directory the walk enters; Windows through
//! NtNotifyChangeDirectoryFileEx over the whole tree. The checker stays resident between ordinary
//! runs, and the cache keeps deterministic analysis to the files that changed.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");
const language = @import("language.zig");
const project = @import("project.zig");
const config = @import("config.zig");
const memory = @import("memory.zig");
const Ignore = @import("ignore.zig").Ignore;
const Io = std.Io;

/// Clears the terminal and its scrollback and moves to the top, so each run starts on a clean screen.
pub const clear_screen = "\x1b[2J\x1b[3J\x1b[H";

/// What the rerun's environment carries so its --agent output says that saving reruns the check.
pub const env_var = "ZANITY_WATCH";

/// Each wait answers one change, so this many is far more than any session makes.
const max_waits = 1 << 40;

/// Which changed paths are worth a rerun: a source file, a project file, zanity.toml or a
/// .gitignore under one of the paths `check` was given, outside the directories the walk skips
/// and the files .gitignore and `exclude` leave out.
pub const ChangeFilter = struct {
    /// The absolute paths of the files and directories `check` was given.
    roots: []const []const u8,
    /// The .gitignore and exclude patterns the walk loaded.
    ignore: *const Ignore,

    pub fn relevant(scope: *const ChangeFilter, path: []const u8) bool {
        if (path.len == 0) assert.panic("asked whether an empty path changed anything; the watcher passes each changed file's absolute path", .{});
        if (scope.roots.len == 0) assert.panic("a watch scope with no roots matches nothing; pass the paths check was given", .{});
        const root = for (scope.roots) |r| {
            if (within(path, r)) break r;
        } else return false;
        const relative = std.mem.trimStart(u8, path[root.len..], "/\\");
        const name = std.fs.path.basename(path);
        if (!readByCheck(name, relative)) return false;
        var parts = std.mem.tokenizeAny(u8, relative, "/\\");
        var directory: ?[]const u8 = null;
        for (0..relative.len + 1) |_| {
            const part = parts.next() orelse break;
            if (directory) |d| if (scope.leftOut(path, d)) return false;
            directory = part;
        }
        return !scope.ignore.ignored(path, .file);
    }

    /// Whether the walk leaves out `directory`, a component of `path`, and so everything in it.
    fn leftOut(scope: *const ChangeFilter, path: []const u8, directory: []const u8) bool {
        if (directory.len == 0) assert.panic("asked whether an unnamed directory in '{s}' is left out; tokenizing never yields an empty component", .{path});
        const start = @intFromPtr(directory.ptr) - @intFromPtr(path.ptr);
        if (start + directory.len > path.len) assert.panic("'{s}' is not a part of '{s}'; pass a component tokenized from the path", .{ directory, path });
        return project.skippedDir(directory) or scope.ignore.ignored(path[0 .. start + directory.len], .directory);
    }
};

/// Whether `check` reads a file called `name` at `relative`, empty for a file given by name, or
/// reads it to decide which files to check.
fn readByCheck(name: []const u8, relative: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether check reads a file with no name at '{s}'; pass a file's base name", .{relative});
    if (relative.len > 0 and !std.mem.endsWith(u8, relative, name)) assert.panic("'{s}' is not the name at the end of '{s}'; pass the base name of the same path", .{ name, relative });
    if (language.forPath(name) != null) return true;
    if (std.mem.eql(u8, name, config.file_name) or std.mem.eql(u8, name, ".gitignore")) return true;
    return relative.len > 0 and project.isProjectFile(relative);
}

/// Whether `path` is `root` or lies under it.
fn within(path: []const u8, root: []const u8) bool {
    if (root.len == 0) assert.panic("checking '{s}' against an empty root; roots are absolute paths", .{path});
    if (path.len == 0) assert.panic("checking an empty path against '{s}'; pass the changed file's absolute path", .{root});
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/' or path[root.len] == '\\' or root[root.len - 1] == '/';
}

/// The longest directory every one of `paths` lies in, as a prefix of the first.
pub fn commonDirectory(paths: []const []const u8) []const u8 {
    if (paths.len == 0) assert.panic("finding the directory shared by no paths; pass at least one", .{});
    var shared = paths[0];
    for (paths[1..]) |path| {
        for (0..shared.len + 1) |_| {
            if (within(path, shared)) break;
            shared = std.fs.path.dirname(shared) orelse return std.fs.path.sep_str;
        }
    }
    if (!within(paths[0], shared)) assert.panic("'{s}' is not under the shared directory '{s}'", .{ paths[0], shared });
    return shared;
}

/// `args`, the command line after the program's name, written into `out` after `exe` without
/// --watch, and with --agent when no other output was chosen, so each rerun checks once and
/// says where each finding is and how to fix it.
pub fn rerunArgs(out: [][]const u8, exe: []const u8, args: []const []const u8) []const []const u8 {
    if (out.len < args.len + 2) assert.panic("room for {d} arguments to rerun {d}; give rerunArgs() two more slots than the arguments", .{ out.len, args.len });
    if (exe.len == 0) assert.panic("rerunning zanity from an empty path; pass the path executablePath() found", .{});
    out[0] = exe;
    var len: usize = 1;
    var chosen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "--watch=true")) continue;
        chosen = chosen or std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--plain") or std.mem.startsWith(u8, arg, "--agent");
        out[len] = arg;
        len += 1;
    }
    if (!chosen) {
        out[len] = "--agent";
        len += 1;
    }
    return out[0..len];
}

pub const Watcher = switch (builtin.os.tag) {
    .macos => FsEvents,
    .linux => Inotify,
    .windows => DirectoryNotify,
    else => @compileError("zanity check --watch has no way to hear of file changes on " ++ @tagName(builtin.os.tag) ++ "; add a watcher to src/watch.zig"),
};

pub const Error = error{ WatchUnavailable, TooManyWatches, LimitExceeded } || Io.Cancelable;

/// Watch defaults to agent output unless the command chose a format or explicitly turned it off.
pub fn agentOutput(args: []const []const u8, chose_format: bool, asked: bool) bool {
    if (asked and chose_format) assert.panic("agent output was requested with a machine format; speaksToAgent() must reject that first", .{});
    if (args.len == 0) assert.panic("choosing watch output from no command arguments; main() passes the check command", .{});
    for (args) |arg| if (std.mem.eql(u8, arg, "--agent=false")) return false;
    return asked or !chose_format;
}

/// Writes rows during a resident watch run in the same two machine formats zcli uses.
pub fn renderRows(comptime Row: type, out: *std.Io.Writer, json: bool, rows: []const Row) !void {
    const fields = .{ "path", "line", "column", "severity", "rule", "message", "fix", "edit_start", "edit_end", "edit_text" };
    if (@typeInfo(Row) != .@"struct") assert.panic("rendering watched rows of {s}; output rows must be structs", .{@typeName(Row)});
    if (@typeInfo(Row).@"struct".field_names.len != fields.len) assert.panic("rendering {d} fields with names for {d}; keep watch rows in step with the command row", .{ @typeInfo(Row).@"struct".field_names.len, fields.len });
    if (json) {
        try std.json.Stringify.value(rows, .{}, out);
        return out.writeByte('\n');
    }
    for (rows) |row| {
        inline for (fields, 0..) |field, i| {
            if (i != 0) try out.writeByte('\t');
            try out.writeAll(field ++ "=");
            try std.json.Stringify.value(@field(row, field), .{}, out);
        }
        try out.writeByte('\n');
    }
}

/// What a watcher is told to watch: `trees`, the directories holding the paths `check` was given,
/// and `directories`, every directory the walk entered, for systems that watch one at a time.
pub const Targets = struct {
    scope: *const ChangeFilter,
    trees: []const []const u8,
    directories: []const []const u8,
};

/// FSEvents: one stream over every tree, kept running between checks, so a change made while a
/// check runs is answered as soon as it ends.
const FsEvents = struct {
    library: std.DynLib,
    api: Api,
    scope: *const ChangeFilter,
    semaphore: dispatch.semaphore_t,
    queue: dispatch.queue_t,

    const dispatch = std.c.dispatch;
    const core_services = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

    const StreamRef = *opaque {};
    const CFStringRef = *const opaque {};
    const CFArrayRef = *const opaque {};
    const EventId = enum(u64) { since_now = std.math.maxInt(u64), _ };
    const CreateFlags = packed struct(u32) { use_cf_types: bool = false, no_defer: bool = false, watch_root: bool = false, ignore_self: bool = false, file_events: bool = false, _: u27 = 0 };
    const EventFlags = packed struct(u32) { must_scan_sub_dirs: bool, user_dropped: bool, kernel_dropped: bool, event_ids_wrapped: bool, history_done: bool, root_changed: bool, mount: bool, unmount: bool, _: u24 = 0 };
    const Context = extern struct { version: i32 = 0, info: ?*anyopaque, retain: ?*const anyopaque = null, release: ?*const anyopaque = null, copy_description: ?*const anyopaque = null };
    const Callback = *const fn (StreamRef, ?*anyopaque, usize, *anyopaque, [*]const EventFlags, [*]const EventId) callconv(.c) void;

    /// The CoreServices functions the watcher calls, looked up when it starts.
    const Api = struct {
        FSEventStreamCreate: *const fn (?*const anyopaque, Callback, *const Context, CFArrayRef, EventId, f64, CreateFlags) callconv(.c) ?StreamRef,
        FSEventStreamSetDispatchQueue: *const fn (StreamRef, dispatch.queue_t) callconv(.c) void,
        FSEventStreamStart: *const fn (StreamRef) callconv(.c) bool,
        CFArrayCreate: *const fn (?*const anyopaque, [*]const CFStringRef, i32, ?*const anyopaque) callconv(.c) ?CFArrayRef,
        CFStringCreateWithCString: *const fn (?*const anyopaque, [*:0]const u8, u32) callconv(.c) ?CFStringRef,
    };
    const utf8: u32 = 0x8000100;
    /// Seconds FSEvents gathers changes for before reporting them, so one save is one rerun.
    const latency = 0.02;
    /// More changes in one report than any save makes; FSEvents asks for a rescan long before.
    const max_batch = 1 << 24;
    /// FSEvents allows a few thousand watched trees; zanity is given far fewer paths than this.
    const max_trees = 1024;

    pub fn initWatcher(self: *FsEvents, _: std.mem.Allocator, _: Io, targets: Targets) Error!void {
        if (targets.trees.len == 0) assert.panic("watching no directories; pass the paths check was given", .{});
        if (targets.trees.len > max_trees) return error.TooManyWatches;
        if (targets.directories.len < targets.trees.len) assert.panic("{d} watched trees but the walk entered only {d} directories; every tree is a directory the walk started from", .{ targets.trees.len, targets.directories.len });
        self.library = std.DynLib.open(core_services) catch return error.WatchUnavailable;
        const info = @typeInfo(Api).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            @field(self.api, name) = self.library.lookup(T, name) orelse return error.WatchUnavailable;
        }
        self.scope = targets.scope;
        self.semaphore = dispatch.semaphore_create(0) orelse return error.WatchUnavailable;
        self.queue = dispatch.queue_create("zanity-watch", dispatch.QUEUE_SERIAL()) orelse return error.WatchUnavailable;
        var strings: [max_trees]CFStringRef = undefined;
        for (targets.trees, strings[0..targets.trees.len]) |tree, *string| {
            var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
            const terminated = std.fmt.bufPrintSentinel(&buffer, "{s}", .{tree}, 0) catch return error.LimitExceeded;
            string.* = self.api.CFStringCreateWithCString(null, terminated, utf8) orelse return error.WatchUnavailable;
        }
        const array = self.api.CFArrayCreate(null, &strings, @intCast(targets.trees.len), null) orelse return error.WatchUnavailable;
        const context: Context = .{ .info = self };
        const stream = self.api.FSEventStreamCreate(null, &changed, &context, array, .since_now, latency, .{ .file_events = true, .watch_root = true }) orelse return error.WatchUnavailable;
        self.api.FSEventStreamSetDispatchQueue(stream, self.queue);
        if (!self.api.FSEventStreamStart(stream)) return error.WatchUnavailable;
    }

    /// Returns once a relevant change has been reported, taking every report that came with it.
    pub fn wait(self: *FsEvents) Error!void {
        const waited = dispatch.semaphore_wait(self.semaphore, .FOREVER);
        if (waited != 0) assert.panic("waiting forever on the watch semaphore returned {d}; fix the dispatch timeout or handle its error", .{waited});
        var drained: usize = 0;
        for (0..max_waits) |_| {
            if (dispatch.semaphore_wait(self.semaphore, .NOW) != 0) break;
            drained += 1;
        }
        if (drained == max_waits) assert.panic("took {d} change reports at once; raise max_waits or coalesce them in changed()", .{drained});
    }

    fn changed(_: StreamRef, info: ?*anyopaque, count: usize, paths: *anyopaque, flags: [*]const EventFlags, _: [*]const EventId) callconv(.c) void {
        const self: *FsEvents = @ptrCast(@alignCast(info orelse assert.panic("FSEvents reported {d} changes with no context; initWatcher() passes the watcher as the stream's info", .{count})));
        if (count == 0) assert.panic("FSEvents called back with no changes; ignore empty callbacks or fix the stream flags", .{});
        if (count > max_batch) assert.panic("FSEvents reported {d} changes in one batch; raise max_batch or request a rescan past {d}", .{ count, max_batch });
        const names: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths));
        for (names[0..count], flags[0..count]) |name, flag| {
            if (flag.history_done) continue;
            if (!flag.must_scan_sub_dirs and !self.scope.relevant(std.mem.span(name))) continue;
            _ = dispatch.semaphore_signal(self.semaphore);
            return;
        }
    }
};

/// inotify: a watch on each directory the walk entered, and on each directory made since.
const Inotify = struct {
    fd: i32,
    scope: *const ChangeFilter,
    watched: memory.Bounded(Watched),
    text: memory.Text,
    buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)),

    const linux = std.os.linux;
    const Watched = struct { wd: i32, path: []const u8 };
    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE | linux.IN.ONLYDIR;
    /// Directories one session can watch, and the bytes of the paths of those made since it began.
    const max_directories = 1 << 16;
    const path_bytes = 1 << 24;

    pub fn initWatcher(self: *Inotify, gpa: std.mem.Allocator, _: Io, targets: Targets) Error!void {
        if (targets.directories.len == 0) assert.panic("watching no directories; collect() records every directory it enters", .{});
        if (targets.directories.len < targets.trees.len) assert.panic("{d} watched trees but the walk entered only {d} directories; every tree is a directory the walk started from", .{ targets.trees.len, targets.directories.len });
        const rc = linux.inotify_init1(linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.WatchUnavailable;
        self.fd = @intCast(rc);
        self.scope = targets.scope;
        self.watched = memory.Bounded(Watched).initBounded(gpa, max_directories, "watched directories") catch return error.LimitExceeded;
        self.text = memory.Text.initText(gpa, path_bytes) catch return error.LimitExceeded;
        for (targets.directories) |directory| try self.watch(directory);
    }

    fn watch(self: *Inotify, directory: []const u8) Error!void {
        if (directory.len == 0) assert.panic("watching a directory with an empty path; pass the absolute path the walk found", .{});
        if (self.fd < 0) assert.panic("adding a watch on '{s}' to inotify descriptor {d}; initWatcher() must open it first", .{ directory, self.fd });
        var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        const terminated = std.fmt.bufPrintSentinel(&buffer, "{s}", .{directory}, 0) catch return error.LimitExceeded;
        const rc = linux.inotify_add_watch(self.fd, terminated, mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOSPC => return error.TooManyWatches,
            .NOENT, .NOTDIR => return,
            else => return error.WatchUnavailable,
        }
        try self.watched.add(.{ .wd = @intCast(rc), .path = directory });
    }

    fn directoryOf(self: *const Inotify, wd: i32) ?[]const u8 {
        if (wd < 0) assert.panic("inotify reported watch {d}; it numbers watches from 1", .{wd});
        if (self.watched.len == 0) assert.panic("looking up watch {d} with no directories watched; initWatcher() watches at least the roots", .{wd});
        for (self.watched.items()) |w| if (w.wd == wd) return w.path;
        return null;
    }

    /// Returns once a relevant change has been read, watching each new directory on the way.
    pub fn wait(self: *Inotify) Error!void {
        if (self.fd < 0) assert.panic("waiting on inotify descriptor {d}; initWatcher() must open it first", .{self.fd});
        if (self.watched.len == 0) assert.panic("waiting with no directories watched; initWatcher() watches at least the roots", .{});
        for (0..max_waits) |_| {
            const rc = linux.read(self.fd, &self.buffer, self.buffer.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.WatchUnavailable,
            }
            if (try self.anyRelevant(self.buffer[0..rc])) return;
        }
        assert.panic("read {d} batches of changes without one worth a rerun", .{max_waits});
    }

    fn anyRelevant(self: *Inotify, events: []const u8) Error!bool {
        if (events.len < @sizeOf(linux.inotify_event)) assert.panic("read {d} bytes of events, less than one event of {d}; read() returns whole events", .{ events.len, @sizeOf(linux.inotify_event) });
        var relevant = false;
        var offset: usize = 0;
        for (0..events.len) |_| {
            if (offset + @sizeOf(linux.inotify_event) > events.len) break;
            const event: *const linux.inotify_event = @ptrCast(@alignCast(events[offset..].ptr));
            offset += @sizeOf(linux.inotify_event) + event.len;
            if (event.mask & linux.IN.Q_OVERFLOW != 0) relevant = true;
            const name = event.getName() orelse continue;
            const directory = self.directoryOf(event.wd) orelse continue;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ directory, name }) catch continue;
            if (event.mask & linux.IN.ISDIR != 0) {
                const made = event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
                if (made and !project.skippedDir(name) and !self.scope.ignore.ignored(path, .directory)) try self.watch(try self.text.copy(path));
                continue;
            }
            if (event.mask & linux.IN.CREATE != 0) continue;
            relevant = relevant or self.scope.relevant(path);
        }
        if (offset > events.len) assert.panic("read past the {d} bytes of events to {d}; the kernel writes whole events", .{ events.len, offset });
        return relevant;
    }
};

/// NtNotifyChangeDirectoryFileEx over the one directory every path lies in, with its whole tree.
const DirectoryNotify = struct {
    handle: windows.HANDLE,
    root: []const u8,
    scope: *const ChangeFilter,
    buffer: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.INFORMATION)),

    const windows = std.os.windows;

    pub fn initWatcher(self: *DirectoryNotify, _: std.mem.Allocator, io: Io, targets: Targets) Error!void {
        if (targets.trees.len == 0) assert.panic("watching no directories; pass the paths check was given", .{});
        if (targets.directories.len < targets.trees.len) assert.panic("{d} watched trees but the walk entered only {d} directories; every tree is a directory the walk started from", .{ targets.trees.len, targets.directories.len });
        self.root = commonDirectory(targets.trees);
        self.scope = targets.scope;
        const directory = Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return error.WatchUnavailable;
        self.handle = directory.handle;
    }

    /// Returns once a relevant change has been reported, or the system lost track of them.
    pub fn wait(self: *DirectoryNotify) Error!void {
        if (self.root.len == 0) assert.panic("waiting on a directory with an empty path; initWatcher() sets it", .{});
        if (self.scope.roots.len == 0) assert.panic("waiting under {s} with a filter that has no roots", .{self.root});
        for (0..max_waits) |_| {
            var status_block: windows.IO_STATUS_BLOCK = undefined;
            var status = windows.ntdll.NtNotifyChangeDirectoryFileEx(self.handle, null, null, null, &status_block, &self.buffer, self.buffer.len, .{ .FILE_NAME = true, .DIR_NAME = true, .SIZE = true, .LAST_WRITE = true, .CREATION = true }, .TRUE, .Notify);
            if (status == .PENDING) {
                _ = windows.ntdll.NtWaitForSingleObject(self.handle, .FALSE, null);
                status = status_block.u.Status;
            }
            switch (status) {
                .SUCCESS => {},
                .NOTIFY_ENUM_DIR => return,
                else => return error.WatchUnavailable,
            }
            if (status_block.Information == 0 or self.anyRelevant(self.buffer[0..status_block.Information])) return;
        }
        assert.panic("read {d} batches of changes without one worth a rerun", .{max_waits});
    }

    fn anyRelevant(self: *DirectoryNotify, records: []u8) bool {
        if (records.len < @sizeOf(windows.FILE.NOTIFY.INFORMATION)) assert.panic("read {d} bytes of changes, less than one record; the system writes whole records", .{records.len});
        if (records.len > self.buffer.len) assert.panic("{d} bytes of changes in a buffer of {d}", .{ records.len, self.buffer.len });
        var offset: usize = 0;
        for (0..records.len) |_| {
            if (offset + @sizeOf(windows.FILE.NOTIFY.INFORMATION) > records.len) break;
            const record: *windows.FILE.NOTIFY.INFORMATION = @ptrCast(@alignCast(records[offset..].ptr));
            var name: [std.fs.max_path_bytes]u8 = undefined;
            const length = std.unicode.wtf16LeToWtf8(&name, record.fileName());
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&buffer, "{s}\\{s}", .{ self.root, name[0..length] }) catch return true;
            if (self.scope.relevant(path)) return true;
            if (record.NextEntryOffset == 0) break;
            offset += record.NextEntryOffset;
        }
        return false;
    }
};

test "a rerun keeps every option but --watch, and asks for agent output" {
    var out: [8][]const u8 = undefined;
    const argv = rerunArgs(&out, "/bin/zanity", &.{ "check", "src", "--watch", "--strict", "--watch=true" });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/bin/zanity", "check", "src", "--strict", "--agent" }), argv);
}

test "a rerun keeps the output the command line chose" {
    var out: [8][]const u8 = undefined;
    const argv = rerunArgs(&out, "/bin/zanity", &.{ "check", "--watch", "--json" });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/bin/zanity", "check", "--json" }), argv);
}

test "a resident watch defaults to agent output unless the command chooses otherwise" {
    try std.testing.expect(agentOutput(&.{ "check", ".", "--watch" }, false, false));
    try std.testing.expect(!agentOutput(&.{ "check", ".", "--watch", "--agent=false" }, false, true));
    try std.testing.expect(!agentOutput(&.{ "check", ".", "--watch", "--json" }, true, false));
}

test "resident watch rows use zcli's JSON and plain formats" {
    const TestRow = struct { path: []const u8, line: u32, column: u32, severity: []const u8, rule: []const u8, message: []const u8, fix: []const u8, edit_start: ?u32, edit_end: ?u32, edit_text: ?[]const u8 };
    const rows = [_]TestRow{.{ .path = "a.py", .line = 2, .column = 3, .severity = "warning", .rule = "example", .message = "found", .fix = "fix it", .edit_start = null, .edit_end = null, .edit_text = null }};
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderRows(TestRow, &out, true, &rows);
    try std.testing.expectEqualStrings("[{\"path\":\"a.py\",\"line\":2,\"column\":3,\"severity\":\"warning\",\"rule\":\"example\",\"message\":\"found\",\"fix\":\"fix it\",\"edit_start\":null,\"edit_end\":null,\"edit_text\":null}]\n", out.buffered());
    out = .fixed(&buffer);
    try renderRows(TestRow, &out, false, &rows);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "path=\"a.py\"\tline=2\tcolumn=3\tseverity=\"warning\""));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "\tedit_start=null\tedit_end=null\tedit_text=null\n"));
}

test "only files check reads, outside skipped and ignored directories, are worth a rerun" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ignore = try Ignore.initIgnore(arena_state.allocator(), .{ .ignore_patterns = 8, .ignore_bytes = 1024 });
    try ignore.exclude("/repo", "vendor/");
    const scope: ChangeFilter = .{ .roots = &.{"/repo"}, .ignore = &ignore };
    try std.testing.expect(scope.relevant("/repo/src/app.py"));
    try std.testing.expect(scope.relevant("/repo/zanity.toml"));
    try std.testing.expect(!scope.relevant("/repo/notes.txt"));
    try std.testing.expect(!scope.relevant("/repo/.zig-cache/o/app.py"));
    try std.testing.expect(!scope.relevant("/repo/node_modules/x/index.ts"));
    try std.testing.expect(!scope.relevant("/repo/vendor/lib.py"));
    try std.testing.expect(!scope.relevant("/repository/app.py"));
}

test "the shared directory of several paths is their deepest common ancestor" {
    try std.testing.expectEqualStrings("/repo", commonDirectory(&.{ "/repo/src", "/repo/tests" }));
    try std.testing.expectEqualStrings("/repo/src", commonDirectory(&.{"/repo/src"}));
    try std.testing.expectEqualStrings("/", commonDirectory(&.{ "/a", "/b" }));
}

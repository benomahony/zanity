//! cyclic-import: files that import each other, directly or through other files, found from
//! each file's top-level imports and reported once per cycle, at the import that uses the fewest
//! names, since that is the cheapest one to remove.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const language = @import("language.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Import = facts_module.Import;
const graph = @import("graph.zig");

/// Files a finding names before saying how many more the cycle holds.
const max_listed = 6;
/// Directories a dotted import is looked up from, climbing from the importing file's.
const max_roots = 16;
/// The longest file path an import resolves to.
const max_path = std.fs.max_path_bytes;
/// Marks a file in no cycle, or a cycle with no cheapest import chosen yet.
const unseen = std.math.maxInt(u32);

/// An import from file `from` of file `to`, by its index in Facts.imports.
const Edge = struct {
    from: u32,
    to: u32,
    import: u32,

    /// Whether `a` sorts before `b`: by importing file, then by import.
    fn before(_: void, a: Edge, b: Edge) bool {
        if (a.from == a.to) assert.panic("ordering import {d}, of file {d} by itself; edgesOf() leaves those out", .{ a.import, a.from });
        if (b.from == b.to) assert.panic("ordering import {d}, of file {d} by itself; edgesOf() leaves those out", .{ b.import, b.from });
        if (a.from != b.from) return a.from < b.from;
        return a.import < b.import;
    }
};

/// Memory cyclic-import runs in, reserved up front for the most files and imports a run holds.
pub const ImportScratch = struct {
    files: [][]const u8,
    edges: []Edge,
    first_edge: []u32,
    targets: []u32,
    cycle_of: []u32,
    cheapest: []u32,
    search: graph.CycleSearch,

    pub fn initImportScratch(gpa: std.mem.Allocator, limits: memory.Limits) std.mem.Allocator.Error!ImportScratch {
        if (limits.files == 0 or limits.imports == 0) assert.panic("memory.Limits allows {d} files and {d} imports; cyclic-import needs room for both", .{ limits.files, limits.imports });
        const files = limits.files;
        const scratch: ImportScratch = .{
            .files = try memory.reserveUninitialized(gpa, []const u8, files),
            .edges = try memory.reserveUninitialized(gpa, Edge, limits.imports),
            .first_edge = try memory.reserveUninitialized(gpa, u32, @as(usize, files) + 1),
            .targets = try memory.reserveUninitialized(gpa, u32, limits.imports),
            .cycle_of = try memory.reserveUninitialized(gpa, u32, files),
            .cheapest = try memory.reserveUninitialized(gpa, u32, files),
            .search = try .initCycleSearch(gpa, files, "importing files"),
        };
        if (scratch.targets.len != scratch.edges.len) assert.panic("reserved {d} targets for {d} edges", .{ scratch.targets.len, scratch.edges.len });
        return scratch;
    }
};

/// A cycle's cheapest import to remove: its edge, and which cycle it is and how many files it holds.
const Cheapest = struct { edge: Edge, cycle: u32, size: u32 };

/// The importing files, sorted, and the cycle each is in, or `unseen` for none, side by side.
const Membership = struct { files: []const []const u8, cycle_of: []const u32 };

/// Reports each cycle of files that import one another.
pub fn checkCycles(facts: *Facts, findings: *memory.Bounded(Finding), scratch: *ImportScratch) error{LimitExceeded}!void {
    if (facts.imports.capacity() > scratch.edges.len) assert.panic("Facts holds up to {d} imports but the search has room for {d} edges; reserve both from memory.Limits.imports", .{ facts.imports.capacity(), scratch.edges.len });
    const before = findings.len;
    const imports = facts.imports.items();
    const files = try filesOf(facts, imports, scratch);
    const edges = try edgesOf(imports, files, scratch);
    const targets = scratch.targets[0..edges.len];
    for (edges, targets) |e, *t| t.* = e.to;
    const imported: graph.Graph = .{ .offsets = scratch.first_edge[0 .. files.len + 1], .targets = targets };
    const cycles = try imported.cycles(&scratch.search);
    const cycle_of = scratch.cycle_of[0..files.len];
    @memset(cycle_of, unseen);
    for (cycles, 0..) |c, i| for (c.members) |m| {
        cycle_of[m] = @intCast(i);
    };
    const cheapest = scratch.cheapest[0..cycles.len];
    @memset(cheapest, unseen);
    for (edges, 0..) |e, i| {
        const c = cycle_of[e.from];
        if (c == unseen or cycle_of[e.to] != c) continue;
        const best = &cheapest[c];
        if (best.* == unseen or cheaper(imports, e, edges[best.*])) best.* = @intCast(i);
    }
    for (cycles, cheapest, 0..) |c, edge, i| {
        if (edge == unseen) assert.panic("cycle {d} of {d} files has no import inside it; edgesOf() leaves out only imports of a file by itself", .{ i, c.members.len });
        try report(facts, findings, .{ .files = files, .cycle_of = cycle_of }, .{ .edge = edges[edge], .cycle = @intCast(i), .size = @intCast(c.members.len) });
    }
    if (findings.len - before > cycles.len) assert.panic("cyclic-import reported {d} findings for {d} cycles; it reports each cycle once", .{ findings.len - before, cycles.len });
}

/// The distinct files that import anything, normalised and sorted, into `scratch.files`.
fn filesOf(facts: *Facts, imports: []const Import, scratch: *ImportScratch) error{LimitExceeded}![]const []const u8 {
    var count: usize = 0;
    var buffer: [max_path]u8 = undefined;
    for (imports, 0..) |imp, i| {
        if (i > 0 and std.mem.eql(u8, imp.path, imports[i - 1].path)) continue;
        const clean = normalise(imp.path, &buffer) orelse continue;
        if (count == scratch.files.len) return error.LimitExceeded;
        scratch.files[count] = try facts.text.copy(clean);
        count += 1;
    }
    const files = scratch.files[0..count];
    std.mem.sort([]const u8, files, {}, lessThan);
    var kept: usize = 0;
    for (files) |f| {
        if (kept > 0 and std.mem.eql(u8, files[kept - 1], f)) continue;
        files[kept] = f;
        kept += 1;
    }
    if (kept > imports.len) assert.panic("found {d} importing files among {d} imports", .{ kept, imports.len });
    if (kept > 1 and !lessThan({}, files[0], files[kept - 1])) assert.panic("the {d} importing files run from '{s}' to '{s}', out of order; find() needs them sorted", .{ kept, files[0], files[kept - 1] });
    return files[0..kept];
}

/// Each import that names another checked file, sorted by importing file, into `scratch.edges`,
/// with `scratch.first_edge[f]` where file `f`'s edges start.
fn edgesOf(imports: []const Import, files: []const []const u8, scratch: *ImportScratch) error{LimitExceeded}![]Edge {
    if (files.len >= scratch.first_edge.len) assert.panic("{d} files with room to mark where {d} start their edges; reserve one more than the files", .{ files.len, scratch.first_edge.len });
    var count: usize = 0;
    var buffer: [max_path]u8 = undefined;
    for (imports, 0..) |imp, i| {
        const from = find(files, normalise(imp.path, &buffer) orelse continue) orelse continue;
        const to = resolve(files, imp) orelse continue;
        if (to == from) continue;
        if (count == scratch.edges.len) return error.LimitExceeded;
        scratch.edges[count] = .{ .from = from, .to = to, .import = @intCast(i) };
        count += 1;
    }
    const edges = scratch.edges[0..count];
    std.mem.sort(Edge, edges, {}, Edge.before);
    var at: usize = 0;
    for (0..files.len + 1) |f| {
        while (at < edges.len and edges[at].from < f) at += 1;
        scratch.first_edge[f] = @intCast(at);
    }
    if (scratch.first_edge[files.len] != edges.len) assert.panic("the {d} edges were not all placed among {d} files", .{ edges.len, files.len });
    return edges;
}

/// Whether removing import `a` costs less than removing `b`: it uses fewer names, or as many
/// and comes first by file and line, so the choice is the same on every run.
fn cheaper(imports: []const Import, a: Edge, b: Edge) bool {
    if (a.import == b.import) assert.panic("comparing import {d} with itself; each import makes at most one edge", .{a.import});
    const x = imports[a.import];
    const y = imports[b.import];
    if (x.path.len == 0 or y.path.len == 0) assert.panic("comparing imports with no file; every import records the file making it", .{});
    if (x.names != y.names) return x.names < y.names;
    const by_path = std.mem.order(u8, x.path, y.path);
    if (by_path != .eq) return by_path == .lt;
    return x.line < y.line;
}

/// The checked file `imp` names, by the importing language's rules, or null when it names a
/// package, a file outside the project, or no file zanity checked.
fn resolve(files: []const []const u8, imp: Import) ?u32 {
    const adapter = language.named(imp.language) orelse assert.panic("{s}: an import was recorded in language '{s}', which zanity doesn't know", .{ imp.path, imp.language });
    if (imp.spec.len == 0) assert.panic("{s}:{d}: an import with an empty module; flush() skips those", .{ imp.path, imp.line + 1 });
    const dir = std.fs.path.dirname(imp.path) orelse "";
    const found = switch (adapter.tables.import_style) {
        .none => null,
        .relative => resolveRelative(files, dir, imp.spec, adapter.tables),
        .dotted => resolveDotted(files, dir, imp.spec, adapter.tables.import_suffixes),
    };
    if (found) |f| if (f >= files.len) assert.panic("{s}: '{s}' resolved to file {d} of {d}", .{ imp.path, imp.spec, f, files.len });
    return found;
}

/// The checked file `spec` names as a path from `dir`, the importing file's directory, trying
/// each of the language's suffixes after it, then after it without an ending it may be written
/// with in place of the file's own.
fn resolveRelative(files: []const []const u8, dir: []const u8, spec: []const u8, tables: *const language.Tables) ?u32 {
    const suffixes = tables.import_suffixes;
    if (suffixes.len == 0) assert.panic("resolving '{s}' with no suffixes; list at least \"\" under import_suffixes", .{spec});
    if (spec.len == 0) assert.panic("resolving an empty module from '{s}'; resolve() rejects those", .{dir});
    if (under(files, dir, spec, suffixes)) |found| return found;
    for (tables.import_stripped_endings) |ending| {
        if (spec.len > ending.len and std.mem.endsWith(u8, spec, ending)) return under(files, dir, spec[0 .. spec.len - ending.len], suffixes);
    }
    return null;
}

/// The checked file the dotted `spec` names: from `dir` up for each leading dot past the first,
/// or, with none, from the first of `dir` and its parents that holds it.
fn resolveDotted(files: []const []const u8, dir: []const u8, spec: []const u8, suffixes: []const []const u8) ?u32 {
    if (suffixes.len == 0) assert.panic("resolving '{s}' with no suffixes; list the file endings under import_suffixes", .{spec});
    const dots = std.mem.indexOfNone(u8, spec, ".") orelse spec.len;
    if (spec.len - dots > max_path) return null;
    var name_buffer: [max_path]u8 = undefined;
    const name = name_buffer[0 .. spec.len - dots];
    for (spec[dots..], 0..) |c, i| name[i] = if (c == '.') '/' else c;
    var root: []const u8 = dir;
    for (0..max_roots) |depth| {
        if (dots == 0 or depth + 1 >= dots) if (under(files, root, name, suffixes)) |found| return found;
        if (dots > 0 and depth + 1 >= dots) return null;
        if (root.len == 0) return null;
        root = std.fs.path.dirname(root) orelse "";
    }
    if (dots > max_roots) assert.panic("'{s}' climbs {d} directories, past the {d} looked through", .{ spec, dots, max_roots });
    return null;
}

/// The first checked file at `name` under `root` with one of `suffixes` after it.
fn under(files: []const []const u8, root: []const u8, name: []const u8, suffixes: []const []const u8) ?u32 {
    if (suffixes.len == 0) assert.panic("looking for '{s}' under '{s}' with no suffixes to try", .{ name, root });
    var joined: [max_path]u8 = undefined;
    var clean: [max_path]u8 = undefined;
    for (suffixes) |suffix| {
        const path = std.fmt.bufPrint(&joined, "{s}/{s}{s}", .{ root, name, suffix }) catch return null;
        const found = find(files, normalise(path, &clean) orelse continue) orelse continue;
        if (!std.mem.endsWith(u8, files[found], suffix)) assert.panic("'{s}' under '{s}' was found as '{s}', which doesn't end in '{s}'", .{ name, root, files[found], suffix });
        return found;
    }
    return null;
}

/// `path` without empty, `.` or `..` parts, into `buffer`; null when it climbs above its root.
fn normalise(path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    if (path.len == 0) assert.panic("normalising an empty path; pass a file's path or a directory joined to a module", .{});
    if (path.len > buffer.len) return null;
    var len: usize = 0;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (len == 0) return null;
            len = std.mem.lastIndexOfScalar(u8, buffer[0..len], '/') orelse 0;
            continue;
        }
        if (len > 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len..][0..part.len], part);
        len += part.len;
    }
    if (len > path.len) assert.panic("normalised '{s}' into {d} bytes, more than it had", .{ path, len });
    return buffer[0..len];
}

/// Where `path` sits in the sorted `files`, if it does.
fn find(files: []const []const u8, path: []const u8) ?u32 {
    if (files.len > 1 and !lessThan({}, files[0], files[files.len - 1])) assert.panic("searching {d} files that run from '{s}' to '{s}', out of order; filesOf() sorts them", .{ files.len, files[0], files[files.len - 1] });
    var low: usize = 0;
    var high: usize = files.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, files[middle], path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @intCast(middle),
        }
    }
    if (low > files.len) assert.panic("searched {d} files and landed at {d}, past the end", .{ files.len, low });
    return null;
}

/// Whether path `a` sorts before path `b`, byte by byte.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) assert.panic("ordering an empty path against '{s}'; filesOf() keeps only normalised file paths", .{b});
    if (b.len == 0) assert.panic("ordering '{s}' against an empty path; filesOf() keeps only normalised file paths", .{a});
    return std.mem.order(u8, a, b) == .lt;
}

/// Reports `cycle` at its cheapest import, naming the files `membership` puts in it.
fn report(facts: *Facts, findings: *memory.Bounded(Finding), membership: Membership, cycle: Cheapest) error{LimitExceeded}!void {
    if (cycle.size < 2) assert.panic("reporting a cycle of {d} file; a cycle needs two or more", .{cycle.size});
    if (membership.files.len != membership.cycle_of.len) assert.panic("{d} files with cycles noted for {d}; checkCycles() notes one per file", .{ membership.files.len, membership.cycle_of.len });
    const files = membership.files;
    const cycle_of = membership.cycle_of;
    const edge = cycle.edge;
    if (cycle_of[edge.from] != cycle.cycle or cycle_of[edge.to] != cycle.cycle) assert.panic("reporting cycle {d} at an import from cycle {d} to {d}; checkCycles() picks an import inside the cycle", .{ cycle.cycle, cycle_of[edge.from], cycle_of[edge.to] });
    var listed: [max_listed][]const u8 = undefined;
    var count: usize = 0;
    for (cycle_of, 0..) |c, f| {
        if (c != cycle.cycle or count == max_listed) continue;
        listed[count] = files[f];
        count += 1;
    }
    const imp = facts.imports.items()[edge.import];
    const text = facts.text;
    const members = Members{ .names = listed[0..count], .more = cycle.size - @as(u32, @intCast(count)) };
    const from = files[edge.from];
    const target = files[edge.to];
    const message = if (imp.names == 0)
        try text.format("{d} files import each other in a cycle ({f}), so none can be read, tested or changed without the others. This import of '{s}' uses no name from it, the fewest of any import in the cycle, so it is the cheapest to remove.", .{ cycle.size, members, target })
    else
        try text.format("{d} files import each other in a cycle ({f}), so none can be read, tested or changed without the others. This import of '{s}' uses only {d} name{s} from it ({s}), the fewest of any import in the cycle, so it is the cheapest to remove.", .{ cycle.size, members, target, imp.names, if (imp.names == 1) "" else "s", imp.shown });
    const fix = if (imp.names == 0)
        try text.format("Remove this import of '{s}'; nothing in '{s}' uses it.", .{ target, from })
    else
        try text.format("Move {s} out of '{s}' into a file neither imports, or into '{s}', and import it from there, so '{s}' no longer imports '{s}'.", .{ imp.shown, target, from, from, target });
    try findings.add(.{ .path = imp.path, .line = imp.line, .column = imp.column, .rule = "cyclic-import", .message = message, .fix = fix });
}

/// The files of a cycle a finding lists, and how many more it holds.
const Members = struct {
    names: []const []const u8,
    more: u32,

    pub fn format(self: Members, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.names.len < 2 and self.more == 0) assert.panic("listing a cycle of {d} file; a cycle holds two or more", .{self.names.len});
        if (self.names.len > max_listed) assert.panic("listing {d} files of a cycle, past the {d} a finding names", .{ self.names.len, max_listed });
        for (self.names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
        if (self.more > 0) try writer.print(" and {d} more", .{self.more});
    }
};

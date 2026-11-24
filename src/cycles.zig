//! cyclic-import: files that import each other, directly or through other files, found from
//! each file's top-level imports and reported once per cycle, at the import that uses the fewest
//! names, since that is the cheapest one to remove.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Import = facts_module.Import;
const graph = @import("graph.zig");
const import_paths = @import("import_paths.zig");
const normalise = import_paths.normalisePath;
const find = import_paths.findFile;
const lessThan = import_paths.pathBefore;
const resolve = import_paths.resolve;

/// Files a finding names before saying how many more the cycle holds.
const max_listed = 6;
/// The longest file path an import resolves to.
const max_path = import_paths.max_path;
/// Marks a file in no cycle, or a cycle with no cheapest import chosen yet.
const unseen = std.math.maxInt(u32);

/// An import from file `from` of file `to`, by its index in Facts.imports.
pub const ImportEdge = struct {
    from: u32,
    to: u32,
    import: u32,

    /// Whether `a` sorts before `b`: by importing file, then imported file, then import, so every
    /// import of one file by another sits together.
    fn before(_: void, a: ImportEdge, b: ImportEdge) bool {
        if (a.from == a.to) assert.panic("ordering import {d}, of file {d} by itself; edgesOf() leaves those out", .{ a.import, a.from });
        if (b.from == b.to) assert.panic("ordering import {d}, of file {d} by itself; edgesOf() leaves those out", .{ b.import, b.from });
        if (a.from != b.from) return a.from < b.from;
        if (a.to != b.to) return a.to < b.to;
        return a.import < b.import;
    }

    /// Whether `a` and `b` are imports of the same file by the same file.
    fn sameFiles(a: ImportEdge, b: ImportEdge) bool {
        if (a.from == a.to) assert.panic("comparing import {d}, of file {d} by itself; edgesOf() leaves those out", .{ a.import, a.from });
        if (b.from == b.to) assert.panic("comparing import {d}, of file {d} by itself; edgesOf() leaves those out", .{ b.import, b.from });
        return a.from == b.from and a.to == b.to;
    }
};

/// Every import one file makes of another, as a run of the sorted edges, and how many names they
/// use from it between them: removing all of them is what breaks the dependency.
const Dependency = struct {
    edges: []const ImportEdge,
    names: u32,

    /// The run of edges from `edges[first]` that import the same file by the same file.
    fn at(edges: []const ImportEdge, imports: []const Import, first: usize) Dependency {
        if (first >= edges.len) assert.panic("asked for the dependency at edge {d} of {d}", .{ first, edges.len });
        var end = first + 1;
        var names: u32 = imports[edges[first].import].names;
        for (edges[first + 1 ..]) |e| {
            if (!ImportEdge.sameFiles(e, edges[first])) break;
            names += imports[e.import].names;
            end += 1;
        }
        if (end - first > imports.len) assert.panic("a dependency of {d} imports among {d}", .{ end - first, imports.len });
        return .{ .edges = edges[first..end], .names = names };
    }
};

/// Memory cyclic-import runs in, reserved up front for the most files and imports a run holds.
pub const ImportScratch = struct {
    files: [][]const u8,
    edges: []ImportEdge,
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
            .edges = try memory.reserveUninitialized(gpa, ImportEdge, limits.imports),
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

/// A cycle's cheapest dependency to remove, and which cycle it is and how many files it holds.
const Cheapest = struct { dependency: Dependency, cycle: u32, size: u32 };

/// The importing files, sorted, and the cycle each is in, or `unseen` for none, side by side.
const Membership = struct { files: []const []const u8, cycle_of: []const u32 };

/// The checked files, normalised and sorted, and each import of one by another, sorted by
/// importing file: what cyclic-import and context-leak read.
pub const ImportGraph = struct { files: []const []const u8, edges: []const ImportEdge };

/// Resolves every import in `facts` to the file among `checked` it names.
pub fn importGraph(facts: *Facts, checked: []const []const u8, scratch: *ImportScratch) error{LimitExceeded}!ImportGraph {
    if (facts.imports.capacity() > scratch.edges.len) assert.panic("Facts holds up to {d} imports but the search has room for {d} edges; reserve both from memory.Limits.imports", .{ facts.imports.capacity(), scratch.edges.len });
    const imports = facts.imports.items();
    const files = try filesOf(facts, checked, scratch);
    const edges = try edgesOf(imports, files, scratch);
    if (edges.len > imports.len) assert.panic("{d} edges from {d} imports; each import makes at most one", .{ edges.len, imports.len });
    return .{ .files = files, .edges = edges };
}

/// Reports each cycle of files that import one another.
pub fn checkCycles(facts: *Facts, findings: *memory.Bounded(Finding), scratch: *ImportScratch, built: ImportGraph) error{LimitExceeded}!void {
    if (built.edges.len > scratch.targets.len) assert.panic("{d} edges in room for {d} targets; importGraph() fills the same scratch", .{ built.edges.len, scratch.targets.len });
    const before = findings.len;
    const imports = facts.imports.items();
    const files = built.files;
    const edges = built.edges;
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
        if (i > 0 and ImportEdge.sameFiles(edges[i - 1], e)) continue;
        const c = cycle_of[e.from];
        if (c == unseen or cycle_of[e.to] != c) continue;
        const best = &cheapest[c];
        if (best.* == unseen or cheaper(imports, Dependency.at(edges, imports, i), Dependency.at(edges, imports, best.*))) best.* = @intCast(i);
    }
    for (cycles, cheapest, 0..) |c, first, i| {
        if (first == unseen) assert.panic("cycle {d} of {d} files has no import inside it; edgesOf() leaves out only imports of a file by itself", .{ i, c.members.len });
        try report(facts, findings, .{ .files = files, .cycle_of = cycle_of }, .{ .dependency = Dependency.at(edges, imports, first), .cycle = @intCast(i), .size = @intCast(c.members.len) });
    }
    if (findings.len - before > cycles.len) assert.panic("cyclic-import reported {d} findings for {d} cycles; it reports each cycle once", .{ findings.len - before, cycles.len });
}

/// The distinct checked files, normalised and sorted, into `scratch.files`.
fn filesOf(facts: *Facts, checked: []const []const u8, scratch: *ImportScratch) error{LimitExceeded}![]const []const u8 {
    var count: usize = 0;
    var buffer: [max_path]u8 = undefined;
    for (checked) |path| {
        const clean = normalise(path, &buffer) orelse continue;
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
    if (kept > checked.len) assert.panic("found {d} files among {d} checked", .{ kept, checked.len });
    if (kept > 1 and !lessThan({}, files[0], files[kept - 1])) assert.panic("the {d} checked files run from '{s}' to '{s}', out of order; find() needs them sorted", .{ kept, files[0], files[kept - 1] });
    return files[0..kept];
}

/// Each import that names another checked file, sorted by importing file, into `scratch.edges`,
/// with `scratch.first_edge[f]` where file `f`'s edges start.
fn edgesOf(imports: []const Import, files: []const []const u8, scratch: *ImportScratch) error{LimitExceeded}![]ImportEdge {
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
    std.mem.sort(ImportEdge, edges, {}, ImportEdge.before);
    var at: usize = 0;
    for (0..files.len + 1) |f| {
        while (at < edges.len and edges[at].from < f) at += 1;
        scratch.first_edge[f] = @intCast(at);
    }
    if (scratch.first_edge[files.len] != edges.len) assert.panic("the {d} edges were not all placed among {d} files", .{ edges.len, files.len });
    return edges;
}

/// Whether removing dependency `a` costs less than removing `b`: its imports use fewer names, or
/// as many and its first comes first by file and line, so the choice is the same on every run.
fn cheaper(imports: []const Import, a: Dependency, b: Dependency) bool {
    if (a.edges.ptr == b.edges.ptr) assert.panic("comparing the dependency at import {d} with itself; checkCycles() compares each with the best so far", .{a.edges[0].import});
    const x = imports[a.edges[0].import];
    const y = imports[b.edges[0].import];
    if (x.path.len == 0 or y.path.len == 0) assert.panic("comparing imports with no file; every import records the file making it", .{});
    if (a.names != b.names) return a.names < b.names;
    const by_path = std.mem.order(u8, x.path, y.path);
    if (by_path != .eq) return by_path == .lt;
    return x.line < y.line;
}

/// Reports `cycle` at its cheapest import, naming the files `membership` puts in it.
fn report(facts: *Facts, findings: *memory.Bounded(Finding), membership: Membership, cycle: Cheapest) error{LimitExceeded}!void {
    if (cycle.size < 2) assert.panic("reporting a cycle of {d} file; a cycle needs two or more", .{cycle.size});
    if (membership.files.len != membership.cycle_of.len) assert.panic("{d} files with cycles noted for {d}; checkCycles() notes one per file", .{ membership.files.len, membership.cycle_of.len });
    const files = membership.files;
    const cycle_of = membership.cycle_of;
    const dependency = cycle.dependency;
    const edge = dependency.edges[0];
    if (cycle_of[edge.from] != cycle.cycle or cycle_of[edge.to] != cycle.cycle) assert.panic("reporting cycle {d} at an import from cycle {d} to {d}; checkCycles() picks an import inside the cycle", .{ cycle.cycle, cycle_of[edge.from], cycle_of[edge.to] });
    var listed: [max_listed][]const u8 = undefined;
    var count: usize = 0;
    for (cycle_of, 0..) |c, f| {
        if (c != cycle.cycle or count == max_listed) continue;
        listed[count] = files[f];
        count += 1;
    }
    const imports = facts.imports.items();
    const imp = imports[edge.import];
    const text = facts.text;
    const members = Members{ .names = listed[0..count], .more = cycle.size - @as(u32, @intCast(count)) };
    const from = files[edge.from];
    const target = files[edge.to];
    const shown = Shown{ .imports = imports, .edges = dependency.edges };
    const many = dependency.edges.len > 1;
    const subject = if (many) try text.format("These {d} imports of '{s}' use", .{ dependency.edges.len, target }) else try text.format("This import of '{s}' uses", .{target});
    const conclusion = if (many) "they are" else "it is";
    const names = dependency.names;
    const message = if (names == 0)
        try text.format("{d} files import each other in a cycle ({f}), so none can be read, tested or changed without the others. {s} no name from it, the fewest of any file's imports in the cycle, so {s} the cheapest to remove.", .{ cycle.size, members, subject, conclusion })
    else
        try text.format("{d} files import each other in a cycle ({f}), so none can be read, tested or changed without the others. {s} only {d} name{s} from it ({f}), the fewest of any file's imports in the cycle, so {s} the cheapest to remove.", .{ cycle.size, members, subject, names, if (names == 1) "" else "s", shown, conclusion });
    const fix = if (names == 0)
        try text.format("Remove {s} of '{s}'; nothing in '{s}' uses {s}.", .{ if (many) "these imports" else "this import", target, from, if (many) "them" else "it" })
    else
        try text.format("Move {f} out of '{s}' into a file neither imports, or into '{s}', and import {s} from there, so '{s}' no longer imports '{s}'.", .{ shown, target, from, if (names == 1) "it" else "them", from, target });
    try findings.add(.{ .path = imp.path, .line = imp.line, .column = imp.column, .rule = "cyclic-import", .message = message, .fix = fix });
}

/// The names a dependency's imports use, each import's as it quotes them, separated by ", ".
const Shown = struct {
    imports: []const Import,
    edges: []const ImportEdge,

    pub fn format(self: Shown, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.edges.len == 0) assert.panic("quoting the names of a dependency with no imports; Dependency.at() returns at least one", .{});
        if (self.edges.len > self.imports.len) assert.panic("quoting {d} imports among {d}", .{ self.edges.len, self.imports.len });
        var written: usize = 0;
        for (self.edges) |e| {
            const quoted = self.imports[e.import].shown;
            if (quoted.len == 0) continue;
            if (written > 0) try writer.writeAll(", ");
            try writer.writeAll(quoted);
            written += 1;
        }
    }
};

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

//! The rules that read which checked file imports which: cyclic-import, in cycles.zig, and
//! context-leak here, an import from one context of a file another context keeps to itself. A
//! context that lists `exports` in zanity.toml is reached from other contexts only through those.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const config = @import("config.zig");
const cycles = @import("cycles.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const rules = @import("rules.zig");
const language = @import("language.zig");
const Edit = facts_module.Edit;

/// Marks a context whose exported file has not been looked for yet.
const unsearched = std.math.maxInt(u32);
/// Marks a context none of whose checked files it exports.
const none = unsearched - 1;

/// What the import rules work in: memory for the graph, every checked file, and the zanity.toml
/// that declares the project's contexts, if any.
pub const Space = struct { space: *cycles.ImportScratch, files: []const []const u8, anchor: ?config.Anchor };

/// cyclic-import and context-leak, over one graph of which checked file imports which.
pub fn checkImports(facts: *Facts, enabled: rules.Set, findings: *memory.Bounded(Finding), work: Space) error{LimitExceeded}!void {
    if (!enabled.enabled("cyclic-import") and !enabled.enabled("context-leak")) assert.panic("checking imports with neither import rule enabled; checkStructure() checks first", .{});
    if (work.files.len == 0 and facts.imports.len > 0) assert.panic("{d} imports with no checked files to resolve them to; pass the workspace's files to checkStructure()", .{facts.imports.len});
    const before = findings.len;
    const built = try cycles.importGraph(facts, work.files, work.space);
    if (enabled.enabled("cyclic-import")) try cycles.checkCycles(facts, findings, work.space, built);
    if (enabled.enabled("context-leak")) if (work.anchor) |anchor| try checkLeaks(facts, findings, built, anchor);
    if (findings.len < before) assert.panic("the import rules dropped findings from {d} to {d}; they may only add", .{ before, findings.len });
}

/// Reports each import that reaches into another context past what that context exports.
fn checkLeaks(facts: *Facts, findings: *memory.Bounded(Finding), built: cycles.ImportGraph, anchor: config.Anchor) error{LimitExceeded}!void {
    if (built.edges.len > facts.imports.len) assert.panic("{d} import edges from {d} imports; importGraph() makes at most one per import", .{ built.edges.len, facts.imports.len });
    const settings = anchor.config;
    const scopes = settings.domainsAndContexts();
    const guarded = for (scopes) |s| {
        if (s.exports_len > 0) break true;
    } else false;
    if (!guarded) return;
    const before = findings.len;
    var exported: [config.max_scopes]u32 = @splat(unsearched);
    var buffers: [2][std.fs.max_path_bytes]u8 = undefined;
    for (built.edges) |e| {
        const target = anchor.relative(built.files[e.to], &buffers[0]);
        const importer = anchor.relative(built.files[e.from], &buffers[1]);
        if (target.len == 0 or importer.len == 0) continue;
        const owner = settings.scopeOf(target) orelse continue;
        const home = &scopes[owner];
        if (home.exports_len == 0 or home.exported(target)) continue;
        const from = settings.scopeOf(importer) orelse continue;
        if (from == owner or !scopes[from].context) continue;
        if (exported[owner] == unsearched) exported[owner] = exportedFile(built.files, anchor, owner);
        try report(facts, findings, .{ .edge = e, .files = built.files, .edges = built.edges, .from = &scopes[from], .owner = home, .exported = exported[owner] });
    }
    if (findings.len - before > built.edges.len) assert.panic("context-leak reported {d} findings for {d} imports; it reports each import once", .{ findings.len - before, built.edges.len });
}

/// The first checked file, in path order, that the context at `owner` exports, or `none`.
fn exportedFile(files: []const []const u8, anchor: config.Anchor, owner: usize) u32 {
    const scopes = anchor.config.domainsAndContexts();
    if (scopes[owner].exports_len == 0) assert.panic("looking for what [{s}] exports, which lists no exports; checkLeaks() checks only contexts that do", .{scopes[owner].name});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (files, 0..) |path, i| {
        const relative = anchor.relative(path, &buffer);
        if (relative.len == 0 or anchor.config.scopeOf(relative) != owner) continue;
        if (scopes[owner].exported(relative)) return @intCast(i);
    }
    if (files.len >= none) assert.panic("{d} checked files, too many to number past the markers", .{files.len});
    return none;
}

/// One import that leaks: the files it joins, the contexts they are in, and the file the
/// imported context exports, or `none`.
const Leak = struct {
    edge: cycles.ImportEdge,
    files: []const []const u8,
    edges: []const cycles.ImportEdge,
    from: *const config.Scope,
    owner: *const config.Scope,
    exported: u32,
};

fn report(facts: *Facts, findings: *memory.Bounded(Finding), leak: Leak) error{LimitExceeded}!void {
    if (leak.from == leak.owner) assert.panic("reporting an import inside [{s}] as a leak; checkLeaks() skips imports within one context", .{leak.owner.name});
    if (!leak.from.context or !leak.owner.context) assert.panic("reporting an import from [{s}] into [{s}] where one is not a context", .{ leak.from.name, leak.owner.name });
    const imp = facts.imports.items()[leak.edge.import];
    const text = facts.text;
    const target = leak.files[leak.edge.to];
    const owner = leak.owner.name;
    const message = try text.format("This import reaches '{s}', which context {s} keeps to itself, from context {s}; other contexts may import only what {s} exports, so {s} cannot change '{s}' without breaking {s}.", .{ target, owner, leak.from.name, owner, owner, std.fs.path.basename(target), leak.from.name });
    const names = if (imp.shown.len > 0) imp.shown else try text.format("what it needs", .{});
    const them = if (imp.names == 1) "it" else "them";
    const edit = try reexported(facts, leak);
    const fix = if (edit) |e|
        try text.format("Import {s} from {s}, which {s} exports and which already re-exports {s} from '{s}'.", .{ names, e.replacement, owner, them, target })
    else if (leak.exported == none)
        try text.format("Import {s} from a file {s} exports, not from '{s}'; none of the checked files matches its exports ({s}), so export {s} from one that does.", .{ names, owner, target, leak.owner.exports[0], names })
    else
        try text.format("Import {s} from '{s}', which {s} exports, not from '{s}'; if '{s}' does not offer {s} yet, re-export {s} there.", .{ names, leak.files[leak.exported], owner, target, leak.files[leak.exported], names, them });
    try findings.add(.{ .path = imp.path, .line = imp.line, .column = imp.column, .rule = "context-leak", .message = message, .fix = fix, .edit = edit });
}

/// The edit that takes the import's names from the exported module instead, when that module
/// imports every one of them from the same internal file, so they are the same objects there.
/// Null unless the import only takes names (it binds no module and quotes all it takes) by a
/// dotted module path that names a file, as Python's `from billing.ledger import post_entry`.
fn reexported(facts: *Facts, leak: Leak) error{LimitExceeded}!?Edit {
    if (leak.exported == none) return null;
    const imports = facts.imports.items();
    const imp = imports[leak.edge.import];
    const tables = (language.named(imp.language) orelse assert.panic("{s}: an import was recorded in language '{s}', which zanity doesn't know", .{ imp.path, imp.language })).tables;
    if (tables.import_style != .dotted or tables.import_inner_names) return null;
    if (imp.bound or imp.submodule or imp.names == 0 or imp.spec[0] == '.') return null;
    if (imp.names != std.mem.count(u8, imp.shown, ", ") + 1) return null;
    if (imp.spec_end <= imp.spec_start) assert.panic("{s}:{d}: the import of '{s}' records no place for its module", .{ imp.path, imp.line + 1, imp.spec });
    const offered = for (leak.edges) |e| {
        if (e.from != leak.exported or e.to != leak.edge.to) continue;
        if (takesAll(imports[e.import].shown, imp.shown)) break true;
    } else false;
    if (!offered) return null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const module = moduleOf(.{ .target = leak.files[leak.edge.to], .exported = leak.files[leak.exported], .spec = imp.spec }, tables.import_suffixes, &buffer) orelse return null;
    if (module.len == 0 or std.mem.eql(u8, module, imp.spec)) assert.panic("{s}:{d}: '{s}' would be rewritten to '{s}'; an exported file is never the file the import already names", .{ imp.path, imp.line + 1, imp.spec, module });
    return .{ .start = imp.spec_start, .end = imp.spec_end, .replacement = try facts.text.copy(module) };
}

/// Whether the names `offered`, as an import quotes them, include every name in `wanted`.
fn takesAll(offered: []const u8, wanted: []const u8) bool {
    if (wanted.len == 0) assert.panic("checking that an import offers no names; reexported() asks only for imports that take some", .{});
    for ([_][]const u8{ wanted, offered }) |quoted| if (std.mem.startsWith(u8, quoted, ", ") or std.mem.endsWith(u8, quoted, ", ")) assert.panic("the quoted names '{s}' hold an empty name; shownNames() joins captured names", .{quoted});
    var names = std.mem.splitSequence(u8, wanted, ", ");
    while (names.next()) |name| {
        var others = std.mem.splitSequence(u8, offered, ", ");
        const found = while (others.next()) |other| {
            if (std.mem.eql(u8, other, name)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// The directory `target` sits under as the module path `spec_path`, one of `suffixes` after
/// it, as `src/billing/ledger.py` sits under `src/` as `billing/ledger`; null when it doesn't.
fn rootOf(target: []const u8, spec_path: []const u8, suffixes: []const []const u8) ?[]const u8 {
    if (spec_path.len == 0) assert.panic("finding where '{s}' is rooted for an empty module path", .{target});
    for (suffixes) |suffix| {
        const tail = spec_path.len + suffix.len;
        if (target.len < tail or !std.mem.endsWith(u8, target, suffix)) continue;
        if (!std.mem.eql(u8, target[target.len - tail ..][0..spec_path.len], spec_path)) continue;
        const before = target[0 .. target.len - tail];
        if (before.len > target.len) assert.panic("the root of '{s}' is longer than it", .{target});
        if (before.len == 0 or before[before.len - 1] == '/') return before;
    }
    return null;
}

/// The file a dotted import names, the exported file to name instead, and the import's module.
const Paths = struct { target: []const u8, exported: []const u8, spec: []const u8 };

/// The dotted module that names `paths.exported` from the same root `paths.spec` names
/// `paths.target` from, into `buffer`; null when either is not a module file under that root.
fn moduleOf(paths: Paths, suffixes: []const []const u8, buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (suffixes.len == 0) assert.panic("naming the module of '{s}' with no suffixes; list the file endings under import_suffixes", .{paths.exported});
    if (paths.spec.len > buffer.len) return null;
    const spec_path = buffer[0..paths.spec.len];
    for (paths.spec, spec_path) |c, *p| p.* = if (c == '.') '/' else c;
    const root = rootOf(paths.target, spec_path, suffixes) orelse return null;
    if (!std.mem.startsWith(u8, paths.exported, root)) return null;
    const rest = paths.exported[root.len..];
    var longest: usize = 0;
    for (suffixes) |suffix| if (suffix.len > longest and rest.len > suffix.len and std.mem.endsWith(u8, rest, suffix)) {
        longest = suffix.len;
    };
    if (longest == 0) return null;
    const module = buffer[0 .. rest.len - longest];
    for (rest[0..module.len], module) |c, *m| m.* = if (c == '/') '.' else c;
    if (std.mem.indexOfScalar(u8, module, '.') == 0) assert.panic("'{s}' under '{s}' named the module '{s}', starting with a dot", .{ paths.exported, root, module });
    return module;
}

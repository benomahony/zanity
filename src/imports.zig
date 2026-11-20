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
        try report(facts, findings, .{ .edge = e, .files = built.files, .from = &scopes[from], .owner = home, .exported = exported[owner] });
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
    const fix = if (leak.exported == none)
        try text.format("Import {s} from a file {s} exports, not from '{s}'; none of the checked files matches its exports ({s}), so export {s} from one that does.", .{ names, owner, target, leak.owner.exports[0], names })
    else
        try text.format("Import {s} from '{s}', which {s} exports, not from '{s}'; if '{s}' does not offer {s} yet, re-export {s} there.", .{ names, leak.files[leak.exported], owner, target, leak.files[leak.exported], names, if (imp.names == 1) "it" else "them" });
    try findings.add(.{ .path = imp.path, .line = imp.line, .column = imp.column, .rule = "context-leak", .message = message, .fix = fix });
}

//! Keeps src/rules.zig and catalogue/catalogue.json telling the same story:
//! every entry a rule claims exists and names the rule back, and nothing else claims support.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");

const CatalogueEntry = struct {
    id: []const u8,
    implementation_status: []const u8,
    rule_ids: []const []const u8,
    /// defect, policy_violation or risk_indicator: how sure a finding in this family can be.
    assessment_kind: []const u8,
};

const Catalogue = struct { entries: []const CatalogueEntry };

fn listsName(names: []const []const u8, wanted: []const u8) bool {
    if (wanted.len == 0) assert.panic("expected a name to look for, got an empty one among {d}; pass the rule or entry name to look for", .{names.len});
    const found = for (names) |n| {
        if (std.mem.eql(u8, n, wanted)) break true;
    } else false;
    if (found and names.len == 0) assert.panic("expected to find '{s}' only in a non-empty list, got an empty one; call listsName() only with a list read from catalogue.json", .{wanted});
    return found;
}

fn entryById(entries: []const CatalogueEntry, id: []const u8) ?CatalogueEntry {
    if (id.len == 0) assert.panic("expected an entry id, got an empty one among {d} entries; every entry in catalogue/catalogue.json needs an id, so copy catalogue.json from the engineering-error-catalogue repository", .{entries.len});
    const index = for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.id, id)) break i;
    } else return null;
    if (index >= entries.len) assert.panic("expected an index below {d}, got {d}; entryById() must search only within the entries", .{ entries.len, index });
    return entries[index];
}

test "the catalogue and the rules agree on which rule detects which entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "catalogue/catalogue.json", arena, .unlimited);
    const catalogue = try std.json.parseFromSliceLeaky(Catalogue, arena, bytes, .{ .ignore_unknown_fields = true });
    var problems: usize = 0;
    for (rules.all) |rule| for (rule.catalogue) |id| {
        const entry = entryById(catalogue.entries, id) orelse {
            std.debug.print("\nrule {s} claims {s}, which is not in catalogue/catalogue.json", .{ rule.name, id });
            problems += 1;
            continue;
        };
        if (rule.severity == .@"error" and std.mem.eql(u8, entry.assessment_kind, "risk_indicator")) {
            std.debug.print("\nrule {s} reports errors, but {s} is a risk indicator, which the catalogue says never proves a bug; make the rule a warning", .{ rule.name, id });
            problems += 1;
        }
        if (!listsName(entry.rule_ids, rule.name) or std.mem.eql(u8, entry.implementation_status, "unsupported")) {
            std.debug.print("\n{s} does not list rule {s} as support; run python3 catalogue/sync.py", .{ id, rule.name });
            problems += 1;
        }
    };
    for (catalogue.entries) |entry| for (entry.rule_ids) |name| {
        const rule = rules.find(name) orelse {
            std.debug.print("\n{s} names rule {s}, which zanity does not have; run python3 catalogue/sync.py", .{ entry.id, name });
            problems += 1;
            continue;
        };
        if (!listsName(rule.catalogue, entry.id)) {
            std.debug.print("\n{s} names rule {s}, whose .catalogue does not list it; run python3 catalogue/sync.py", .{ entry.id, name });
            problems += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 0), problems);
}

const Question = struct { id: []const u8, question: []const u8, severity: []const u8 };

test "each catalogue question asks about a family no rule detects, as catalogue/questions.json says" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const catalogue = try std.json.parseFromSliceLeaky(Catalogue, arena, try std.Io.Dir.cwd().readFileAlloc(io, "catalogue/catalogue.json", arena, .unlimited), .{ .ignore_unknown_fields = true });
    const listed = try std.json.parseFromSliceLeaky([]const Question, arena, try std.Io.Dir.cwd().readFileAlloc(io, "catalogue/questions.json", arena, .unlimited), .{ .ignore_unknown_fields = true });
    var problems: usize = 0;
    if (listed.len != rules.catalogue.questions.len) {
        std.debug.print("\ncatalogue/questions.json lists {d} questions but src/catalogue_questions.zig has {d}; run python3 catalogue/questions.py", .{ listed.len, rules.catalogue.questions.len });
        problems += 1;
    }
    for (listed, 0..) |q, i| {
        const rule = if (i < rules.catalogue.questions.len) rules.catalogue.questions[i] else break;
        if (!std.mem.eql(u8, rule.alias, q.id) or !std.mem.eql(u8, rule.question, q.question)) {
            std.debug.print("\n{s} in catalogue/questions.json differs from rule {s}; run python3 catalogue/questions.py", .{ q.id, rule.name });
            problems += 1;
        }
        const entry = entryById(catalogue.entries, q.id) orelse {
            std.debug.print("\nthe question {s} names a family catalogue/catalogue.json doesn't have", .{q.id});
            problems += 1;
            continue;
        };
        if (entry.rule_ids.len > 0) {
            std.debug.print("\n{s} is detected by {s}, so asking about it wastes a question; remove it from catalogue/questions.json", .{ q.id, entry.rule_ids[0] });
            problems += 1;
        }
        if (rule.severity == .@"error" and std.mem.eql(u8, entry.assessment_kind, "risk_indicator")) {
            std.debug.print("\n{s} reports errors, but the catalogue says a risk indicator never proves a bug; make it a warning in catalogue/questions.json", .{q.id});
            problems += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), problems);
}

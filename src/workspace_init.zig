//! Allocates a workspace and establishes stable ownership links before publishing it.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const batch = @import("batch.zig");
const Facts = @import("facts.zig").Facts;
const project_manifest_capacity = 1024;
const baseline_review_bytes = 256 * 1024 * 1024;

pub fn initWorkspace(comptime Workspace: type, gpa: std.mem.Allocator, process_io: std.Io, limits: memory.Limits) std.mem.Allocator.Error!*Workspace {
    if (limits.files == 0) assert.panic("memory.Limits.files is 0, so zanity could not check any file", .{});
    if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so zanity could not read any file", .{});
    // Only the CLI startup and its resident watcher construct this local workspace. Limits
    // are program policy; no network request supplies them. Validate derived capacities before
    // allocating any components, then establish the stable text/facts ownership link.
    const review_snapshots = 2;
    const replacement_copies = 2;
    const max_capacity = std.math.maxInt(usize);
    const finding_count: usize = limits.findings;
    const source_bytes: usize = limits.file_bytes;
    // Each review may contain current and resolved rows; replacement storage allows two source
    // copies. These bounds also make the extra source terminator byte safe before allocation.
    if (finding_count > max_capacity / review_snapshots or source_bytes > max_capacity / replacement_copies) return error.OutOfMemory;
    const row_capacity = finding_count * review_snapshots;
    const source_capacity = source_bytes + 1;
    const replacement_capacity = source_bytes * replacement_copies;
    const ws = try gpa.create(Workspace);
    // Facts retain a pointer to the workspace's text arena, so establish that stable
    // address before building the other components. No partially initialized workspace escapes.
    const text = try memory.Text.initText(gpa, limits.text_bytes);
    ws.text = text;
    const facts = try Facts.initFacts(gpa, limits, &ws.text);
    ws.* = .{
        .limits = limits,
        .text = text,
        .facts = facts,
        .io = process_io,
        .naming = try .initNamingScratch(gpa, limits),
        .liveness = try .initLiveScratch(gpa, limits),
        .graph = try .initGraphScratch(gpa, limits),
        .findings = try .initBounded(gpa, limits.findings, "findings across all files"),
        .files = try .initBounded(gpa, limits.files, "files"),
        .project_files = try .initBounded(gpa, project_manifest_capacity, "project files"),
        .dirs = try .initBounded(gpa, limits.files, "directories"),
        .order = try memory.reserveUninitialized(gpa, batch.Sized, limits.files),
        .rows = try .initBounded(gpa, row_capacity, "findings and resolved baseline entries"),
        .table = try .initTableScratch(gpa, limits.files),
        .history = try .initHistory(gpa, limits.findings),
        .baseline_buffer = try memory.reserveUninitialized(gpa, u8, baseline_review_bytes),
        .source = try memory.reserveUninitialized(gpa, u8, source_capacity),
        .fixed = try memory.reserveUninitialized(gpa, u8, replacement_capacity),
        .analysis = try memory.reserveUninitialized(gpa, u8, limits.analysis_bytes),
        .ignore = try .initIgnore(gpa, limits),
    };
    return ws;
}

//! Allocates a workspace and establishes stable ownership links before publishing it.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const batch = @import("batch.zig");
const Facts = @import("facts.zig").Facts;

pub fn initWorkspace(comptime Workspace: type, gpa: std.mem.Allocator, io: std.Io, limits: memory.Limits) std.mem.Allocator.Error!*Workspace {
    if (limits.files == 0) assert.panic("memory.Limits.files is 0, so zanity could not check any file", .{});
    if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so zanity could not read any file", .{});
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
        .io = io,
        .naming = try .initNamingScratch(gpa, limits),
        .liveness = try .initLiveScratch(gpa, limits),
        .graph = try .initGraphScratch(gpa, limits),
        .findings = try .initBounded(gpa, limits.findings, "findings across all files"),
        .files = try .initBounded(gpa, limits.files, "files"),
        .project_files = try .initBounded(gpa, 1024, "project files"),
        .dirs = try .initBounded(gpa, limits.files, "directories"),
        .order = try memory.reserveUninitialized(gpa, batch.Sized, limits.files),
        .rows = try .initBounded(gpa, std.math.mul(usize, limits.findings, 2) catch return error.OutOfMemory, "findings and resolved baseline entries"),
        .table = try .initTableScratch(gpa, limits.files),
        .history = try .initHistory(gpa, limits.findings),
        .baseline_buffer = try memory.reserveUninitialized(gpa, u8, 1 << 28),
        .source = try memory.reserveUninitialized(gpa, u8, std.math.add(usize, limits.file_bytes, 1) catch return error.OutOfMemory),
        .fixed = try memory.reserveUninitialized(gpa, u8, std.math.mul(usize, limits.file_bytes, 2) catch return error.OutOfMemory),
        .analysis = try memory.reserveUninitialized(gpa, u8, limits.analysis_bytes),
        .ignore = try .initIgnore(gpa, limits),
    };
    return ws;
}

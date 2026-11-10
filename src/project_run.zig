//! What checking a project's files needs, shared by project.zig and the checks it runs.
const std = @import("std");
const Io = std.Io;
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;

/// What checking the project files needs: where to read them and where to report.
pub const ProjectRun = struct {
    io: Io,
    /// One extra byte beyond the largest accepted file, to detect truncated reads.
    buffer: []u8,
    facts: *Facts,
    enabled: rules.Set,
    findings: *memory.Bounded(Finding),
};

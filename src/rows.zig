//! The rows a check publishes, one per finding, and what comparing them with a baseline found.

/// Hex characters in a finding's SHA-256 identity.
pub const id_hex_length = 64;

/// One finding as `--json` and `--plain` publish it. Lines and columns count from 1. When zanity
/// can fix it, the edit replaces bytes `edit_start` to `edit_end` of the file with `edit_text`.
pub const Row = struct {
    path: []const u8,
    line: u32,
    column: u32,
    severity: []const u8,
    rule: []const u8,
    message: []const u8,
    fix: []const u8,
    matching_total: ?usize = null,
    next_offset: ?usize = null,
    edit_start: ?u32 = null,
    edit_end: ?u32 = null,
    edit_text: ?[]const u8 = null,
    id: []const u8 = "",
    classification: []const u8 = "unclassified",
};

/// What comparing a check's rows with a baseline found: how many are new, still there or gone,
/// and where the next page of matching rows starts.
pub const Review = struct {
    new: usize = 0,
    existing: usize = 0,
    resolved: usize = 0,
    matching: usize = 0,
    next: ?usize = null,
    new_counts: @import("report.zig").Counts = .{ .files = 0 },
};

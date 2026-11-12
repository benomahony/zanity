//! The buffers checking one file uses, allocated once per worker within memory.Limits and
//! cleared between files, so checking allocates nothing per file.
const std = @import("std");
const assert = @import("assert.zig");
const Allocator = std.mem.Allocator;
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const memory = @import("memory.zig");
const constructs = @import("constructs.zig");
const Spans = @import("spans.zig").Spans;
const NameCounts = @import("name_counts.zig").NameCounts;
const ImportNotes = @import("import_notes.zig").ImportNotes;
const Call = constructs.Call;
const Context = constructs.Context;
const Diagnostic = constructs.Diagnostic;
const Owned = constructs.Owned;
const Parameter = constructs.Parameter;
const Suppression = constructs.Suppression;
const Trail = constructs.Trail;
const Weak = constructs.Weak;

pub const FileScratch = struct {
    contexts: memory.Bounded(Context),
    opened: memory.Bounded(u8),
    diagnostics: memory.Bounded(Diagnostic),
    suppressions: memory.Bounded(Suppression),
    codes: memory.Bounded([]const u8),
    trail: memory.Bounded(Trail),
    calls: memory.Bounded(Call),
    signature: memory.Bounded(Parameter),
    weak: memory.Bounded(Weak),
    locals: memory.Bounded(Owned),
    spans: Spans,
    declared: memory.Bounded(constructs.Declared),
    /// A declared type waiting for the name it declares, which comes after it.
    pending_type: ?ts.Node = null,
    bare_calls: memory.Bounded(Owned),
    async_names: memory.Bounded([]const u8),
    statement_calls: memory.Bounded(ts.Node),
    repeats: memory.Bounded(constructs.Repeat),
    writes: memory.Bounded(constructs.Write),
    names: NameCounts,
    imports: ImportNotes,
    /// The nodes the walk is inside, outermost first, so their parents need no search.
    path: memory.Bounded(ts.Node),
    /// The chain from the root to a node, from ancestorsOf().
    ancestors: memory.Bounded(ts.Node),
    in_comment: []bool,
    code_lines: []bool,
    captures: captures.CaptureScratch,

    pub fn initCheckScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!FileScratch {
        if (limits.depth == 0 or limits.per_file == 0) assert.panic("memory.Limits.depth is {d} and per_file is {d}; both must be above 0 to check a file", .{ limits.depth, limits.per_file });
        if (limits.file_bytes == 0) assert.panic("memory.Limits.file_bytes is 0, so no file could be checked; set it above 0", .{});
        return .{
            .contexts = try .initBounded(gpa, limits.depth, "nested constructs in one file"),
            .opened = try .initBounded(gpa, limits.depth, "constructs opened per syntax node in one file"),
            .diagnostics = try .initBounded(gpa, limits.per_file, "findings in one file"),
            .suppressions = try .initBounded(gpa, limits.per_file, "suppression comments in one file"),
            .codes = try .initBounded(gpa, limits.per_file, "suppressed rule names in one file"),
            .trail = try .initBounded(gpa, limits.depth, "nested statements in one file"),
            .calls = try .initBounded(gpa, limits.captures, "calls in one file"),
            .signature = try .initBounded(gpa, limits.per_file, "parameters in one file"),
            .weak = try .initBounded(gpa, limits.per_file, "weak assertions in one file"),
            .locals = try .initBounded(gpa, limits.per_file, "local names in one file"),
            .spans = try .initSpans(gpa, limits.per_file),
            .declared = try .initBounded(gpa, limits.per_file, "declared names in one file"),
            .bare_calls = try .initBounded(gpa, limits.per_file, "unqualified calls in one file"),
            .async_names = try .initBounded(gpa, limits.per_file, "async functions in one file"),
            .statement_calls = try .initBounded(gpa, limits.per_file, "calls made as statements in one file"),
            .repeats = try .initBounded(gpa, limits.per_file, "repeatable expressions in one function"),
            .writes = try .initBounded(gpa, limits.per_file, "assignments in one file"),
            .names = try .initNameCounts(gpa, limits.per_file),
            .imports = try .initImportNotes(gpa, limits),
            .path = try .initBounded(gpa, limits.depth, "syntax nodes on the walk's path in one file"),
            .ancestors = try .initBounded(gpa, limits.depth, "ancestors of one syntax node"),
            .in_comment = try memory.reserveUninitialized(gpa, bool, limits.file_bytes),
            .code_lines = try memory.reserveUninitialized(gpa, bool, std.math.add(usize, limits.file_bytes, 1) catch return error.OutOfMemory),
            .captures = try .initCaptureScratch(gpa, limits),
        };
    }

    pub fn clearFile(self: *FileScratch) void {
        inline for (.{ "contexts", "opened", "diagnostics", "suppressions", "codes", "trail", "calls", "signature", "weak", "locals", "spans", "declared", "bare_calls", "async_names", "statement_calls", "repeats", "writes", "path", "ancestors" }) |field| {
            @field(self, field).clear();
        }
        self.names.reset();
        self.imports.clear();
        self.pending_type = null;
        if (self.contexts.len != 0) assert.panic("clearing the per-file scratch left {d} open constructs; clearFile() must clear contexts, so add it to the field list there", .{self.contexts.len});
        if (self.diagnostics.len != 0) assert.panic("clearing the per-file scratch left {d} findings; clearFile() must clear diagnostics, so add it to the field list there", .{self.diagnostics.len});
    }
};

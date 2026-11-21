//! The ids of the captures the checks look up by name, resolved once per language's compiled
//! query, so a check tests a node's captures without comparing names.
const assert = @import("assert.zig");
const captures = @import("captures.zig");
const std = @import("std");

/// The capture a Vocabulary field holds the id of: its name with the first `_` written as `.`,
/// as `import_name` holds `import.name`; `comment` holds `comment.outer`.
fn captureOf(comptime field: []const u8) []const u8 {
    if (field.len < 3 or field[0] == '_' or field[field.len - 1] == '_') assert.panic("Vocabulary.{s} can't name a capture; name it <group>_<capture>, as import_name holds import.name", .{field});
    if (std.mem.eql(u8, field, "comment")) return "comment.outer";
    const at = std.mem.indexOfScalar(u8, field, '_') orelse @compileError("Vocabulary." ++ field ++ " names no capture; name it <group>_<capture>, as import_name holds import.name");
    const capture = field[0..at] ++ "." ++ field[at + 1 ..];
    if (capture.len != field.len) assert.panic("Vocabulary.{s} became the capture {s}, of another length; only its first _ becomes a .", .{ field, capture });
    return capture;
}

/// The literal kinds a query captures as `@type.<kind>` on an argument, in the order of
/// `Tables.literal_types`' fields.
pub const literal_kinds = [_][]const u8{ "text", "letter", "whole", "fraction", "truth" };

/// The ids of the `@type.<kind>` captures for each of `literal_kinds` in `c`.
pub fn literalIds(c: captures.Compiled) [literal_kinds.len]?captures.Id {
    var ids: [literal_kinds.len]?captures.Id = undefined;
    inline for (literal_kinds, 0..) |kind, i| ids[i] = c.id("type." ++ kind);
    if (ids.len != literal_kinds.len) assert.panic("looked up {d} literal captures for {d} kinds; look up one per kind", .{ ids.len, literal_kinds.len });
    if (c.names.len == 0) assert.panic("looking up literal captures in a query with no captures; check the language's query files", .{});
    return ids;
}

pub const Vocabulary = struct {
    comment: ?captures.Id,
    /// A type naming the type of the expression it belongs to, such as a construction's.
    type_of: ?captures.Id,
    /// Literals of each of `literal_kinds`.
    type_literals: [literal_kinds.len]?captures.Id,
    literal_true: ?captures.Id,
    literal_constant: ?captures.Id,
    literal_falsy: ?captures.Id,
    literal_none: ?captures.Id,
    literal_collection: ?captures.Id,
    literal_string: ?captures.Id,
    error_message: ?captures.Id,
    string_format: ?captures.Id,
    expression_path: ?captures.Id,
    expression_conditional: ?captures.Id,
    compare_not_null: ?captures.Id,
    compare_non_negative: ?captures.Id,
    compare_equal: ?captures.Id,
    compare_subject: ?captures.Id,
    compare_value: ?captures.Id,
    assignment_compound: ?captures.Id,
    function_passthrough: ?captures.Id,
    catch_swallowed: ?captures.Id,
    arith_difference: ?captures.Id,
    string_built: ?captures.Id,
    async_name: ?captures.Id,
    statement_call: ?captures.Id,
    control_chain: ?captures.Id,
    decision_point: ?captures.Id,
    test_outer: ?captures.Id,
    test_check: ?captures.Id,
    test_constant: ?captures.Id,
    test_shared_state: ?captures.Id,
    chain_link: ?captures.Id,
    /// A struct whose fields sit in the order they are written, for padded-struct.
    layout_struct: ?captures.Id,
    expression_repeatable: ?captures.Id,
    write_target: ?captures.Id,
    reference_name: ?captures.Id,
    import_statement: ?captures.Id,
    import_module: ?captures.Id,
    import_binding: ?captures.Id,
    import_name: ?captures.Id,
    import_submodule: ?captures.Id,
    import_via: ?captures.Id,
    import_used: ?captures.Id,
    abstraction_name: ?captures.Id,
    implementation_base: ?captures.Id,
    reference_passed: ?captures.Id,
    visibility_public: ?captures.Id,
    opaque_negated: ?captures.Id,
    opaque_left: ?captures.Id,
    opaque_key: ?captures.Id,
    opaque_right: ?captures.Id,
    double_behaviour: ?captures.Id,
    double_branch: ?captures.Id,
    call_verification: ?captures.Id,
    storage_read: ?captures.Id,

    pub fn lookup(c: captures.Compiled) Vocabulary {
        if (c.names.len == 0) assert.panic("the query has no captures, so no rule could run; check the language's query files", .{});
        if (c.predicates.len == 0) assert.panic("the query has {d} captures but no patterns; check the language's query files listed in languages/manifest.zon", .{c.names.len});
        var v: Vocabulary = undefined;
        inline for (@typeInfo(Vocabulary).@"struct".field_names) |name| {
            @field(v, name) = if (comptime std.mem.eql(u8, name, "type_literals")) literalIds(c) else c.id(comptime captureOf(name));
        }
        return v;
    }
};

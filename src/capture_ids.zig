//! The ids of the captures the checks look up by name, resolved once per language's compiled
//! query, so a check tests a node's captures without comparing names.
const assert = @import("assert.zig");
const captures = @import("captures.zig");

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
    expression_repeatable: ?captures.Id,
    write_target: ?captures.Id,
    reference_name: ?captures.Id,
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
        return .{
            .comment = c.id("comment.outer"),
            .type_of = c.id("type.of"),
            .type_literals = literalIds(c),
            .literal_true = c.id("literal.true"),
            .literal_constant = c.id("literal.constant"),
            .literal_falsy = c.id("literal.falsy"),
            .literal_none = c.id("literal.none"),
            .literal_collection = c.id("literal.collection"),
            .literal_string = c.id("literal.string"),
            .error_message = c.id("error.message"),
            .string_format = c.id("string.format"),
            .expression_path = c.id("expression.path"),
            .expression_conditional = c.id("expression.conditional"),
            .compare_not_null = c.id("compare.not_null"),
            .compare_non_negative = c.id("compare.non_negative"),
            .compare_equal = c.id("compare.equal"),
            .compare_subject = c.id("compare.subject"),
            .compare_value = c.id("compare.value"),
            .assignment_compound = c.id("assignment.compound"),
            .function_passthrough = c.id("function.passthrough"),
            .catch_swallowed = c.id("catch.swallowed"),
            .arith_difference = c.id("arith.difference"),
            .string_built = c.id("string.built"),
            .async_name = c.id("async.name"),
            .statement_call = c.id("statement.call"),
            .control_chain = c.id("control.chain"),
            .decision_point = c.id("decision.point"),
            .test_outer = c.id("test.outer"),
            .test_check = c.id("test.check"),
            .test_constant = c.id("test.constant"),
            .test_shared_state = c.id("test.shared_state"),
            .chain_link = c.id("chain.link"),
            .expression_repeatable = c.id("expression.repeatable"),
            .write_target = c.id("write.target"),
            .reference_name = c.id("reference.name"),
            .abstraction_name = c.id("abstraction.name"),
            .implementation_base = c.id("implementation.base"),
            .reference_passed = c.id("reference.passed"),
            .visibility_public = c.id("visibility.public"),
            .opaque_negated = c.id("opaque.negated"),
            .opaque_left = c.id("opaque.left"),
            .opaque_key = c.id("opaque.key"),
            .opaque_right = c.id("opaque.right"),
            .double_behaviour = c.id("double.behaviour"),
            .double_branch = c.id("double.branch"),
            .call_verification = c.id("call.verification"),
            .storage_read = c.id("storage.read"),
        };
    }
};

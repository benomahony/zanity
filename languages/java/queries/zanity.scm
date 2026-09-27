(method_declaration
  name: (identifier) @function.name)

(constructor_declaration
  name: (identifier) @function.name)

(formal_parameters
  [
    (formal_parameter)
    (spread_parameter)
  ] @function.parameter)

(method_declaration
  body: (block
    .
    [
      (expression_statement
        (method_invocation))
      (return_statement
        (method_invocation))
    ]
    .)) @function.passthrough

(method_invocation
  name: (identifier) @call.name)

(method_invocation
  object: (_) @call.receiver)

(method_invocation
  arguments: (argument_list
    (_) @call.argument))

(while_statement
  condition: (parenthesized_expression
    (_) @loop.condition))

(do_statement
  condition: (parenthesized_expression
    (_) @loop.condition))

(for_statement
  condition: (_) @loop.condition)

(enhanced_for_statement
  value: (_) @loop.iterable)

(true) @literal.true

(assert_statement
  .
  (_) @assertion.condition) @assertion.outer

(assert_statement
  ":"
  (_) @assertion.message)

(catch_clause
  body: (block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed

((method_declaration
  (modifiers
    [
      (marker_annotation
        name: (identifier) @_test)
      (annotation
        name: (identifier) @_test)
    ])) @test.outer
  (#eq? @_test "Test"))

(local_variable_declaration
  declarator: (variable_declarator
    name: (_) @assignment.lhs
    value: (_) @assignment.rhs)) @assignment.outer

(assignment_expression
  left: (_) @assignment.lhs
  right: (_) @assignment.rhs) @assignment.outer

[
  (decimal_integer_literal)
  (decimal_floating_point_literal)
  (string_literal)
  (character_literal)
  (true)
  (false)
  (null_literal)
] @literal.constant

[
  (false)
  (null_literal)
] @literal.falsy

((decimal_integer_literal) @literal.falsy
  (#eq? @literal.falsy "0"))

(null_literal) @literal.none

(array_initializer) @literal.collection

[
  (identifier)
  (field_access)
] @expression.path

(binary_expression
  left: (_) @compare.subject
  operator: "!="
  right: (null_literal)) @compare.not_null

(binary_expression
  left: (_) @compare.subject
  operator: "=="
  right: (_) @compare.value) @compare.equal

[
  (while_statement)
  (do_statement)
  (for_statement)
  (enhanced_for_statement)
] @loop.outer

[
  (method_declaration)
  (constructor_declaration)
] @function.outer

(function_declaration
  name: (identifier) @function.name
  body: (block))

(call_expression
  function: (_) @call.callee)

(call_expression
  function: (identifier) @call.name)

(call_expression
  function: (field_expression
    object: (_) @call.receiver
    member: (identifier) @call.name))

(call_expression
  arguments: (arguments
    (_) @call.argument))

(while_statement
  condition: (_) @loop.condition)

(for_statement
  .
  (_) @loop.iterable)

((boolean) @literal.true
  (#eq? @literal.true "true"))

((call_expression
  function: [
    (identifier) @_assert
    (field_expression
      member: (identifier) @_assert)
  ]
  arguments: (arguments
    .
    (_) @assertion.condition)) @assertion.outer
  (#eq? @_assert "assert"))

(assignment_expression
  left: (_) @assignment.lhs
  operator: "="
  right: _ @assignment.rhs) @assignment.outer

(variable_declaration
  (identifier) @assignment.lhs
  "="
  _ @assignment.rhs) @assignment.outer

[
  (integer)
  (float)
  (string)
  (multiline_string)
  (boolean)
  "null"
] @literal.constant

((boolean) @literal.falsy
  (#eq? @literal.falsy "false"))

((integer) @literal.falsy
  (#any-of? @literal.falsy "0" "0x0" "0b0" "0o0"))

"null" @literal.falsy

"null" @literal.none

(anonymous_struct_initializer) @literal.collection

[
  (identifier)
  (field_expression)
] @expression.path

(binary_expression
  left: (_) @compare.subject
  operator: "!="
  right: "null") @compare.not_null

(binary_expression
  left: (_) @compare.subject
  operator: "=="
  right: _ @compare.value) @compare.equal

(function_declaration
  (parameters
    (parameter) @function.parameter))

(function_declaration
  body: (block
    .
    (expression_statement
      [
        (call_expression)
        (return_expression
          (call_expression))
        (return_expression
          (try_expression
            (call_expression)))
      ])
    .)) @function.passthrough

(catch_expression
  (block
    .
    "{"
    .
    "}"
    .) @catch.swallowed)

(test_declaration) @test.outer

(function_declaration
  name: (identifier) @name) @definition.function

(variable_declaration
  (identifier) @name
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ]) @definition.class

(source_file
  (variable_declaration
    (identifier) @name
    [
      (integer)
      (float)
      (string)
      (multiline_string)
      (boolean)
    ]) @definition.constant)

[
  (while_statement)
  (for_statement)
] @loop.outer

(function_declaration) @function.outer

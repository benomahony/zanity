(function_declaration
  name: (identifier) @function.name)

(method_definition
  name: (property_identifier) @function.name)

(variable_declarator
  name: (identifier) @function.name
  value: [
    (arrow_function)
    (function_expression)
  ]) @function.outer

(formal_parameters
  [
    (required_parameter)
    (optional_parameter)
  ] @function.parameter)

([
  (function_declaration
    body: (statement_block
      .
      [
        (expression_statement
          (call_expression))
        (return_statement
          (call_expression))
      ]
      .))
  (method_definition
    body: (statement_block
      .
      [
        (expression_statement
          (call_expression))
        (return_statement
          (call_expression))
      ]
      .))
  (arrow_function
    body: (call_expression))
  (arrow_function
    body: (statement_block
      .
      [
        (expression_statement
          (call_expression))
        (return_statement
          (call_expression))
      ]
      .))
] @function.passthrough)

(call_expression
  function: (_) @call.callee)

(call_expression
  function: (identifier) @call.name)

(call_expression
  function: (member_expression
    object: (_) @call.receiver
    property: (property_identifier) @call.name))

(call_expression
  arguments: (arguments
    (_) @call.argument))

(while_statement
  condition: (parenthesized_expression
    (_) @loop.condition))

(do_statement
  condition: (parenthesized_expression
    (_) @loop.condition))

((for_statement
  condition: (_) @loop.condition)
  (#not-eq? @loop.condition ";"))

(for_in_statement
  right: (_) @loop.iterable)

(true) @literal.true

((call_expression
  function: (identifier) @_assert
  arguments: (arguments
    .
    (_) @assertion.condition)) @assertion.outer
  (#eq? @_assert "assert"))

((call_expression
  function: (member_expression
    object: (identifier) @_console
    property: (property_identifier) @_assert)
  arguments: (arguments
    .
    (_) @assertion.condition)) @assertion.outer
  (#eq? @_console "console")
  (#eq? @_assert "assert"))

((call_expression
  function: [
    (identifier) @_assert
    (member_expression
      property: (property_identifier) @_assert)
  ]
  arguments: (arguments
    .
    (_)
    .
    (_) @assertion.message))
  (#eq? @_assert "assert"))

(catch_clause
  body: (statement_block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed

((call_expression
  function: (identifier) @_test
  arguments: (arguments
    .
    (string)
    .
    [
      (arrow_function)
      (function_expression)
    ])) @test.outer
  (#any-of? @_test "it" "test"))

(variable_declarator
  name: (_) @assignment.lhs
  value: (_) @assignment.rhs) @assignment.outer

[
  (number)
  (string)
  (template_string)
  (true)
  (false)
  (null)
] @literal.constant

[
  (false)
  (null)
] @literal.falsy

((number) @literal.falsy
  (#any-of? @literal.falsy "0" "0.0"))

(null) @literal.none

[
  (array)
  (object)
] @literal.collection

[
  (identifier)
  (member_expression)
] @expression.path

(binary_expression
  left: (_) @compare.subject
  operator: [
    "!=="
    "!="
  ]
  right: (null)) @compare.not_null

(binary_expression
  left: (_) @compare.subject
  operator: [
    "==="
    "=="
  ]
  right: (_) @compare.value) @compare.equal

[
  (while_statement)
  (do_statement)
  (for_statement)
  (for_in_statement)
] @loop.outer

[
  (function_declaration)
  (method_definition)
  (arrow_function)
  (function_expression)
] @function.outer

; Parameter names, so findings can refer to them.
(required_parameter
  pattern: (identifier) @parameter.name)

(optional_parameter
  pattern: (identifier) @parameter.name)

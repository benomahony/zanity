(function_item
  name: (identifier) @function.name)

(function_item
  parameters: (parameters
    [
      (parameter)
      (self_parameter)
    ] @function.parameter))

(function_item
  body: (block
    .
    [
      (call_expression)
      (expression_statement
        (call_expression))
      (expression_statement
        (return_expression
          (call_expression)))
    ]
    .)) @function.passthrough

(call_expression
  function: (_) @call.callee)

(call_expression
  function: (identifier) @call.name)

(call_expression
  function: (scoped_identifier
    name: (identifier) @call.name))

(call_expression
  function: (field_expression
    value: (_) @call.receiver
    field: (field_identifier) @call.name))

(call_expression
  arguments: (arguments
    (_) @call.argument))

(while_expression
  condition: (_) @loop.condition)

(for_expression
  value: (_) @loop.iterable)

((boolean_literal) @literal.true
  (#eq? @literal.true "true"))

((macro_invocation
  macro: (identifier) @_assert
  (token_tree) @assertion.condition) @assertion.outer
  (#any-of? @_assert "assert" "debug_assert" "assert_eq" "assert_ne" "debug_assert_eq" "debug_assert_ne"))

((macro_invocation
  macro: (identifier) @_assert
  (token_tree
    ","
    (string_literal) @assertion.message))
  (#any-of? @_assert "assert" "debug_assert" "assert_eq" "assert_ne" "debug_assert_eq" "debug_assert_ne"))

((match_arm
  pattern: (match_pattern
    (tuple_struct_pattern
      type: (identifier) @_err))
  value: (block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed
  (#eq? @_err "Err"))

(let_declaration
  pattern: "_"
  value: (call_expression)) @catch.swallowed

(_
  (attribute_item
    (attribute
      (identifier) @_test))
  .
  (function_item) @test.outer
  (#eq? @_test "test"))

[
  (loop_expression)
  (while_expression)
  (for_expression)
] @loop.outer

(function_item) @function.outer

; Parameter names, so findings can refer to them.
(parameter
  pattern: (identifier) @parameter.name)

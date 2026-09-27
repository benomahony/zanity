(function_declaration
  name: (identifier) @function.name)

(method_declaration
  name: (field_identifier) @function.name)

(function_declaration
  parameters: (parameter_list
    [
      (parameter_declaration
        name: (identifier) @function.parameter)
      (variadic_parameter_declaration
        name: (identifier) @function.parameter)
    ]))

(method_declaration
  parameters: (parameter_list
    [
      (parameter_declaration
        name: (identifier) @function.parameter)
      (variadic_parameter_declaration
        name: (identifier) @function.parameter)
    ]))

([
  (function_declaration
    body: (block
      (statement_list
        .
        [
          (expression_statement
            (call_expression))
          (return_statement
            (expression_list
              .
              (call_expression)
              .))
        ]
        .)))
  (method_declaration
    body: (block
      (statement_list
        .
        [
          (expression_statement
            (call_expression))
          (return_statement
            (expression_list
              .
              (call_expression)
              .))
        ]
        .)))
] @function.passthrough)

(call_expression
  function: (_) @call.callee)

(call_expression
  function: (identifier) @call.name)

(call_expression
  function: (selector_expression
    operand: (_) @call.receiver
    field: (field_identifier) @call.name))

(call_expression
  arguments: (argument_list
    (_) @call.argument))

(for_statement
  (range_clause) @loop.iterable)

(for_statement
  (for_clause
    condition: (_) @loop.condition))

(for_statement
  [
    (binary_expression)
    (unary_expression)
    (identifier)
    (call_expression)
    (selector_expression)
    (parenthesized_expression)
    (true)
    (false)
  ] @loop.condition)

(true) @literal.true

((if_statement
  condition: (_) @assertion.condition
  consequence: (block
    (statement_list
      .
      (expression_statement
        (call_expression
          function: (identifier) @_panic
          arguments: (argument_list
            .
            (_) @assertion.message)))
      .))) @assertion.outer
  (#eq? @_panic "panic"))

((if_statement
  condition: (binary_expression
    left: (identifier) @_err
    operator: "!="
    right: (nil))
  consequence: (block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed
  (#eq? @_err "err"))

(for_statement) @loop.outer

[
  (function_declaration)
  (method_declaration)
  (func_literal)
] @function.outer

; Parameter names, so findings can refer to them.
(parameter_declaration
  name: (identifier) @parameter.name)

(variadic_parameter_declaration
  name: (identifier) @parameter.name)

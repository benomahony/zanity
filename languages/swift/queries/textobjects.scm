(class_declaration
  body: (class_body
    .
    "{"
    _+ @class.inner
    "}")) @class.outer

(class_declaration
  body: (enum_class_body
    .
    "{"
    _+ @class.inner
    "}")) @class.outer

(function_declaration
  body: (function_body
    .
    "{"
    _+ @function.inner
    "}")) @function.outer

(lambda_literal
  ("{"
    _+ @function.inner
    "}")) @function.outer

(call_suffix
  (value_arguments
    .
    "("
    _+ @call.inner
    ")")) @call.outer

(value_argument
  value: (_) @parameter.inner) @parameter.outer

(comment) @comment.outer

(multiline_comment) @comment.outer

(function_declaration) @function.outer

(init_declaration) @function.outer

(deinit_declaration) @function.outer

[
  (for_statement)
  (while_statement)
  (repeat_while_statement)
] @loop.outer

[
  (if_statement)
  (guard_statement)
  (switch_statement)
] @conditional.outer

(control_transfer_statement
  result: (_) @return.inner) @return.outer

(statements
  (_) @statement.outer)

(property_declaration
  name: (pattern
    bound_identifier: (simple_identifier) @assignment.lhs)
  value: (_) @assignment.rhs) @assignment.outer

(assignment
  target: (_) @assignment.lhs
  result: (_) @assignment.rhs) @assignment.outer

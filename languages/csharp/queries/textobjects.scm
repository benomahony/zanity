[
  (class_declaration)
  (struct_declaration)
  (record_declaration)
  (interface_declaration)
  (enum_declaration)
] @class.outer

[
  (class_declaration
    body: (declaration_list
      .
      "{"
      .
      (_) @class.inner))
  (struct_declaration
    body: (declaration_list
      .
      "{"
      .
      (_) @class.inner))
  (record_declaration
    body: (declaration_list
      .
      "{"
      .
      (_) @class.inner))
  (interface_declaration
    body: (declaration_list
      .
      "{"
      .
      (_) @class.inner))
]

[
  (method_declaration)
  (constructor_declaration)
  (destructor_declaration)
  (operator_declaration)
  (conversion_operator_declaration)
  (local_function_statement)
] @function.outer

[
  (method_declaration
    body: (block
      .
      "{"
      .
      (_) @function.inner))
  (constructor_declaration
    body: (block
      .
      "{"
      .
      (_) @function.inner))
  (local_function_statement
    body: (block
      .
      "{"
      .
      (_) @function.inner))
]

[
  (method_declaration
    body: (arrow_expression_clause
      "=>"
      .
      (_) @function.inner))
  (local_function_statement
    body: (arrow_expression_clause
      "=>"
      .
      (_) @function.inner))
]

(return_statement
  (_)? @return.inner) @return.outer

[
  (for_statement)
  (foreach_statement)
  (while_statement)
  (do_statement)
] @loop.outer

(for_statement
  body: (_) @loop.inner)

(foreach_statement
  body: (_) @loop.inner)

(while_statement
  body: (_) @loop.inner)

(do_statement
  body: (_) @loop.inner)

(if_statement
  consequence: (_)? @conditional.inner
  alternative: (_)? @conditional.inner) @conditional.outer

(switch_statement
  body: (switch_body) @conditional.inner) @conditional.outer

(block) @block.outer

[
  (invocation_expression)
  (object_creation_expression)
] @call.outer

(invocation_expression
  arguments: (argument_list
    .
    "("
    .
    (_) @call.inner))

(object_creation_expression
  arguments: (argument_list
    .
    "("
    .
    (_) @call.inner))

; parameters
(parameter_list
  "," @parameter.outer
  .
  (parameter) @parameter.inner @parameter.outer)

(parameter_list
  .
  (parameter) @parameter.inner @parameter.outer
  .
  ","? @parameter.outer)

(argument_list
  "," @parameter.outer
  .
  (argument) @parameter.inner @parameter.outer)

(argument_list
  .
  (argument) @parameter.inner @parameter.outer
  .
  ","? @parameter.outer)

(comment) @comment.outer

[
  (integer_literal)
  (real_literal)
] @number.inner

(statement) @statement.outer

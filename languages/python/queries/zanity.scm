(function_definition
  name: (identifier) @function.name)

(call
  function: (_) @call.callee)

(call
  function: (identifier) @call.name)

(call
  function: (attribute
    object: (_) @call.receiver
    attribute: (identifier) @call.name))

(while_statement
  condition: (_) @loop.condition)

(for_statement
  right: (_) @loop.iterable)

(true) @literal.true

(assert_statement
  .
  (_) @assertion.condition) @assertion.outer

(assert_statement
  ","
  (_) @assertion.message)

(call
  arguments: (argument_list
    (expression) @call.argument))

(augmented_assignment) @assignment.compound

(typed_parameter
  (identifier) @parameter.name
  type: (type) @parameter.type)

(typed_default_parameter
  name: (identifier) @parameter.name
  type: (type) @parameter.type)

[
  (string)
  (concatenated_string)
  (integer)
  (float)
  (true)
  (false)
  (none)
] @literal.constant

[
  (false)
  (none)
] @literal.falsy

((integer) @literal.falsy
  (#any-of? @literal.falsy "0" "00" "000" "0x0" "0o0" "0b0"))

((float) @literal.falsy
  (#any-of? @literal.falsy "0.0" "0." ".0" "0.00" "00.0"))

((string
  .
  (string_start)
  .
  (string_end)) @literal.falsy)

(none) @literal.none

[
  (dictionary)
  (list)
  (set)
  (tuple)
] @literal.collection

((string
  (string_start) @_start) @string.format
  (#any-of? @_start "f\"" "f'" "f\"\"\"" "f'''" "F\"" "F'" "F\"\"\"" "F'''" "rf\"" "rf'" "rf\"\"\"" "rf'''" "rF\"" "rF'" "rF\"\"\"" "rF'''" "Rf\"" "Rf'" "Rf\"\"\"" "Rf'''" "RF\"" "RF'" "RF\"\"\"" "RF'''" "fr\"" "fr'" "fr\"\"\"" "fr'''" "fR\"" "fR'" "fR\"\"\"" "fR'''" "Fr\"" "Fr'" "Fr\"\"\"" "Fr'''" "FR\"" "FR'" "FR\"\"\"" "FR'''"))

[
  (identifier)
  (attribute)
] @expression.path

(comparison_operator
  .
  (_) @compare.subject
  .
  "is not"
  .
  (none)
  .) @compare.not_null

(comparison_operator
  .
  (_) @compare.subject
  .
  ">="
  .
  ((integer) @_zero
    (#eq? @_zero "0"))
  .) @compare.non_negative

(comparison_operator
  .
  (_) @compare.subject
  .
  ">"
  .
  ((unary_operator
    "-"
    (integer) @_one)
    (#eq? @_one "1"))
  .) @compare.non_negative

(comparison_operator
  .
  (_) @compare.subject
  .
  "=="
  .
  (_) @compare.value
  .) @compare.equal

(function_definition
  parameters: (parameters
    [
      (identifier)
      (typed_parameter)
      (default_parameter)
      (typed_default_parameter)
      (list_splat_pattern)
      (dictionary_splat_pattern)
    ] @function.parameter))

(function_definition
  body: (block
    .
    [
      (call)
      (expression_statement
        (call))
      (return_statement
        (call))
    ]
    .)) @function.passthrough

(except_clause
  (block
    .
    [
      (pass_statement)
      (ellipsis)
      (expression_statement
        (ellipsis))
    ]
    .)) @catch.swallowed

(named_expression
  name: (_) @assignment.lhs
  value: (_) @assignment.rhs) @assignment.outer

[
  (while_statement)
  (for_statement)
] @loop.outer

(function_definition) @function.outer

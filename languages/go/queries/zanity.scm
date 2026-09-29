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

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(interpreted_string_literal) @literal.string

(raw_string_literal) @literal.string

; CWE-1071: an empty body with not even a comment.
([
  (if_statement
    consequence: (block) @_body)
  (for_statement
    body: (block) @_body)
] @finding.empty-block
  (#empty? @_body))

; An empty `else` is reported at the `else`, not at the `if` whose body may be fine.
((if_statement
  "else" @finding.empty-block
  alternative: (block) @_body)
  (#empty? @_body))

; CWE-570, CWE-571: a condition that is a literal.
(if_statement
  condition: [(true) (false)]) @finding.constant-condition

; CWE-1077: exact equality with a floating-point literal other than zero.
((binary_expression
  operator: ["==" "!="]
  right: (float_literal) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0"))

((binary_expression
  left: (float_literal) @_float
  operator: ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0"))

; CWE-561: the statement right after one that always leaves the block.
; Labeled statements can be reached by goto, so they are not listed.
(statement_list
  [
    (return_statement)
    (break_statement)
    (continue_statement)
    (goto_statement)
  ]
  .
  [
    (expression_statement)
    (assignment_statement)
    (short_var_declaration)
    (inc_statement)
    (dec_statement)
    (send_statement)
    (var_declaration)
    (const_declaration)
    (if_statement)
    (for_statement)
    (expression_switch_statement)
    (type_switch_statement)
    (select_statement)
    (go_statement)
    (defer_statement)
    (return_statement)
    (break_statement)
    (continue_statement)
    (block)
  ] @finding.unreachable-code)

; CWE-478: a switch without a default case.
[
  (expression_switch_statement)
  (type_switch_statement)
] @finding.missing-default

(default_case) @unless.missing-default

; CWE-295: a TLS config with certificate checks turned off.
((keyed_element
  key: (literal_element
    (identifier) @_key)
  value: (literal_element
    (true))) @finding.tls-verification-disabled
  (#eq? @_key "InsecureSkipVerify"))

; Shapes the engine measures or cross-checks: strings built at runtime (SQL), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

(binary_expression
  operator: "+") @string.built

((call_expression
  function: (selector_expression
    field: (field_identifier) @_function)) @string.built
  (#eq? @_function "Sprintf"))

[
  (if_statement)
  (for_statement)
  (expression_switch_statement)
  (type_switch_statement)
  (select_statement)
] @control.outer

(if_statement
  alternative: (if_statement) @control.chain)

[
  (if_statement)
  (for_statement)
  (expression_case)
  (type_case)
  (communication_case)
] @decision.point

(binary_expression
  operator: ["&&" "||"]) @decision.point

; Names and field accesses, for rules that look at the values an expression reads.
[
  (identifier)
  (selector_expression)
] @expression.path

; A local declared as a statement of a block, and the blocks it could move into. `_` discards
; a value; it declares nothing.
(block
  (statement_list
    (short_var_declaration
      left: (expression_list
        (identifier) @declaration.name
        (#not-eq? @declaration.name "_"))) @declaration.outer))

(block
  (statement_list
    (var_declaration
      (var_spec
        name: (identifier) @declaration.name
        (#not-eq? @declaration.name "_"))) @declaration.outer))

(block) @declaration.block

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (call_expression)
  (unary_expression
    operator: "<-")
  (func_literal)
] @declaration.effect

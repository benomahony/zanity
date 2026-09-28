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

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(string_literal) @literal.string

(field_declaration
  declarator: (variable_declarator
    name: (_) @assignment.lhs
    value: (_) @assignment.rhs)) @assignment.outer

; CWE-1071: an empty body with not even a comment. Empty catch bodies are swallowed-error's.
([
  (if_statement
    consequence: (block) @_body)
  (for_statement
    body: (block) @_body)
  (enhanced_for_statement
    body: (block) @_body)
  (while_statement
    body: (block) @_body)
  (do_statement
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
  condition: (parenthesized_expression
    [(true) (false)])) @finding.constant-condition

(ternary_expression
  condition: [(true) (false)]) @finding.constant-condition

; CWE-1077: exact equality with a floating-point literal other than zero.
((binary_expression
  operator: ["==" "!="]
  right: (decimal_floating_point_literal) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0" "0.0f" "0.0d" "0f" "0d" "0.0F" "0.0D"))

((binary_expression
  left: (decimal_floating_point_literal) @_float
  operator: ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0" "0.0f" "0.0d" "0f" "0d" "0.0F" "0.0D"))

; CWE-396: catching the root exception types.
((catch_clause
  (catch_formal_parameter
    (catch_type
      (type_identifier) @_type))) @finding.generic-catch
  (#any-of? @_type "Exception" "Throwable" "RuntimeException"))

; The message of a thrown exception, for the error-message rules.
(throw_statement
  (object_creation_expression
    arguments: (argument_list
      .
      (string_literal) @error.message)))

; CWE-584: a return inside finally replaces the exception or return already under way.
((return_statement) @finding.return-in-finally
  (#has-ancestor? @finding.return-in-finally finally_clause))

; CWE-597: == on a string literal compares references, not text.
(binary_expression
  operator: ["==" "!="]
  right: (string_literal)) @finding.identity-comparison

(binary_expression
  left: (string_literal)
  operator: ["==" "!="]) @finding.identity-comparison

; CWE-783: `!a == b` negates `a`, and `a & b == c` compares before masking.
(binary_expression
  left: (unary_expression
    operator: "!")
  operator: ["==" "!="]) @finding.precedence-trap

(binary_expression
  operator: ["&" "|" "^"]
  right: (binary_expression
    operator: ["==" "!=" "<" ">" "<=" ">="])) @finding.precedence-trap

(binary_expression
  left: (binary_expression
    operator: ["==" "!=" "<" ">" "<=" ">="])
  operator: ["&" "|" "^"]) @finding.precedence-trap

; CWE-397: declaring or throwing the root exception types.
((throws
  (type_identifier) @_type) @finding.generic-throw
  (#any-of? @_type "Exception" "Throwable"))

((throw_statement
  (object_creation_expression
    type: (type_identifier) @_type)) @finding.generic-throw
  (#any-of? @_type "Exception" "Throwable" "RuntimeException"))

; CWE-484: a case group whose last statement is an ordinary statement, followed by another group.
(switch_block
  (switch_block_statement_group
    [(expression_statement) (local_variable_declaration)]
    .) @finding.switch-fallthrough
  .
  (switch_block_statement_group))

; CWE-478: a switch without a default label.
(switch_expression) @finding.missing-default

((switch_label) @unless.missing-default
  (#eq? @unless.missing-default "default"))

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

(binary_expression
  operator: "+") @string.built

((method_invocation
  name: (identifier) @_method) @string.built
  (#any-of? @_method "format" "formatted"))

[
  (if_statement)
  (for_statement)
  (enhanced_for_statement)
  (while_statement)
  (do_statement)
  (try_statement)
  (switch_expression)
] @control.outer

(if_statement
  alternative: (if_statement) @control.chain)

[
  (if_statement)
  (for_statement)
  (enhanced_for_statement)
  (while_statement)
  (do_statement)
  (catch_clause)
  (ternary_expression)
  (switch_block_statement_group)
] @decision.point

(binary_expression
  operator: ["&&" "||"]) @decision.point

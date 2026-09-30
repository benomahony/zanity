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

; An element read with a constant or a name, one or two deep, so a message can show `d['id']`
; rather than all of `d`.
(subscript
  value: [
    (identifier)
    (attribute)
  ]
  subscript: [
    (string)
    (integer)
    (identifier)
    (attribute)
  ]) @expression.path

(subscript
  value: (subscript
    value: [
      (identifier)
      (attribute)
    ]
    subscript: [
      (string)
      (integer)
      (identifier)
      (attribute)
    ])
  subscript: [
    (string)
    (integer)
    (identifier)
    (attribute)
  ]) @expression.path

; Code that may not run when the expression around it does, so reading it again in a message
; could fail where the expression did not: `d[k]` in `k in d and d[k] > 0`.
(boolean_operator
  right: (_) @expression.conditional)

[
  (conditional_expression)
  (list_comprehension)
  (set_comprehension)
  (dictionary_comprehension)
  (generator_expression)
  (lambda)
] @expression.conditional

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

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(string) @literal.string

; CWE-1071: a body that is only `pass`. Function and class stubs are left alone, and so is a
; body with a comment, which the grammar puts just before the block.
[
  (if_statement
    condition: (_)
    .
    consequence: (block . (pass_statement) .))
  (elif_clause
    condition: (_)
    .
    consequence: (block . (pass_statement) .))
  (else_clause
    .
    body: (block . (pass_statement) .))
  (for_statement
    right: (_)
    .
    body: (block . (pass_statement) .))
  (while_statement
    condition: (_)
    .
    body: (block . (pass_statement) .))
  (with_statement
    (with_clause)
    .
    body: (block . (pass_statement) .))
] @finding.empty-block

; CWE-570, CWE-571: a condition that is a literal. `while True` is unbounded-loop's.
[
  (if_statement
    condition: [(true) (false) (none) (integer) (float) (string)])
  (elif_clause
    condition: [(true) (false) (none) (integer) (float) (string)])
  (while_statement
    condition: [(false) (none)])
] @finding.constant-condition

; CWE-1077: exact equality with a floating-point literal other than zero.
((comparison_operator
  ["==" "!="]
  (float) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0"))

((comparison_operator
  (float) @_float
  ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0"))

; CWE-480: a comparison whose result is thrown away.
(block
  (comparison_operator) @finding.discarded-comparison)

(module
  (comparison_operator) @finding.discarded-comparison)

; CWE-561: the statement right after one that always leaves the block.
(block
  [
    (return_statement)
    (raise_statement)
    (break_statement)
    (continue_statement)
  ]
  .
  (_) @finding.unreachable-code)

; CWE-396: a bare `except:` or one naming the root exception types.
(except_clause
  !value) @finding.generic-catch

((except_clause
  value: [
    (identifier) @_type
    (as_pattern
      .
      (identifier) @_type)
  ]) @finding.generic-catch
  (#any-of? @_type "Exception" "BaseException"))

; The message of a raised exception, for the error-message rules.
(raise_statement
  (call
    arguments: (argument_list
      .
      (string) @error.message)))

; CWE-584: a return inside finally replaces the exception or return already under way.
((return_statement) @finding.return-in-finally
  (#has-ancestor? @finding.return-in-finally finally_clause))

; CWE-595: `is` compares identity; with a literal, equal values can compare unequal.
(comparison_operator
  (_)
  ["is" "is not"]
  [(string) (integer) (float)]) @finding.identity-comparison

; CWE-397: raising the root exception types.
((raise_statement
  [
    (call
      function: (identifier) @_type)
    (identifier) @_type
  ]) @finding.generic-throw
  (#any-of? @_type "Exception" "BaseException"))

; CWE-1164: a bare name, attribute or number as a statement. Strings are left alone: they document.
(block
  [(identifier) (attribute) (integer) (float)] @finding.no-effect-statement)

; CWE-295: requests and httpx calls with certificate checks turned off.
((keyword_argument
  name: (identifier) @_name
  value: (false)) @finding.tls-verification-disabled
  (#eq? @_name "verify"))

; CWE-478: a match statement without a `case _:` catch-all.
(match_statement) @finding.missing-default

((case_clause
  (case_pattern) @unless.missing-default)
  (#eq? @unless.missing-default "_"))

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), async functions and calls made as statements (unawaited calls), nesting and decisions.
(binary_operator
  operator: "-") @arith.difference

(binary_operator
  operator: ["+" "%"]) @string.built

((call
  function: (attribute
    attribute: (identifier) @_method)) @string.built
  (#eq? @_method "format"))

(function_definition
  "async"
  name: (identifier) @async.name)

(block
  (call
    function: (_) @statement.call))

[
  (if_statement)
  (for_statement)
  (while_statement)
  (try_statement)
  (with_statement)
  (match_statement)
] @control.outer

[
  (if_statement)
  (elif_clause)
  (for_statement)
  (while_statement)
  (except_clause)
  (case_clause)
  (conditional_expression)
  (boolean_operator)
  (for_in_clause)
  (if_clause)
] @decision.point

; A check a test makes through unittest, so a test's checks can be counted. `assert` itself is
; already an assertion.
((call
  function: (attribute
    object: (identifier) @_self
    attribute: (identifier) @_check)) @test.check
  (#eq? @_self "self")
  (#any-of? @_check "assertEqual" "assertNotEqual" "assertTrue" "assertFalse" "assertIs" "assertIsNot" "assertIsNone" "assertIsNotNone" "assertIn" "assertNotIn" "assertIsInstance" "assertNotIsInstance" "assertRaises" "assertRaisesRegex" "assertAlmostEqual" "assertNotAlmostEqual" "assertGreater" "assertGreaterEqual" "assertLess" "assertLessEqual" "assertRegex" "assertNotRegex" "assertCountEqual" "assertDictEqual" "assertListEqual" "assertSetEqual" "assertTupleEqual" "assertSequenceEqual" "assertMultiLineEqual" "fail"))

; Statements that change state shared beyond a test: a global, or the process environment.
(global_statement) @test.shared_state

((assignment
  left: (subscript
    value: (attribute
      object: (identifier) @_os
      attribute: (identifier) @_environ))) @test.shared_state
  (#eq? @_os "os")
  (#eq? @_environ "environ"))

((delete_statement
  (subscript
    value: (attribute
      object: (identifier) @_os
      attribute: (identifier) @_environ))) @test.shared_state
  (#eq? @_os "os")
  (#eq? @_environ "environ"))

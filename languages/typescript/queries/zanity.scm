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

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(string) @literal.string

; CWE-1071: an empty body with not even a comment. Empty catch bodies are swallowed-error's.
([
  (if_statement
    consequence: (statement_block) @_body)
  (else_clause
    (statement_block) @_body)
  (for_statement
    body: (statement_block) @_body)
  (for_in_statement
    body: (statement_block) @_body)
  (while_statement
    body: (statement_block) @_body)
  (do_statement
    body: (statement_block) @_body)
] @finding.empty-block
  (#empty? @_body))

; CWE-570, CWE-571: a condition that is a literal. `while (true)` is unbounded-loop's.
(if_statement
  condition: (parenthesized_expression
    [(true) (false) (null) (undefined) (number) (string)])) @finding.constant-condition

(while_statement
  condition: (parenthesized_expression
    [(false) (null) (undefined)])) @finding.constant-condition

(ternary_expression
  condition: [(true) (false) (null) (undefined)]) @finding.constant-condition

; CWE-480: a comparison whose result is thrown away.
(expression_statement
  (binary_expression
    operator: ["==" "===" "!=" "!==" "<" ">" "<=" ">="]) @finding.discarded-comparison)

; CWE-561: the statement right after one that always leaves the block.
; Function and class declarations are hoisted, so they still take effect and are not listed.
; One pattern per way of leaving, and a kind check on the next statement, rather than an
; alternation on each side: the query engine tracks an alternation one state per kind through
; every nested block, which made this the costliest TypeScript pattern.
(statement_block
  (return_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(statement_block
  (throw_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(statement_block
  (break_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(statement_block
  (continue_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(switch_case
  (return_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(switch_case
  (throw_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(switch_case
  (break_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(switch_case
  (continue_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "expression_statement" "lexical_declaration" "variable_declaration" "if_statement" "for_statement" "for_in_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement"))

(debugger_statement) @finding.debug-leftover

; The message of a thrown error, for the error-message rules.
(throw_statement
  (new_expression
    arguments: (arguments
      .
      (string) @error.message)))

; CWE-584: a return inside finally replaces the exception or return already under way.
((return_statement) @finding.return-in-finally
  (#has-ancestor? @finding.return-in-finally finally_clause))

; CWE-783: `!a == b` negates `a`, and `a & b == c` compares before masking.
(binary_expression
  left: (unary_expression
    operator: "!")
  operator: ["==" "===" "!=" "!=="]) @finding.precedence-trap

(binary_expression
  operator: ["&" "|" "^"]
  right: (binary_expression
    operator: ["==" "===" "!=" "!==" "<" ">" "<=" ">="])) @finding.precedence-trap

(binary_expression
  left: (binary_expression
    operator: ["==" "===" "!=" "!==" "<" ">" "<=" ">="])
  operator: ["&" "|" "^"]) @finding.precedence-trap

; CWE-484: a case whose last statement is an ordinary statement, followed by another case.
; A trailing comment such as `// falls through` is the last child instead, so it is not reported.
(switch_body
  (switch_case
    [(expression_statement) (lexical_declaration)]
    .) @finding.switch-fallthrough
  .
  [(switch_case) (switch_default)])

; CWE-478: a switch without a default case.
(switch_statement) @finding.missing-default

(switch_default) @unless.missing-default

; CWE-1164: a bare name, property access or number as a statement.
(expression_statement
  [(identifier) (member_expression) (number)] @finding.no-effect-statement)

; CWE-295: Node's TLS options with certificate checks turned off.
((pair
  key: (property_identifier) @_key
  value: (false)) @finding.tls-verification-disabled
  (#eq? @_key "rejectUnauthorized"))

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), async functions and calls made as statements (unawaited calls), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

(binary_expression
  operator: "+") @string.built

(template_string
  (template_substitution)) @string.built

(function_declaration
  "async"
  name: (identifier) @async.name)

(method_definition
  "async"
  name: (property_identifier) @async.name)

(variable_declarator
  name: (identifier) @async.name
  value: (arrow_function
    "async"))

(expression_statement
  (call_expression
    function: (_) @statement.call))

[
  (if_statement)
  (for_statement)
  (for_in_statement)
  (while_statement)
  (do_statement)
  (try_statement)
  (switch_statement)
] @control.outer

(else_clause
  (if_statement) @control.chain)

[
  (if_statement)
  (for_statement)
  (for_in_statement)
  (while_statement)
  (do_statement)
  (switch_case)
  (catch_clause)
  (ternary_expression)
] @decision.point

(binary_expression
  operator: ["&&" "||" "??"]) @decision.point

; A local declared with let or const as a statement of a block, and the blocks it could move
; into. var is scoped to the whole function, so it is left out.
(statement_block
  (lexical_declaration
    (variable_declarator
      name: (identifier) @declaration.name)) @declaration.outer)

(statement_block) @declaration.block

; A class body's methods run later, so a local moved into one would be made at a different time.
(class_body) @declaration.barrier

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (call_expression)
  (new_expression)
  (await_expression)
  (yield_expression)
  (assignment_expression)
  (augmented_assignment_expression)
  (update_expression)
] @declaration.effect

; A check a test makes, `expect(x).toBe(y)` or `assert.equal(x, y)`, so a test's checks can be
; counted.
(call_expression
  function: (member_expression
    object: [
      (call_expression
        function: (identifier) @_expect)
      (member_expression
        object: (call_expression
          function: (identifier) @_expect))
    ])
  (#eq? @_expect "expect")) @test.check

((call_expression
  function: (member_expression
    object: (identifier) @_assert)) @test.check
  (#eq? @_assert "assert"))

; An assignment to the process environment, which changes it for every test after this one.
((assignment_expression
  left: [
    (member_expression
      object: (member_expression
        object: (identifier) @_process
        property: (property_identifier) @_env))
    (subscript_expression
      object: (member_expression
        object: (identifier) @_process
        property: (property_identifier) @_env))
  ]) @test.shared_state
  (#eq? @_process "process")
  (#eq? @_env "env"))

; A test or suite turned off: `it.skip`, `describe.skip`, `test.skip`, or the `x`-prefixed forms.
((call_expression
  function: (member_expression
    object: (identifier) @_suite
    property: (property_identifier) @_skip)
  arguments: (arguments)) @finding.skipped-test
  (#any-of? @_suite "it" "test" "describe" "suite" "context")
  (#eq? @_skip "skip"))

((call_expression
  function: (identifier) @_skipped
  arguments: (arguments)) @finding.skipped-test
  (#any-of? @_skipped "xit" "xtest" "xdescribe" "xcontext"))

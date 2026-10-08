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

(identifier) @expression.path

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

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

[
  (string_literal)
  (raw_string_literal)
] @literal.string

[
  (integer_literal)
  (float_literal)
  (char_literal)
  (boolean_literal)
] @literal.constant

; Textobjects capture `let` and plain assignments; constants and statics are added here.
[
  (const_item
    name: (identifier) @assignment.lhs
    value: (_) @assignment.rhs)
  (static_item
    name: (identifier) @assignment.lhs
    value: (_) @assignment.rhs)
] @assignment.outer

; CWE-1071: an empty body with not even a comment.
([
  (if_expression
    consequence: (block) @_body)
  (else_clause
    (block) @_body)
  (for_expression
    body: (block) @_body)
  (while_expression
    body: (block) @_body)
] @finding.empty-block
  (#empty? @_body))

; CWE-570, CWE-571: a condition that is a literal. `while true` is unbounded-loop's.
(if_expression
  condition: (boolean_literal)) @finding.constant-condition

((while_expression
  condition: (boolean_literal) @_value) @finding.constant-condition
  (#eq? @_value "false"))

; CWE-1077: exact equality with a floating-point literal other than zero.
((binary_expression
  operator: ["==" "!="]
  right: (float_literal) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." "0.0f32" "0.0f64" "0f32" "0f64"))

((binary_expression
  left: (float_literal) @_float
  operator: ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." "0.0f32" "0.0f64" "0f32" "0f64"))

; CWE-480: a comparison whose result is thrown away.
(expression_statement
  (binary_expression
    operator: ["==" "!=" "<" ">" "<=" ">="]) @finding.discarded-comparison)

; CWE-561: the statement right after one that always leaves the block. Items still take effect.
(block
  (expression_statement
    [
      (return_expression)
      (break_expression)
      (continue_expression)
    ])
  .
  [
    (expression_statement)
    (let_declaration)
  ] @finding.unreachable-code)

; CWE-489: `dbg!` dumps its argument to stderr.
((macro_invocation
  macro: (identifier) @_macro) @finding.debug-leftover
  (#eq? @_macro "dbg"))

; The message of a panic and its relatives, for the error-message rules.
((macro_invocation
  macro: (identifier) @_macro
  (token_tree
    .
    (string_literal) @error.message))
  (#any-of? @_macro "panic" "unreachable" "todo" "unimplemented" "bail" "anyhow"))

; CWE-1164: a bare name, field access or number as a statement.
(expression_statement
  [(identifier) (field_expression) (integer_literal) (float_literal)] @finding.no-effect-statement)

; CWE-295: reqwest and native-tls builders with certificate checks turned off.
((call_expression
  function: (field_expression
    field: (field_identifier) @_method)
  arguments: (arguments
    (boolean_literal) @_value)) @finding.tls-verification-disabled
  (#any-of? @_method "danger_accept_invalid_certs" "danger_accept_invalid_hostnames")
  (#eq? @_value "true"))

; Shapes the engine measures: subtractions (wall-clock durations), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

[
  (if_expression)
  (for_expression)
  (while_expression)
  (loop_expression)
  (match_expression)
] @control.outer

(else_clause
  (if_expression) @control.chain)

[
  (if_expression)
  (for_expression)
  (while_expression)
  (match_arm)
] @decision.point

(binary_expression
  operator: ["&&" "||"]) @decision.point

; A local declared as a statement of a block, and the blocks it could move into.
(block
  (let_declaration
    pattern: (identifier) @declaration.name) @declaration.outer)

(block) @declaration.block

; Code that runs later, so a local moved into it would be made at a different time.
[
  (closure_expression)
  (async_block)
] @declaration.barrier

; An initializer that can leave the block, so moving it would skip or change what comes after.
[
  (return_expression)
  (break_expression)
  (continue_expression)
  (try_expression)
] @declaration.exit

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (call_expression)
  (macro_invocation)
  (await_expression)
  (assignment_expression)
  (compound_assignment_expr)
  (unsafe_block)
] @declaration.effect

; A test turned off with #[ignore], which `cargo test` skips unless asked.
((attribute_item
  (attribute
    (identifier) @_ignore)) @finding.skipped-test
  (#eq? @_ignore "ignore"))

; A test that expects any panic at all, so it passes when the code panics for the wrong reason:
; #[should_panic] without `expected = "..."`.
((attribute_item
  (attribute
    (identifier) @_panic
    .)) @finding.broad-expected-error
  (#eq? @_panic "should_panic"))

; A member access, so chains of them can be measured.
(field_expression) @chain.link

; Expressions whose copies within a function are duplication: calls, member accesses, indexing
; and arithmetic.
[
  (call_expression)
  (field_expression)
  (index_expression)
  (binary_expression)
] @expression.repeatable

; What an assignment or increment writes to, so an expression that reads it is known to change.
[
  (assignment_expression
    left: (_) @write.target)
  (compound_assignment_expr
    left: (_) @write.target)
]

; A call made for its effect, its value discarded: copies of it each do something.
[
  (expression_statement
    (call_expression) @call.discarded)
  (expression_statement
    (try_expression
      (call_expression) @call.discarded))
  (expression_statement
    (await_expression
      (call_expression) @call.discarded))
]

; A returned value: each early return computes it once, on its own way out.
(return_expression
  (_) @expression.returned)

; `pub`, so code outside the module can use it.
(_
  (visibility_modifier)) @visibility.public

; Names the code refers to, for dead-symbol: every name other than where it is defined.
[
  (identifier)
  (field_identifier)
  (type_identifier)
] @reference.name

; Traits, and what types implement them, for single-impl-abstraction.
(trait_item
  name: (type_identifier) @abstraction.name)

(impl_item
  trait: [
    (type_identifier) @implementation.base
    (generic_type
      type: (type_identifier) @implementation.base)
    (scoped_type_identifier
      name: (type_identifier) @implementation.base)
  ])

; Statements that leave the block they are in, so code holding one can't move into a function.
[
  (return_expression)
  (break_expression)
  (continue_expression)
] @flow.exit

; A method of a trait's implementation is called through the trait.
(impl_item
  trait: (_)
  body: (declaration_list
    (function_item) @visibility.public))

; CWE-369: a literal zero divisor.
((binary_expression
  operator: ["/" "%"]
  right: [(integer_literal) (float_literal)] @_zero_divisor) @finding.divide-by-zero
  (#any-of? @_zero_divisor "0" "00" "0.0" "0." "0x0" "0o0" "0b0"))

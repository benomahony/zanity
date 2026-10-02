(function_declaration
  name: (identifier) @function.name
  body: (block))

(call_expression
  function: (_) @call.callee)

(call_expression
  function: (identifier) @call.name)

(call_expression
  function: (field_expression
    object: (_) @call.receiver
    member: (identifier) @call.name))

(call_expression
  arguments: (arguments
    (_) @call.argument))

(while_statement
  condition: (_) @loop.condition)

(for_statement
  .
  (_) @loop.iterable)

((boolean) @literal.true
  (#eq? @literal.true "true"))

((call_expression
  function: [
    (identifier) @_assert
    (field_expression
      member: (identifier) @_assert)
  ]
  arguments: (arguments
    .
    (_) @assertion.condition)) @assertion.outer
  (#eq? @_assert "assert"))

; The asserting form Zig recommends when a failure needs to explain itself:
; `if (!ok) std.debug.panic("expected {d} got {d}", .{ want, got });` or `@panic("...")`,
; as a statement, a loop body or a comptime check. Either polarity asserts: the branch only panics.
((if_statement
  condition: (_) @assertion.condition
  body: [
    (call_expression
      function: (field_expression
        member: (identifier) @_panic)
      arguments: (arguments
        .
        (_) @assertion.message))
    (builtin_function
      (builtin_identifier) @_panic
      (arguments
        .
        (_) @assertion.message))
    (block_expression
      (block
        .
        (expression_statement
          [
            (call_expression
              function: (field_expression
                member: (identifier) @_panic)
              arguments: (arguments
                .
                (_) @assertion.message))
            (builtin_function
              (builtin_identifier) @_panic
              (arguments
                .
                (_) @assertion.message))
          ])
        .))
  ]) @assertion.outer
  (#any-of? @_panic "panic" "@panic" "@compileError"))

((if_expression
  condition: (_) @assertion.condition
  [
    (call_expression
      function: (field_expression
        member: (identifier) @_panic)
      arguments: (arguments
        .
        (_) @assertion.message))
    (builtin_function
      (builtin_identifier) @_panic
      (arguments
        .
        (_) @assertion.message))
    (block_expression
      (block
        .
        (expression_statement
          [
            (call_expression
              function: (field_expression
                member: (identifier) @_panic)
              arguments: (arguments
                .
                (_) @assertion.message))
            (builtin_function
              (builtin_identifier) @_panic
              (arguments
                .
                (_) @assertion.message))
          ])
        .))
  ]) @assertion.outer
  (#any-of? @_panic "panic" "@panic" "@compileError"))

(assignment_expression
  left: (_) @assignment.lhs
  operator: "="
  right: _ @assignment.rhs) @assignment.outer

(variable_declaration
  (identifier) @assignment.lhs
  "="
  _ @assignment.rhs) @assignment.outer

[
  (integer)
  (float)
  (string)
  (multiline_string)
  (boolean)
  "null"
] @literal.constant

((boolean) @literal.falsy
  (#eq? @literal.falsy "false"))

((integer) @literal.falsy
  (#any-of? @literal.falsy "0" "0x0" "0b0" "0o0"))

"null" @literal.falsy

"null" @literal.none

(anonymous_struct_initializer) @literal.collection

[
  (identifier)
  (field_expression)
] @expression.path

; An element read with a constant or a name, so a message can show `items[i]` rather than all
; of `items`.
(index_expression
  object: [
    (identifier)
    (field_expression)
  ]
  index: [
    (identifier)
    (integer)
    (field_expression)
  ]) @expression.path

; Code that may not run when the expression around it does, so reading it again in a message
; could fail where the expression did not: `items[i]` in `i < items.len and items[i] > 0`.
(binary_expression
  operator: [
    "and"
    "or"
  ]
  right: (_) @expression.conditional)

[
  (if_expression)
  (switch_expression)
] @expression.conditional

(binary_expression
  left: (_) @compare.subject
  operator: "!="
  right: "null") @compare.not_null

(binary_expression
  left: (_) @compare.subject
  operator: "=="
  right: _ @compare.value) @compare.equal

(function_declaration
  (parameters
    (parameter) @function.parameter))

(function_declaration
  body: (block
    .
    (expression_statement
      [
        (call_expression)
        (return_expression
          (call_expression))
        (return_expression
          (try_expression
            (call_expression)))
      ])
    .)) @function.passthrough

(catch_expression
  (block
    .
    "{"
    .
    "}"
    .) @catch.swallowed)

(test_declaration) @test.outer

(function_declaration
  name: (identifier) @name) @definition.function

; The value is anchored right after `=`, allowing one comment between: left unanchored, the
; query engine keeps every enclosing declaration's match open through the whole container it
; defines, which in Zig is often the rest of the file. The anchor also leaves out a container
; that is only a variable's type, as in `const state: enum { a, b } = .a`.
(variable_declaration
  (identifier) @name
  "="
  .
  (comment)?
  .
  [
    (struct_declaration)
    (enum_declaration)
    (union_declaration)
    (opaque_declaration)
  ]) @definition.class

(source_file
  (variable_declaration
    (identifier) @name
    "="
    .
    (comment)?
    .
    [
      (integer)
      (float)
      (string)
      (multiline_string)
      (boolean)
    ]) @definition.constant)

[
  (while_statement)
  (for_statement)
] @loop.outer

(function_declaration) @function.outer

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(string) @literal.string

; CWE-1071: an empty body with not even a comment.
([
  (if_statement
    body: (block_expression
      (block) @_body))
  (while_statement
    body: (block_expression
      (block) @_body))
  (for_statement
    body: (block_expression
      (block) @_body))
  (else_clause
    alternative: (labeled_statement
      (block) @_body))
] @finding.empty-block
  (#empty? @_body))

; CWE-570, CWE-571: a condition that is a literal. `while (true)` is unbounded-loop's.
[
  (if_statement
    condition: (boolean))
  (if_expression
    condition: (boolean))
] @finding.constant-condition

((while_statement
  condition: (boolean) @_value) @finding.constant-condition
  (#eq? @_value "false"))

; CWE-1077: exact equality with a floating-point literal other than zero.
((binary_expression
  operator: ["==" "!="]
  right: (float) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0"))

((binary_expression
  left: (float) @_float
  operator: ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0"))

; CWE-489: `@breakpoint()` stops the program for a debugger.
((builtin_function
  (builtin_identifier) @_builtin) @finding.debug-leftover
  (#eq? @_builtin "@breakpoint"))

; The message of a panic outside an assertion, for the error-message rules.
((builtin_function
  (builtin_identifier) @_builtin
  (arguments
    .
    (string) @error.message))
  (#any-of? @_builtin "@panic" "@compileError"))

; Shapes the engine measures: subtractions (wall-clock durations), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

[
  (if_statement)
  (while_statement)
  (for_statement)
  (switch_expression)
] @control.outer

(else_clause
  alternative: (if_statement) @control.chain)

[
  (if_statement)
  (if_expression)
  (while_statement)
  (for_statement)
  (switch_case)
] @decision.point

(binary_expression
  operator: ["and" "or"]) @decision.point

; A local declared as a statement of a block, and the blocks it could move into. This grammar
; parses an assignment such as `a += b` as a variable_declaration too, so the name must follow
; `const` or `var`.
(block
  (variable_declaration
    ["const" "var"]
    .
    (identifier) @declaration.name) @declaration.outer)

(block) @declaration.block

; Code that runs once per iteration, or later, so a local moved into it is made at a different time.
[
  (for_expression)
  (while_expression)
  (defer_statement)
  (errdefer_statement)
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
  (builtin_function)
  (assignment_expression)
] @declaration.effect

; A check a test makes through std.testing, so a test's checks can be counted.
((call_expression
  function: (field_expression
    member: (identifier) @_check)) @test.check
  (#any-of? @_check "expect" "expectEqual" "expectEqualStrings" "expectEqualSlices" "expectEqualDeep" "expectError" "expectApproxEqAbs" "expectApproxEqRel" "expectFmt" "expectStringStartsWith" "expectStringEndsWith"))

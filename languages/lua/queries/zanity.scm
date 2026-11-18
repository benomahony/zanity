(function_declaration
  name: (identifier) @function.name)

(function_declaration
  name: (dot_index_expression
    field: (identifier) @function.name))

; `function Tree:walk()` takes the table it is called on as `self`, so it is a method.
(function_declaration
  name: (method_index_expression
    method: (identifier) @function.name)) @function.method

; A function stored under a name, `local f = function() end` or `M.f = function() end`, and one
; written as a field of a table, `{ setup = function() end }`. The value list is part of the
; function too, so the function it holds is this one rather than an unnamed one inside it.
(assignment_statement
  (variable_list
    .
    name: [
      (identifier) @function.name
      (dot_index_expression
        field: (identifier) @function.name)
    ]
    .)
  (expression_list
    .
    value: (function_definition)
    .) @function.outer) @function.outer

(field
  name: (identifier) @function.name
  value: (function_definition)) @function.outer

(parameters
  [
    (identifier)
    (vararg_expression)
  ] @function.parameter)

(parameters
  (identifier) @parameter.name)

([
  (function_declaration
    body: (block
      .
      [
        (function_call)
        (return_statement
          (expression_list
            .
            (function_call)
            .))
      ]
      .))
  (function_definition
    body: (block
      .
      [
        (function_call)
        (return_statement
          (expression_list
            .
            (function_call)
            .))
      ]
      .))
] @function.passthrough)

(function_call
  name: (_) @call.callee)

(function_call
  name: (identifier) @call.name)

(function_call
  name: (dot_index_expression
    table: (_) @call.receiver
    field: (identifier) @call.name))

(function_call
  name: (method_index_expression
    table: (_) @call.receiver
    method: (identifier) @call.name))

(function_call
  arguments: (arguments
    (_) @call.argument))

(while_statement
  condition: (_) @loop.condition)

; `repeat ... until false` never stops, so its condition is left uncaptured, as a loop with no
; condition is.
((repeat_statement
  condition: (_) @loop.condition)
  (#not-kind-eq? @loop.condition "false" "nil"))

(for_generic_clause
  (expression_list) @loop.iterable)

(for_numeric_clause) @loop.iterable

(true) @literal.true

((function_call
  name: (identifier) @_assert
  arguments: (arguments
    .
    (_) @assertion.condition)) @assertion.outer
  (#eq? @_assert "assert"))

((function_call
  name: (identifier) @_assert
  arguments: (arguments
    .
    (_)
    .
    (_) @assertion.message))
  (#eq? @_assert "assert"))

; A call that runs code and throws its error away: `pcall(f)` as a statement, whose status no
; one reads.
([
  (block
    (function_call
      name: (identifier) @_protected) @catch.swallowed)
  (chunk
    (function_call
      name: (identifier) @_protected) @catch.swallowed)
]
  (#any-of? @_protected "pcall" "xpcall"))

; An xpcall whose handler does nothing, and a function named as an error handler whose body is
; empty: each drops every error passed to it.
((function_call
  name: (identifier) @_xpcall
  arguments: (arguments
    (_)
    .
    (function_definition
      parameters: (parameters)
      .) @catch.swallowed))
  (#eq? @_xpcall "xpcall"))

((function_declaration
  name: [
    (identifier) @_handler
    (dot_index_expression
      field: (identifier) @_handler)
    (method_index_expression
      method: (identifier) @_handler)
  ]
  parameters: (parameters)
  .) @catch.swallowed
  (#any-word? @_handler "except" "exception" "catch" "rescue" "error" "err"))

; A busted test, `it("name", function() ... end)`.
((function_call
  name: (identifier) @_test
  arguments: (arguments
    .
    (string) @test.name
    .
    (function_definition))) @test.outer
  (#any-of? @_test "it" "test" "spec"))

[
  (string)
  (number)
  (true)
  (false)
  (nil)
] @literal.constant

; Only false and nil are falsy: 0 and "" are true.
[
  (false)
  (nil)
] @literal.falsy

(nil) @literal.none

(table_constructor) @literal.collection

; A string formatted from values, `string.format(...)` or `("..."):format(...)`.
((function_call
  name: (dot_index_expression
    table: (identifier) @_string
    field: (identifier) @_format)) @string.format
  (#eq? @_string "string")
  (#eq? @_format "format"))

((function_call
  name: (method_index_expression
    method: (identifier) @_format)) @string.format
  (#eq? @_format "format"))

[
  (identifier)
  (dot_index_expression)
] @expression.path

; An element read with a constant or a name, so a message can show `t["id"]` rather than all of `t`.
(bracket_index_expression
  table: [
    (identifier)
    (dot_index_expression)
  ]
  field: [
    (string)
    (number)
    (identifier)
    (dot_index_expression)
  ]) @expression.path

; Code that may not run when the expression around it does: `t[k]` in `t and t[k] > 0`.
(binary_expression
  operator: [
    "and"
    "or"
  ]
  right: (_) @expression.conditional)

(function_definition) @expression.conditional

(binary_expression
  left: (_) @compare.subject
  operator: "~="
  right: (nil)) @compare.not_null

((binary_expression
  left: (_) @compare.subject
  operator: ">="
  right: (number) @_zero) @compare.non_negative
  (#eq? @_zero "0"))

((binary_expression
  left: (_) @compare.subject
  operator: ">"
  right: (unary_expression
    operator: "-"
    operand: (number) @_one)) @compare.non_negative
  (#eq? @_one "1"))

(binary_expression
  left: (_) @compare.subject
  operator: "=="
  right: (_) @compare.value) @compare.equal

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

(string) @literal.string

; CWE-1071: a body with no statement and not even a comment, which the grammar puts in the
; statement rather than in a block. A comment in an empty elseif or else belongs to the if around
; it, after that branch, so the branch must be followed by the next one or the end.
[
  (if_statement
    condition: (_)
    .)
  (if_statement
    condition: (_)
    .
    alternative: (_))
  (for_statement
    clause: (_)
    .)
  (while_statement
    condition: (_)
    .)
  (repeat_statement
    .
    condition: (_))
] @finding.empty-block

(if_statement
  (elseif_statement
    condition: (_)
    .) @finding.empty-block
  .
  [
    (elseif_statement)
    (else_statement)
  ])

(if_statement
  (elseif_statement
    condition: (_)
    .) @finding.empty-block
  .)

((if_statement
  (else_statement) @finding.empty-block
  .)
  (#empty? @finding.empty-block))

; CWE-570, CWE-571: a condition that is a literal. `while true` is unbounded-loop's.
(if_statement
  condition: [
    (true)
    (false)
    (nil)
    (number)
    (string)
  ]) @finding.constant-condition

(elseif_statement
  condition: [
    (true)
    (false)
    (nil)
    (number)
    (string)
  ]) @finding.constant-condition

(while_statement
  condition: [
    (false)
    (nil)
  ]) @finding.constant-condition

; CWE-1077: exact equality with a fractional literal. Lua has one kind of number, so a fraction is
; told by its text: a digit and a point, as `0.1` and `3.14` are.
((binary_expression
  operator: [
    "=="
    "~="
  ]
  right: (number) @_float) @finding.float-equality
  (#any-prefix? @_float "0." "1." "2." "3." "4." "5." "6." "7." "8." "9." ".")
  (#not-any-of? @_float "0.0" "0." ".0"))

((binary_expression
  left: (number) @_float
  operator: [
    "=="
    "~="
  ]) @finding.float-equality
  (#any-prefix? @_float "0." "1." "2." "3." "4." "5." "6." "7." "8." "9." ".")
  (#not-any-of? @_float "0.0" "0." ".0"))

; CWE-561: the statement right after one that always leaves the block. A label after a jump is
; reachable through a goto, so it is left alone. Lua allows a return only as a block's last
; statement, so nothing can follow one.
(block
  (break_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "assignment_statement" "function_call" "variable_declaration" "function_declaration" "if_statement" "while_statement" "repeat_statement" "for_statement" "do_statement" "return_statement" "break_statement" "goto_statement"))

(block
  (goto_statement)
  .
  (_) @finding.unreachable-code
  (#kind-eq? @finding.unreachable-code "assignment_statement" "function_call" "variable_declaration" "function_declaration" "if_statement" "while_statement" "repeat_statement" "for_statement" "do_statement" "return_statement" "break_statement" "goto_statement"))

((block
  (function_call
    name: (identifier) @_error)
  .
  (_) @finding.unreachable-code)
  (#eq? @_error "error")
  (#kind-eq? @finding.unreachable-code "assignment_statement" "function_call" "variable_declaration" "function_declaration" "if_statement" "while_statement" "repeat_statement" "for_statement" "do_statement" "return_statement" "break_statement" "goto_statement"))

; CWE-783: `not a == b` negates `a` and compares the result, so it is never `not (a == b)`.
(binary_expression
  left: (unary_expression
    operator: "not")
  operator: [
    "=="
    "~="
    "<"
    ">"
    "<="
    ">="
  ]) @finding.precedence-trap

; CWE-1075: a jump. `goto continue` is how Lua, which has no continue statement, writes one.
((goto_statement
  (identifier) @_label) @finding.goto-statement
  (#not-eq? @_label "continue"))

; CWE-295: LuaSec's and lua-resty-http's options with certificate checks turned off.
((field
  name: (identifier) @_key
  value: (string
    content: (string_content) @_none)) @finding.tls-verification-disabled
  (#eq? @_key "verify")
  (#eq? @_none "none"))

((field
  name: (identifier) @_key
  value: (false)) @finding.tls-verification-disabled
  (#eq? @_key "ssl_verify"))

; CWE-369: a literal zero divisor.
((binary_expression
  operator: [
    "/"
    "//"
    "%"
  ]
  right: (number) @_zero_divisor) @finding.divide-by-zero
  (#any-of? @_zero_divisor "0" "00" "0.0" "0." ".0" "0x0"))

; CWE-1056: a named function that takes any number of arguments. An anonymous one is usually a
; wrapper, where `...` passes every call through unchanged.
(function_declaration
  parameters: (parameters
    (vararg_expression) @finding.variadic-parameter))

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), calls made as statements, nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

(binary_expression
  operator: "..") @string.built

[
  (block
    (function_call
      name: (_) @statement.call))
  (chunk
    (function_call
      name: (_) @statement.call))
]

[
  (if_statement)
  (for_statement)
  (while_statement)
  (repeat_statement)
] @control.outer

[
  (if_statement)
  (elseif_statement)
  (for_statement)
  (while_statement)
  (repeat_statement)
] @decision.point

(binary_expression
  operator: [
    "and"
    "or"
  ]) @decision.point

; A local declared as a statement of a block, and the blocks it could move into.
(block
  (variable_declaration
    [
      (assignment_statement
        (variable_list
          .
          name: (identifier) @declaration.name
          .))
      (variable_list
        .
        name: (identifier) @declaration.name
        .)
    ]) @declaration.outer)

(block) @declaration.block

; An initializer that does something besides compute a value, so --fix won't move it.
(function_call) @declaration.effect

; A check a test makes through luassert, `assert.are.equal(a, b)` or `assert.is_true(x)`, or
; through luaunit, `lu.assertEquals(a, b)`, so a test's checks can be counted.
((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
      (function_call
        name: (dot_index_expression
          table: (identifier) @_assert))
      (dot_index_expression
        table: (function_call
          name: (dot_index_expression
            table: (identifier) @_assert)))
    ])) @test.check
  (#eq? @_assert "assert"))

((function_call
  name: (dot_index_expression
    table: (identifier) @_luaunit
    field: (identifier) @_check)) @test.check
  (#any-of? @_luaunit "lu" "luaunit")
  (#any-prefix? @_check "assert" "fail"))

; A yes/no check of one comparison, which fails with "Expected objects to be the same" and hides
; both sides.
((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
    ]
    field: (identifier) @_check)
  arguments: (arguments
    .
    (binary_expression
      left: (_) @opaque.left
      operator: [
        "=="
        "~="
      ] @opaque.key
      right: (_) @opaque.right)
    .)) @finding.opaque-check
  (#eq? @_assert "assert")
  (#any-of? @_check "is_true" "True" "truthy" "is_truthy"))

((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
    ]
    field: (identifier) @_check)
  arguments: (arguments
    .
    (binary_expression
      left: (_) @opaque.left
      operator: [
        "=="
        "~="
      ] @opaque.key
      right: (_) @opaque.right)
    .)) @finding.opaque-check @opaque.negated
  (#eq? @_assert "assert")
  (#any-of? @_check "is_false" "False" "falsy" "is_falsy"))

; Statements that change state shared beyond a test: a global set through `_G`, or the module
; cache and search path every `require` reads.
((assignment_statement
  (variable_list
    name: [
      (dot_index_expression
        table: (identifier) @_shared)
      (bracket_index_expression
        table: (identifier) @_shared)
    ])) @test.shared_state
  (#eq? @_shared "_G"))

((assignment_statement
  (variable_list
    name: [
      (dot_index_expression
        table: (identifier) @_package
        field: (identifier) @_field)
      (bracket_index_expression
        table: (dot_index_expression
          table: (identifier) @_package
          field: (identifier) @_field))
    ])) @test.shared_state
  (#eq? @_package "package")
  (#any-of? @_field "path" "cpath" "loaded" "preload"))

; A test turned off with no condition: busted's `pending`, or luaunit's skip as the test body's
; own statement. A skip under an `if`, or luaunit's skipIf, says when the test can't run.
((function_call
  name: (identifier) @_pending) @finding.skipped-test
  (#eq? @_pending "pending"))

((function_declaration
  body: (block
    (function_call
      name: (dot_index_expression
        table: (identifier) @_luaunit
        field: (identifier) @_skip)) @finding.skipped-test))
  (#any-of? @_luaunit "lu" "luaunit")
  (#eq? @_skip "skip"))

; A test that expects any error at all, so it passes when the code fails for the wrong reason:
; luassert's `has_error(f)` with no error to match, or luaunit's assertError, which never takes one.
((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
    ]
    field: (identifier) @_raises)
  arguments: (arguments
    .
    (_)
    .)) @finding.broad-expected-error
  (#eq? @_assert "assert")
  (#any-of? @_raises "has_error" "has_errors" "error" "errors"))

((function_call
  name: (dot_index_expression
    table: (identifier) @_luaunit
    field: (identifier) @_raises)) @finding.broad-expected-error
  (#any-of? @_luaunit "lu" "luaunit")
  (#eq? @_raises "assertError"))

; A member access, so chains of them can be measured.
[
  (dot_index_expression)
  (method_index_expression)
] @chain.link

; Expressions whose copies within a function are duplication: calls, member accesses, indexing
; and arithmetic.
[
  (function_call)
  (dot_index_expression)
  (bracket_index_expression)
  (binary_expression)
] @expression.repeatable

; What an assignment writes to, so an expression that reads it is known to change.
(assignment_statement
  (variable_list
    name: (_) @write.target))

; A call made for its effect, its value discarded: copies of it each do something.
[
  (block
    (function_call) @call.discarded)
  (chunk
    (function_call) @call.discarded)
]

; A returned value: each early return computes it once, on its own way out.
(return_statement
  (expression_list
    (_) @expression.returned))

; A call whose result something else ends, such as a span: the caller it is returned to, or the
; table it is stored on.
[
  (return_statement
    (expression_list
      (function_call) @call.handed_off))
  (assignment_statement
    (variable_list
      name: [
        (dot_index_expression)
        (bracket_index_expression)
      ])
    (expression_list
      (function_call) @call.handed_off))
]

; A call whose results are unpacked into two names, as opentelemetry-lua's
; `local ctx, span = tracer:start(ctx, name)` gives a context and a span; not a value and its
; error, as in `local ok, err = conn:start()`.
((assignment_statement
  (variable_list
    .
    (_)
    .
    (_) @_second
    .)
  (expression_list
    .
    (function_call) @call.paired
    .))
  (#not-any-suffix? @_second "err" "Err"))

; The same with its first result thrown away, as in `local _, span = tracer:start(ctx, name)`.
((assignment_statement
  (variable_list
    .
    (identifier) @_first
    .
    (_)
    .)
  (expression_list
    .
    (function_call) @call.context_discarded
    .))
  (#eq? @_first "_"))

; The name a call's last result is bound to, such as the span a start returns.
(assignment_statement
  (variable_list
    (identifier) @binding.name
    .)
  (expression_list
    .
    (function_call) @binding.value
    .))

; A name stored on a table, which then owns what it holds.
(assignment_statement
  (variable_list
    name: [
      (dot_index_expression)
      (bracket_index_expression)
    ])
  (expression_list
    (identifier) @binding.handed_off))

; Names the code refers to, for dead-symbol: every name other than where it is defined.
(identifier) @reference.name

; A function written as a field of a table, `{ setup = function() end }`, or stored in a table held
; by another, `function M.actions.focus()`: whatever the table is handed to reaches it by its key.
(table_constructor
  (field
    name: (identifier)
    value: (function_definition))) @visibility.public

(function_declaration
  name: (dot_index_expression
    table: (dot_index_expression))) @visibility.public

(assignment_statement
  (variable_list
    .
    name: (dot_index_expression
      table: (dot_index_expression))
    .)
  (expression_list
    .
    value: (function_definition)
    .)) @visibility.public

; Statements that leave the block they are in, so code holding one can't move into a function.
[
  (return_statement)
  (break_statement)
  (goto_statement)
] @flow.exit

; Values checked by common test frameworks, for deterministic test-quality checks.

((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
    ]
    field: (identifier) @_check)
  arguments: (arguments
    .
    (_) @test.value
    .)) @test.constant
  (#eq? @_assert "assert")
  (#any-of? @_check "is_true" "True" "truthy" "is_truthy" "is_false" "False" "falsy" "is_falsy" "is_nil" "Nil" "is_not_nil"))

((function_call
  name: (dot_index_expression
    table: [
      (identifier) @_assert
      (dot_index_expression
        table: (identifier) @_assert)
    ]
    field: (identifier) @_check)
  arguments: (arguments
    .
    (_) @test.value
    .
    (_) @test.value)) @test.constant
  (#eq? @_assert "assert")
  (#any-of? @_check "equal" "equals" "same" "are_equal" "are_same" "is_equal" "is_same" "unique" "near"))

((function_call
  name: (dot_index_expression
    table: (identifier) @_luaunit
    field: (identifier) @_check)
  arguments: (arguments
    .
    (_) @test.value
    .)) @test.constant
  (#any-of? @_luaunit "lu" "luaunit")
  (#any-of? @_check "assertTrue" "assertFalse" "assertNil" "assertNotNil" "assertEvalToTrue" "assertEvalToFalse"))

((function_call
  name: (dot_index_expression
    table: (identifier) @_luaunit
    field: (identifier) @_check)
  arguments: (arguments
    .
    (_) @test.value
    .
    (_) @test.value)) @test.constant
  (#any-of? @_luaunit "lu" "luaunit")
  (#any-of? @_check "assertEquals" "assertNotEquals" "assertItemsEquals" "assertAlmostEquals"))

; A module's top-level requires, for cyclic-import: the module each names and the name it binds
; the whole module, or one of its members, to. A require inside a function runs when it is
; called, after every module has loaded, so it makes no cycle; and a bare `require("setup")` runs
; a file for its side effects without taking a name a finding could tell you to move.
(chunk
  (variable_declaration
    (assignment_statement
      (variable_list
        .
        name: (identifier) @import.binding
        .)
      (expression_list
        .
        value: (function_call
          name: (identifier) @_require
          arguments: (arguments
            .
            (string
              content: (string_content) @import.module)
            .))
        .))) @import.statement
  (#eq? @_require "require"))

(chunk
  (variable_declaration
    (assignment_statement
      (variable_list
        .
        name: (identifier)
        .)
      (expression_list
        .
        value: (dot_index_expression
          table: (function_call
            name: (identifier) @_require
            arguments: (arguments
              .
              (string
                content: (string_content) @import.module)
              .))
          field: (identifier) @import.name)
        .))) @import.statement
  (#eq? @_require "require"))

; A member read through a name, `billing.charge` or `billing:charge()`, so each import counts the
; names it supplies.
(dot_index_expression
  table: (identifier) @import.via
  field: (identifier) @import.used)

(method_index_expression
  table: (identifier) @import.via
  method: (identifier) @import.used)

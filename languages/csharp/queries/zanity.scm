[
  (method_declaration
    name: (identifier) @function.name)
  (constructor_declaration
    name: (identifier) @function.name)
  (destructor_declaration
    name: (identifier) @function.name)
  (local_function_statement
    name: (identifier) @function.name)
]

; A lambda's parameters are its own, not the enclosing method's. `params int[] rest`: the grammar
; puts a params parameter's type and name on the list itself.
[
  (method_declaration
    parameters: (parameter_list
      [
        (parameter) @function.parameter
        name: (identifier) @function.parameter
      ]))
  (constructor_declaration
    parameters: (parameter_list
      [
        (parameter) @function.parameter
        name: (identifier) @function.parameter
      ]))
  (local_function_statement
    parameters: (parameter_list
      [
        (parameter) @function.parameter
        name: (identifier) @function.parameter
      ]))
  (operator_declaration
    parameters: (parameter_list
      [
        (parameter) @function.parameter
        name: (identifier) @function.parameter
      ]))
]

(method_declaration
  body: (block
    .
    [
      (expression_statement
        (invocation_expression))
      (return_statement
        (invocation_expression))
    ]
    .)) @function.passthrough

(method_declaration
  body: (arrow_expression_clause
    (invocation_expression))) @function.passthrough

(invocation_expression
  function: [
    (identifier) @call.name
    (generic_name
      (identifier) @call.name)
    (member_access_expression
      expression: (_) @call.receiver
      name: [
        (identifier) @call.name
        (generic_name
          (identifier) @call.name)
      ])
  ])

; `new Random(42)` and `new Mock<IStore>()` call a constructor, so the type is the call's name.
(object_creation_expression
  type: [
    (identifier) @call.name
    (generic_name
      (identifier) @call.name)
    (qualified_name
      qualifier: (_) @call.receiver
      name: [
        (identifier) @call.name
        (generic_name
          (identifier) @call.name)
      ])
  ])

; A named argument, `retries: 3`, is its value.
(argument_list
  (argument
    (_) @call.argument
    .))

(while_statement
  condition: (_) @loop.condition)

(do_statement
  condition: (_) @loop.condition)

(for_statement
  condition: (_) @loop.condition)

(foreach_statement
  right: (_) @loop.iterable)

((boolean_literal) @literal.true
  (#eq? @literal.true "true"))

; Debug.Assert and Trace.Assert: the condition, then an optional message.
((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_class
    name: (identifier) @_assert)
  arguments: (argument_list
    .
    (argument
      (_) @assertion.condition))) @assertion.outer
  (#any-of? @_class "Debug" "Trace")
  (#eq? @_assert "Assert"))

((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_class
    name: (identifier) @_assert)
  arguments: (argument_list
    .
    (argument)
    .
    (argument
      (_) @assertion.message)))
  (#any-of? @_class "Debug" "Trace")
  (#eq? @_assert "Assert"))

; A guard clause, `if (x is null) throw new ArgumentNullException(nameof(x));`, fails loudly
; when its condition holds, as an assertion does. Its condition is a comparison, a pattern, a flag
; or a check such as `string.IsNullOrEmpty(x)`; an `if` around a call that does the work, as in
; `if (!cache.TryAdd(key, value)) throw ...`, is control flow, not a check on the state.
(if_statement
  condition: [
    (binary_expression)
    (is_pattern_expression)
    (identifier)
    (member_access_expression)
    (prefix_unary_expression
      [
        (identifier)
        (member_access_expression)
        (parenthesized_expression)
      ])
    (invocation_expression
      function: (member_access_expression
        expression: (predefined_type)))
    (prefix_unary_expression
      (invocation_expression
        function: (member_access_expression
          expression: (predefined_type))))
  ] @assertion.condition
  consequence: [
    (throw_statement)
    (block
      .
      (throw_statement)
      .)
  ]
  !alternative) @assertion.outer

(if_statement
  condition: [
    (binary_expression)
    (is_pattern_expression)
    (identifier)
    (member_access_expression)
    (prefix_unary_expression
      [
        (identifier)
        (member_access_expression)
        (parenthesized_expression)
      ])
    (invocation_expression
      function: (member_access_expression
        expression: (predefined_type)))
    (prefix_unary_expression
      (invocation_expression
        function: (member_access_expression
          expression: (predefined_type))))
  ]
  consequence: [
    (throw_statement
      (object_creation_expression
        arguments: (argument_list
          .
          (argument
            (_) @assertion.message))))
    (block
      .
      (throw_statement
        (object_creation_expression
          arguments: (argument_list
            .
            (argument
              (_) @assertion.message))))
      .)
  ]
  !alternative)

; `ArgumentNullException.ThrowIfNull(x)` and its kin: the runtime builds the message from the
; argument's own expression, so the argument is the message as well as the condition.
((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_exception
    name: (identifier) @_guard)
  arguments: (argument_list
    .
    (argument
      (_) @assertion.condition @assertion.message))) @assertion.outer
  (#any-of? @_exception "ArgumentNullException" "ArgumentException" "ArgumentOutOfRangeException" "ObjectDisposedException")
  (#any-of? @_guard "ThrowIfNull" "ThrowIfNullOrEmpty" "ThrowIfNullOrWhiteSpace" "ThrowIfNegative" "ThrowIfZero" "ThrowIfNegativeOrZero" "ThrowIfGreaterThan" "ThrowIfGreaterThanOrEqual" "ThrowIfLessThan" "ThrowIfLessThanOrEqual" "ThrowIfEqual" "ThrowIfNotEqual" "ThrowIf"))

(catch_clause
  body: (block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed

; A function named as an error handler whose body is empty drops every error passed to it.
((method_declaration
  name: (identifier) @_handler
  body: (block
    .
    "{"
    .
    "}"
    .)) @catch.swallowed
  (#any-word? @_handler "except" "exception" "catch" "rescue" "error" "err"))

; A test in xUnit ([Fact], [Theory]), NUnit ([Test], [TestCase]) or MSTest ([TestMethod]).
((method_declaration
  (attribute_list
    (attribute
      name: (identifier) @_test))) @test.outer
  (#any-of? @_test "Fact" "Theory" "Test" "TestCase" "TestCaseSource" "TestMethod" "DataTestMethod"))

(variable_declaration
  (variable_declarator
    name: (identifier) @assignment.lhs
    .
    (_) @assignment.rhs)) @assignment.outer

(assignment_expression
  left: (_) @assignment.lhs
  right: (_) @assignment.rhs) @assignment.outer

[
  (integer_literal)
  (real_literal)
  (string_literal)
  (verbatim_string_literal)
  (raw_string_literal)
  (character_literal)
  (boolean_literal)
  (null_literal)
] @literal.constant

(null_literal) @literal.falsy

((boolean_literal) @literal.falsy
  (#eq? @literal.falsy "false"))

((integer_literal) @literal.falsy
  (#eq? @literal.falsy "0"))

(null_literal) @literal.none

[
  (initializer_expression)
  (collection_expression)
] @literal.collection

[
  (identifier)
  (member_access_expression)
] @expression.path

(binary_expression
  left: (_) @compare.subject
  operator: "!="
  right: (null_literal)) @compare.not_null

(is_pattern_expression
  expression: (_) @compare.subject
  pattern: (negated_pattern
    (constant_pattern
      (null_literal)))) @compare.not_null

(binary_expression
  left: (_) @compare.subject
  operator: "=="
  right: (_) @compare.value) @compare.equal

[
  (while_statement)
  (do_statement)
  (for_statement)
  (foreach_statement)
] @loop.outer

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

[
  (string_literal)
  (verbatim_string_literal)
  (raw_string_literal)
] @literal.string

; A property's initial value, `= "..."`, or what its getter returns, `=> "..."`.
(property_declaration
  name: (identifier) @assignment.lhs
  value: (arrow_expression_clause
    (_) @assignment.rhs)) @assignment.outer

((property_declaration
  name: (identifier) @assignment.lhs
  value: (_) @assignment.rhs) @assignment.outer
  (#not-kind-eq? @assignment.rhs "arrow_expression_clause"))

; CWE-1071: an empty body with not even a comment. Empty catch bodies are swallowed-error's.
([
  (if_statement
    consequence: (block) @_body)
  (for_statement
    body: (block) @_body)
  (foreach_statement
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
  condition: (boolean_literal)) @finding.constant-condition

(conditional_expression
  condition: (boolean_literal)) @finding.constant-condition

; CWE-1077: exact equality with a floating-point literal other than zero. A decimal literal, `0.1m`,
; is exact, so comparing with one is fine.
((binary_expression
  operator: ["==" "!="]
  right: (real_literal) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0" "0.0f" "0.0d" "0f" "0d" "0.0F" "0.0D" "0D" "0F")
  (#not-any-suffix? @_float "m" "M"))

((binary_expression
  left: (real_literal) @_float
  operator: ["==" "!="]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0." ".0" "0.0f" "0.0d" "0f" "0d" "0.0F" "0.0D" "0D" "0F")
  (#not-any-suffix? @_float "m" "M"))

; CWE-396: catching the root exception types, or everything with a bare `catch`. A `when` filter
; narrows what the catch takes.
((catch_clause
  (catch_declaration
    type: [
      (identifier) @_type
      (qualified_name
        name: (identifier) @_type)
    ])) @finding.generic-catch
  (#any-of? @_type "Exception" "SystemException"))

(catch_clause
  .
  body: (block)) @finding.generic-catch

(catch_clause
  (catch_filter_clause) @unless.generic-catch)

; The message of a thrown exception, for the error-message rules.
([
  (throw_statement
    (object_creation_expression
      arguments: (argument_list
        .
        (argument
          (_) @error.message))))
  (throw_expression
    (object_creation_expression
      arguments: (argument_list
        .
        (argument
          (_) @error.message))))
])

; CWE-783: `!a == b` negates `a`, and `a & b == c` compares before masking.
(binary_expression
  left: (prefix_unary_expression
    "!")
  operator: ["==" "!="]) @finding.precedence-trap

(binary_expression
  operator: ["&" "|" "^"]
  right: (binary_expression
    operator: ["==" "!=" "<" ">" "<=" ">="])) @finding.precedence-trap

(binary_expression
  left: (binary_expression
    operator: ["==" "!=" "<" ">" "<=" ">="])
  operator: ["&" "|" "^"]) @finding.precedence-trap

; CWE-397: throwing the root exception types.
([
  (throw_statement
    (object_creation_expression
      type: (identifier) @_type))
  (throw_expression
    (object_creation_expression
      type: (identifier) @_type))
] @finding.generic-throw
  (#any-of? @_type "Exception" "SystemException" "ApplicationException"))

; CWE-478: a switch without a default label, or a switch expression without a discard arm.
(switch_statement) @finding.missing-default

(switch_section
  "default" @unless.missing-default)

(switch_expression) @finding.missing-default

(switch_expression_arm
  .
  (discard) @unless.missing-default)

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), async methods and calls made as statements (unawaited calls), nesting and decisions.
(binary_expression
  operator: "-") @arith.difference

(binary_expression
  operator: "+") @string.built

(interpolated_string_expression
  (interpolation)) @string.built

((invocation_expression
  function: (member_access_expression
    name: (identifier) @_method)) @string.built
  (#any-of? @_method "Format" "Concat" "Join"))

((method_declaration
  (modifier) @_async
  name: (identifier) @async.name)
  (#eq? @_async "async"))

((local_function_statement
  (modifier) @_async
  name: (identifier) @async.name)
  (#eq? @_async "async"))

(expression_statement
  (invocation_expression
    function: (_) @statement.call))

[
  (if_statement)
  (for_statement)
  (foreach_statement)
  (while_statement)
  (do_statement)
  (try_statement)
  (switch_statement)
  (switch_expression)
] @control.outer

(if_statement
  alternative: (if_statement) @control.chain)

[
  (if_statement)
  (for_statement)
  (foreach_statement)
  (while_statement)
  (do_statement)
  (catch_clause)
  (conditional_expression)
  (switch_section)
  (switch_expression_arm)
] @decision.point

(binary_expression
  operator: ["&&" "||" "??"]) @decision.point

; A local declared as a statement of a block, and the blocks it could move into.
(block
  (local_declaration_statement
    (variable_declaration
      (variable_declarator
        name: (identifier) @declaration.name))) @declaration.outer)

(block) @declaration.block

; Code that runs later, so a local moved into it would be made at a different time.
[
  (lambda_expression)
  (anonymous_method_expression)
  (local_function_statement)
  (declaration_list)
] @declaration.barrier

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (invocation_expression)
  (object_creation_expression)
  (implicit_object_creation_expression)
  (array_creation_expression)
  (assignment_expression)
  (prefix_unary_expression)
  (postfix_unary_expression)
  (await_expression)
] @declaration.effect

; A check a test makes through xUnit, NUnit or MSTest's Assert classes, or FluentAssertions.
((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_assert)) @test.check
  (#any-of? @_assert "Assert" "ClassicAssert" "CollectionAssert" "StringAssert" "FileAssert" "DirectoryAssert"))

((invocation_expression
  function: (member_access_expression
    name: (identifier) @_should)) @test.check
  (#eq? @_should "Should"))

; A test turned off: [Fact(Skip = "...")] in xUnit, [Ignore] in NUnit and MSTest.
((attribute
  (attribute_argument_list
    (attribute_argument
      name: (identifier) @_skip))) @finding.skipped-test
  (#eq? @_skip "Skip"))

((attribute
  name: (identifier) @_ignore) @finding.skipped-test
  (#eq? @_ignore "Ignore"))

; A test that expects any exception at all, so it passes when the code fails for the wrong reason.
((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_assert
    name: (generic_name
      (identifier) @_throws
      (type_argument_list
        (identifier) @_exception)))) @finding.broad-expected-error
  (#any-of? @_assert "Assert" "ClassicAssert")
  (#any-of? @_throws "Throws" "ThrowsAsync" "ThrowsAny" "ThrowsAnyAsync" "ThrowsException" "ThrowsExceptionAsync" "Catch" "CatchAsync")
  (#any-of? @_exception "Exception" "SystemException"))

((attribute
  name: (identifier) @_expected
  (attribute_argument_list
    .
    (attribute_argument
      (typeof_expression
        type: (identifier) @_exception)))) @finding.broad-expected-error
  (#eq? @_expected "ExpectedException")
  (#any-of? @_exception "Exception" "SystemException"))

; A member access, so chains of them can be measured.
(member_access_expression) @chain.link

; Expressions whose copies within a function are duplication: calls, member accesses, indexing
; and arithmetic.
[
  (invocation_expression)
  (member_access_expression)
  (element_access_expression)
  (binary_expression)
] @expression.repeatable

; What an assignment or increment writes to, so an expression that reads it is known to change.
[
  (assignment_expression
    left: (_) @write.target)
  (prefix_unary_expression
    ["++" "--"]
    (_) @write.target)
  (postfix_unary_expression
    (_) @write.target)
]

; A call made for its effect, its value discarded: copies of it each do something.
(expression_statement
  (invocation_expression) @call.discarded)

; A returned value: each early return computes it once, on its own way out.
(return_statement
  (_) @expression.returned)

; Public or protected, so code outside the assembly can use it.
((_
  (modifier) @_visibility) @visibility.public
  (#any-of? @_visibility "public" "protected"))

; Names the code refers to, for dead-symbol: every name other than where it is defined.
(identifier) @reference.name

; Interfaces and abstract classes, and what types implement or extend, for single-impl-abstraction.
(interface_declaration
  name: (identifier) @abstraction.name)

((class_declaration
  (modifier) @_abstract
  name: (identifier) @abstraction.name)
  (#eq? @_abstract "abstract"))

(base_list
  [
    (identifier) @implementation.base
    (generic_name
      (identifier) @implementation.base)
    (qualified_name
      name: (identifier) @implementation.base)
  ])

; Attributed, so a framework can reach it, as [HttpGet], [Fact] and [JsonConstructor] do.
(_
  (attribute_list)) @visibility.public

; `override` and interface members implemented explicitly are reached through their base.
((_
  (modifier) @_override) @visibility.public
  (#eq? @_override "override"))

(method_declaration
  (explicit_interface_specifier)) @visibility.public

; Statements that leave the block they are in, so code holding one can't move into a function.
[
  (return_statement)
  (break_statement)
  (continue_statement)
  (goto_statement)
  (yield_statement)
] @flow.exit

; CWE-369: a literal zero divisor.
((binary_expression
  operator: ["/" "%"]
  right: [(integer_literal) (real_literal)] @_zero_divisor) @finding.divide-by-zero
  (#any-of? @_zero_divisor "0" "00" "0.0" "0." ".0" "0L" "0u" "0U" "0UL" "0ul"))

; CWE-481: assignment used as a condition instead of an equality comparison. Only a bool can be
; assigned there, so `if (done = true)` compiles and always runs.
(if_statement
  condition: (assignment_expression
    operator: "=") @finding.assignment-in-condition)

(while_statement
  condition: (assignment_expression
    operator: "=") @finding.assignment-in-condition)

; CWE-395: catching NullReferenceException in place of a null check.
((catch_clause
  (catch_declaration
    type: [
      (identifier) @_null_exception
      (qualified_name
        name: (identifier) @_null_exception)
    ])) @finding.null-catch
  (#eq? @_null_exception "NullReferenceException"))

; CWE-585: a lock with nothing in it.
((lock_statement
  (block) @_lock_body) @finding.empty-synchronized
  (#empty? @_lock_body))

; CWE-383: a thread made by hand instead of through the thread pool or a hosted service.
((object_creation_expression
  type: (identifier) @_thread_type) @finding.direct-thread
  (#eq? @_thread_type "Thread"))

; CWE-561: the statement right after one that always leaves the block. A label can still be
; jumped to and a local function is declared, not run, so neither is listed.
((block
  (return_statement)
  .
  (_) @finding.unreachable-code)
  (#kind-eq? @finding.unreachable-code "expression_statement" "local_declaration_statement" "if_statement" "for_statement" "foreach_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement" "using_statement" "lock_statement" "yield_statement" "goto_statement"))

((block
  (throw_statement)
  .
  (_) @finding.unreachable-code)
  (#kind-eq? @finding.unreachable-code "expression_statement" "local_declaration_statement" "if_statement" "for_statement" "foreach_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement" "using_statement" "lock_statement" "yield_statement" "goto_statement"))

((block
  (break_statement)
  .
  (_) @finding.unreachable-code)
  (#kind-eq? @finding.unreachable-code "expression_statement" "local_declaration_statement" "if_statement" "for_statement" "foreach_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement" "using_statement" "lock_statement" "yield_statement" "goto_statement"))

((block
  (continue_statement)
  .
  (_) @finding.unreachable-code)
  (#kind-eq? @finding.unreachable-code "expression_statement" "local_declaration_statement" "if_statement" "for_statement" "foreach_statement" "while_statement" "do_statement" "return_statement" "throw_statement" "try_statement" "switch_statement" "break_statement" "continue_statement" "using_statement" "lock_statement" "yield_statement" "goto_statement"))

; CWE-295: a certificate callback that accepts every certificate.
((assignment_expression
  left: [
    (identifier) @_callback
    (member_access_expression
      name: (identifier) @_callback)
  ]
  right: (lambda_expression
    body: (boolean_literal) @_accepts)) @finding.tls-verification-disabled
  (#any-of? @_callback "ServerCertificateCustomValidationCallback" "ServerCertificateValidationCallback" "RemoteCertificateValidationCallback")
  (#eq? @_accepts "true"))

((assignment_expression
  left: [
    (identifier) @_callback
    (member_access_expression
      name: (identifier) @_callback)
  ]
  right: (member_access_expression
    name: (identifier) @_accept_any)) @finding.tls-verification-disabled
  (#eq? @_callback "ServerCertificateCustomValidationCallback")
  (#eq? @_accept_any "DangerousAcceptAnyServerCertificateValidator"))

; A yes/no check of a comparison or of `Equals`, which fails with "Expected: True, Actual: False"
; and hides both sides.
((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_assert
    name: (identifier) @_check)
  arguments: (argument_list
    .
    (argument
      [
        (binary_expression
          left: (_) @opaque.left
          operator: _ @opaque.key
          right: (_) @opaque.right)
        (invocation_expression
          function: (member_access_expression
            expression: (_) @opaque.left
            name: (identifier) @opaque.key)
          arguments: (argument_list
            .
            (argument
              (_) @opaque.right)
            .))
      ])
    .)) @finding.opaque-check
  (#eq? @_assert "Assert")
  (#eq? @_check "True"))

((invocation_expression
  function: (member_access_expression
    expression: (identifier) @_assert
    name: (identifier) @_check)
  arguments: (argument_list
    .
    (argument
      [
        (binary_expression
          left: (_) @opaque.left
          operator: _ @opaque.key
          right: (_) @opaque.right)
        (invocation_expression
          function: (member_access_expression
            expression: (_) @opaque.left
            name: (identifier) @opaque.key)
          arguments: (argument_list
            .
            (argument
              (_) @opaque.right)
            .))
      ])
    .)) @finding.opaque-check @opaque.negated
  (#eq? @_assert "Assert")
  (#eq? @_check "False"))

; CWE-1056: a parameter that takes any number of arguments.
(parameter_list
  "params"
  name: (identifier) @finding.variadic-parameter)

; CWE-1075: a jump to a label. `goto case` and `goto default` move between the sections of one
; switch, as C# requires in place of falling through.
(goto_statement) @finding.goto-statement

(goto_statement
  [
    "case"
    "default"
  ] @unless.goto-statement)

; `DateTime.Now` reads the clock as a call would, though it is written as a property.
((member_access_expression
  expression: (identifier) @call.receiver
  name: (identifier) @call.name) @call.outer
  (#any-of? @call.receiver "DateTime" "DateTimeOffset")
  (#any-of? @call.name "Now" "UtcNow"))

; CWE-111: a method implemented in native code through P/Invoke.
((method_declaration
  (modifier) @_extern) @finding.unsafe-jni
  (#eq? @_extern "extern"))

; CWE-493, CWE-500: a public static field that any caller can reassign. Modifiers may come in any
; order, so each is matched by its text.
((field_declaration
  (modifier) @_first
  (modifier) @_second) @finding.public-static-field
  (#any-of? @_first "public" "static")
  (#any-of? @_second "public" "static")
  (#not-eq? @_first @_second))

((field_declaration
  (modifier) @unless.public-static-field)
  (#any-of? @unless.public-static-field "readonly" "const"))

; CWE-582, CWE-607: a public static readonly array, whose elements anyone can still change.
((field_declaration
  (modifier) @_first
  (modifier) @_second
  (modifier) @_third
  (variable_declaration
    type: (array_type))) @finding.public-static-array
  (#any-of? @_first "public" "static" "readonly")
  (#any-of? @_second "public" "static" "readonly")
  (#any-of? @_third "public" "static" "readonly")
  (#not-eq? @_first @_second)
  (#not-eq? @_first @_third)
  (#not-eq? @_second @_third))

; CWE-486: comparing types by name, `a.GetType().Name == b.GetType().Name`.
((binary_expression
  left: (member_access_expression
    expression: (invocation_expression
      function: [
        (identifier) @_left_get_type
        (member_access_expression
          name: (identifier) @_left_get_type)
      ])
    name: (identifier) @_left_name)
  operator: ["==" "!="]
  right: (member_access_expression
    expression: (invocation_expression
      function: [
        (identifier) @_right_get_type
        (member_access_expression
          name: (identifier) @_right_get_type)
      ])
    name: (identifier) @_right_name)) @finding.class-name-comparison
  (#eq? @_left_get_type "GetType")
  (#eq? @_right_get_type "GetType")
  (#any-of? @_left_name "Name" "FullName")
  (#any-of? @_right_name "Name" "FullName"))

; CWE-581: a class or struct that defines only one side of the Equals/GetHashCode contract.
(([
  (class_declaration
    body: (declaration_list
      (method_declaration
        name: (identifier) @_equals_method
        parameters: (parameter_list
          .
          (parameter)
          .))))
  (struct_declaration
    body: (declaration_list
      (method_declaration
        name: (identifier) @_equals_method
        parameters: (parameter_list
          .
          (parameter)
          .))))
] @finding.equals-without-hashcode)
  (#eq? @_equals_method "Equals"))

((method_declaration
  name: (identifier) @_hash_for_equals) @unless.equals-without-hashcode
  (#eq? @_hash_for_equals "GetHashCode"))

(([
  (class_declaration
    body: (declaration_list
      (method_declaration
        name: (identifier) @_hash_method)))
  (struct_declaration
    body: (declaration_list
      (method_declaration
        name: (identifier) @_hash_method)))
] @finding.hashcode-without-equals)
  (#eq? @_hash_method "GetHashCode"))

((method_declaration
  name: (identifier) @_equals_for_hash) @unless.hashcode-without-equals
  (#eq? @_equals_for_hash "Equals"))

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

; A local declared as a statement of a block, and the blocks it could move into.
(block
  (local_variable_declaration
    declarator: (variable_declarator
      name: (identifier) @declaration.name)) @declaration.outer)

(block) @declaration.block

; Code that runs later, so a local moved into it would be made at a different time.
[
  (lambda_expression)
  (class_body)
] @declaration.barrier

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (method_invocation)
  (object_creation_expression)
  (array_creation_expression)
  (assignment_expression)
  (update_expression)
] @declaration.effect

; A check a test makes through JUnit or AssertJ, so a test's checks can be counted.
((method_invocation
  name: (identifier) @_check) @test.check
  (#any-of? @_check "assertEquals" "assertNotEquals" "assertTrue" "assertFalse" "assertNull" "assertNotNull" "assertSame" "assertNotSame" "assertArrayEquals" "assertIterableEquals" "assertLinesMatch" "assertThrows" "assertDoesNotThrow" "assertTimeout" "assertAll" "assertThat" "fail"))

; A test turned off: JUnit's @Disabled, or @Ignore from JUnit 4.
((marker_annotation
  name: (identifier) @_disabled) @finding.skipped-test
  (#any-of? @_disabled "Disabled" "Ignore"))

((annotation
  name: (identifier) @_disabled) @finding.skipped-test
  (#any-of? @_disabled "Disabled" "Ignore"))

; A test that expects any exception at all, so it passes when the code fails for the wrong reason.
((method_invocation
  name: (identifier) @_throws
  arguments: (argument_list
    .
    (class_literal
      (type_identifier) @_exception))) @finding.broad-expected-error
  (#any-of? @_throws "assertThrows" "assertThrowsExactly")
  (#any-of? @_exception "Exception" "Throwable" "RuntimeException"))

; A member access, so chains of them can be measured.
(field_access) @chain.link

; Expressions whose copies within a function are duplication: calls, member accesses, indexing
; and arithmetic.
[
  (method_invocation)
  (field_access)
  (array_access)
  (binary_expression)
] @expression.repeatable

; What an assignment or increment writes to, so an expression that reads it is known to change.
[
  (assignment_expression
    left: (_) @write.target)
  (update_expression
    (_) @write.target)
]

; A call made for its effect, its value discarded: copies of it each do something.
(expression_statement
  (method_invocation) @call.discarded)

; A returned value: each early return computes it once, on its own way out.
(return_statement
  (_) @expression.returned)

; Public or protected, so code outside the class's package can use it.
(_
  (modifiers
    [
      "public"
      "protected"
    ])) @visibility.public

; Names the code refers to, for dead-symbol: every name other than where it is defined.
[
  (identifier)
  (type_identifier)
] @reference.name

; Interfaces and abstract classes, and what classes implement or extend, for single-impl-abstraction.
(interface_declaration
  name: (identifier) @abstraction.name)

(class_declaration
  (modifiers
    "abstract")
  name: (identifier) @abstraction.name)

(super_interfaces
  (type_list
    [
      (type_identifier) @implementation.base
      (generic_type
        (type_identifier) @implementation.base)
    ]))

(superclass
  [
    (type_identifier) @implementation.base
    (generic_type
      (type_identifier) @implementation.base)
  ])

; Annotated, so a framework can reach it, as @Bean, @GetMapping and @Test do.
(_
  (modifiers
    [
      (marker_annotation)
      (annotation)
    ])) @visibility.public

; Statements that leave the block they are in, so code holding one can't move into a function.
[
  (return_statement)
  (break_statement)
  (continue_statement)
] @flow.exit

; CWE-369: a literal zero divisor.
((binary_expression
  operator: ["/" "%"]
  right: [(decimal_integer_literal) (decimal_floating_point_literal)] @_zero_divisor) @finding.divide-by-zero
  (#any-of? @_zero_divisor "0" "00" "0.0" "0." ".0"))

; CWE-481: assignment used as a condition instead of an equality comparison.
(if_statement
  condition: (parenthesized_expression
    (assignment_expression) @finding.assignment-in-condition))

; Java-specific executable weakness patterns.
((catch_clause
  (catch_formal_parameter
    (catch_type
      (type_identifier) @_null_exception))) @finding.null-catch
  (#eq? @_null_exception "NullPointerException"))

((synchronized_statement
  body: (block) @_synchronized_body) @finding.empty-synchronized
  (#empty? @_synchronized_body))

((method_declaration
  (modifiers "public")
  name: (identifier) @_finalizer) @finding.public-finalizer
  (#eq? @_finalizer "finalize"))

((object_creation_expression
  type: (type_identifier) @_thread_type) @finding.direct-thread
  (#eq? @_thread_type "Thread"))

(method_declaration
  (modifiers "native")) @finding.unsafe-jni

(field_declaration
  (modifiers
    "public"
    "static")) @finding.public-static-field

(field_declaration
  (modifiers
    "static"
    "public")) @finding.public-static-field

(field_declaration
  (modifiers
    "final" @unless.public-static-field))

[
  (field_declaration
    (modifiers "public" "static" "final")
    type: (array_type))
  (field_declaration
    (modifiers "public" "final" "static")
    type: (array_type))
  (field_declaration
    (modifiers "static" "public" "final")
    type: (array_type))
  (field_declaration
    (modifiers "static" "final" "public")
    type: (array_type))
  (field_declaration
    (modifiers "final" "public" "static")
    type: (array_type))
  (field_declaration
    (modifiers "final" "static" "public")
    type: (array_type))
] @finding.public-static-array

; Java lifecycle and object-model contracts whose evidence is wholly inside one expression or
; method. The @unless captures are descendants of the method finding, so patternFinding can cancel
; the absence finding when the required superclass call or final modifier is present.
((method_declaration
  name: (identifier) @_finalize_name
  body: (block)) @finding.missing-super-finalizer
  (#eq? @_finalize_name "finalize"))

((method_invocation
  object: (super)
  name: (identifier) @_super_finalize) @unless.missing-super-finalizer
  (#eq? @_super_finalize "finalize"))

((method_declaration
  name: (identifier) @_clone_name
  body: (block)) @finding.missing-super-clone
  (#eq? @_clone_name "clone"))

((method_invocation
  object: (super)
  name: (identifier) @_super_clone) @unless.missing-super-clone
  (#eq? @_super_clone "clone"))

((method_declaration
  (modifiers "public")
  name: (identifier) @_public_clone) @finding.public-clone-method
  (#eq? @_public_clone "clone"))

((method_declaration
  (modifiers
    "final" @unless.public-clone-method)
  name: (identifier) @_final_clone)
  (#eq? @_final_clone "clone"))

((method_invocation
  object: (object_creation_expression
    type: (type_identifier) @_thread_constructor)
  name: (identifier) @_run_method) @finding.thread-run
  (#eq? @_thread_constructor "Thread")
  (#eq? @_run_method "run"))

; Comparing Class objects by their names can confuse equal simple names from different packages.
((binary_expression
  left: (method_invocation
    object: (method_invocation
      name: (identifier) @_left_get_class)
    name: (identifier) @_left_get_name)
  operator: ["==" "!="]
  right: (method_invocation
    object: (method_invocation
      name: (identifier) @_right_get_class)
    name: (identifier) @_right_get_name)) @finding.class-name-comparison
  (#eq? @_left_get_class "getClass")
  (#eq? @_left_get_name "getName")
  (#eq? @_right_get_class "getClass")
  (#eq? @_right_get_name "getName"))

; A Java class that defines only one side of the equals/hashCode contract.
((class_declaration
  body: (class_body
    (method_declaration
      name: (identifier) @_equals_method))) @finding.equals-without-hashcode
  (#eq? @_equals_method "equals"))

((method_declaration
  name: (identifier) @_hash_for_equals) @unless.equals-without-hashcode
  (#eq? @_hash_for_equals "hashCode"))

((class_declaration
  body: (class_body
    (method_declaration
      name: (identifier) @_hash_method))) @finding.hashcode-without-equals
  (#eq? @_hash_method "hashCode"))

((method_declaration
  name: (identifier) @_equals_for_hash) @unless.hashcode-without-equals
  (#eq? @_equals_for_hash "equals"))

; Struts ActionForm fields must stay behind bean accessors.
((class_declaration
  superclass: (superclass
    (type_identifier) @_action_form)
  body: (class_body
    (field_declaration) @finding.struts-public-field))
  (#eq? @_action_form "ActionForm"))

((field_declaration
  (modifiers
    "private" @unless.struts-public-field)))

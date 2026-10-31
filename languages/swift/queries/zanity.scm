; A function's name is a simple identifier: the grammar also gives its return type the field `name`.
[
  (function_declaration
    name: (simple_identifier) @function.name)
  (init_declaration
    "init" @function.name)
  (deinit_declaration
    "deinit" @function.name)
]

; A closure's parameters are its own, not the enclosing function's.
[
  (function_declaration
    (parameter) @function.parameter)
  (init_declaration
    (parameter) @function.parameter)
]

; A body that is one call, returned or not: Swift returns a lone expression implicitly. A subscript,
; `items[0]`, is a call_expression too, so only a call with parentheses or a closure counts.
(function_declaration
  body: (function_body
    (statements
      .
      [
        (call_expression
          (call_suffix
            (value_arguments
              "(")))
        (control_transfer_statement
          result: (call_expression
            (call_suffix
              (value_arguments
                "("))))
      ]
      .))) @function.passthrough

; A call. The grammar parses a subscript, `items[i]`, as a call_expression whose arguments are in
; brackets, and `defer { }` as a call to `defer` with a trailing closure; neither is a call.
(call_expression
  (call_suffix
    (value_arguments
      "("))) @call.outer

((call_expression
  .
  (_) @_callee
  (call_suffix
    .
    (lambda_literal))) @call.outer
  (#not-eq? @_callee "defer"))

; `Mock<Store>()` and `[Int]()` construct a type written with its arguments.
(constructor_expression) @call.outer

([
  (call_expression
    .
    (_) @call.callee
    (call_suffix
      (value_arguments
        "(")))
  (call_expression
    .
    (_) @call.callee
    (call_suffix
      .
      (lambda_literal)))
]
  (#not-eq? @call.callee "defer"))

; `Date()` and `UUID()` read the clock and make a random identifier, but `Date(timeIntervalSince1970:)`
; and `UUID(uuidString:)` don't, so those two are named as calls only with no arguments.
([
  (call_expression
    .
    (simple_identifier) @call.name
    (call_suffix
      (value_arguments
        "(")))
  (call_expression
    .
    (simple_identifier) @call.name
    (call_suffix
      .
      (lambda_literal)))
]
  (#not-any-of? @call.name "defer" "Date" "UUID"))

((call_expression
  .
  (simple_identifier) @call.name
  (call_suffix
    (value_arguments) @_none
    .))
  (#any-of? @call.name "Date" "UUID")
  (#eq? @_none "()"))

[
  (call_expression
    .
    (navigation_expression
      target: (_) @call.receiver
      suffix: (navigation_suffix
        suffix: (simple_identifier) @call.name))
    (call_suffix
      (value_arguments
        "(")))
  (call_expression
    .
    (navigation_expression
      target: (_) @call.receiver
      suffix: (navigation_suffix
        suffix: (simple_identifier) @call.name))
    (call_suffix
      .
      (lambda_literal)))
]

(constructor_expression
  constructed_type: (user_type
    (type_identifier) @call.name))

; A labelled argument, `retries: 3`, is its value; a trailing closure is an argument too.
(call_expression
  (call_suffix
    (value_arguments
      "("
      (value_argument
        value: (_) @call.argument))))

(call_expression
  (call_suffix
    (lambda_literal) @call.argument))

(constructor_expression
  (constructor_suffix
    (value_arguments
      (value_argument
        value: (_) @call.argument))))

; `Date.now` reads the clock as `Date()` does, though it is written as a property.
((navigation_expression
  target: (simple_identifier) @call.receiver
  suffix: (navigation_suffix
    suffix: (simple_identifier) @call.name)) @call.outer
  (#eq? @call.receiver "Date")
  (#eq? @call.name "now"))

; RSA padding is chosen by naming an algorithm, `.rsaEncryptionPKCS1`, so the name is the call.
((prefix_expression
  target: (simple_identifier) @call.name) @call.outer
  (#eq? @call.name "rsaEncryptionPKCS1"))

((navigation_expression
  target: (simple_identifier) @call.receiver
  suffix: (navigation_suffix
    suffix: (simple_identifier) @call.name)) @call.outer
  (#eq? @call.receiver "SecKeyAlgorithm")
  (#eq? @call.name "rsaEncryptionPKCS1"))

(while_statement
  condition: (_) @loop.condition)

(repeat_while_statement
  condition: (_) @loop.condition)

(for_statement
  collection: (_) @loop.iterable)

((boolean_literal) @literal.true
  (#eq? @literal.true "true"))

; `assert` and `precondition`: the condition, then an optional message.
((call_expression
  .
  (simple_identifier) @_assert
  (call_suffix
    (value_arguments
      .
      (value_argument
        value: (_) @assertion.condition)))) @assertion.outer
  (#any-of? @_assert "assert" "precondition"))

((call_expression
  .
  (simple_identifier) @_assert
  (call_suffix
    (value_arguments
      .
      (value_argument)
      .
      (value_argument
        value: (_) @assertion.message))))
  (#any-of? @_assert "assert" "precondition"))

; A guard that stops the program or throws when its condition fails checks the state as an
; assertion does; a guard that returns or breaks is control flow. Its condition always runs, unlike
; an assert's, so it is not captured as one. The message is fatalError's, or the error thrown.
((guard_statement
  (statements
    .
    [
      (call_expression
        .
        (simple_identifier) @_fail)
      (control_transfer_statement
        (throw_keyword))
    ]
    .)) @assertion.outer
  (#any-of? @_fail "fatalError" "preconditionFailure"))

((guard_statement
  (statements
    .
    (call_expression
      .
      (simple_identifier) @_fail
      (call_suffix
        (value_arguments
          .
          (value_argument
            value: (_) @assertion.message))))
    .))
  (#any-of? @_fail "fatalError" "preconditionFailure"))

(guard_statement
  (statements
    .
    (control_transfer_statement
      (throw_keyword)
      (_) @assertion.message)
    .))

; An empty catch drops the error, and so does `try?` whose optional result nobody reads, except in a
; failable initializer, where `try? self.init(...)` turns the error into the initializer's nil.
(catch_block
  "{"
  .
  "}") @catch.swallowed

((statements
  (try_expression
    (try_operator) @_try
    expr: (_) @_expr) @catch.swallowed)
  (#eq? @_try "try?")
  (#not-any-prefix? @_expr "self.init(" "super.init("))

((assignment
  target: (directly_assignable_expression
    (simple_identifier) @_discard)
  result: (try_expression
    (try_operator) @_try)) @catch.swallowed
  (#eq? @_discard "_")
  (#eq? @_try "try?"))

; A function named as an error handler whose body is empty drops every error passed to it.
((function_declaration
  name: (simple_identifier) @_handler
  body: (function_body
    .
    "{"
    .
    "}"
    .)) @catch.swallowed
  (#any-word? @_handler "except" "exception" "catch" "rescue" "error" "err"))

; A test: an XCTest method, named `test...` and taking nothing, of a class with a superclass or an
; extension; a swift-testing `@Test` function; or a Quick `it("...") { }`.
((class_declaration
  (inheritance_specifier)
  body: (class_body
    (function_declaration
      name: (simple_identifier) @_test
      .
      [
        (throws)
        (function_body)
      ]) @test.outer))
  (#any-prefix? @_test "test"))

((class_declaration
  declaration_kind: "extension"
  body: (class_body
    (function_declaration
      name: (simple_identifier) @_test
      .
      [
        (throws)
        (function_body)
      ]) @test.outer))
  (#any-prefix? @_test "test"))

((function_declaration
  (modifiers
    (attribute
      .
      (user_type
        (type_identifier) @_test)))) @test.outer
  (#eq? @_test "Test"))

((call_expression
  .
  (simple_identifier) @_test
  (call_suffix
    (value_arguments
      .
      (value_argument
        value: (line_string_literal) @test.name)
      .)
    (lambda_literal))) @test.outer
  (#eq? @_test "it"))

; Textobjects capture stored properties and plain assignments; a computed property that returns one
; expression, `var token: String { "..." }`, is added here.
(property_declaration
  name: (pattern
    bound_identifier: (simple_identifier) @assignment.lhs)
  computed_value: (computed_property
    (statements
      .
      (_) @assignment.rhs
      .))) @assignment.outer

(assignment
  operator: [
    "+="
    "-="
    "*="
    "/="
    "%="
  ]) @assignment.compound

[
  (integer_literal)
  (real_literal)
  (hex_literal)
  (oct_literal)
  (bin_literal)
  (boolean_literal)
  (nil_literal)
] @literal.constant

(nil_literal) @literal.falsy

((boolean_literal) @literal.falsy
  (#eq? @literal.falsy "false"))

((integer_literal) @literal.falsy
  (#eq? @literal.falsy "0"))

(nil_literal) @literal.none

[
  (array_literal)
  (dictionary_literal)
] @literal.collection

[
  (simple_identifier)
  (navigation_expression)
] @expression.path

(equality_expression
  lhs: (_) @compare.subject
  op: "!="
  rhs: (nil_literal)) @compare.not_null

(equality_expression
  lhs: (_) @compare.subject
  op: "=="
  rhs: (_) @compare.value) @compare.equal

; Engineering error catalogue rules: each `@finding.<rule>` capture is a finding of that rule.

[
  (line_string_literal)
  (multi_line_string_literal)
  (raw_string_literal)
] @literal.string

; A string with `\(value)` in it is formatted at runtime.
([
  (line_string_literal
    interpolation: (interpolated_expression))
  (multi_line_string_literal
    interpolation: (interpolated_expression))
] @string.format @string.built)

; CWE-1071: an empty body with not even a comment. The grammar gives an empty body no node, so the
; body is empty when its braces are adjacent. An empty `else` is reported at the `else`, not at the
; `if` whose body may be fine.
(if_statement
  "{"
  .
  "}"
  .
  (else)) @finding.empty-block

(if_statement
  "{"
  .
  "}"
  .) @finding.empty-block

(if_statement
  (else) @finding.empty-block
  .
  "{"
  .
  "}")

[
  (while_statement
    "{"
    .
    "}")
  (for_statement
    "{"
    .
    "}")
  (repeat_while_statement
    "{"
    .
    "}")
] @finding.empty-block

; CWE-570, CWE-571: a condition that is a literal. `while true` is unbounded-loop's.
(if_statement
  condition: (boolean_literal)) @finding.constant-condition

(guard_statement
  condition: (boolean_literal)) @finding.constant-condition

(ternary_expression
  condition: (boolean_literal)) @finding.constant-condition

((while_statement
  condition: (boolean_literal) @_value) @finding.constant-condition
  (#eq? @_value "false"))

; CWE-1077: exact equality with a floating-point literal other than zero.
((equality_expression
  op: [
    "=="
    "!="
  ]
  rhs: (real_literal) @_float) @finding.float-equality
  (#not-any-of? @_float "0.0" "0.0e0"))

((equality_expression
  lhs: (real_literal) @_float
  op: [
    "=="
    "!="
  ]) @finding.float-equality
  (#not-any-of? @_float "0.0" "0.0e0"))

; CWE-561: the statement right after one that always leaves the block: a `return` with a value, a
; `throw`, a `break` or a `continue`. A bare `return` takes the next line as its value, and the grammar
; gives `return` before `#else` the directive as its value, so neither is listed; nor is `yield`,
; which an accessor resumes after. Declarations of functions and types are not run either.
((statements
  [
    (control_transfer_statement
      "return"
      result: (_) @_value)
    (control_transfer_statement
      (throw_keyword))
    (control_transfer_statement
      [
        "break"
        "continue"
      ])
  ]
  .
  (_) @finding.unreachable-code)
  (#not-kind-eq? @_value "directive")
  (#kind-eq? @finding.unreachable-code "call_expression" "assignment" "property_declaration" "if_statement" "guard_statement" "for_statement" "while_statement" "repeat_while_statement" "switch_statement" "do_statement" "control_transfer_statement" "try_expression" "await_expression"))

; CWE-295: Alamofire's evaluator that trusts any certificate, and a URLSession challenge answered
; with whatever trust the server presented, unchecked.
((call_expression
  .
  (simple_identifier) @_evaluator) @finding.tls-verification-disabled
  (#any-of? @_evaluator "DisabledTrustEvaluator" "DisabledEvaluator"))

((function_declaration
  name: (simple_identifier) @_session
  body: (function_body
    (statements
      .
      (call_expression
        (call_suffix
          (value_arguments
            .
            (value_argument
              value: (prefix_expression
                target: (simple_identifier) @_use))
            .
            (value_argument
              value: (call_expression
                .
                (simple_identifier) @_credential
                (call_suffix
                  (value_arguments
                    .
                    (value_argument
                      name: (value_argument_label
                        (simple_identifier) @_trust))
                    .))))
            .))) @finding.tls-verification-disabled
      .)))
  (#eq? @_session "urlSession")
  (#eq? @_use "useCredential")
  (#eq? @_credential "URLCredential")
  (#eq? @_trust "trust"))

; Shapes the engine measures or cross-checks: subtractions (wall-clock durations), strings built at
; runtime (SQL), nesting and decisions.
(additive_expression
  op: "-") @arith.difference

(additive_expression
  op: "+") @string.built

((call_expression
  .
  (simple_identifier) @_string
  (call_suffix
    (value_arguments
      .
      (value_argument
        name: (value_argument_label
          (simple_identifier) @_format))))) @string.built
  (#eq? @_string "String")
  (#eq? @_format "format"))

[
  (if_statement)
  (guard_statement)
  (for_statement)
  (while_statement)
  (repeat_while_statement)
  (switch_statement)
  (do_statement)
] @control.outer

(if_statement
  (else)
  .
  (if_statement) @control.chain)

[
  (if_statement)
  (guard_statement)
  (for_statement)
  (while_statement)
  (repeat_while_statement)
  (switch_entry)
  (catch_block)
  (ternary_expression)
  (conjunction_expression)
  (disjunction_expression)
  (nil_coalescing_expression)
] @decision.point

; A local declared as a statement of a block, and the blocks it could move into.
(statements
  (property_declaration
    name: (pattern
      bound_identifier: (simple_identifier) @declaration.name)) @declaration.outer)

(statements) @declaration.block

; Code that runs later, so a local moved into it would be made at a different time.
[
  (lambda_literal)
  (function_declaration)
  (class_declaration)
] @declaration.barrier

; An initializer that can leave the block, so moving it would skip or change what comes after.
[
  (control_transfer_statement)
  (try_expression)
] @declaration.exit

; An initializer that does something besides compute a value, so --fix won't move it.
[
  (call_expression)
  (constructor_expression)
  (macro_invocation)
  (await_expression)
  (try_expression)
  (assignment)
  (lambda_literal)
] @declaration.effect

; A check a test makes: XCTest's XCTAssert family, XCTFail and XCTUnwrap, swift-testing's #expect
; and #require, and Nimble's `expect(x).to(...)`, where the matcher call counts, so an `expect`
; with no matcher checks nothing.
((call_expression
  .
  (simple_identifier) @_check) @test.check
  (#any-prefix? @_check "XCTAssert" "XCTFail" "XCTUnwrap"))

((macro_invocation
  (simple_identifier) @_check) @test.check
  (#any-of? @_check "expect" "require"))

((call_expression
  .
  (navigation_expression
    target: (call_expression
      .
      (simple_identifier) @_expect)
    suffix: (navigation_suffix
      suffix: (simple_identifier) @_check))) @test.check
  (#eq? @_expect "expect")
  (#any-of? @_check "to" "toNot" "notTo" "toEventually" "toEventuallyNot"))

; A test turned off with no condition: XCTest's `throw XCTSkip(...)` as the first statement of the
; body, swift-testing's `.disabled()` or `.disabled("reason")`, and Quick's `xit`. A skip after an
; `if`, a guard or an `#if` says when the test can't run, and so does `XCTSkipIf`, `XCTSkipUnless`,
; `.disabled(if:)` or `.disabled(...)` given anything but a reason, so they are left alone.
((function_body
  (statements
    .
    (control_transfer_statement
      (throw_keyword)
      (call_expression
        .
        (simple_identifier) @_skip)) @finding.skipped-test))
  (#eq? @_skip "XCTSkip"))

((attribute
  .
  (user_type
    (type_identifier) @_test)
  (call_expression
    .
    (prefix_expression
      target: (simple_identifier) @_disabled)
    (call_suffix
      (value_arguments) @_reason)) @finding.skipped-test)
  (#any-of? @_test "Test" "Suite")
  (#eq? @_disabled "disabled")
  (#eq? @_reason "()"))

((attribute
  .
  (user_type
    (type_identifier) @_test)
  (call_expression
    .
    (prefix_expression
      target: (simple_identifier) @_disabled)
    (call_suffix
      (value_arguments
        .
        (value_argument
          value: (line_string_literal))
        .))) @finding.skipped-test)
  (#any-of? @_test "Test" "Suite")
  (#eq? @_disabled "disabled"))

((call_expression
  .
  (simple_identifier) @_skip
  (call_suffix
    (lambda_literal))) @finding.skipped-test
  (#any-of? @_skip "xit" "xdescribe" "xcontext"))

; A test that expects any error at all, so it passes when the code fails for the wrong reason:
; XCTAssertThrowsError without a closure that looks at the error, and `#expect(throws:)` given
; `Error.self` or `(any Error).self`.
((call_expression
  .
  (simple_identifier) @_throws) @finding.broad-expected-error
  (#eq? @_throws "XCTAssertThrowsError"))

((call_expression
  .
  (simple_identifier) @_throws
  (call_suffix
    [
      (lambda_literal) @unless.broad-expected-error
      (value_arguments
        (value_argument
          value: (lambda_literal) @unless.broad-expected-error))
    ]))
  (#eq? @_throws "XCTAssertThrowsError"))

((macro_invocation
  (simple_identifier) @_expect
  (call_suffix
    (value_arguments
      .
      (value_argument
        name: (value_argument_label
          (simple_identifier) @_throws)
        value: (_) @_error)))) @finding.broad-expected-error
  (#eq? @_expect "expect")
  (#eq? @_throws "throws")
  (#any-of? @_error "Error.self" "(any Error).self" "any Error.self"))

; A member access, so chains of them can be measured.
(navigation_expression) @chain.link

; Expressions whose copies within a function are duplication: calls, member accesses, subscripts
; and arithmetic.
[
  (call_expression)
  (navigation_expression)
  (additive_expression)
  (multiplicative_expression)
  (comparison_expression)
  (equality_expression)
  (nil_coalescing_expression)
  (bitwise_operation)
  (infix_expression)
] @expression.repeatable

; What an assignment writes to, so an expression that reads it is known to change. A property
; changed through `self.` or a local is the target the assignment names.
(assignment
  target: (directly_assignable_expression
    (_) @write.target))

; A call made for its effect, its value discarded: copies of it each do something.
[
  (statements
    (call_expression) @call.discarded)
  (statements
    (try_expression
      expr: (call_expression) @call.discarded))
  (statements
    (await_expression
      expr: (call_expression) @call.discarded))
]

; A returned value: each early return computes it once, on its own way out.
(control_transfer_statement
  result: (_) @expression.returned)

; A call whose result something else ends, such as a span: the caller it is returned to, or the
; object it is stored on.
[
  (control_transfer_statement
    result: (call_expression) @call.handed_off)
  (assignment
    target: (directly_assignable_expression
      (navigation_expression))
    result: (call_expression) @call.handed_off)
]

; `public` or `open`, so code outside the module can use it.
((_
  (modifiers
    (visibility_modifier) @_visibility)) @visibility.public
  (#any-of? @_visibility "public" "open"))

; Attributed, so a framework can reach it, as @objc, @IBAction, @Test and @main do, or an override,
; which is reached through its superclass.
(_
  (modifiers
    (attribute))) @visibility.public

((_
  (modifiers
    (member_modifier) @_override)) @visibility.public
  (#eq? @_override "override"))

; A member of a type or extension that inherits or adopts a protocol may implement a requirement,
; which the protocol's callers or runtime reach. A class with a superclass can be reached by name, as
; a storyboard reaches a view controller and XCTest finds a test case.
(class_declaration
  (inheritance_specifier)
  body: (class_body
    [
      (function_declaration)
      (property_declaration)
      (init_declaration)
      (subscript_declaration)
    ] @visibility.public))

(class_declaration
  declaration_kind: "class"
  (inheritance_specifier)) @visibility.public

; Names the code refers to, for dead-symbol: every name other than where it is defined.
[
  (simple_identifier)
  (type_identifier)
] @reference.name

; The type an extension extends, which naming there doesn't keep alive, and the protocols it
; adopts, which only that type, if reachable, keeps alive.
(class_declaration
  declaration_kind: "extension"
  name: (user_type
    (type_identifier) @reference.self))

(class_declaration
  declaration_kind: "extension"
  (inheritance_specifier
    inherits_from: (user_type
      (type_identifier) @reference.held)))

; Protocols, and what types adopt them, for single-impl-abstraction.
(protocol_declaration
  name: (type_identifier) @abstraction.name)

(inheritance_specifier
  inherits_from: (user_type
    (type_identifier) @implementation.base))

; Statements that leave the block they are in, so code holding one can't move into a function.
(control_transfer_statement) @flow.exit

; CWE-369: a literal zero divisor.
((multiplicative_expression
  op: [
    "/"
    "%"
  ]
  rhs: [
    (integer_literal)
    (real_literal)
  ] @_zero_divisor) @finding.divide-by-zero
  (#any-of? @_zero_divisor "0" "00" "0.0" "0x0" "0o0" "0b0"))

; CWE-1056: a parameter that takes any number of arguments, `_ values: Int...`.
(parameter
  name: (simple_identifier) @finding.variadic-parameter
  "...")

; CWE-493, CWE-500: a public static `var` that any caller can reassign. A `let` can't be, and a
; computed property has no storage to replace.
((property_declaration
  (modifiers
    (visibility_modifier) @_public
    (property_modifier) @_static)
  (value_binding_pattern) @_var
  !computed_value) @finding.public-static-field
  (#any-of? @_public "public" "open")
  (#any-of? @_static "static" "class")
  (#eq? @_var "var"))

; CWE-581: a Hashable type with its own `==` but not its own `hash(into:)`. Swift then synthesizes
; the hash from every stored property, so values `==` calls equal can hash differently.
((class_declaration
  (inheritance_specifier
    inherits_from: (user_type
      (type_identifier) @_hashable))
  body: (class_body
    (function_declaration
      name: "=="))) @finding.equals-without-hashcode
  (#eq? @_hashable "Hashable"))

((function_declaration
  name: (simple_identifier) @_hash) @unless.equals-without-hashcode
  (#eq? @_hash "hash"))

((property_declaration
  name: (pattern
    bound_identifier: (simple_identifier) @_hash_value)) @unless.equals-without-hashcode
  (#eq? @_hash_value "hashValue"))

; CWE-383: a thread made by hand instead of through a task or a dispatch queue.
((call_expression
  .
  (navigation_expression
    target: (simple_identifier) @_thread
    suffix: (navigation_suffix
      suffix: (simple_identifier) @_detach))) @finding.direct-thread
  (#eq? @_thread "Thread")
  (#eq? @_detach "detachNewThread"))

((call_expression
  .
  (simple_identifier) @_thread
  (call_suffix
    [
      (value_arguments
        "("
        (value_argument
          name: (value_argument_label)))
      (lambda_literal)
    ])) @finding.direct-thread
  (#eq? @_thread "Thread"))

; CWE-323: a CryptoKit nonce made from fixed bytes: a literal byte array or the bytes of a literal.
((call_expression
  .
  (navigation_expression) @_nonce
  (call_suffix
    (value_arguments
      .
      (value_argument
        name: (value_argument_label
          (simple_identifier) @_data)
        value: [
          (array_literal
            .
            element: [
              (integer_literal)
              (hex_literal)
            ])
          (call_expression
            .
            (simple_identifier) @_bytes
            (call_suffix
              (value_arguments
                .
                (value_argument
                  value: (navigation_expression
                    target: (line_string_literal)))
                .)))
        ] @finding.constant-aead-nonce)
      .)))
  (#any-of? @_nonce "AES.GCM.Nonce" "ChaChaPoly.Nonce")
  (#eq? @_data "data")
  (#any-of? @_bytes "Data" "Array"))

; EXT-VERIFY-004: an attribute that turns a compiler check off: `@preconcurrency` silences
; concurrency diagnostics for what it imports or adopts, `@unchecked Sendable` and
; `nonisolated(unsafe)` turn data-race checking off.
((attribute
  .
  (user_type
    (type_identifier) @_lint_off)
  .) @finding.relaxed-check
  (#any-of? @_lint_off "preconcurrency" "unchecked"))

((member_modifier) @finding.relaxed-check
  (#eq? @finding.relaxed-check "nonisolated(unsafe)"))

; Methods whose parameters something else decides, for dead-parameter: overrides, protocol
; requirements, and the methods of a type or extension that adopts a superclass or protocol, which
; may implement one; attributed methods such as @objc and @IBAction, whose signature a selector or
; the runtime fixes.
((function_declaration
  (modifiers
    (member_modifier) @_override)) @method.override
  (#eq? @_override "override"))

(protocol_declaration
  body: (protocol_body
    (protocol_function_declaration) @method.override))

(class_declaration
  (inheritance_specifier)
  body: (class_body
    (function_declaration) @method.override))

(function_declaration
  (modifiers
    (attribute))) @method.override

; Values checked by common test frameworks, for deterministic test-quality checks.

((call_expression
  . (simple_identifier) @_check
  (call_suffix (value_arguments . (value_argument value: (_) @test.value)))) @test.constant
  (#any-of? @_check "XCTAssert" "XCTAssertTrue" "XCTAssertFalse" "XCTAssertNil" "XCTAssertNotNil"))
((call_expression
  . (simple_identifier) @_check
  (call_suffix (value_arguments . (value_argument value: (_) @test.value) . (value_argument value: (_) @test.value)))) @test.constant
  (#any-of? @_check "XCTAssertEqual" "XCTAssertNotEqual" "XCTAssertIdentical" "XCTAssertNotIdentical" "XCTAssertGreaterThan" "XCTAssertGreaterThanOrEqual" "XCTAssertLessThan" "XCTAssertLessThanOrEqual"))
((macro_invocation
  (simple_identifier) @_check
  (call_suffix (value_arguments . (value_argument value: (_) @test.value)))) @test.constant
  (#any-of? @_check "expect" "require"))

; A yes/no check of a comparison, which fails with "XCTAssertTrue failed" and hides both sides.
; The grammar groups the right side of `a == b && c` as `b && c`, so a comparison whose right side
; is a logical or another comparison is left alone: it doesn't split where it reads. swift-testing's
; `#expect(a == b)` shows both sides already.
((call_expression
  .
  (simple_identifier) @_check
  (call_suffix
    (value_arguments
      .
      (value_argument
        value: [
          (equality_expression
            lhs: (_) @opaque.left
            op: _ @opaque.key
            rhs: (_) @opaque.right)
          (comparison_expression
            lhs: (_) @opaque.left
            op: _ @opaque.key
            rhs: (_) @opaque.right)
        ])))) @finding.opaque-check
  (#any-of? @_check "XCTAssert" "XCTAssertTrue")
  (#not-kind-eq? @opaque.right "conjunction_expression" "disjunction_expression" "ternary_expression" "equality_expression" "comparison_expression"))

((call_expression
  .
  (simple_identifier) @_check
  (call_suffix
    (value_arguments
      .
      (value_argument
        value: [
          (equality_expression
            lhs: (_) @opaque.left
            op: _ @opaque.key
            rhs: (_) @opaque.right)
          (comparison_expression
            lhs: (_) @opaque.left
            op: _ @opaque.key
            rhs: (_) @opaque.right)
        ])))) @finding.opaque-check @opaque.negated
  (#eq? @_check "XCTAssertFalse")
  (#not-kind-eq? @opaque.right "conjunction_expression" "disjunction_expression" "ternary_expression" "equality_expression" "comparison_expression"))

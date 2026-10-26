(import_declaration
  (identifier) @local.definition.import)

(function_declaration
  name: (simple_identifier) @local.definition.function)

; Scopes. A guard's bindings belong to the enclosing scope, which runs on after it.
[
  (statements)
  (for_statement)
  (while_statement)
  (repeat_while_statement)
  (do_statement)
  (if_statement)
  (switch_statement)
  (function_declaration)
  (init_declaration)
  (deinit_declaration)
  (lambda_literal)
  (catch_block)
  (class_declaration)
  (protocol_declaration)
] @local.scope

; Definitions
(pattern
  bound_identifier: (simple_identifier) @local.definition.var)

[
  (if_statement
    bound_identifier: (simple_identifier) @local.definition.var)
  (guard_statement
    bound_identifier: (simple_identifier) @local.definition.var)
  (while_statement
    bound_identifier: (simple_identifier) @local.definition.var)
]

(lambda_parameter
  name: (simple_identifier) @local.definition.var)

; Parameters of functions and initializers; a closure's are its own locals. A parameter's type is
; also its `name`, so only the identifier is the parameter.
[
  (function_declaration
    (parameter
      name: (simple_identifier) @local.definition.parameter))
  (init_declaration
    (parameter
      name: (simple_identifier) @local.definition.parameter))
]

; References
(simple_identifier) @local.reference

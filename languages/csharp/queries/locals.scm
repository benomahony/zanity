; Scopes
(compilation_unit) @local.scope

[
  (class_declaration)
  (struct_declaration)
  (record_declaration)
  (interface_declaration)
  (enum_declaration)
] @local.scope

[
  (method_declaration)
  (constructor_declaration)
  (local_function_statement)
  (lambda_expression)
  (anonymous_method_expression)
] @local.scope

[
  (for_statement)
  (foreach_statement)
  (catch_clause)
  (using_statement)
  (fixed_statement)
  (switch_section)
] @local.scope

(block) @local.scope

; Definitions
(variable_declarator
  .
  (identifier) @local.definition.var)

(variable_declarator
  (tuple_pattern
    (identifier) @local.definition.var))

(declaration_expression
  name: (identifier) @local.definition.var)

(foreach_statement
  left: (identifier) @local.definition.var)

(foreach_statement
  left: (tuple_pattern
    (identifier) @local.definition.var))

(catch_declaration
  name: (identifier) @local.definition.var)

(declaration_pattern
  name: (identifier) @local.definition.var)

; Parameters of methods, constructors and local functions; a lambda's are its own locals.
(_
  parameters: (parameter_list
    (parameter
      name: (identifier) @local.definition.parameter))
  (#not-has-ancestor? @local.definition.parameter lambda_expression))

(_
  parameters: (parameter_list
    name: (identifier) @local.definition.parameter)
  (#not-has-ancestor? @local.definition.parameter lambda_expression))

(lambda_expression
  parameters: [
    (implicit_parameter) @local.definition.var
    (parameter_list
      (parameter
        name: (identifier) @local.definition.var))
  ])

(method_declaration
  name: (identifier) @local.definition.method)

(local_function_statement
  name: (identifier) @local.definition.method)

(property_declaration
  name: (identifier) @local.definition)

(type_parameter
  (identifier) @local.definition.type)

(class_declaration
  name: (identifier) @local.definition)

; References
(identifier) @local.reference

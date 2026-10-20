; Type definitions
(class_declaration name: (identifier) @name) @definition.class

(struct_declaration name: (identifier) @name) @definition.class

(record_declaration name: (identifier) @name) @definition.class

(enum_declaration name: (identifier) @name) @definition.class

(interface_declaration name: (identifier) @name) @definition.interface

; Method definitions
(method_declaration name: (identifier) @name) @definition.method

(local_function_statement name: (identifier) @name) @definition.function

; Constructor definitions
(constructor_declaration name: (identifier) @name) @definition.method

; Base types: `class Foo : Bar, IBaz`
(base_list
  [
    (identifier) @name
    (generic_name (identifier) @name)
  ]) @reference.implementation

; Method calls
(invocation_expression
  function: [
    (identifier) @name
    (generic_name (identifier) @name)
    (member_access_expression name: (identifier) @name)
    (member_access_expression name: (generic_name (identifier) @name))
  ]) @reference.call

(object_creation_expression
  type: [
    (identifier) @name
    (generic_name (identifier) @name)
    (qualified_name name: (identifier) @name)
  ]) @reference.class

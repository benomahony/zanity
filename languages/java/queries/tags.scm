; Class definitions
(class_declaration name: (identifier) @name) @definition.class

; Interface definitions
(interface_declaration name: (identifier) @name) @definition.interface

; Method definitions
(method_declaration name: (identifier) @name) @definition.method

; Constructor definitions
(constructor_declaration name: (identifier) @name) @definition.method

; Class inheritance: `class Foo extends Bar`
(class_declaration
  superclass: (superclass (type_identifier) @name)) @reference.implementation

; Interface implementation: `class Foo implements Bar, Baz`
(class_declaration
  interfaces: (super_interfaces (type_list (type_identifier) @name))) @reference.implementation

; Interface extension: `interface Foo extends Bar, Baz`
(interface_declaration
  (extends_interfaces (type_list (type_identifier) @name))) @reference.implementation

; Method calls
(method_invocation name: (identifier) @name) @reference.call

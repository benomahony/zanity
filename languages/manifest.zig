pub const Entry = struct {
    name: []const u8,
    extensions: []const []const u8,
    ecosystem: []const u8,
    scanner: bool,
    queries: []const []const u8,
    not_applicable: []const []const u8 = &.{},
};

pub const Tables = struct {
    ecosystem: []const u8,
    /// Calls, made bare, that run code no one can review, such as Python's `compile(source, ...)`.
    forbidden_calls: []const []const u8 = &.{},
    /// Methods that run code on any receiver, such as `obj.eval()`; `re.compile` is not one.
    forbidden_methods: []const []const u8 = &.{},
    constant_constructors: []const []const u8 = &.{},
    total_conversions: []const []const u8 = &.{},
    length_calls: []const []const u8 = &.{},
    type_checks: []const []const u8 = &.{},
    null_types: []const []const u8 = &.{},
    /// Methods whose parameters an interface or protocol fixes, such as Python's `__exit__` or
    /// Go's `ServeHTTP`, so a parameter they don't use can't be removed.
    fixed_signatures: []const []const u8 = &.{},
    test_prefixes: []const []const u8 = &.{},
    /// How many words a test's name needs, besides filler such as "test" or "works", to say
    /// what behaviour it expects. Go names a test after the function and its cases in t.Run, so 1.
    test_name_words: u8 = 2,
    sleeps: []const []const u8 = &.{},
    nondeterministic: []const []const u8 = &.{},
    test_doubles: []const []const u8 = &.{},
    /// Calls that check how a test double was called, such as Mockito's `verify(mock)`.
    verification_calls: []const []const u8 = &.{},
    /// Methods, on any receiver, that check how a test double was called, such as
    /// `assert_called_with` or `toHaveBeenCalledWith`.
    verification_methods: []const []const u8 = &.{},
    /// Calls that change state the whole process shares, such as an environment variable or the
    /// working directory, so a test that makes them changes the tests after it.
    process_state_calls: []const []const u8 = &.{},
    /// Calls that read or change the real file system.
    filesystem_calls: []const []const u8 = &.{},
    /// Methods, on any receiver, that read or change the real file system, such as `read_text`.
    filesystem_methods: []const []const u8 = &.{},
    /// Names a test's own temporary directory goes by, such as pytest's `tmp_path`; file system
    /// calls on a path that starts with one are isolated.
    temp_roots: []const []const u8 = &.{},
    /// Calls that make a temporary file or directory the test framework doesn't clean up.
    unmanaged_temp_calls: []const []const u8 = &.{},
    /// Calls that read what someone types, so a test that makes them waits for a person.
    stdin_reads: []const []const u8 = &.{},
    /// Calls that make a real network request or connection.
    network_calls: []const []const u8 = &.{},
    /// Calls that connect to a real database.
    database_calls: []const []const u8 = &.{},
    /// Database names that live only in memory, so a connection to one is isolated.
    in_memory_databases: []const []const u8 = &.{},
    /// Calls that start a real process.
    process_calls: []const []const u8 = &.{},
    /// Names the language or its standard library requires, such as Zig's `format` for `{f}`
    /// or Go's `String`; many types define them, so they are not duplicate names.
    protocol_names: []const []const u8 = &.{},
    /// Calls whose first argument is an error message, such as `logging.error` or `errors.New`.
    error_calls: []const []const u8 = &.{},
    /// Methods whose first argument is an error message on any receiver, such as Rust's `expect`.
    error_methods: []const []const u8 = &.{},
    /// Text that marks a value formatted into a message, such as `{` in Zig or `%` in Go.
    format_markers: []const []const u8 = &.{},
    /// Hash functions too weak to protect anything, such as MD5 and SHA-1.
    weak_hashes: []const []const u8 = &.{},
    /// General-purpose pseudo-random APIs that are documented as unsuitable for security decisions.
    weak_randoms: []const []const u8 = &.{},
    /// Pseudo-random initialisers whose first argument supplies their seed.
    seed_calls: []const []const u8 = &.{},
    /// Regular-expression compilers whose first argument is the pattern.
    regex_calls: []const []const u8 = &.{},
    /// CBC constructors whose IV is respectively their first, second or third argument.
    iv_first_calls: []const []const u8 = &.{},
    iv_second_calls: []const []const u8 = &.{},
    iv_third_calls: []const []const u8 = &.{},
    /// XML parser constructors that accept entity-resolution options.
    xml_entity_calls: []const []const u8 = &.{},
    /// AEAD constructors that accept a nonce as a named option.
    aead_nonce_calls: []const []const u8 = &.{},
    /// Password derivation calls whose second or third argument is the salt.
    password_salt_second_calls: []const []const u8 = &.{},
    password_salt_third_calls: []const []const u8 = &.{},
    /// RSA encryption/decryption APIs that select PKCS#1 v1.5 directly or by transformation text.
    rsa_pkcs1_calls: []const []const u8 = &.{},
    rsa_transformation_calls: []const []const u8 = &.{},
    /// Formatting calls whose format string is their first or second argument.
    format_first_calls: []const []const u8 = &.{},
    format_second_calls: []const []const u8 = &.{},
    /// Redirect APIs whose destination is their first or third argument, and redirect methods
    /// whose receiver type is not available from syntax alone.
    redirect_first_calls: []const []const u8 = &.{},
    redirect_third_calls: []const []const u8 = &.{},
    redirect_first_methods: []const []const u8 = &.{},
    /// XPath evaluators whose expression is their first or second argument, and XPath methods.
    xpath_first_calls: []const []const u8 = &.{},
    xpath_second_calls: []const []const u8 = &.{},
    xpath_first_methods: []const []const u8 = &.{},
    /// LDAP query APIs whose filter is a direct method argument.
    ldap_second_methods: []const []const u8 = &.{},
    ldap_third_methods: []const []const u8 = &.{},
    /// HTTP response APIs whose second method argument is a header value.
    header_second_methods: []const []const u8 = &.{},
    /// Template engines whose caller-supplied source is compiled from a call or method argument.
    template_first_calls: []const []const u8 = &.{},
    template_first_methods: []const []const u8 = &.{},
    template_second_methods: []const []const u8 = &.{},
    /// Expression-language parsers whose first method argument is executable expression text.
    expression_first_methods: []const []const u8 = &.{},
    /// APIs that deliberately treat their first argument as already-safe HTML markup.
    raw_html_first_calls: []const []const u8 = &.{},
    /// Integer parsers whose optional second argument selects the radix.
    integer_parse_calls: []const []const u8 = &.{},
    /// Browser APIs that open a new browsing context and can retain a writable opener.
    window_open_calls: []const []const u8 = &.{},
    /// APIs formally deprecated or removed by the language or its standard library.
    obsolete_calls: []const []const u8 = &.{},
    /// Allocation APIs whose first or second argument controls the amount reserved.
    allocation_size_first_calls: []const []const u8 = &.{},
    allocation_size_second_calls: []const []const u8 = &.{},
    /// Calls that can run code named in the data they read, such as `pickle.loads`.
    unsafe_deserializers: []const []const u8 = &.{},
    /// Calls that choose a temporary path without securely creating it, leaving a race for an attacker.
    insecure_temp_calls: []const []const u8 = &.{},
    /// Calls that terminate the whole process from inside application or container code.
    process_exit_calls: []const []const u8 = &.{},
    /// Methods that explicitly invoke an object's finalizer instead of leaving lifetime to the runtime.
    explicit_finalizer_methods: []const []const u8 = &.{},
    /// Calls that hand their first argument to a shell as a command line.
    shell_calls: []const []const u8 = &.{},
    /// Methods, on any receiver, whose first argument is SQL text, such as `execute`.
    sql_methods: []const []const u8 = &.{},
    /// Calls that write their arguments to a log or the console.
    log_calls: []const []const u8 = &.{},
    /// Wall-clock reads, which jump when the clock is adjusted, so they can't time a duration.
    wall_clocks: []const []const u8 = &.{},
    /// Calls that return something to await, which does nothing unless awaited.
    async_calls: []const []const u8 = &.{},
    /// Calls that stop the program for a debugger or dump its state for one.
    debug_calls: []const []const u8 = &.{},
    mutating_calls: []const []const u8 = &.{},
    self_receivers: []const []const u8 = &.{},
    methods_need_receiver: bool = false,
    /// Whether a name's case says it is exported, as Go's capitalised names are.
    exported_by_case: bool = false,
    /// Whether a call to a capitalised name makes a new object, as `Event()` does in Python.
    constructors_capitalised: bool = false,
    /// Forbidden calls that take an attribute's name second, as `getattr(obj, "name")` does: with a
    /// literal name they are an ordinary, reviewable attribute access.
    attribute_calls: []const []const u8 = &.{},
    /// Generic types written as values, as `dict[str, Any]` is in a `cast()`: a type, not a computation.
    generic_types: []const []const u8 = &.{},
    allocating_calls: []const []const u8 = &.{},
    initializer_prefixes: []const []const u8 = &.{},
    test_file_prefixes: []const []const u8 = &.{},
    test_file_suffixes: []const []const u8 = &.{},
    /// How to write an assertion that explains its failure. `$condition` is the
    /// asserted condition, `$message` its text as a string, `$shown` one
    /// `assertion_value` per value it reads and `$values` those values.
    assertion_form: []const u8 = "",
    /// `assertion_form` for a condition that reads no values.
    assertion_form_bare: []const u8 = "",
    /// How `$shown` presents one value named `$name`.
    assertion_value: []const u8 = "",
    /// Whether `$message` sits in a format string in `assertion_form`, where braces must be doubled.
    assertion_braces_doubled: bool = false,
    /// What starts a comment that runs to the end of the line; fixes leave TODOs with it.
    line_comment: []const u8 = "",
    /// An affix that marks names the language's protocol defines, such as Python's `__name__`.
    protocol_affix: []const u8 = "",
    /// Prefix bytes that mark a name private by convention, such as `_` in Python.
    private_prefixes: []const u8 = "",
};

pub const entries: []const Entry = @import("manifest.zon");
pub const tables: []const Tables = @import("tables.zon");

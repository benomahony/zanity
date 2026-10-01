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
    attribute_calls: []const []const u8 = &.{},
    constant_constructors: []const []const u8 = &.{},
    total_conversions: []const []const u8 = &.{},
    length_calls: []const []const u8 = &.{},
    type_checks: []const []const u8 = &.{},
    null_types: []const []const u8 = &.{},
    test_prefixes: []const []const u8 = &.{},
    sleeps: []const []const u8 = &.{},
    nondeterministic: []const []const u8 = &.{},
    test_doubles: []const []const u8 = &.{},
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
    /// Calls that can run code named in the data they read, such as `pickle.loads`.
    unsafe_deserializers: []const []const u8 = &.{},
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
    protocol_affix: []const u8 = "",
    private_prefixes: []const u8 = "",
    exported_by_case: bool = false,
};

pub const entries: []const Entry = @import("manifest.zon");
pub const tables: []const Tables = @import("tables.zon");

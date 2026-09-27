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
    forbidden_calls: []const []const u8 = &.{},
    constant_constructors: []const []const u8 = &.{},
    total_conversions: []const []const u8 = &.{},
    length_calls: []const []const u8 = &.{},
    type_checks: []const []const u8 = &.{},
    null_types: []const []const u8 = &.{},
    test_prefixes: []const []const u8 = &.{},
    sleeps: []const []const u8 = &.{},
    nondeterministic: []const []const u8 = &.{},
    test_doubles: []const []const u8 = &.{},
    mutating_calls: []const []const u8 = &.{},
    self_receivers: []const []const u8 = &.{},
    methods_need_receiver: bool = false,
    allocating_calls: []const []const u8 = &.{},
    initializer_prefixes: []const []const u8 = &.{},
    test_file_prefixes: []const []const u8 = &.{},
    test_file_suffixes: []const []const u8 = &.{},
};

pub const entries: []const Entry = @import("manifest.zon");
pub const tables: []const Tables = @import("tables.zon");

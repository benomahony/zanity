//! Assertion failures that explain themselves without costing compile time. std.debug.panic
//! parses its format string at comptime, so each of zanity's hundreds of assertions compiled its
//! own copy of std.fmt. Here the template is an ordinary string, read only when an assertion
//! fails, and the arguments become run-time values, so every call shares one formatter.

const std = @import("std");
const Writer = std.Io.Writer;

/// No assertion message needs more values than this.
const max_args = 8;
/// Room for a message and for the values shown with their own format method.
const room = 4096;
/// Ends a message too long for `room`, so a cut is never mistaken for the whole message.
const cut_marker = "... (message cut)";

const Arg = union(enum) {
    int: i128,
    float: f64,
    text: []const u8,
};

/// Panics with `template`'s `{d}`, `{s}`, `{t}`, `{f}`, `{x}` and `{c}` filled from `args` in
/// order, as `std.debug.panic(template, args)` would: `if (!ok) assert.panic("expected {d} got {d}", .{ want, got });`.
pub fn panic(template: []const u8, args: anytype) noreturn {
    if (args.len > max_args) @compileError(std.fmt.comptimePrint("assert.panic shows at most {d} values and was given {d}; split the message or show fewer", .{ max_args, args.len }));
    if (template.len == 0) @panic("assert.panic was given an empty message; say what was expected and what was found instead");
    var scratch: [room]u8 = undefined;
    var shown: Writer = .fixed(&scratch);
    var values: [args.len]Arg = undefined;
    inline for (args, 0..) |arg, i| values[i] = argument(&shown, arg);
    panicWith(template, &values);
}

/// `arg` as a run-time value. A type with a format method is written into `shown` now, so
/// nothing past this point depends on its type.
fn argument(shown: *Writer, arg: anytype) Arg {
    const T = @TypeOf(arg);
    const info = @typeInfo(T);
    if (info == .int and info.int.bits > 64) @compileError("assert.panic shows integers up to 64 bits; " ++ @typeName(T) ++ " is wider, so show it in parts");
    if (info == .pointer and std.meta.Elem(T) != u8) @compileError("assert.panic shows a pointer only as a string, and " ++ @typeName(T) ++ " does not point to bytes; pass the value it points to");
    return switch (info) {
        .int, .comptime_int => .{ .int = arg },
        .float, .comptime_float => .{ .float = arg },
        .@"enum", .enum_literal => .{ .text = @tagName(arg) },
        .error_set => .{ .text = @errorName(arg) },
        .pointer => |p| .{ .text = if (p.size == .many) std.mem.span(arg) else arg },
        .@"struct", .@"union" => if (@hasDecl(T, "format")) shown: {
            const start = shown.end;
            arg.format(shown) catch break :shown .{ .text = "(too long to show)" };
            break :shown .{ .text = shown.buffered()[start..] };
        } else .{ .text = @tagName(arg) },
        else => @compileError("assert.panic cannot show a " ++ @typeName(T) ++ "; pass an integer, float, string, enum, error, or a type with a format method"),
    };
}

noinline fn panicWith(template: []const u8, args: []const Arg) noreturn {
    const placeholders = std.mem.count(u8, template, "{");
    if (placeholders != args.len) std.debug.panic("assert.panic was given {d} values for the {d} placeholders in \"{s}\"; give each placeholder one value", .{ args.len, placeholders, template });
    var buffer: [room]u8 = undefined;
    const message = fillTemplate(&buffer, template, args);
    if (message.len == 0) std.debug.panic("filling \"{s}\" gave an empty message; fillTemplate must copy the template's text", .{template});
    std.debug.panic("{s}", .{message});
}

/// `template` with each placeholder replaced by the next of `args`, ending in `cut_marker` if it
/// does not fit `buffer`.
fn fillTemplate(buffer: []u8, template: []const u8, args: []const Arg) []const u8 {
    if (buffer.len <= cut_marker.len) std.debug.panic("a {d}-byte buffer leaves no room for a message beside \"{s}\"; pass a larger one", .{ buffer.len, cut_marker });
    var w: Writer = .fixed(buffer[0 .. buffer.len - cut_marker.len]);
    const whole = filled: {
        var rest = template;
        for (args) |arg| {
            const open = std.mem.indexOfScalar(u8, rest, '{') orelse std.debug.panic("\"{s}\" has fewer placeholders than its {d} values; give each value a placeholder", .{ template, args.len });
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse std.debug.panic("\"{s}\" opens a placeholder it never closes; close it, as in {{d}}", .{template});
            w.writeAll(rest[0..open]) catch break :filled false;
            writeArg(&w, rest[open + 1 .. close], arg) catch break :filled false;
            rest = rest[close + 1 ..];
        }
        if (std.mem.indexOfScalar(u8, rest, '{') != null) std.debug.panic("\"{s}\" has more placeholders than its {d} values; give each placeholder a value", .{ template, args.len });
        w.writeAll(rest) catch break :filled false;
        break :filled true;
    };
    if (whole) return w.buffered();
    @memcpy(buffer[w.end..][0..cut_marker.len], cut_marker);
    return buffer[0 .. w.end + cut_marker.len];
}

/// One value, checked against its placeholder as std.fmt would at compile time.
fn writeArg(w: *Writer, spec: []const u8, arg: Arg) Writer.Error!void {
    if (spec.len != 1 or std.mem.indexOfScalar(u8, "dstfxc", spec[0]) == null) std.debug.panic("assert.panic has no {{{s}}} placeholder; use {{d}}, {{s}}, {{t}}, {{f}}, {{x}} or {{c}}", .{spec});
    const numeric = spec[0] == 'd' or spec[0] == 'x' or spec[0] == 'c';
    if (numeric != (arg != .text)) std.debug.panic("a {{{s}}} placeholder was given a {t}; use {{d}}, {{x}} or {{c}} for numbers and {{s}}, {{t}} or {{f}} for the rest", .{ spec, arg });
    switch (arg) {
        .int => |n| switch (spec[0]) {
            'x' => try w.print("{x}", .{n}),
            'c' => try w.writeByte(@truncate(@as(u128, @bitCast(n)))),
            else => try w.print("{d}", .{n}),
        },
        .float => |f| if (spec[0] == 'd') try w.print("{d}", .{f}) else std.debug.panic("a {{{s}}} placeholder was given the fraction {d}; show fractions with {{d}}", .{ spec, f }),
        .text => |s| try w.writeAll(s),
    }
}

test "assert.panic's messages read as std.debug.panic's would" {
    var scratch: [64]u8 = undefined;
    var shown: Writer = .fixed(&scratch);
    const version: std.SemanticVersion = .{ .major = 1, .minor = 2, .patch = 3 };
    const args = [_]Arg{ argument(&shown, @as(usize, 3)), argument(&shown, "main.zig"), argument(&shown, std.builtin.OptimizeMode.Debug), argument(&shown, version), argument(&shown, @as(u8, 255)), argument(&shown, @as(u8, 'z')) };
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("3 in main.zig, debug at 1.2.3: ff z", fillTemplate(&buffer, "{d} in {s}, {t} at {f}: {x} {c}", &args));
    var small: [24]u8 = undefined;
    try std.testing.expectEqualStrings("a long ... (message cut)", fillTemplate(&small, "a long message that does not fit", &.{}));
}
